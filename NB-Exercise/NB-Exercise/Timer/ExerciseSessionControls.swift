//
//  ExerciseSessionControls.swift
//  NBExercise
//
//  The bridge the Live Activity's buttons cross to reach the timer.
//
//  The buttons are `AppIntent`s, and an intent used by a Live Activity has to
//  be compiled into the widget extension so the `Button(intent:)` can name the
//  type. But the extension can't see `ExerciseTimerStore` — that type reaches
//  into UIKit, UserNotifications and the recorder, none of which belong in a
//  widget. So the intents depend on this deliberately tiny sink instead, and
//  `NBExerciseApp` wires the closures to the real store at launch.
//
//  `@MainActor` is load-bearing, not decoration: `@Dependency` requires a
//  `Sendable` value, and a plain class holding mutable closures isn't one.
//  Isolating it to the main actor makes it `Sendable` and is correct anyway,
//  since every handler ends up touching main-actor state.
//

import Foundation

@MainActor
final class ExerciseSessionControls {

    /// Pauses a running session. Set by the app; `nil` in the widget
    /// extension, where there's no timer to pause.
    var pause: (() -> Void)?

    /// Resumes a paused session.
    var resume: (() -> Void)?

    /// Ends the session early and saves what was done, as distinct from the
    /// timer's `reset()`, which throws the session away.
    var finish: (() -> Void)?

    /// `nonisolated` so it can be constructed from a `WidgetBundle.init()`,
    /// which — unlike SwiftUI's `App.init()` — isn't main-actor isolated.
    /// Safe because there's nothing to initialise: every property starts nil.
    nonisolated init() {}
}
