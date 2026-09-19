//
//  SampleWorkoutStore.swift
//  NBExercise
//
//  A `WorkoutDataSource` backed by canned data. Two jobs:
//
//    1. SwiftUI previews — `HKHealthStore` returns nothing in a preview, so
//       every stats view would otherwise render its empty state.
//    2. The simulator, which has no Health data unless you hand-add some.
//
//  Being a plain value source, it also makes the stats layer unit-testable
//  without a device or a permission prompt.
//

import Foundation

/// Deterministic fake workout history. Dates are generated relative to "now"
/// so the data always looks current, but the shape is fixed.
struct SampleWorkoutStore: WorkoutDataSource {

    var isAvailable: Bool { true }

    func requestAuthorization() async throws -> WorkoutAuthorizationState { .authorized }

    func recentWorkouts(limit: Int) async throws -> [WorkoutSummary] {
        Array(Self.workouts.prefix(limit))
    }

    func totals(in interval: DateInterval) async throws -> ActivityTotals {
        Self.workouts
            .filter { interval.contains($0.start) }
            .reduce(into: ActivityTotals.zero) { totals, workout in
                totals.workoutCount += 1
                totals.totalDuration += workout.duration
                totals.activeEnergyBurnedKilocalories += workout.activeEnergyBurnedKilocalories ?? 0
                totals.distanceMeters += workout.distanceMeters ?? 0
            }
    }

    func dailyRings(days: Int) async throws -> [DailyRings] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // A plausible week: mostly closed rings with one light day, so the UI
        // is exercised with both complete and partial states.
        let movePattern: [Double] = [520, 610, 340, 480, 700, 250, 560]
        let exercisePattern: [Double] = [34, 45, 18, 30, 52, 9, 38]
        let standPattern: [Double] = [12, 13, 9, 11, 14, 7, 12]

        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let index = (days - 1 - offset) % movePattern.count
            return DailyRings(
                date: date,
                activeEnergyBurnedKilocalories: movePattern[index],
                activeEnergyGoalKilocalories: 500,
                exerciseMinutes: exercisePattern[index],
                exerciseGoalMinutes: 30,
                standHours: standPattern[index],
                standGoalHours: 12
            )
        }
    }

    // MARK: - Fixture data

    private static let workouts: [WorkoutSummary] = {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        return [
            WorkoutSummary(
                id: UUID(),
                activity: .running,
                start: ago(3),
                end: ago(3).addingTimeInterval(32 * 60),
                duration: 32 * 60,
                activeEnergyBurnedKilocalories: 348,
                distanceMeters: 5_420,
                averageHeartRate: 152,
                sourceName: "Apple Watch"
            ),
            WorkoutSummary(
                id: UUID(),
                activity: .strength,
                start: ago(27),
                end: ago(27).addingTimeInterval(45 * 60),
                duration: 45 * 60,
                activeEnergyBurnedKilocalories: 262,
                distanceMeters: nil,
                averageHeartRate: 118,
                sourceName: "Apple Watch"
            ),
            WorkoutSummary(
                id: UUID(),
                activity: .cycling,
                start: ago(50),
                end: ago(50).addingTimeInterval(68 * 60),
                duration: 68 * 60,
                activeEnergyBurnedKilocalories: 540,
                distanceMeters: 21_300,
                averageHeartRate: 139,
                sourceName: "iPhone"
            ),
            WorkoutSummary(
                id: UUID(),
                activity: .yoga,
                start: ago(74),
                end: ago(74).addingTimeInterval(25 * 60),
                duration: 25 * 60,
                activeEnergyBurnedKilocalories: 84,
                distanceMeters: nil,
                averageHeartRate: 92,
                sourceName: "Apple Watch"
            ),
            WorkoutSummary(
                id: UUID(),
                activity: .walking,
                start: ago(96),
                end: ago(96).addingTimeInterval(41 * 60),
                duration: 41 * 60,
                activeEnergyBurnedKilocalories: 156,
                distanceMeters: 3_780,
                averageHeartRate: 101,
                sourceName: "iPhone"
            )
        ]
    }()
}
