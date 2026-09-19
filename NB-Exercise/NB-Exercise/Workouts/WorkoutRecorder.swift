//
//  WorkoutRecorder.swift
//  NBExercise
//
//  The write seam. `HealthKitWorkoutRecorder` is the live implementation;
//  `ExerciseTimerStore` holds one and calls it at every transport point.
//
//  Two things flow back out of a recorder:
//
//    - `state`, so the timer knows whether a session is live and the view can
//      show the "REC" affordance.
//    - `metrics`, the live figures the Exercise tab renders while the session
//      runs. This is the whole point of recording in-app rather than reading
//      Health after the fact: the Stats tab is a weekly review and only
//      updates on refresh, so nothing there can give feedback mid-session.
//
//  The protocol is `@MainActor` and `Observable`, so a view reading
//  `store.liveMetrics` picks up each update without any plumbing — HealthKit's
//  delegate callbacks arrive off the main actor and hop once, inside the
//  recorder.
//

import Foundation
import Observation

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

/// The live figures for a session in progress.
///
/// Every metric is optional because which ones exist depends on the device and
/// the activity: an iPhone has no heart-rate sensor (that needs a paired Watch
/// or an external monitor), and strength work has no meaningful distance. The
/// UI shows a dash rather than a zero for anything absent — a real 0 bpm and
/// "we can't measure this" are very different claims.
struct LiveWorkoutMetrics: Equatable, Sendable {
    /// Time the session has been collecting, excluding paused stretches. Not
    /// the same as the timer's countdown, which runs against wall-clock time.
    var elapsed: TimeInterval = 0
    var heartRate: Double?
    var activeEnergyBurnedKilocalories: Double?
    var distanceMeters: Double?

    static let empty = LiveWorkoutMetrics()
}

/// Records a workout to HealthKit for the duration of a timed exercise.
@MainActor
protocol WorkoutRecorder: AnyObject, Observable {
    var state: RecordingState { get }

    /// The live figures, updated as HealthKit collects samples. `.empty`
    /// before a session starts.
    var metrics: LiveWorkoutMetrics { get }

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
