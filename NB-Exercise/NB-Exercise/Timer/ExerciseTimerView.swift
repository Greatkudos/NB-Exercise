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

    /// Drives the popover explaining the recording indicator. The indicator
    /// is the only place the app says it's writing to Health, so it has to be
    /// able to explain itself on demand.
    @State private var isShowingRecordingInfo = false

    /// Minimum width of a duration preset capsule. Scaled so the six presets
    /// wrap onto further rows at accessibility text sizes rather than
    /// squeezing their labels.
    @ScaledMetric(relativeTo: .footnote) private var presetMinWidth: CGFloat = 52

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 28) {
                        countdown(in: geo.size)
                        motivation

                        if store.isRecording {
                            liveMetrics
                        }

                        if store.hasFinished {
                            completionBanner
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
                        motivationToggle
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
                        recordingIndicator
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

    // MARK: - Motivation

    /// The encouragement under the countdown. The store hands over one line
    /// at a time and decides when it changes — this just shows it.
    @ViewBuilder
    private var motivation: some View {
        // The slot only exists once a session is underway — reserving it on
        // an untouched timer just reads as a gap. Within a session it holds
        // a fixed height even while empty (paused, or between lines), so the
        // countdown doesn't shuffle up and down as messages change.
        if store.showsMotivation && !isAtRest {
            Text(store.motivationalMessage ?? "")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                // A new line is a new view, so the transition actually runs
                // instead of the text swapping in place.
                .id(store.motivationalMessage)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: store.motivationalMessage)
                // It's the one thing on this screen a VoiceOver user
                // couldn't otherwise tell had changed.
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    /// Shown when the clock reaches zero. The factual line stays put and the
    /// congratulation sits under it, so turning the messages off loses the
    /// flourish but never the confirmation that the session actually ended.
    private var completionBanner: some View {
        VStack(spacing: 8) {
            Text("\(store.activity.displayName) complete")
                .font(.headline)
                .foregroundStyle(.tint)

            if let congratulation = store.completionMessage {
                Text(congratulation)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .transition(.opacity)
    }

    private var motivationToggle: some View {
        Toggle(isOn: $store.showsMotivation) {
            Label("Motivational Messages", systemImage: "quote.bubble")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityHint("Shows encouragement under the countdown while a session runs")
    }

    // MARK: - Recording indicator

    /// A red dot on its own told the user nothing — and the toolbar's button
    /// treatment made it look tappable, which it wasn't. So it now carries a
    /// visible label *and* actually responds, explaining what's being
    /// recorded and the caveats that come with recording on iPhone.
    private var recordingIndicator: some View {
        Button {
            isShowingRecordingInfo = true
        } label: {
            Label(
                store.isRunning ? "Recording" : "Paused",
                systemImage: store.isRunning ? "record.circle" : "pause.circle"
            )
        }
        .tint(.red)
        .accessibilityHint("Explains what this session records to Health")
        .popover(isPresented: $isShowingRecordingInfo) {
            RecordingInfoPopover(
                activity: store.activity,
                isPaused: !store.isRunning,
                warning: store.recordingWarning
            )
            // Without this the popover becomes a sheet on iPhone, which is
            // far too heavy for a one-paragraph explanation.
            .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Live metrics

    /// The figures HealthKit is collecting right now. Shown only while a
    /// recording is live — with nothing to report it would just be a row of
    /// dashes competing with the countdown.
    private var liveMetrics: some View {
        let metrics = store.liveMetrics
        // Formatted here rather than with `map`, which would hand the
        // main-actor-isolated formatters to a nonisolated closure.
        let heartRate = if let bpm = metrics.heartRate {
            Format.heartRate(bpm)
        } else {
            "—"
        }
        let energy = if let kilocalories = metrics.activeEnergyBurnedKilocalories {
            Format.energy(kilocalories)
        } else {
            "—"
        }

        return HStack(spacing: 0) {
            LiveMetric(
                title: "Heart Rate",
                value: heartRate,
                symbol: "heart.fill",
                tint: .pink
            )
            LiveMetric(
                title: "Energy",
                value: energy,
                symbol: "flame.fill",
                tint: .orange
            )
            // Distance is meaningless for strength work and yoga, so the
            // recorder reports nil and the tile drops out rather than
            // claiming a flat zero.
            if let distance = metrics.distanceMeters {
                LiveMetric(
                    title: "Distance",
                    value: Format.distance(distance),
                    symbol: "point.topleft.down.to.point.bottomright.curvepath",
                    tint: .teal
                )
            }
        }
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
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

            // Six presets no longer fit a single row at their intrinsic
            // width, so the capsules share the row evenly and wrap once the
            // text gets large enough that they can't.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: presetMinWidth), spacing: 6)],
                spacing: 6
            ) {
                ForEach(ExerciseTimerStore.presets, id: \.self) { minutes in
                    Button {
                        store.setDuration(minutes)
                    } label: {
                        Text("\(minutes)")
                            .frame(maxWidth: .infinity)
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

/// What the recording indicator says when tapped.
///
/// Deliberately covers the two things the figures on screen can't explain for
/// themselves: where the session is going, and why heart rate may read as a
/// dash. Both are the kind of thing a user would otherwise read as a bug.
private struct RecordingInfoPopover: View {
    let activity: ExerciseActivity
    let isPaused: Bool
    let warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                isPaused ? "Recording Paused" : "Recording to Health",
                systemImage: isPaused ? "pause.circle" : "record.circle"
            )
            .font(.headline)
            .foregroundStyle(.red)

            Text("This session is being saved to Health as a \(activity.displayName.lowercased()) workout, so it counts towards your activity rings and appears in Stats when it finishes.")

            // Stated up front because a dash where a number should be reads
            // as a failure otherwise.
            Text("Heart rate needs a paired Apple Watch or an external monitor — iPhone has no heart-rate sensor. Energy recorded on iPhone is estimated from movement.")
                .foregroundStyle(.secondary)

            if let warning {
                Divider()
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.leading)
        .padding()
        .frame(idealWidth: 280)
    }
}

/// One live figure in the strip under the countdown.
private struct LiveMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

#Preview {
    ExerciseTimerView(store: ExerciseTimerStore())
}
