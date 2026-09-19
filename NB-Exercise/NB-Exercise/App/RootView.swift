//
//  RootView.swift
//  NBExercise
//
//  The three-tab shell. `TabView` with the `.sidebarAdaptable` style so iPad
//  gets a sidebar (and the iPadOS 26+ floating tab bar) while iPhone keeps a
//  conventional bottom bar, from one declaration.
//

import SwiftUI

struct RootView: View {
    let timerStore: ExerciseTimerStore
    let statsStore: WorkoutStatsStore
    let podcastStore: PodcastStore

    /// Persisted so relaunching returns to the tab the user was last on —
    /// mid-routine, that's usually the timer.
    @SceneStorage("RootView.selectedTab") private var selection: TabSelection = .exercise

    /// `@AppStorage` rather than `@SceneStorage`: this survives the app being
    /// deleted from the app switcher, so the first-run screen is shown once
    /// per install and not once per scene.
    @AppStorage("RootView.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    /// Not named `Tab`: that would shadow SwiftUI's `Tab` view inside this
    /// type, and the builders below would resolve to the enum instead.
    enum TabSelection: String {
        case exercise, listen, stats
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Exercise", systemImage: "timer", value: TabSelection.exercise) {
                ExerciseTimerView(store: timerStore)
            }

            Tab("Listen", systemImage: "headphones", value: TabSelection.listen) {
                PodcastsView(store: podcastStore)
            }

            Tab("Stats", systemImage: "chart.bar.fill", value: TabSelection.stats) {
                WorkoutStatsView(store: statsStore)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // The now-playing bar sits above the tab bar on every tab, so
        // playback stays reachable while the timer runs.
        .safeAreaInset(edge: .bottom) {
            NowPlayingBar(store: podcastStore)
        }
        // A cover rather than a sheet: the three things it explains aren't
        // stated anywhere else in the app, so it shouldn't be swipe-away-able
        // before it's been read.
        .fullScreenCover(isPresented: .constant(!hasCompletedOnboarding)) {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }
}
