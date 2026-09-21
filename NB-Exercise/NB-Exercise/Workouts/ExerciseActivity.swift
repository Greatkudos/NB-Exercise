//
//  ExerciseActivity.swift
//  NBExercise
//
//  The activity vocabulary, split out of `WorkoutSummary` because it's one of
//  only two files shared with the watch app — see `ExerciseSessionSync` for the
//  other. Keeping it separate means the watch target doesn't drag in the stats
//  types, which are iPhone-only and would never be read there.
//
//  `nonisolated` on the enum and its extensions is load-bearing. The project
//  builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and HealthKit's
//  session delegates — on both platforms — are nonisolated and need to decode
//  an activity before they can hop to the main actor.
//

import Foundation
import HealthKit

/// The kind of activity a workout recorded. A deliberately small subset of
/// `HKWorkoutActivityType` — the handful this app presents — plus `.other` as
/// the catch-all so an unrecognised type from Health never gets dropped.
nonisolated enum ExerciseActivity: String, CaseIterable, Identifiable, Sendable {
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

// MARK: - Codable

/// Hand-written rather than synthesised so that a raw value this build doesn't
/// know lands on `.other` instead of throwing. The two ends of a mirrored
/// session are separate binaries that the user can update independently, so a
/// watch running a newer build really can send an activity this one has never
/// heard of — and losing the whole snapshot over it would stop the countdown.
extension ExerciseActivity: Codable {
    nonisolated init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ExerciseActivity(rawValue: raw) ?? .other
    }
}

// MARK: - HealthKit mapping

extension ExerciseActivity {

    /// The HealthKit type to record as. The inverse of the mapping in
    /// `HealthKitWorkoutStore`, which narrows HealthKit's types down to these.
    var hkWorkoutActivityType: HKWorkoutActivityType {
        switch self {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .hiking: return .hiking
        case .swimming: return .swimming
        case .rowing: return .rowing
        case .elliptical: return .elliptical
        case .strength: return .traditionalStrengthTraining
        case .yoga: return .yoga
        case .coreTraining: return .coreTraining
        case .highIntensityIntervalTraining: return .highIntensityIntervalTraining
        case .other: return .other
        }
    }

    /// Which distance quantity the activity actually produces. Strength work
    /// and yoga have none, so they get nil rather than a misleading zero.
    var distanceQuantityType: HKQuantityType? {
        switch self {
        case .walking, .running, .hiking:
            return HKQuantityType(.distanceWalkingRunning)
        case .cycling:
            return HKQuantityType(.distanceCycling)
        case .swimming:
            return HKQuantityType(.distanceSwimming)
        case .rowing, .elliptical, .strength, .yoga,
             .coreTraining, .highIntensityIntervalTraining, .other:
            return nil
        }
    }

    /// A workout configuration for this activity.
    ///
    /// `.unknown` for location rather than guessing indoor/outdoor: the app
    /// never asks, and a wrong guess changes HealthKit's calorie model.
    var workoutConfiguration: HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = hkWorkoutActivityType
        configuration.locationType = .unknown
        return configuration
    }

    /// Recovers the activity from a configuration handed back by HealthKit —
    /// the path a session launched with `startWatchApp(with:)` arrives on.
    /// Falls back to `.other`, matching the decoding behaviour above.
    init(_ configuration: HKWorkoutConfiguration) {
        let match = ExerciseActivity.allCases.first {
            $0.hkWorkoutActivityType == configuration.activityType
        }
        self = match ?? .other
    }
}
