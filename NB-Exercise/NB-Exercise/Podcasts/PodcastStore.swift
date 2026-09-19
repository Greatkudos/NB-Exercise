//
//  PodcastStore.swift
//  NBExercise
//
//  The Listen tab's model layer, reworked from Nexus's `PodcastManager` onto
//  SwiftData. Owns three concerns:
//
//    1. Subscriptions — `Subscription` rows keyed by normalised feed URL.
//    2. Episode state — position and played flag per guid, created lazily.
//    3. Catalogue & downloads — episodes are re-parsed from the network and
//       never stored; downloaded audio lives on device only.
//
//  Position writes are coalesced (see `handlePosition`) so per-second
//  playback ticks don't thrash the store.
//
//  Dropped from the Nexus original: sync tombstones, the iCloud backup
//  archive, and per-feed `updatedAt` stamping for last-write-wins merging.
//  None of it applies without multi-device sync, and it was most of the
//  file's complexity.
//

import Foundation
import Observation
import SwiftData
import CryptoKit

@MainActor
@Observable
final class PodcastStore {

    private(set) var subscriptions: [Subscription] = []
    private(set) var episodes: [PodcastEpisode] = []
    private(set) var episodeStates: [String: EpisodeStateInfo] = [:]
    private(set) var catalogState: PodcastCatalogState = .idle

    private(set) var downloads: [String: DownloadRecord] = [:]
    private(set) var downloadingGUIDs: Set<String> = []

    var errorMessage: String?

    /// The ordered playlist driving auto-advance, set when playback starts
    /// from the downloads list. Transient — never persisted.
    private(set) var queue: [PodcastEpisode] = []

    /// Removes a downloaded file once finished, to reclaim space. Persisted
    /// locally.
    var autoDeleteFinishedDownloads: Bool {
        didSet {
            UserDefaults.standard.set(autoDeleteFinishedDownloads, forKey: Self.autoDeleteKey)
        }
    }

    let playback: PodcastPlaybackController

    @ObservationIgnored private let context: ModelContext

    /// Coalesced position writes: latest position per guid, flushed at most
    /// every `flushInterval` seconds while playing.
    @ObservationIgnored private var pendingPositions: [String: TimeInterval] = [:]
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored private let flushInterval: TimeInterval = 10

    /// Identifies the most recent `refresh(feedURL:)`, so a slow fetch that
    /// finishes after a newer one is discarded.
    @ObservationIgnored private var refreshToken = 0

    private static let downloadsKey = "PodcastDownloads"
    private static let autoDeleteKey = "PodcastAutoDeleteFinished"

    var isLoading: Bool { catalogState.isLoading }

    init(context: ModelContext, playback: PodcastPlaybackController) {
        self.context = context
        self.playback = playback
        self.autoDeleteFinishedDownloads =
            UserDefaults.standard.bool(forKey: Self.autoDeleteKey)

        if let data = UserDefaults.standard.data(forKey: Self.downloadsKey),
           let decoded = try? JSONDecoder().decode([String: DownloadRecord].self, from: data) {
            downloads = decoded
        }

        playback.positionHandler = { [weak self] guid, position in
            self?.handlePosition(guid: guid, position: position)
        }
        playback.finishedHandler = { [weak self] guid in
            self?.handleFinished(guid: guid)
        }

        loadSubscriptions()
    }

    // MARK: - URL normalisation

    /// Trims, validates, and upgrades `http://` to `https://` so stored feeds
    /// aren't blocked by App Transport Security, and so the two forms of the
    /// same feed dedupe to one subscription. From Nexus's `RSSFeedManager`.
    static func normalizeFeedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        guard scheme == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return trimmed
        }
        components.scheme = "https"
        return components.url?.absoluteString ?? trimmed
    }

    // MARK: - Subscriptions

    func loadSubscriptions() {
        let descriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.dateAdded, order: .forward)]
        )
        subscriptions = (try? context.fetch(descriptor)) ?? []
    }

    /// Subscribe to a feed, then kick off an initial refresh so metadata and
    /// episodes populate.
    func subscribe(
        feedURL rawURL: String,
        title: String? = nil,
        author: String? = nil,
        imageURL: String? = nil
    ) {
        guard let normalized = Self.normalizeFeedURL(rawURL) else {
            errorMessage = "That doesn't look like a valid feed URL."
            return
        }
        guard subscription(feedURL: normalized) == nil else {
            errorMessage = "You're already subscribed to that podcast."
            return
        }

        context.insert(
            Subscription(
                feedURL: normalized,
                title: title ?? normalized,
                author: author,
                imageURL: imageURL
            )
        )
        save()
        loadSubscriptions()
        Task { await refresh(feedURL: normalized) }
    }

    func unsubscribe(_ subscription: Subscription) {
        context.delete(subscription)
        save()
        loadSubscriptions()
    }

    private func subscription(feedURL: String) -> Subscription? {
        var descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { $0.feedURL == feedURL }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Catalogue (not persisted)

    func refresh(feedURL: String) async {
        guard let url = URL(string: feedURL) else { return }

        refreshToken += 1
        let token = refreshToken

        // Moving to a different show: drop the old catalogue immediately so
        // nothing renders the previous show's episodes while the new feed
        // downloads. Re-refreshing the show already on screen keeps its
        // episodes visible — pull-to-refresh shouldn't blank the list.
        if catalogState.feedURL != feedURL { episodes = [] }
        catalogState = .loading(feedURL: feedURL)

        let channel = await PodcastParser().parseFeed(from: url, feedURL: feedURL)

        // A newer refresh started while this was in flight — easy to do on a
        // poor connection by tapping through shows — so its result wins.
        guard token == refreshToken else { return }

        guard let channel else {
            catalogState = .failed(feedURL: feedURL)
            // With nothing to show, the list presents its own inline "couldn't
            // load" state with a retry; a failed refresh over an already
            // visible list has no other signal, so alert in that case only.
            if !episodes.isEmpty { errorMessage = "Couldn't load that podcast feed." }
            return
        }

        episodes = channel.episodes.sorted { $0.pubDate > $1.pubDate }
        catalogState = .loaded(feedURL: feedURL)
        fillMissingMetadata(feedURL: feedURL, from: channel)
        loadStates(for: channel.episodes.map(\.guid))
    }

    /// Populate a subscription's title/author/artwork from the parsed feed
    /// the first time it's fetched — e.g. when subscribed by bare URL. Only
    /// writes when something was actually missing.
    private func fillMissingMetadata(feedURL: String, from channel: PodcastChannel) {
        guard let row = subscription(feedURL: feedURL) else { return }
        var changed = false

        if (row.title.isEmpty || row.title == feedURL), !channel.title.isEmpty {
            row.title = channel.title
            changed = true
        }
        if row.author == nil, let author = channel.author {
            row.author = author
            changed = true
        }
        if row.imageURL == nil, let image = channel.imageURL?.absoluteString {
            row.imageURL = image
            changed = true
        }

        if changed {
            save()
            loadSubscriptions()
        }
    }

    // MARK: - Episode state

    private func loadStates(for guids: [String]) {
        guard !guids.isEmpty else {
            episodeStates = [:]
            return
        }
        let wanted = Set(guids)
        let descriptor = FetchDescriptor<EpisodeState>(
            predicate: #Predicate { wanted.contains($0.guid) }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        episodeStates = Dictionary(
            rows.map { ($0.guid, $0.info) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func state(for guid: String) -> EpisodeStateInfo {
        episodeStates[guid] ?? .unplayed
    }

    /// Fetch or create the row for a guid. Does not save.
    private func upsertState(guid: String, feedURL: String? = nil) -> EpisodeState {
        var descriptor = FetchDescriptor<EpisodeState>(
            predicate: #Predicate { $0.guid == guid }
        )
        descriptor.fetchLimit = 1

        if let existing = (try? context.fetch(descriptor))?.first {
            if existing.feedURL == nil { existing.feedURL = feedURL }
            existing.updatedAt = .now
            return existing
        }

        let row = EpisodeState(guid: guid, feedURL: feedURL)
        context.insert(row)
        return row
    }

    // MARK: - Playback

    /// Start (or resume) a single episode. Ends any active downloads
    /// playlist so a one-off tap doesn't keep auto-advancing the old queue.
    func playEpisode(_ episode: PodcastEpisode) {
        queue = []
        startPlayback(episode)
    }

    /// Play the downloads list as a playlist, beginning at `record`.
    func playQueue(_ records: [DownloadRecord], startingAt record: DownloadRecord) {
        let items = records.compactMap { downloadedEpisode(for: $0) }
        guard let start = items.first(where: { $0.guid == record.guid }) else { return }
        queue = items
        startPlayback(start)
    }

    /// The shared play path: reads the saved position, prefers a downloaded
    /// file over the stream, applies the show's speed, hands off to the
    /// player. Leaves `queue` alone so callers control playlist context.
    private func startPlayback(_ episode: PodcastEpisode) {
        let info = state(for: episode.guid)
        // A played episode restarts from the beginning; otherwise resume.
        let resumeAt = info.isPlayed ? 0 : info.position
        let url = localURL(for: episode) ?? episode.audioURL
        playback.setPlaybackRate(preferredPlaybackRate(feedURL: episode.feedURL))
        playback.play(episode, from: resumeAt, url: url)
    }

    /// An episode finished: mark it played, then advance to the next item in
    /// the active playlist. A finished episode not in the queue just stops.
    private func handleFinished(guid: String) {
        markPlayed(guid: guid)
        guard let index = queue.firstIndex(where: { $0.guid == guid }),
              index + 1 < queue.count else { return }
        startPlayback(queue[index + 1])
    }

    func preferredPlaybackRate(feedURL: String) -> Float {
        let rate = subscriptions.first { $0.feedURL == feedURL }?.preferredPlaybackRate
        return Float(rate ?? 1.0)
    }

    /// Set the speed for the playing show and remember it for that feed.
    func setPlaybackRate(_ rate: Float) {
        playback.setPlaybackRate(rate)
        guard let feedURL = playback.currentEpisode?.feedURL,
              let row = subscription(feedURL: feedURL),
              row.preferredPlaybackRate != Double(rate) else { return }
        // No-op when unchanged, so dragging the speed slider doesn't write
        // on every intermediate value.
        row.preferredPlaybackRate = Double(rate)
        save()
        loadSubscriptions()
    }

    func markPlayed(guid: String) {
        pendingPositions[guid] = nil
        let row = upsertState(guid: guid)
        row.isPlayed = true
        row.position = 0
        save()
        episodeStates[guid] = EpisodeStateInfo(position: 0, isPlayed: true)

        if autoDeleteFinishedDownloads { deleteDownload(guid: guid) }
    }

    func togglePlayed(guid: String, feedURL: String) {
        let nowPlayed = !state(for: guid).isPlayed
        let row = upsertState(guid: guid, feedURL: feedURL)
        row.isPlayed = nowPlayed
        if nowPlayed { row.position = 0 }
        save()
        episodeStates[guid] = EpisodeStateInfo(
            position: nowPlayed ? 0 : state(for: guid).position,
            isPlayed: nowPlayed
        )
    }

    /// Called ~1×/second by the player. Cached in memory and flushed at most
    /// every `flushInterval` seconds.
    private func handlePosition(guid: String, position: TimeInterval) {
        pendingPositions[guid] = position
        episodeStates[guid] = EpisodeStateInfo(
            position: position,
            isPlayed: episodeStates[guid]?.isPlayed ?? false
        )
        if Date().timeIntervalSince(lastFlush) >= flushInterval { flushPending() }
    }

    /// Write pending positions and save once. Call on background/resign so
    /// the last position isn't lost.
    func flushPending() {
        guard !pendingPositions.isEmpty else { return }

        var feedByGUID = Dictionary(
            episodes.map { ($0.guid, $0.feedURL) },
            uniquingKeysWith: { first, _ in first }
        )
        // The loaded catalogue is whichever show is on screen, which needn't
        // be the one playing — fall back to the playing episode's own feed.
        if let playing = playback.currentEpisode {
            feedByGUID[playing.guid] = playing.feedURL
        }

        for (guid, position) in pendingPositions {
            let row = upsertState(guid: guid, feedURL: feedByGUID[guid])
            row.position = position
        }
        pendingPositions.removeAll()
        lastFlush = Date()
        save()
    }

    // MARK: - Downloads (local only)

    private var downloadsFolder: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        var folder = base.appendingPathComponent("Podcasts", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // Episodes are always re-fetchable from the feed, so keep them out of
        // device and iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }

    /// Deterministic filename: a hash of the guid, keeping it filesystem-safe
    /// and stable across refreshes.
    private func fileName(for episode: PodcastEpisode) -> String {
        let hash = SHA256.hash(data: Data(episode.guid.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = episode.audioURL.pathExtension.isEmpty
            ? "mp3"
            : episode.audioURL.pathExtension
        return "\(hash).\(ext)"
    }

    func localURL(for episode: PodcastEpisode) -> URL? {
        guard downloads[episode.guid] != nil, let folder = downloadsFolder else { return nil }
        let url = folder.appendingPathComponent(fileName(for: episode))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func isDownloaded(_ episode: PodcastEpisode) -> Bool { localURL(for: episode) != nil }

    /// Build a playable episode from a download record, pointing at the
    /// on-disk file — lets the downloads playlist play without that feed's
    /// catalogue loaded. Nil if the file is missing.
    func downloadedEpisode(for record: DownloadRecord) -> PodcastEpisode? {
        guard let folder = downloadsFolder else { return nil }
        let url = folder.appendingPathComponent(record.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let artwork = subscriptions.first { $0.feedURL == record.feedURL }?.imageURL
        return PodcastEpisode(
            guid: record.guid,
            title: record.title,
            summary: "",
            audioURL: url,
            audioType: nil,
            pubDate: Date(),
            duration: nil,
            imageURL: artwork.flatMap { URL(string: $0) },
            feedURL: record.feedURL,
            feedTitle: record.feedTitle
        )
    }

    func download(_ episode: PodcastEpisode) {
        guard let folder = downloadsFolder,
              !downloadingGUIDs.contains(episode.guid),
              localURL(for: episode) == nil else { return }

        downloadingGUIDs.insert(episode.guid)
        let record = DownloadRecord(
            guid: episode.guid,
            title: episode.title,
            feedURL: episode.feedURL,
            feedTitle: episode.feedTitle.isEmpty ? episode.feedURL : episode.feedTitle,
            fileName: fileName(for: episode)
        )
        let destination = folder.appendingPathComponent(record.fileName)
        let source = episode.audioURL

        Task { [weak self] in
            do {
                let (tmp, _) = try await URLSession.shared.download(from: source)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tmp, to: destination)
                await MainActor.run { [weak self] in
                    self?.finishDownload(record, success: true)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.finishDownload(record, success: false)
                    self?.errorMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func finishDownload(_ record: DownloadRecord, success: Bool) {
        downloadingGUIDs.remove(record.guid)
        guard success else { return }
        downloads[record.guid] = record
        persistDownloads()
    }

    func deleteDownload(_ episode: PodcastEpisode) { deleteDownload(guid: episode.guid) }

    func deleteDownload(guid: String) {
        if let record = downloads[guid], let folder = downloadsFolder {
            try? FileManager.default.removeItem(
                at: folder.appendingPathComponent(record.fileName)
            )
        }
        downloads[guid] = nil
        persistDownloads()
    }

    func clearAllDownloads() {
        if let folder = downloadsFolder {
            for record in downloads.values {
                try? FileManager.default.removeItem(
                    at: folder.appendingPathComponent(record.fileName)
                )
            }
        }
        downloads.removeAll()
        persistDownloads()
    }

    /// Downloads grouped by show — the shape the downloads list renders.
    var downloadsByShow: [(feedTitle: String, records: [DownloadRecord])] {
        Dictionary(grouping: downloads.values, by: \.feedTitle)
            .map { (feedTitle: $0.key, records: $0.value.sorted { $0.title < $1.title }) }
            .sorted {
                $0.feedTitle.localizedCaseInsensitiveCompare($1.feedTitle) == .orderedAscending
            }
    }

    /// Every download flattened in display order — the sequence the playlist
    /// plays through.
    var orderedDownloads: [DownloadRecord] { downloadsByShow.flatMap(\.records) }

    func downloadSize(_ record: DownloadRecord) -> Int64 {
        guard let folder = downloadsFolder else { return 0 }
        let url = folder.appendingPathComponent(record.fileName)
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    var totalDownloadSize: Int64 {
        downloads.values.reduce(0) { $0 + downloadSize($1) }
    }

    private func persistDownloads() {
        if let data = try? JSONEncoder().encode(downloads) {
            UserDefaults.standard.set(data, forKey: Self.downloadsKey)
        }
    }

    // MARK: - Search

    /// Look up podcasts by name via the public iTunes Search API, so a show
    /// can be added without hunting down its feed URL.
    func search(_ term: String) async -> [PodcastSearchResult] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/search")
        else { return [] }

        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "term", value: query)
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        else { return [] }

        return decoded.results.compactMap { result in
            guard let feed = result.feedUrl, !feed.isEmpty else { return nil }
            return PodcastSearchResult(
                title: result.collectionName ?? feed,
                author: result.artistName ?? "",
                feedURL: feed,
                artworkURL: result.artworkUrl600.flatMap { URL(string: $0) }
            )
        }
    }

    private struct ITunesSearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let collectionName: String?
            let artistName: String?
            let feedUrl: String?
            let artworkUrl600: String?
        }
    }

    // MARK: - Helpers

    private func save() {
        guard context.hasChanges else { return }
        do { try context.save() }
        catch { errorMessage = "Couldn't save: \(error.localizedDescription)" }
    }
}
