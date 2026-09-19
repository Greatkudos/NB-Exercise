//
//  WorkoutStatsStore.swift
//  NBExercise
//
//  What the Stats tab binds to. Holds the loaded workout data and the
//  authorization state, and drives everything through a `WorkoutDataSource`
//  so it never touches HealthKit directly.
//
//  `@Observable` rather than `ObservableObject`: SwiftUI then invalidates only
//  the views that actually read a given property, instead of every view
//  observing the object.
//

import Foundation
import Observation

@MainActor
@Observable
final class WorkoutStatsStore {

    private(set) var authorization: WorkoutAuthorizationState = .notDetermined
    private(set) var recentWorkouts: [WorkoutSummary] = []
    private(set) var weekTotals: ActivityTotals = .zero
    private(set) var rings: [DailyRings] = []
    private(set) var isLoading = false

    /// Set when a load fails. Surfaced as an inline message rather than an
    /// alert — a Health read failing shouldn't interrupt a workout in
    /// progress on another tab.
    private(set) var errorMessage: String?

    private let source: WorkoutDataSource

    /// How many workouts the recent list shows, and how many days of rings to
    /// fetch. A week of rings matches the row of day circles in the header.
    private let recentLimit = 20
    private let ringDays = 7

    init(source: WorkoutDataSource) {
        self.source = source
    }

    var isAvailable: Bool { source.isAvailable }

    /// True once a load has completed and found nothing. Distinct from
    /// "haven't loaded yet", so the UI doesn't flash an empty state while the
    /// first query is still running.
    var hasLoadedEmpty: Bool {
        !isLoading && authorization == .authorized && recentWorkouts.isEmpty
    }

    /// Asks for Health access, then loads. Safe to call on every appearance —
    /// HealthKit only shows the sheet once.
    func requestAccessAndLoad() async {
        guard source.isAvailable else {
            authorization = .unavailable
            return
        }
        do {
            authorization = try await source.requestAuthorization()
        } catch {
            authorization = .denied
            errorMessage = "Couldn't get access to Health: \(error.localizedDescription)"
            return
        }
        await load()
    }

    /// Refetches everything. The three queries are independent, so they run
    /// concurrently and the view updates once when all three land.
    func load() async {
        guard source.isAvailable else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let workouts = source.recentWorkouts(limit: recentLimit)
            async let totals = source.totalsForCurrentWeek()
            async let dailyRings = source.dailyRings(days: ringDays)

            let (loadedWorkouts, loadedTotals, loadedRings) =
                try await (workouts, totals, dailyRings)

            recentWorkouts = loadedWorkouts
            weekTotals = loadedTotals
            rings = loadedRings
        } catch {
            errorMessage = "Couldn't read workout data: \(error.localizedDescription)"
        }
    }

    /// Today's rings, when the Watch has written a summary for today.
    var todayRings: DailyRings? {
        let today = Calendar.current.startOfDay(for: Date())
        return rings.first { Calendar.current.isDate($0.date, inSameDayAs: today) }
    }

    /// Recent workouts bucketed by day, newest day first — the shape the list
    /// renders as sections.
    var workoutsByDay: [(day: Date, workouts: [WorkoutSummary])] {
        let calendar = Calendar.current
        return Dictionary(grouping: recentWorkouts) { calendar.startOfDay(for: $0.start) }
            .map { (day: $0.key, workouts: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }
}
