//
//  NBExerciseApp.swift
//  NBExercise
//
//  App entry point. The three stores are created here and live for the whole
//  session, which matters for two of them:
//
//    - `PodcastPlaybackController` / `PodcastStore`: playback has to survive
//      switching to the Exercise tab, so the player can't be owned by the
//      view that started it.
//    - `ExerciseTimerStore`: the countdown keeps running while the user
//      browses episodes.
//

import SwiftUI
import SwiftData

@main
struct NBExerciseApp: App {

    /// Everything persisted: subscriptions and per-episode playback state.
    /// The episode catalogue and downloads are deliberately outside SwiftData
    /// — see `PodcastPersistence`.
    private let modelContainer: ModelContainer

    @State private var timerStore: ExerciseTimerStore
    @State private var statsStore: WorkoutStatsStore
    @State private var podcastStore: PodcastStore

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Subscription.self, EpisodeState.self)
        } catch {
            // Nothing sensible to fall back to: without a store the Listen
            // tab can't function, and a silent in-memory container would
            // lose the user's subscriptions without telling them.
            fatalError("Couldn't create the model container: \(error)")
        }
        modelContainer = container

        let playback = PodcastPlaybackController()

        // The recorder is attached here rather than created by the timer so
        // the timer stays runnable without HealthKit (see its `#Preview`).
        let timer = ExerciseTimerStore()
        timer.recorder = HealthKitWorkoutRecorder()

        _timerStore = State(initialValue: timer)
        _statsStore = State(
            initialValue: WorkoutStatsStore(source: HealthKitWorkoutStore())
        )
        _podcastStore = State(
            initialValue: PodcastStore(
                context: container.mainContext,
                playback: playback
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                timerStore: timerStore,
                statsStore: statsStore,
                podcastStore: podcastStore
            )
            .onChange(of: scenePhase) { _, phase in
                // Persist the playback position on the way out, so a resume
                // point isn't lost if the app is terminated in the
                // background.
                if phase != .active { podcastStore.flushPending() }
            }
        }
        .modelContainer(modelContainer)
    }
}
