//
//  WatchSessionView.swift
//  NBExercise Watch App
//
//  Two screens in one, chosen by whether a session exists: the setup screen
//  that picks an activity and a length, and the session screen that runs it.
//
//  Deliberately smaller than the phone's `ExerciseTimerView`. The motivation
//  lines, the preset grid and the recording explainer all stay on the phone —
//  a watch glance is a countdown, two numbers and a way to stop.
//

import SwiftUI

struct WatchSessionView: View {
    @Bindable var manager: WatchWorkoutManager

    var body: some View {
        NavigationStack {
            Group {
                if manager.isSessionActive {
                    SessionScreen(manager: manager)
                } else {
                    SetupScreen(manager: manager)
                }
            }
            .navigationTitle("Exercise")
        }
    }
}

// MARK: - Setup

private struct SetupScreen: View {
    @Bindable var manager: WatchWorkoutManager

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Activity", selection: $manager.activity) {
                    ForEach(ExerciseActivity.allCases) { activity in
                        Label(activity.displayName, systemImage: activity.symbolName)
                            .tag(activity)
                    }
                }
                .pickerStyle(.navigationLink)

                // The Digital Crown is the right control for a number on a
                // watch — a slider this narrow is a fiddly target mid-workout.
                Stepper(
                    value: Binding(
                        get: { manager.durationMinutes },
                        set: { manager.setDuration($0) }
                    ),
                    in: WatchWorkoutManager.minMinutes...WatchWorkoutManager.maxMinutes,
                    step: 5
                ) {
                    Text("\(manager.durationMinutes) min")
                        .monospacedDigit()
                }
                .accessibilityLabel("Exercise duration")
                .accessibilityValue("\(manager.durationMinutes) minutes")

                HStack(spacing: 6) {
                    ForEach(WatchWorkoutManager.presets, id: \.self) { minutes in
                        Button("\(minutes)") {
                            manager.setDuration(minutes)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("\(minutes) minutes")
                    }
                }
                .font(.footnote)

                Button {
                    Task { await manager.start() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                if let message = manager.errorMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Session

private struct SessionScreen: View {
    @Bindable var manager: WatchWorkoutManager

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(clock(manager.remaining))
                    .font(.system(size: 42, weight: .light, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(manager.isRunning ? .primary : .secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: manager.remaining)
                    .accessibilityLabel("Time remaining")

                Label(manager.activity.displayName, systemImage: manager.activity.symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Metric(
                        value: manager.heartRate.map { "\(Int($0.rounded()))" } ?? "—",
                        symbol: "heart.fill",
                        tint: .pink,
                        label: "Heart rate"
                    )
                    Metric(
                        value: manager.activeEnergyBurnedKilocalories
                            .map { "\(Int($0.rounded()))" } ?? "—",
                        symbol: "flame.fill",
                        tint: .orange,
                        label: "Active energy"
                    )
                }

                HStack(spacing: 8) {
                    Button {
                        manager.isRunning ? manager.pause() : manager.resume()
                    } label: {
                        Image(systemName: manager.isRunning ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(manager.isRunning ? "Pause" : "Resume")

                    Button {
                        manager.finish()
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityLabel("End and save")
                }
                .padding(.top, 2)

                // Discarding is set apart from ending, and labelled for what
                // it costs: the two are one tap from each other and only one
                // of them is recoverable.
                Button("Discard", role: .destructive) {
                    manager.discard()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if let message = manager.errorMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// Local rather than the app's `Format.clock`, which lives in a file the
    /// watch target has no other reason to compile.
    private func clock(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// One live figure. Dashes rather than zeros for anything not yet measured —
/// a real 0 bpm and "we don't have this" are different claims.
private struct Metric: View {
    let value: String
    let symbol: String
    let tint: Color
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

#Preview {
    WatchSessionView(manager: WatchWorkoutManager())
}
