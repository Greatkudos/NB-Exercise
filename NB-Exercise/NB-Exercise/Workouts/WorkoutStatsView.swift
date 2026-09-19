//
//  WorkoutStatsView.swift
//  NBExercise
//
//  The Stats tab: this week's totals, a week of activity rings, and the
//  recent workout list grouped by day.
//
//  Reads only from `WorkoutStatsStore`, so it renders identically whether the
//  data came from HealthKit or `SampleWorkoutStore`.
//

import SwiftUI

struct WorkoutStatsView: View {
    @State private var store: WorkoutStatsStore

    init(store: WorkoutStatsStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !store.isAvailable {
                    unavailableState
                } else {
                    content
                }
            }
            .navigationTitle("Stats")
            .task {
                // HealthKit only presents the sheet once, so this is safe on
                // every appearance and covers the user granting access in
                // Settings after first declining.
                await store.requestAccessAndLoad()
            }
            .refreshable { await store.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            if let message = store.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }

            Section("This Week") {
                weekTotals
            }

            if !store.rings.isEmpty {
                Section("Activity") {
                    ringsRow
                }
            }

            if store.hasLoadedEmpty {
                Section {
                    emptyState
                }
            } else {
                ForEach(store.workoutsByDay, id: \.day) { group in
                    Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(group.workouts) { workout in
                            WorkoutRow(workout: workout)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Week totals

    private var weekTotals: some View {
        // An adaptive grid so the four tiles sit two-up on iPhone and
        // four-up on iPad without a size-class branch.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), spacing: 12)],
            spacing: 12
        ) {
            StatTile(
                title: "Workouts",
                value: "\(store.weekTotals.workoutCount)",
                symbol: "figure.mixed.cardio"
            )
            StatTile(
                title: "Time",
                value: Format.duration(store.weekTotals.totalDuration),
                symbol: "clock"
            )
            StatTile(
                title: "Energy",
                value: Format.energy(store.weekTotals.activeEnergyBurnedKilocalories),
                symbol: "flame"
            )
            StatTile(
                title: "Distance",
                value: Format.distance(store.weekTotals.distanceMeters),
                symbol: "point.topleft.down.to.point.bottomright.curvepath"
            )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Rings

    private var ringsRow: some View {
        HStack(spacing: 10) {
            ForEach(store.rings) { day in
                VStack(spacing: 6) {
                    RingsBadge(rings: day)
                        .frame(width: 34, height: 34)
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.ringsAccessibilityLabel(for: day))
            }
        }
        .padding(.vertical, 4)
    }

    private static func ringsAccessibilityLabel(for day: DailyRings) -> String {
        let weekday = day.date.formatted(.dateTime.weekday(.wide))
        let move = Int((day.moveFraction * 100).rounded())
        let exercise = Int((day.exerciseFraction * 100).rounded())
        let stand = Int((day.standFraction * 100).rounded())
        return "\(weekday): move \(move)%, exercise \(exercise)%, stand \(stand)%"
    }

    // MARK: - Empty / unavailable

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Workouts Yet", systemImage: "figure.run")
        } description: {
            // Worth spelling out: an authorised-but-empty result is
            // indistinguishable from a denied one, so the copy has to cover
            // both without claiming which it is.
            Text("Workouts recorded on this iPhone or your Apple Watch will appear here. If you've recorded some already, check that NBExercise has access in Settings ▸ Health ▸ Data Access & Devices.")
        }
    }

    private var unavailableState: some View {
        ContentUnavailableView {
            Label("Health Data Unavailable", systemImage: "heart.slash")
        } description: {
            Text("This device doesn't support Health data.")
        }
    }
}

// MARK: - Components

/// One labelled figure in the weekly totals grid.
private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Three concentric arcs standing in for the Move / Exercise / Stand rings.
///
/// Drawn by hand rather than using `HKActivityRingView`: that's a UIKit view
/// needing a `UIViewRepresentable` wrapper, and it can't render at this size
/// legibly. The colours deliberately echo Apple's ring palette.
private struct RingsBadge: View {
    let rings: DailyRings

    var body: some View {
        ZStack {
            arc(fraction: rings.moveFraction, color: .red, inset: 0)
            arc(fraction: rings.exerciseFraction, color: .green, inset: 5)
            arc(fraction: rings.standFraction, color: .cyan, inset: 10)
        }
    }

    private func arc(fraction: Double, color: Color, inset: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(fraction, 0.001))
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
    }
}

/// One workout in the recent list.
private struct WorkoutRow: View {
    let workout: WorkoutSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.activity.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activity.displayName)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(workout.start.formatted(date: .omitted, time: .shortened))
                    if let source = workout.sourceName {
                        Text("·")
                        Text(source)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.duration(workout.duration))
                    .font(.body)
                    .monospacedDigit()
                if let energy = workout.activeEnergyBurnedKilocalories {
                    Text(Format.energy(energy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    WorkoutStatsView(store: WorkoutStatsStore(source: SampleWorkoutStore()))
}
