//
//  PodcastPlaybackController.swift
//  NBExercise
//
//  Owns the AVPlayer. Ported from Nexus with two changes:
//
//    1. `@Observable` instead of `ObservableObject`. The periodic time
//       observer fires once a second and touches `currentTime`; with
//       `@Published` that invalidated every observing view, including ones
//       that only read the episode title.
//    2. The `.nexusAudioPlaybackDidStart` cross-player coordination is gone —
//       Nexus had a separate music player to pause against, this app doesn't.
//
//  Everything else is deliberately unchanged, in particular the audio session
//  handling. It already uses the iOS 27 session APIs
//  (`didBecomeInactiveNotification` / `resumptionRecommendationNotification`)
//  rather than the withdrawn interruption began/ended pair, and the retry
//  loop on resume is load-bearing: activation fails while an interrupting app
//  still holds the session.
//
//  Held at app scope so playback survives tab switches — which matters here
//  more than it did in Nexus, since the whole point is listening while the
//  exercise timer runs on another tab.
//

import Foundation
import Observation
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
@Observable
final class PodcastPlaybackController {

    private(set) var currentEpisode: PodcastEpisode?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var artwork: UIImage?
    private(set) var playbackRate: Float = 1.0

    var playbackError: String?

    /// Called roughly once a second with the playing episode's guid and
    /// position, and again on pause/stop. `PodcastStore` coalesces these so
    /// per-second ticks don't thrash SwiftData.
    @ObservationIgnored
    var positionHandler: ((String, TimeInterval) -> Void)?

    /// Called with an episode's guid when it plays to the end.
    @ObservationIgnored
    var finishedHandler: ((String) -> Void)?

    // MARK: - Private state

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var audioSessionConfigured = false
    @ObservationIgnored private var remoteCommandsConfigured = false

    /// Podcasts conventionally skip forward 30 / back 15.
    @ObservationIgnored private let skipForwardInterval: TimeInterval = 30
    @ObservationIgnored private let skipBackwardInterval: TimeInterval = 15

    /// The URL the current item was created from, so the player can be
    /// rebuilt after the media daemon restarts.
    @ObservationIgnored private var currentItemURL: URL?

    /// Whether playback was running when an interruption began. Only then
    /// does the app restart audio once the interruption ends.
    @ObservationIgnored private var wasPlayingBeforeInterruption = false

    /// Set while a resume attempt is retrying, so repeated recommendations
    /// don't stack up overlapping attempts.
    @ObservationIgnored private var isResuming = false

    init() {
        observeAudioSession()
    }

    deinit {
        for token in sessionObservers { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Transport

    /// Starts (or resumes) `episode` from `resumeAt` seconds. `url` is the
    /// downloaded file when available, otherwise the streaming enclosure.
    func play(_ episode: PodcastEpisode, from resumeAt: TimeInterval, url: URL) {
        // Re-tapping the episode already loaded just resumes it.
        if currentEpisode?.guid == episode.guid, let player {
            isPlaying = true
            updateNowPlaying()
            prepareAudioSession { [weak self] in
                guard let self, self.player === player, self.isPlaying else { return }
                player.play()
                self.applyRate()
            }
            return
        }

        teardownCurrentItem()
        playbackError = nil
        artwork = nil
        currentTime = resumeAt
        duration = episode.duration ?? 0

        configureRemoteCommandsIfNeeded()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        currentEpisode = episode
        currentItemURL = url

        if resumeAt > 1 {
            newPlayer.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }

        installTimeObserver(on: newPlayer)
        observeItem(item, guid: episode.guid)
        loadArtwork(for: episode)

        isPlaying = true
        updateNowPlaying()
        prepareAudioSession { [weak self] in
            guard let self, self.player === newPlayer, self.isPlaying else { return }
            newPlayer.play()
            newPlayer.defaultRate = self.playbackRate
            newPlayer.rate = self.playbackRate
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
            // An explicit pause outranks a pending interruption resume.
            wasPlayingBeforeInterruption = false
            reportPosition()
        } else {
            isPlaying = true
            prepareAudioSession { [weak self] in
                guard let self, self.player === player, self.isPlaying else { return }
                player.play()
                self.applyRate()
            }
        }
        updateNowPlaying()
    }

    /// Sets playback speed, applying it immediately when playing. Persists
    /// across episodes until changed.
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        applyRate()
        updateNowPlaying()
    }

    /// Pushes `playbackRate` onto the player. `AVPlayer.rate` doubles as the
    /// play/pause flag, so only apply it while actually playing.
    private func applyRate() {
        guard let player else { return }
        player.defaultRate = playbackRate
        if player.timeControlStatus != .paused {
            player.rate = playbackRate
        }
    }

    func skipForward() { seek(to: currentTime + skipForwardInterval) }
    func skipBackward() { seek(to: max(0, currentTime - skipBackwardInterval)) }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = duration > 0 ? min(seconds, duration) : max(0, seconds)
        player.seek(to: CMTime(seconds: max(0, clamped), preferredTimescale: 600))
        currentTime = max(0, clamped)
        reportPosition()
        updateNowPlaying()
    }

    func stop() {
        reportPosition()
        teardownCurrentItem()
        currentEpisode = nil
        currentItemURL = nil
        wasPlayingBeforeInterruption = false
        isPlaying = false
        currentTime = 0
        duration = 0
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Item lifecycle

    private func observeItem(_ item: AVPlayerItem, guid: String) {
        let center = NotificationCenter.default
        let ended = center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.finishedHandler?(guid)
                self.updateNowPlaying()
            }
        }
        let failed = center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "Playback failed."
            Task { @MainActor [weak self] in self?.playbackError = message }
        }
        itemObservers = [ended, failed]
    }

    private func teardownCurrentItem() {
        removeTimeObserver()
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers.removeAll()
        player?.pause()
        player = nil
    }

    private func installTimeObserver(on player: AVPlayer) {
        removeTimeObserver()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = time.seconds
                // A streamed item's duration isn't known until the asset
                // loads, so adopt it once it becomes finite.
                if let itemDuration = player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.isPlaying = (player.timeControlStatus == .playing)
                self.reportPosition()
                self.updateNowPlaying()
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func reportPosition() {
        guard let guid = currentEpisode?.guid else { return }
        positionHandler?(guid, currentTime)
    }

    // MARK: - Artwork

    private func loadArtwork(for episode: PodcastEpisode) {
        guard let imageURL = episode.imageURL else { return }
        let guid = episode.guid
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: imageURL),
                  let image = UIImage(data: data) else { return }
            await MainActor.run { [weak self] in
                // The user may have moved on while this downloaded.
                guard let self, self.currentEpisode?.guid == guid else { return }
                self.artwork = image
                self.updateNowPlaying()
            }
        }
    }

    // MARK: - Interruptions

    /// Watches the shared audio session so playback survives phone calls,
    /// Siri, navigation prompts, and other apps taking the session. Without
    /// this the system pauses the player and nothing ever restarts it.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // iOS 27 replaced the interruption began/ended pair with these two:
        // the session going inactive *is* the interruption, and the system
        // tells us separately — often much later — when resuming is apt.
        let deactivated = center.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleDeactivation(note) }
        }

        let recommended = center.addObserver(
            forName: AVAudioSession.resumptionRecommendationNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let context = note.userInfo?[AVAudioSession.resumptionContextKey]
                    as? AVAudioSession.ResumptionContext
                guard context?.recommendation == .shouldResume else { return }
                self?.resumeAfterInterruption()
            }
        }

        // A media daemon restart invalidates the player and session config.
        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        }

        sessionObservers = [deactivated, recommended, reset]
    }

    /// The session went inactive. When the *system* did it — a call, Siri,
    /// another app — remember that the episode was playing so the resumption
    /// recommendation can start it again.
    private func handleDeactivation(_ note: Notification) {
        guard let context = note.userInfo?[AVAudioSession.deactivationContextKey]
                as? AVAudioSession.DeactivationContext else { return }
        // Our own `setActive(false)` isn't an interruption.
        guard context.source == .system else { return }

        // AVPlayer pauses itself here, so mirror that and save the position
        // in case playback never comes back.
        let playerWasActive = player.map { $0.timeControlStatus != .paused } ?? false
        wasPlayingBeforeInterruption = isPlaying || playerWasActive
        player?.pause()
        isPlaying = false
        reportPosition()
        updateNowPlaying()
    }

    /// Reactivates the session and restarts the episode. Activation fails
    /// while the interrupting app still holds the session (a call hanging up,
    /// Siri finishing a sentence), so retry a few times before giving up and
    /// leaving it paused for the user to resume by hand.
    private func resumeAfterInterruption() {
        guard wasPlayingBeforeInterruption, !isResuming, currentEpisode != nil else { return }
        isResuming = true
        Task { @MainActor [weak self] in
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
                guard let self, self.wasPlayingBeforeInterruption,
                      self.currentEpisode != nil, let player = self.player else { break }
                guard await self.activateAudioSession() else { continue }
                guard self.wasPlayingBeforeInterruption, self.player === player else { break }
                self.wasPlayingBeforeInterruption = false
                player.play()
                self.applyRate()
                self.isPlaying = true
                self.updateNowPlaying()
                break
            }
            self?.isResuming = false
        }
    }

    /// The media daemon restarted, leaving the player and session config
    /// dead. Rebuild both and carry on if the episode was playing; otherwise
    /// clear out — the position is saved, so re-tapping picks up where it
    /// left off.
    private func handleMediaServicesReset() {
        audioSessionConfigured = false
        let shouldResume = isPlaying || wasPlayingBeforeInterruption
        guard shouldResume, let episode = currentEpisode, let url = currentItemURL else {
            stop()
            return
        }
        let resumeAt = currentTime
        reportPosition()
        teardownCurrentItem()
        currentEpisode = nil
        play(episode, from: resumeAt, url: url)
    }

    // MARK: - Session & remote commands

    /// Configures the session once, then (re)activates it before running
    /// `started`. Activation has to be repeated on every start: an
    /// interruption leaves the session inactive, and playing into an inactive
    /// session is silent.
    ///
    /// `setActive(_:)` blocks its caller until the system hands over the
    /// session — which the audio session warns about on the main thread — so
    /// this goes through the asynchronous activate API instead.
    private func prepareAudioSession(then started: @MainActor @escaping () -> Void) {
        Task { @MainActor in
            _ = await activateAudioSession()
            started()
        }
    }

    /// Activates the session, reporting success. Failure is expected while
    /// another app still holds it, and most callers start playback anyway:
    /// the player stays quiet until the session frees up rather than dropping
    /// the user's tap.
    private func activateAudioSession() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        if !audioSessionConfigured {
            // `.spokenAudio` asks the system to pause podcasts rather than
            // duck them when another app speaks (navigation, Siri) — which is
            // why those arrive here as interruptions to resume from.
            try? session.setCategory(.playback, mode: .spokenAudio, options: [])
            audioSessionConfigured = true
        }
        return await withCheckedContinuation { continuation in
            session.activate(options: []) { activated, _ in
                continuation.resume(returning: activated)
            }
        }
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !remoteCommandsConfigured else { return }
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            self.isPlaying = true
            self.updateNowPlaying()
            self.prepareAudioSession { [weak self] in
                guard let self, self.player === player, self.isPlaying else { return }
                player.play()
                self.applyRate()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player else { return .commandFailed }
            player.pause()
            self.isPlaying = false
            self.wasPlayingBeforeInterruption = false
            self.reportPosition()
            self.updateNowPlaying()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: event.positionTime)
            return .success
        }
        remoteCommandsConfigured = true
    }

    private func updateNowPlaying() {
        guard let episode = currentEpisode else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = episode.title
        info[MPMediaItemPropertyArtist] = episode.feedTitle
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                artwork
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
