//
//  NBExerciseWidgetsBundle.swift
//  NBExerciseWidgets
//
//  The extension's entry point. One Live Activity, no Home Screen widgets —
//  the Xcode template's sample widget has been removed rather than left to
//  ship an emoji placeholder.
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct NBExerciseWidgetsBundle: WidgetBundle {

    init() {
        // The transport intents run in the *app's* process, where
        // `NBExerciseApp` registers a sink wired to the live timer. But an
        // unregistered `@Dependency` is a hard `fatalError`, not a catchable
        // error, so register an inert one here too: if the system ever elects
        // to perform an intent inside the extension, the tap does nothing
        // instead of crashing.
        AppDependencyManager.shared.add(dependency: ExerciseSessionControls())
    }

    var body: some Widget {
        ExerciseSessionLiveActivity()
    }
}
