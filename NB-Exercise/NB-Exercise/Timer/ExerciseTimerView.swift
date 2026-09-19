//
//  ExerciseTimerView.swift
//  NBExercise
//
//  The Exercise tab. Ported from Nexus's `FocusTimerView`, with an activity
//  picker and duration presets added, and the layout reworked to fill an iPad
//  window as comfortably as an iPhone one.
//

import SwiftUI

struct ExerciseTimerView: View {
    @Bindable var store: ExerciseTimerStore

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 28) {
                        countdown(in: geo.size)

                        if store.hasFinished {
                            Text("\(store.activity.displayName) complete")
                                .font(.headline)
                                .foregroundStyle(.tint)
                                .transition(.opacity)
                        }

                        if let warning = store.recordingWarning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        activityPicker
                        durationControl
                        controlButtons
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(min(40, geo.size.width * 0.06))
                    // Centre the stack vertically when there's room to spare,
                    // but let it scroll rather than clip at accessibility text
                    // sizes or in a short split-view window.
                    .frame(minHeight: geo.size.height, alignment: .center)
                }
            }
            .navigationTitle("Exercise")
            .toolbar {
                if store.isRecording {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label("Recording", systemImage: "record.circle")
                            .foregroundStyle(.red)
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Recording to Health")
                    }
                }
            }
        }
    }

    // MARK: - Countdown

    private func countdown(in size: CGSize) -> some View {
        Text(Format.clock(store.remaining))
            .font(.system(size: countdownFontSize(in: size), weight: .light, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(store.hasFinished ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.15), value: store.remaining)
            .accessibilityLabel("Time remaining")
            .accessibilityValue(Format.duration(store.remaining))
    }

    /// Picks a size that fills the available space: bounded by both width and
    /// height so the digits never overflow in a short or narrow window, and
    /// clamped to a readable range.
    private func countdownFontSize(in size: CGSize) -> CGFloat {
        let widthBudget = size.width * 0.22
        let heightBudget = size.height * 0.28
        return min(max(min(widthBudget, heightBudget), 36), 160)
    }

    // MARK: - Activity

    private var activityPicker: some View {
        Picker("Activity", selection: $store.activity) {
            ForEach(ExerciseActivity.allCases) { activity in
                Label(activity.displayName, systemImage: activity.symbolName)
                    .tag(activity)
            }
        }
        .pickerStyle(.menu)
        .disabled(store.isRunning)
    }

    // MARK: - Duration

    @ViewBuilder
    private var durationControl: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Duration")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(store.durationMinutes) min")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(store.durationMinutes) },
                    set: { store.setDuration(Int($0.rounded())) }
                ),
                in: Double(ExerciseTimerStore.minMinutes)...Double(ExerciseTimerStore.maxMinutes),
                step: 1
            )
            .disabled(store.isRunning)
            .accessibilityLabel("Exercise duration")
            .accessibilityValue("\(store.durationMinutes) minutes")

            HStack(spacing: 8) {
                ForEach(ExerciseTimerStore.presets, id: \.self) { minutes in
                    Button("\(minutes)") {
                        store.setDuration(minutes)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(store.isRunning)
                    .accessibilityLabel("\(minutes) minutes")
                }
            }
            .font(.footnote)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlButtons: some View {
        HStack(spacing: 16) {
            Button {
                store.isRunning ? store.pause() : store.start()
            } label: {
                Label(
                    store.isRunning ? "Pause" : "Start",
                    systemImage: store.isRunning ? "pause.fill" : "play.fill"
                )
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.space, modifiers: [])

            Button {
                store.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.bordered)
            .disabled(isAtRest)
        }
    }

    /// Nothing to reset when the timer is sitting untouched at its full
    /// duration.
    private var isAtRest: Bool {
        !store.isRunning
            && !store.hasFinished
            && store.remaining == TimeInterval(store.durationMinutes * 60)
    }
}

#Preview {
    ExerciseTimerView(store: ExerciseTimerStore())
}
