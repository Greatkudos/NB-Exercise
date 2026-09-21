//
//  ExerciseSessionSync.swift
//  NBExercise
//
//  The contract between the watch app and the iPhone app during a mirrored
//  workout — the watch-driven sibling of `ExerciseSessionAttributes`, which
//  does the same job for the Live Activity.
//
//  Why this exists at all: a mirrored `HKWorkoutSession` gives the companion
//  iPhone the session's *state* transitions and nothing else. There is no
//  `HKLiveWorkoutBuilder` on the mirrored side, so heart rate, energy and
//  distance never arrive on their own — the watch has to push them, over
//  `sendToRemoteWorkoutSession(data:)`. This is the shape of what it pushes.
//
//  Two design points worth keeping:
//
//    - Snapshots are whole, not deltas. HealthKit batches these while the
//      iPhone app is backgrounded and delivers the backlog in one go, so a
//      receiver that applied deltas would have to replay history to get
//      current. Applying only the last snapshot in a batch is correct here.
//    - `endDate` travels, as it does to the Live Activity, so the phone can
//      tick its own countdown between snapshots instead of freezing at
//      whatever the last one said. The clock stays smooth even though the
//      watch only pushes every half minute.
//
//  Compiled into both the app and the watch target.
//

import Foundation

/// What the iPhone asks the watch to do. The phone never ends a mirrored
/// session itself: the watch owns the `HKWorkoutSession`, so the buttons on
/// the phone and in the Live Activity are remote controls, and the resulting
/// state arrives back as a snapshot.
nonisolated enum ExerciseSessionCommand: String, Codable, Sendable {
    case pause
    case resume
    /// End now and save what was done.
    case finish
    /// Abandon without saving.
    case discard
}

/// The whole of a running session, as the watch sees it.
nonisolated struct ExerciseSessionSnapshot: Codable, Hashable, Sendable {

    var activity: ExerciseActivity

    /// The session's full length, for the progress ring and to restore the
    /// phone's duration dial.
    var totalDuration: TimeInterval

    /// When the countdown reaches zero, or `nil` while paused or finished.
    var endDate: Date?

    /// Time left on the clock. Authoritative while paused; a fallback while
    /// running, where `endDate` drives the display instead.
    var remaining: TimeInterval

    var isRunning: Bool
    var hasFinished: Bool

    /// Set on the last snapshot of a session, so the phone knows to let go
    /// rather than waiting for updates that will never come. The mirrored
    /// session's `.ended` state covers this too, but that arrives on a
    /// different callback and can race the final metrics.
    var isEnded: Bool = false

    /// Collecting time, excluding paused stretches — the builder's figure,
    /// not the countdown's.
    var elapsed: TimeInterval = 0

    var heartRate: Double?
    var activeEnergyBurnedKilocalories: Double?
    var distanceMeters: Double?
}

// MARK: - Encoding

/// One envelope for both directions, so a `Data` blob arriving on either end
/// is self-describing. HealthKit's remote channel is untyped bytes and will
/// happily deliver a command to the watch and a snapshot to the phone; without
/// a tag, the wrong decode would just throw and the payload would be lost.
nonisolated enum ExerciseSessionMessage: Codable, Sendable {
    case snapshot(ExerciseSessionSnapshot)
    case command(ExerciseSessionCommand)

    /// JSON rather than the `NSKeyedArchiver` Apple's sample uses: these are
    /// Codable value types, and keyed archiving would mean an `NSObject`
    /// subclass and `NSSecureCoding` for no gain at this payload size.
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> ExerciseSessionMessage {
        try JSONDecoder().decode(ExerciseSessionMessage.self, from: data)
    }
}
