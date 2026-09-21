//
//  NBExerciseWatchApp.swift
//  NBExercise Watch App
//
//  Entry point for the watch app.
//
//  The one structural note: `WatchWorkoutManager` is owned by the application
//  delegate rather than by the `App` struct. It has to be, because
//  `handle(_:)` — the callback for a session the iPhone launched with
//  `startWatchApp(with:)` — arrives on the delegate, and can arrive before any
//  view has appeared. Hanging the manager off the delegate means there is
//  always exactly one, and it always exists by the time that call lands.
//

import HealthKit
import SwiftUI
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {

    let manager = WatchWorkoutManager()

    /// Called when the companion iPhone promotes a session to the watch. The
    /// configuration carries the activity; the duration is the watch's own.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { await manager.start(with: workoutConfiguration) }
    }
}

@main
struct NBExerciseWatchApp: App {

    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate

    var body: some Scene {
        WindowGroup {
            WatchSessionView(manager: delegate.manager)
        }
    }
}
