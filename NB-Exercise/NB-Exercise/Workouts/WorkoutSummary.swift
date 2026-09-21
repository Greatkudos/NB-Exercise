//
//  WorkoutSummary.swift
//  NBExercise
//
//  The app's own vocabulary for workout data. Nothing above the store layer
//  imports HealthKit: views and stores speak in these value types, and
//  `HealthKitWorkoutStore` is the only place that knows `HKWorkout` exists.
//
//  That indirection is deliberate. It keeps the UI testable against canned
//  data (see `SampleWorkoutStore`), and it means adding workout *recording*
//  later is a new conformance rather than a change to anything on screen.
//
//  `ExerciseActivity` used to live here and now has its own file — it's shared
//  with the watch target, and these stats types aren't.
//

import Foundation

/// One completed workout, flattened to the values this app displays. Energy is
/// in kilocalories and distance in metres — converting to the user's preferred
/// units is a presentation concern, handled at the formatter.
struct WorkoutSummary: Identifiable, Hashable, Sendable {
    /// The HealthKit sample UUID, so a summary stays identifiable across
    /// refetches and can be used to look the original sample back up.
    let id: UUID
    let activity: ExerciseActivity
    let start: Date
    let end: Date
    /// Time actually spent working out, excluding paused stretches — so this
    /// is not always `end.timeIntervalSince(start)`.
    let duration: TimeInterval
    let activeEnergyBurnedKilocalories: Double?
    let distanceMeters: Double?
    let averageHeartRate: Double?
    /// Which device wrote the sample ("Apple Watch", "iPhone", a third-party
    /// app). Surfaced in the UI because it explains why some workouts carry
    /// heart-rate data and others don't.
    let sourceName: String?

    var isFromWatch: Bool {
        sourceName?.localizedCaseInsensitiveContains("watch") ?? false
    }
}

/// Aggregate totals over some window — what the stats header shows.
struct ActivityTotals: Hashable, Sendable {
    var workoutCount: Int = 0
    var totalDuration: TimeInterval = 0
    var activeEnergyBurnedKilocalories: Double = 0
    var distanceMeters: Double = 0

    static let zero = ActivityTotals()
}

/// A single day's Move / Exercise / Stand progress, mirroring the three
/// activity rings. Values and goals are kept separate rather than pre-divided
/// so the UI can show "320 / 500 kcal" as well as the ratio.
struct DailyRings: Identifiable, Hashable, Sendable {
    /// Start of the day the summary covers, in the current calendar.
    let date: Date
    let activeEnergyBurnedKilocalories: Double
    let activeEnergyGoalKilocalories: Double
    let exerciseMinutes: Double
    let exerciseGoalMinutes: Double
    let standHours: Double
    let standGoalHours: Double

    var id: Date { date }

    /// Ring completion clamped to 0...1. A goal of zero means the user hasn't
    /// set one, which reads as "no progress" rather than a divide-by-zero.
    private func fraction(_ value: Double, _ goal: Double) -> Double {
        guard goal > 0 else { return 0 }
        return min(max(value / goal, 0), 1)
    }

    var moveFraction: Double {
        fraction(activeEnergyBurnedKilocalories, activeEnergyGoalKilocalories)
    }
    var exerciseFraction: Double { fraction(exerciseMinutes, exerciseGoalMinutes) }
    var standFraction: Double { fraction(standHours, standGoalHours) }
}
