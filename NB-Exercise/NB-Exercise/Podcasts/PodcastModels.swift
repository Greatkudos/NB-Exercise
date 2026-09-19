//
//  PodcastModels.swift
//  NBExercise
//
//  Copied from Nexus. Value types describing a parsed podcast feed and its
//  episodes — the transient catalogue re-fetched from the network on each
//  device. Only the subscription list and a small per-episode overlay
//  (playback position / played flag) are persisted; the episode catalogue
//  itself is never stored. See `PodcastPersistence`.
//

import Foundation

/// A single playable episode parsed from a feed's `<item>`.
struct PodcastEpisode: Identifiable, Hashable, Sendable {
    /// Stable identifier — the `<guid>` when present, otherwise the audio
    /// URL. Used as the key for persisted playback state, so it has to stay
    /// stable across refreshes.
    let guid: String
    let title: String
    let summary: String
    /// The enclosure media URL — what actually gets streamed or downloaded.
    let audioURL: URL
    /// MIME type from the enclosure (e.g. `audio/mpeg`), when advertised.
    let audioType: String?
    let pubDate: Date
    /// Length in seconds from `<itunes:duration>`, when present.
    let duration: TimeInterval?
    /// Episode artwork (`<itunes:image>`), falling back to the show's.
    let imageURL: URL?
    let feedURL: String
    let feedTitle: String

    var id: String { guid }

    // Identity is the guid alone: two fetches of the same episode differ in
    // incidental metadata (a corrected title, a new artwork URL) but are the
    // same episode as far as playback state is concerned.
    func hash(into hasher: inout Hasher) { hasher.combine(guid) }
    static func == (lhs: PodcastEpisode, rhs: PodcastEpisode) -> Bool {
        lhs.guid == rhs.guid
    }
}

/// A parsed channel: show-level metadata plus its episodes.
struct PodcastChannel: Sendable {
    let title: String
    let author: String?
    let imageURL: URL?
    let episodes: [PodcastEpisode]
    let feedURL: String
}

/// A result from the iTunes Search API, so a show can be found by name
/// instead of pasting a feed URL.
struct PodcastSearchResult: Identifiable, Hashable, Sendable {
    var id: String { feedURL }
    let title: String
    let author: String
    let feedURL: String
    let artworkURL: URL?
}

/// Lightweight per-episode state driving list badges and resume.
struct EpisodeStateInfo: Hashable, Sendable {
    var position: TimeInterval
    var isPlayed: Bool

    static let unplayed = EpisodeStateInfo(position: 0, isPlayed: false)
}

/// Which show the loaded catalogue belongs to and how it was last left.
///
/// Carrying the feed URL in the state — rather than a bare `isLoading` flag —
/// lets the episode list tell "these episodes are mine" from "these belong to
/// the show I was looking at a moment ago", which matters on a slow
/// connection where a fetch can outlive the selection that started it.
enum PodcastCatalogState: Equatable, Sendable {
    case idle
    case loading(feedURL: String)
    case loaded(feedURL: String)
    case failed(feedURL: String)

    var feedURL: String? {
        switch self {
        case .idle: return nil
        case .loading(let url), .loaded(let url), .failed(let url): return url
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
