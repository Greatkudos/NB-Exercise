//
//  ExerciseSessionAttributes.swift
//  NBExercise
//
//  The contract between the app and the Live Activity, compiled into both
//  targets. Everything the wrist needs to render a session has to arrive
//  through here, because the widget extension is a separate process that can
//  see none of the app's stores.
//
//  Two deliberate choices in `ContentState`:
//
//    - `endDate` is carried instead of a pre-formatted countdown string, so
//      the Live Activity can render a self-updating clock with
//      `Text(timerInterval:)`. That ticks on-device with no update from the
//      app, which matters: ActivityKit rate-limits updates, so a Live Activity
//      that pushed a new string every second would be throttled and go stale.
//    - `remaining` is carried *as well*, because a paused session has no end
//      date to count towards and the frozen figure is all there is to show.
//
//  Metrics are optional for the same reason they are in `LiveWorkoutMetrics`:
//  an iPhone has no heart-rate sensor, so a missing value and a zero are
//  different claims and the views render them differently.
//

import ActivityKit
import Foundation

/// `nonisolated` on the conformance is required, not stylistic. The
/// `InferIsolatedConformances` upcoming feature this project builds with would
/// otherwise infer a main-actor-isolated conformance, and ActivityKit hands the
/// attributes to `@concurrent` code — which is a warning today and an error in
/// the Swift 6 language mode.
struct ExerciseSessionAttributes: nonisolated ActivityAttributes {

    /// The part that changes as the session runs.
    struct ContentState: Codable, Hashable {
        /// When the countdown reaches zero, or `nil` while paused or finished.
        var endDate: Date?

        /// Time left on the clock. Authoritative while paused; a fallback for
        /// the running case, where `endDate` drives the display instead.
        var remaining: TimeInterval

        var isRunning: Bool
        var hasFinished: Bool

        var heartRate: Double?
        var activeEnergyBurnedKilocalories: Double?
        var distanceMeters: Double?

        /// The motivation line, or the sign-off once the session finishes.
        var message: String?
    }

    // MARK: - Fixed for the session

    /// e.g. "Walk". Passed as a string rather than an `ExerciseActivity` so
    /// the widget target doesn't need the app's workout types.
    var activityName: String

    /// SF Symbol for the activity, resolved app-side for the same reason.
    var symbolName: String

    /// The session's full length, for the progress ring.
    var totalDuration: TimeInterval
}
