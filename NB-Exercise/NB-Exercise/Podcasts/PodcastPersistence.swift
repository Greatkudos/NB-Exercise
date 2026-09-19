//
//  PodcastPersistence.swift
//  NBExercise
//
//  The SwiftData layer, replacing Nexus's Core Data entities.
//
//  Two things are persisted and nothing else:
//
//    1. `Subscription` — which shows the user follows, keyed by feed URL.
//    2. `EpisodeState` — playback position and played flag per episode guid.
//
//  The episode catalogue is deliberately *not* stored. It's re-parsed from
//  the feed on demand, which keeps the store small and means a show's back
//  catalogue can't go stale. Nexus made the same call.
//
//  Nexus's tombstone rows are gone: they existed to stop an unsubscribe on
//  one device being resurrected by an iCloud merge from another. With no sync
//  here, a delete is just a delete.
//

import Foundation
import SwiftData

/// A followed podcast. `feedURL` is the identity — normalised on the way in
/// (see `PodcastStore.normalizeFeedURL`) so the same show added via http and
/// https doesn't become two subscriptions.
@Model
final class Subscription {
    /// Normalised feed URL. Unique, so `subscribe` can't create duplicates
    /// even if two calls race.
    @Attribute(.unique) var feedURL: String

    /// Show metadata, filled in from the feed on first successful fetch —
    /// subscribing by bare URL leaves these empty until then.
    var title: String
    var author: String?
    var imageURL: String?

    var dateAdded: Date

    /// Preferred playback speed for this show (1.0 = normal), remembered per
    /// feed so a chosen speed sticks for that podcast.
    var preferredPlaybackRate: Double

    init(
        feedURL: String,
        title: String,
        author: String? = nil,
        imageURL: String? = nil,
        dateAdded: Date = .now,
        preferredPlaybackRate: Double = 1.0
    ) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.imageURL = imageURL
        self.dateAdded = dateAdded
        self.preferredPlaybackRate = preferredPlaybackRate
    }

    /// Display title, falling back to the URL when the feed hasn't been
    /// fetched yet.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? feedURL : trimmed
    }
}

/// Playback state for one episode. Rows are created lazily — an episode the
/// user has never touched has no row, and reads fall back to
/// `EpisodeStateInfo.unplayed`.
@Model
final class EpisodeState {
    @Attribute(.unique) var guid: String

    /// Which feed the episode came from. Nullable because a position can be
    /// written for an episode whose feed isn't the loaded catalogue.
    var feedURL: String?

    /// Seconds into the episode. Written at most every 10 seconds while
    /// playing — see `PodcastStore.flushPending`.
    var position: TimeInterval

    var isPlayed: Bool
    var updatedAt: Date

    init(
        guid: String,
        feedURL: String? = nil,
        position: TimeInterval = 0,
        isPlayed: Bool = false,
        updatedAt: Date = .now
    ) {
        self.guid = guid
        self.feedURL = feedURL
        self.position = position
        self.isPlayed = isPlayed
        self.updatedAt = updatedAt
    }

    var info: EpisodeStateInfo {
        EpisodeStateInfo(position: position, isPlayed: isPlayed)
    }
}

/// Metadata for a downloaded episode, kept on device only. Not a `@Model`:
/// downloads are local by nature and the audio file is the real artifact, so
/// a small JSON blob in `UserDefaults` is a better fit than a store row —
/// this is how Nexus did it too.
struct DownloadRecord: Codable, Hashable, Identifiable {
    let guid: String
    let title: String
    let feedURL: String
    let feedTitle: String
    /// Deterministic on-disk filename — a hash of the guid, so it stays
    /// stable across refreshes and is filesystem-safe.
    let fileName: String

    var id: String { guid }
}
