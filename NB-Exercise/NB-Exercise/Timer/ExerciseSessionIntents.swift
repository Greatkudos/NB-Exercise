//
//  ExerciseSessionIntents.swift
//  NBExercise
//
//  The three buttons on the Live Activity, and therefore the three buttons on
//  the wrist. Compiled into both the app and the widget extension: the
//  extension needs the types to build the buttons, the app needs them to run
//  the work.
//
//  All three are `LiveActivityIntent`. That conformance is what lets them run
//  without opening the app — the system launches the app's process headlessly,
//  performs the intent, and lets it update or end the Live Activity. A plain
//  `AppIntent` would have to bring the app to the foreground to touch an
//  activity, which defeats the point of a control on the watch.
//
//  `perform()` is annotated `@MainActor` rather than the type: `AppIntent`'s
//  requirements are nonisolated, so a `@MainActor` intent type doesn't
//  conform. The whole body is main-actor work, so annotating the method is
//  cleaner than wrapping it in `MainActor.run`.
//

import AppIntents

struct PauseExerciseSessionIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "Pause Exercise Timer"
    static let description = IntentDescription(
        "Pauses the exercise timer that's currently running."
    )

    /// Background only. Pausing is complete in itself — there's nothing to
    /// show the user afterwards that would justify pulling the app open,
    /// particularly when the tap came from a watch.
    static let supportedModes: IntentModes = .background

    @Dependency private var controls: ExerciseSessionControls

    @MainActor
    func perform() async throws -> some IntentResult {
        controls.pause?()
        return .result()
    }
}

struct ResumeExerciseSessionIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "Resume Exercise Timer"
    static let description = IntentDescription(
        "Resumes a paused exercise timer."
    )

    static let supportedModes: IntentModes = .background

    @Dependency private var controls: ExerciseSessionControls

    @MainActor
    func perform() async throws -> some IntentResult {
        controls.resume?()
        return .result()
    }
}

/// Ends the session early and saves it. Deliberately not the timer's
/// `reset()`, which discards — someone stopping ten minutes into a twenty
/// minute walk has still walked for ten minutes, and should get the credit.
struct FinishExerciseSessionIntent: LiveActivityIntent {

    static let title: LocalizedStringResource = "End Exercise Session"
    static let description = IntentDescription(
        "Ends the current exercise session and saves it to Health."
    )

    static let supportedModes: IntentModes = .background

    @Dependency private var controls: ExerciseSessionControls

    @MainActor
    func perform() async throws -> some IntentResult {
        controls.finish?()
        return .result()
    }
}
