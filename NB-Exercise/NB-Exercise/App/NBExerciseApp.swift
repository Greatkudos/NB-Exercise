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

import AppIntents
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
        timer.liveActivity = ExerciseLiveActivityController()

        // The Live Activity's buttons are App Intents, so they can be
        // performed in a process launched headlessly — with no window, and no
        // view having appeared to do this wiring. `App.init()` is the only
        // place that runs on *every* launch, including those, and an
        // unregistered `@Dependency` is an uncatchable `fatalError`.
        //
        // The captures are strong on purpose. Both objects live for the
        // process either way, and the registry is global — a weak timer that
        // got released would turn every button on the watch into a silent
        // no-op, which is a worse failure than holding a reference.
        let controls = ExerciseSessionControls()
        controls.pause = { timer.pause() }
        // Resuming *is* starting: `start()` picks up from `remaining` rather
        // than restarting the clock, and tells the recorder to resume.
        controls.resume = { timer.start() }
        controls.finish = { timer.finish() }
        AppDependencyManager.shared.add(dependency: controls)

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
