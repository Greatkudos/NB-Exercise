//
//  ExerciseSessionLiveActivity.swift
//  NBExerciseWidgets
//
//  The session as it appears outside the app: on the Lock Screen, in the
//  Dynamic Island, and — the reason this exists — in the Apple Watch Smart
//  Stack, which picks up Live Activities from a paired iPhone with no watchOS
//  app involved.
//
//  `supplementalActivityFamilies([.small, .medium])` is what opts into a
//  hand-built watch layout. Without it the watch squeezes the Dynamic Island's
//  compact presentation into the Smart Stack, which has room for a glyph and a
//  clock and nothing else — no buttons, so no control from the wrist.
//
//  The countdown is always `Text(timerInterval:)` while running, never a
//  formatted string. The system ticks it locally, so the clock stays correct
//  between the app's throttled updates instead of freezing between them.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct ExerciseSessionLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ExerciseSessionAttributes.self) { context in
            // Lock Screen, Home Screen banner, and StandBy. Also the layout
            // the watch falls back to if `.small` is ever unavailable.
            LockScreenView(context: context)
                .activityBackgroundTint(.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityGlyph(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(context: context)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        MetricsStrip(context: context)
                        TransportButtons(context: context)
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbolName)
                    .foregroundStyle(.tint)
            } compactTrailing: {
                CountdownText(context: context)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.attributes.symbolName)
                    .foregroundStyle(.tint)
            }
            .keylineTint(.orange)
        }
        // `.small` is the watch (and CarPlay); `.medium` is the iPhone and
        // iPad Lock Screen, including StandBy.
        .supplementalActivityFamilies([.small, .medium])
    }
}

// MARK: - Family routing

/// Picks the layout for wherever the activity has ended up. The watch gets a
/// layout of its own rather than a scaled-down phone one — at Smart Stack size
/// the metrics strip is unreadable, and the buttons matter more.
private struct LockScreenView: View {

    @Environment(\.activityFamily) private var activityFamily

    let context: ActivityViewContext<ExerciseSessionAttributes>

    var body: some View {
        switch activityFamily {
        case .small:
            WatchView(context: context)
        case .medium:
            PhoneView(context: context)
        @unknown default:
            PhoneView(context: context)
        }
    }
}

// MARK: - Apple Watch

/// The Smart Stack layout. One line of identity, one big clock, one row of
/// controls — anything more doesn't fit and doesn't earn its place.
private struct WatchView: View {

    let context: ActivityViewContext<ExerciseSessionAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: context.attributes.symbolName)
                    .font(.caption)
                Text(context.attributes.activityName)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                if let heartRate = context.state.heartRate {
                    Label(
                        "\(Int(heartRate.rounded()))",
                        systemImage: "heart.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.pink)
                    .labelStyle(.titleAndIcon)
                }
            }
            .foregroundStyle(.secondary)

            CountdownText(context: context)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            TransportButtons(context: context)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - iPhone / iPad

private struct PhoneView: View {

    let context: ActivityViewContext<ExerciseSessionAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                ActivityGlyph(context: context)
                Spacer(minLength: 12)
                CountdownText(context: context)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }

            // The message is the same encouragement the in-app countdown
            // shows, so a glance at the Lock Screen reads like the app.
            if let message = context.state.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            MetricsStrip(context: context)
            TransportButtons(context: context)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared pieces

private struct ActivityGlyph: View {

    let context: ActivityViewContext<ExerciseSessionAttributes>

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: context.attributes.symbolName)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.attributes.activityName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        if context.state.hasFinished { return "Complete" }
        return context.state.isRunning ? "In progress" : "Paused"
    }
}

/// The countdown. Hands off to `Text(timerInterval:)` while the clock is
/// running so the system ticks it, and falls back to a static figure when
/// there's nothing to count towards.
private struct CountdownText: View {

    let context: ActivityViewContext<ExerciseSessionAttributes>

    var body: some View {
        if context.state.hasFinished {
            Text("Done")
        } else if
            context.state.isRunning,
            let endDate = context.state.endDate,
            endDate > .now
        {
            // The range has to be valid at render time, hence the `> .now`
            // guard — a lapsed end date would trap.
            Text(timerInterval: Date.now...endDate, countsDown: true)
        } else {
            Text(Format.clock(context.state.remaining))
        }
    }
}

/// Heart rate, energy and distance, each dropping out when the device can't
/// measure it. A dash would waste space this layout doesn't have.
private struct MetricsStrip: View {

    let context: ActivityViewContext<ExerciseSessionAttributes>

    var body: some View {
        HStack(spacing: 14) {
            if let heartRate = context.state.heartRate {
                metric(
                    "heart.fill",
                    Format.heartRate(heartRate),
                    tint: .pink
                )
            }
            if let energy = context.state.activeEnergyBurnedKilocalories {
                metric("flame.fill", Format.energy(energy), tint: .orange)
            }
            if let distance = context.state.distanceMeters {
                metric("figure.walk", Format.distance(distance), tint: .green)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func metric(
        _ symbol: String,
        _ value: String,
        tint: Color
    ) -> some View {
        Label {
            Text(value)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Pause / resume and end. The buttons that make this a control surface rather
/// than a readout — and they work in the Smart Stack on the watch, so the
/// session can be driven from the wrist without a watchOS app.
private struct TransportButtons: View {

    let context: ActivityViewContext<ExerciseSessionAttributes>

    var body: some View {
        // A finished session has nothing left to control; the activity ends on
        // its own shortly after.
        if !context.state.hasFinished {
            HStack(spacing: 8) {
                if context.state.isRunning {
                    Button(intent: PauseExerciseSessionIntent()) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                } else {
                    Button(intent: ResumeExerciseSessionIntent()) {
                        Label("Resume", systemImage: "play.fill")
                    }
                }

                Button(intent: FinishExerciseSessionIntent()) {
                    Label("End", systemImage: "stop.fill")
                }
                .tint(.red)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Previews

extension ExerciseSessionAttributes {
    fileprivate static let preview = ExerciseSessionAttributes(
        activityName: "Walk",
        symbolName: "figure.walk",
        totalDuration: 20 * 60
    )
}

extension ExerciseSessionAttributes.ContentState {

    /// Mid-session with a paired Watch feeding heart rate.
    fileprivate static let running = Self(
        endDate: .now.addingTimeInterval(13 * 60 + 24),
        remaining: 13 * 60 + 24,
        isRunning: true,
        hasFinished: false,
        heartRate: 128,
        activeEnergyBurnedKilocalories: 96,
        distanceMeters: 1240,
        message: "Halfway. Settle in."
    )

    /// Paused, and on an iPhone with no heart-rate source — the metrics strip
    /// drops the reading rather than showing a zero.
    fileprivate static let paused = Self(
        endDate: nil,
        remaining: 8 * 60 + 5,
        isRunning: false,
        hasFinished: false,
        heartRate: nil,
        activeEnergyBurnedKilocalories: 142,
        distanceMeters: 1980,
        message: nil
    )

    fileprivate static let finished = Self(
        endDate: nil,
        remaining: 0,
        isRunning: false,
        hasFinished: true,
        heartRate: nil,
        activeEnergyBurnedKilocalories: 214,
        distanceMeters: 2760,
        message: "That's the session. Well done."
    )
}

// The canvas has an activity-family control on this preview: switch it to the
// small family to see the Apple Watch Smart Stack layout, which is the one
// worth checking, since it's the tightest.
#Preview("Lock Screen", as: .content, using: ExerciseSessionAttributes.preview) {
    ExerciseSessionLiveActivity()
} contentStates: {
    ExerciseSessionAttributes.ContentState.running
    ExerciseSessionAttributes.ContentState.paused
    ExerciseSessionAttributes.ContentState.finished
}

#Preview(
    "Dynamic Island",
    as: .dynamicIsland(.expanded),
    using: ExerciseSessionAttributes.preview
) {
    ExerciseSessionLiveActivity()
} contentStates: {
    ExerciseSessionAttributes.ContentState.running
    ExerciseSessionAttributes.ContentState.paused
}
