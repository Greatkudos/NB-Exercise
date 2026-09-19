//
//  WorkoutRecorder.swift
//  NBExercise
//
//  The write seam — declared now, deliberately unimplemented.
//
//  The app currently only reads from Health. When recording is added, it
//  arrives as a single `HKWorkoutSession`-backed conformance to this protocol,
//  injected into `ExerciseTimerStore`. The timer already calls every hook at
//  the right moment; today they land on `nil` and do nothing.
//
//  Keeping the protocol in the tree — rather than "we'll design it later" —
//  is what makes that true. The timer's control flow is already shaped around
//  a recorder's lifecycle, so turning recording on can't force the timer, the
//  views, or the stats layer to change.
//
//  What a real implementation will need beyond this file:
//    - `HKHealthStore.requestAuthorization(toShare:read:)` including
//      `HKQuantityType.workoutType()` in the share set.
//    - The `com.apple.developer.healthkit` entitlement (already present) plus
//      `NSHealthUpdateUsageDescription` in Info.plist (not yet added — it's
//      only required once the app actually writes).
//    - The `workout-processing` background mode, so the session survives the
//      screen locking mid-exercise.
//

import Foundation

/// Where a recording session currently is. Mirrors `HKWorkoutSessionState`
/// without importing HealthKit, so the timer can switch on it freely.
enum RecordingState: Equatable, Sendable {
    case idle
    case starting
    case running
    case paused
    case ending
    /// The session failed. Carries a message suitable for showing the user —
    /// a recording failure must never silently stop the timer.
    case failed(String)

    var isActive: Bool {
        switch self {
        case .running, .paused, .starting: return true
        case .idle, .ending, .failed: return false
        }
    }
}

/// Records a workout to HealthKit for the duration of a timed exercise.
///
/// Not implemented yet. `ExerciseTimerStore.recorder` is `nil`, and every call
/// site tolerates that.
protocol WorkoutRecorder: AnyObject, Sendable {
    var state: RecordingState { get }

    /// Begins a session for `activity`. Throws rather than trapping so the
    /// timer can carry on running un-recorded if Health refuses.
    func start(_ activity: ExerciseActivity) async throws

    func pause() async
    func resume() async

    /// Ends the session and saves it. Returns the saved workout when one was
    /// written — `nil` when the session was too short to be worth keeping, or
    /// was never started.
    @discardableResult
    func end() async throws -> WorkoutSummary?

    /// Abandons the session without saving. Used when the user resets the
    /// timer rather than letting it finish.
    func discard() async
}
