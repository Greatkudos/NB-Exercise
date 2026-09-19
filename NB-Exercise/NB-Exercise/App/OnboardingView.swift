//
//  OnboardingView.swift
//  NBExercise
//
//  The first-run explanation.
//
//  Scoped to the three things the interface genuinely can't say for itself,
//  rather than a tour of what's already visible:
//
//    1. The timer writes to Health. Nothing on the Exercise tab implies a
//       countdown becomes a saved workout, and the only hint afterwards is a
//       red dot in the toolbar.
//    2. Stats is a weekly review, not live. It loads on appearance and on
//       pull-to-refresh, so a user watching it for live figures is watching
//       the wrong screen — the live ones are under the countdown.
//    3. Activity rings need an Apple Watch. Nothing else writes activity
//       summaries, so on an iPhone-only setup that row is simply empty, which
//       is indistinguishable from a bug.
//
//  One screen rather than a paged carousel: it's three facts, and a single
//  screen is read rather than swiped past.
//

import SwiftUI

struct OnboardingView: View {
    /// Set by the caller once the user acknowledges. Owned outside this view
    /// so the persistence decision stays with the shell.
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header

                VStack(alignment: .leading, spacing: 24) {
                    OnboardingPoint(
                        symbol: "timer",
                        tint: .accentColor,
                        title: "Time a session",
                        detail: "Pick an activity and a length, then press Start. While it runs you'll see your live heart rate and energy under the countdown."
                    )
                    OnboardingPoint(
                        symbol: "heart.text.square",
                        tint: .red,
                        title: "Saved to Health",
                        detail: "Finished sessions are saved as workouts in Health, so they count towards your activity rings. A red Recording badge appears while one is in progress — tap it any time to see what's being recorded."
                    )
                    OnboardingPoint(
                        symbol: "chart.bar.fill",
                        tint: .teal,
                        title: "Stats is your week",
                        detail: "The Stats tab summarises the last seven days and your recent workouts. It isn't live — pull down to refresh it. Activity rings there need a paired Apple Watch."
                    )
                }
            }
            .padding(28)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
            .background(.bar)
        }
        // Health access is requested where it's actually needed — on the
        // first session and on opening Stats — not here. Asking during
        // onboarding, before the user has seen why, earns a decline.
        .interactiveDismissDisabled()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "figure.mixed.cardio")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)
            Text("Welcome to NBExercise")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Time your exercise, listen while you move, and keep an eye on your week.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }
}

/// One explained feature in the first-run list.
private struct OnboardingPoint: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    /// Scales with the text so the glyph can't outgrow its column and crowd
    /// the title at accessibility sizes.
    @ScaledMetric(relativeTo: .title2) private var symbolWidth: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                // A fixed column keeps the text edges aligned down the list
                // regardless of how wide each glyph happens to be.
                .frame(width: symbolWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView { }
}
