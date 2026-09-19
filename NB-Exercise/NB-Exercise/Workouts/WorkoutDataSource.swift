//
//  WorkoutDataSource.swift
//  NBExercise
//
//  The read seam. Everything the app displays about past workouts arrives
//  through this protocol, so the stats UI can be driven either by HealthKit
//  (`HealthKitWorkoutStore`) or by canned data (`SampleWorkoutStore`) without
//  knowing the difference.
//

import Foundation

/// Whether the user has been asked for Health access yet, and what came back.
///
/// HealthKit deliberately won't tell you whether *read* permission was
/// granted — that would leak the existence of data the user chose to hide. So
/// `.authorized` here means only "the user has been through the sheet"; an
/// authorised store returning no workouts is indistinguishable from a denied
/// one, and the UI has to treat an empty result as normal either way.
enum WorkoutAuthorizationState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    /// HealthKit isn't present on this device (e.g. some iPads, the simulator
    /// on certain configurations).
    case unavailable
}

/// Read-only access to the user's workout history.
///
/// Implementations are `Sendable` and every call is `async` because HealthKit
/// queries hop off the main actor. Callers are expected to be stores that
/// publish the results, not views calling directly.
protocol WorkoutDataSource: Sendable {
    /// Whether HealthKit is usable at all on this device. Checked before
    /// showing any Health-related affordance.
    var isAvailable: Bool { get }

    /// Presents the Health permission sheet if it hasn't been shown. Safe to
    /// call repeatedly — HealthKit no-ops once the user has answered.
    func requestAuthorization() async throws -> WorkoutAuthorizationState

    /// Most recent workouts, newest first.
    func recentWorkouts(limit: Int) async throws -> [WorkoutSummary]

    /// Aggregate totals for workouts falling inside `interval`.
    func totals(in interval: DateInterval) async throws -> ActivityTotals

    /// Move / Exercise / Stand progress for the last `days` days, oldest
    /// first. Empty when the user has no Apple Watch, since nothing else
    /// writes activity summaries.
    func dailyRings(days: Int) async throws -> [DailyRings]
}

extension WorkoutDataSource {
    /// Totals for the current week, starting on the user's first weekday.
    func totalsForCurrentWeek(calendar: Calendar = .current) async throws -> ActivityTotals {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: Date()) else {
            return .zero
        }
        return try await totals(in: week)
    }
}
