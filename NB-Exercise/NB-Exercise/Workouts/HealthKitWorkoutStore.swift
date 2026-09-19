//
//  HealthKitWorkoutStore.swift
//  NBExercise
//
//  The only file in the app that imports HealthKit. Reads workouts and
//  activity summaries written by iPhone, Apple Watch, or any third-party
//  fitness app, and flattens them into the app's own value types.
//
//  Uses the Swift-concurrency query descriptors (`HKSampleQueryDescriptor`,
//  `HKActivitySummaryQueryDescriptor`) rather than the callback-based
//  `HKSampleQuery` family, so there's no completion-handler bridging.
//

import Foundation
import HealthKit

/// Read-only HealthKit access. Conforms to `WorkoutDataSource`, so swapping in
/// `SampleWorkoutStore` for previews changes nothing above this layer.
///
/// `final class` rather than a struct because `HKHealthStore` is reference-
/// typed and should be created once per app — the docs are explicit that
/// long-lived stores are cheaper than per-query ones.
final class HealthKitWorkoutStore: WorkoutDataSource, @unchecked Sendable {

    private let store = HKHealthStore()

    /// Everything the app reads. Workout samples carry their own statistics,
    /// but the underlying quantity types still have to be authorised
    /// individually or `statistics(for:)` comes back empty.
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKObjectType.activitySummaryType()
        ]
        let quantities: [HKQuantityTypeIdentifier] = [
            .activeEnergyBurned,
            .heartRate,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming,
            .appleExerciseTime
        ]
        for identifier in quantities {
            if let type = HKQuantityType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorization

    func requestAuthorization() async throws -> WorkoutAuthorizationState {
        guard isAvailable else { return .unavailable }

        // Read-only: the share set is empty. When recording lands (see
        // `WorkoutRecorder`), `HKQuantityType.workoutType()` joins the share
        // set and this call gains a `toShare:` argument.
        try await store.requestAuthorization(toShare: [], read: readTypes)

        // HealthKit won't reveal read permission — `authorizationStatus(for:)`
        // reports the *share* status, and returns `.sharingDenied` for a
        // read-only request regardless of what the user chose. Deliberate:
        // otherwise an app could detect hidden data by its absence. So the
        // most we can honestly report is that the sheet has been answered.
        return .authorized
    }

    // MARK: - Workouts

    func recentWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        guard isAvailable else { return [] }

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout()],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: limit
        )
        let workouts = try await descriptor.result(for: store)
        return workouts.map(Self.summary(from:))
    }

    func totals(in interval: DateInterval) async throws -> ActivityTotals {
        guard isAvailable else { return .zero }

        // `strictStartDate` keeps a long workout that began before the window
        // from being counted in it — a Sunday-night run shouldn't land in
        // Monday's totals.
        let timePredicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: [.strictStartDate]
        )
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(timePredicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: HKObjectQueryNoLimit
        )
        let workouts = try await descriptor.result(for: store)

        return workouts.reduce(into: ActivityTotals.zero) { totals, workout in
            let summary = Self.summary(from: workout)
            totals.workoutCount += 1
            totals.totalDuration += summary.duration
            totals.activeEnergyBurnedKilocalories += summary.activeEnergyBurnedKilocalories ?? 0
            totals.distanceMeters += summary.distanceMeters ?? 0
        }
    }

    // MARK: - Activity rings

    func dailyRings(days: Int) async throws -> [DailyRings] {
        guard isAvailable, days > 0 else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return []
        }

        // Activity summaries are addressed by date *components*, not dates,
        // and the calendar has to be attached to them or HealthKit can't
        // resolve the range.
        let units: Set<Calendar.Component> = [.day, .month, .year, .era]
        var startComponents = calendar.dateComponents(units, from: start)
        startComponents.calendar = calendar
        var endComponents = calendar.dateComponents(units, from: today)
        endComponents.calendar = calendar

        let predicate = HKQuery.predicate(
            forActivitySummariesBetweenStart: startComponents,
            end: endComponents
        )
        let descriptor = HKActivitySummaryQueryDescriptor(predicate: predicate)
        let summaries = try await descriptor.result(for: store)

        return summaries.compactMap { summary -> DailyRings? in
            guard let date = summary.dateComponents(for: calendar).date else { return nil }

            let kcal = HKUnit.kilocalorie()
            let minutes = HKUnit.minute()
            let count = HKUnit.count()

            // Goals moved to optional quantities in iOS 16 so an unset goal is
            // distinguishable from a zero one. `DailyRings` treats a zero goal
            // as "no progress", so flattening nil to 0 here is safe.
            let exerciseGoal = summary.exerciseTimeGoal?.doubleValue(for: minutes) ?? 0
            let standGoal = summary.standHoursGoal?.doubleValue(for: count) ?? 0

            return DailyRings(
                date: calendar.startOfDay(for: date),
                activeEnergyBurnedKilocalories: summary.activeEnergyBurned.doubleValue(for: kcal),
                activeEnergyGoalKilocalories: summary.activeEnergyBurnedGoal.doubleValue(for: kcal),
                exerciseMinutes: summary.appleExerciseTime.doubleValue(for: minutes),
                exerciseGoalMinutes: exerciseGoal,
                standHours: summary.appleStandHours.doubleValue(for: count),
                standGoalHours: standGoal
            )
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: - Mapping

    /// Flattens an `HKWorkout` into the app's own summary type.
    ///
    /// Reads metrics via `statistics(for:)` rather than the old
    /// `totalEnergyBurned` / `totalDistance` properties, which Apple
    /// deprecated in iOS 18 — the statistics API is also what correctly
    /// handles workouts HealthKit has since condensed into quantity series.
    private static func summary(from workout: HKWorkout) -> WorkoutSummary {
        let activity = ExerciseActivity(workout.workoutActivityType)

        let energy = workout
            .statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())

        let distance = distanceIdentifier(for: activity)
            .flatMap { workout.statistics(for: HKQuantityType($0)) }?
            .sumQuantity()?
            .doubleValue(for: .meter())

        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let heartRate = workout
            .statistics(for: HKQuantityType(.heartRate))?
            .averageQuantity()?
            .doubleValue(for: heartRateUnit)

        return WorkoutSummary(
            id: workout.uuid,
            activity: activity,
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration,
            activeEnergyBurnedKilocalories: energy,
            distanceMeters: distance,
            averageHeartRate: heartRate,
            sourceName: workout.sourceRevision.source.name
        )
    }

    /// Which distance metric is meaningful for an activity. Strength work and
    /// yoga have none, so they return nil rather than a misleading zero.
    private static func distanceIdentifier(
        for activity: ExerciseActivity
    ) -> HKQuantityTypeIdentifier? {
        switch activity {
        case .walking, .running, .hiking:
            return .distanceWalkingRunning
        case .cycling:
            return .distanceCycling
        case .swimming:
            return .distanceSwimming
        case .rowing, .elliptical, .strength, .yoga,
             .coreTraining, .highIntensityIntervalTraining, .other:
            return nil
        }
    }
}

// MARK: - Activity mapping

private extension ExerciseActivity {
    /// Narrows HealthKit's ~80 activity types down to the ones this app
    /// presents. Anything unrecognised becomes `.other` so a workout from a
    /// third-party app is still listed rather than silently dropped.
    init(_ type: HKWorkoutActivityType) {
        switch type {
        case .walking: self = .walking
        case .running: self = .running
        case .cycling: self = .cycling
        case .hiking: self = .hiking
        case .swimming: self = .swimming
        case .rowing: self = .rowing
        case .elliptical: self = .elliptical
        case .traditionalStrengthTraining, .functionalStrengthTraining: self = .strength
        case .yoga: self = .yoga
        case .coreTraining: self = .coreTraining
        case .highIntensityIntervalTraining: self = .highIntensityIntervalTraining
        default: self = .other
        }
    }
}
