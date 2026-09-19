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

import Foundation

/// The kind of activity a workout recorded. A deliberately small subset of
/// `HKWorkoutActivityType` — the handful this app presents — plus `.other` as
/// the catch-all so an unrecognised type from Health never gets dropped.
enum ExerciseActivity: String, CaseIterable, Identifiable, Sendable {
    case walking
    case running
    case cycling
    case hiking
    case swimming
    case rowing
    case elliptical
    case strength
    case yoga
    case coreTraining
    case highIntensityIntervalTraining
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .walking: return "Walk"
        case .running: return "Run"
        case .cycling: return "Cycle"
        case .hiking: return "Hike"
        case .swimming: return "Swim"
        case .rowing: return "Row"
        case .elliptical: return "Elliptical"
        case .strength: return "Strength"
        case .yoga: return "Yoga"
        case .coreTraining: return "Core"
        case .highIntensityIntervalTraining: return "HIIT"
        case .other: return "Workout"
        }
    }

    /// SF Symbol matching the activity, reusing Apple's own workout glyphs so
    /// the icons read the same way they do in Fitness.
    var symbolName: String {
        switch self {
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .hiking: return "figure.hiking"
        case .swimming: return "figure.pool.swim"
        case .rowing: return "figure.rower"
        case .elliptical: return "figure.elliptical"
        case .strength: return "figure.strengthtraining.traditional"
        case .yoga: return "figure.yoga"
        case .coreTraining: return "figure.core.training"
        case .highIntensityIntervalTraining: return "figure.highintensity.intervaltraining"
        case .other: return "figure.mixed.cardio"
        }
    }
}

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
