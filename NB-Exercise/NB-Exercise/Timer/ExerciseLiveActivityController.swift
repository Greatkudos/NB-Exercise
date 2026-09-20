//
//  ExerciseLiveActivityController.swift
//  NBExercise
//
//  Owns the one Live Activity a session gets. `ExerciseTimerStore` drives it
//  at the transport points and on a throttle while running; nothing else
//  touches ActivityKit.
//
//  This is the piece that puts the session on the Apple Watch. Live Activities
//  from a paired iPhone appear in the watch's Smart Stack automatically — the
//  layout for it lives in `ExerciseSessionLiveActivity` in the widget
//  extension, keyed off the `.small` activity family.
//
//  Every method swallows its errors. A Live Activity is a convenience on top
//  of a session, and the same rule applies here as to the recorder: nothing
//  about it is allowed to cost the user their workout.
//

import ActivityKit
import Foundation
import os

@MainActor
final class ExerciseLiveActivityController {

    /// The activity for the session in progress, if one started.
    private var activity: Activity<ExerciseSessionAttributes>?

    private let log = Logger(
        subsystem: "com.maldeus.NB-Exercise",
        category: "LiveActivity"
    )

    /// False when the user has switched Live Activities off for the app, or
    /// the system won't allow another one right now.
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    /// Starts the activity, or updates the existing one if a session is
    /// somehow already on screen. Called when the timer starts.
    func start(
        activityName: String,
        symbolName: String,
        totalDuration: TimeInterval,
        state: ExerciseSessionAttributes.ContentState
    ) {
        guard isAvailable else { return }

        // Un-pausing calls the timer's `start()` again, which lands here. The
        // session is the same one, so update rather than requesting a second
        // activity the system would likely refuse anyway.
        if activity != nil {
            update(state)
            return
        }

        let attributes = ExerciseSessionAttributes(
            activityName: activityName,
            symbolName: symbolName,
            totalDuration: totalDuration
        )

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content(for: state),
                pushType: nil
            )
        } catch {
            // `ActivityAuthorizationError.denied` lands here, as does hitting
            // the system's cap on simultaneous activities.
            log.error("Couldn't start the Live Activity: \(error.localizedDescription)")
        }
    }

    /// Pushes new content to the activity. Cheap to call, but not free — see
    /// the throttle in `ExerciseTimerStore`.
    func update(_ state: ExerciseSessionAttributes.ContentState) {
        guard let activity else { return }
        Task {
            await activity.update(content(for: state))
        }
    }

    /// Ends the activity, leaving the final state on screen briefly so a
    /// glance after the fact still shows what was done.
    ///
    /// `dismissalPolicy` is `.after` rather than `.default`: the default keeps
    /// a finished activity around for up to four hours, which is far too long
    /// for a twenty-minute walk that's already in the Stats tab.
    func end(_ state: ExerciseSessionAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(
                content(for: state),
                dismissalPolicy: .after(.now.addingTimeInterval(2 * 60))
            )
        }
    }

    /// Tears the activity down immediately, for an abandoned session. Nothing
    /// worth glancing at, so it goes straight off the Lock Screen and the
    /// watch face.
    func cancel() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Content

    /// Wraps a state in an `ActivityContent`, with a stale date so the views
    /// can mark themselves out of date rather than showing a confidently
    /// wrong heart rate.
    ///
    /// A running session leans on `Text(timerInterval:)` to tick on its own,
    /// so it only goes stale once the clock would have run out. A paused one
    /// isn't going anywhere and never goes stale.
    private func content(
        for state: ExerciseSessionAttributes.ContentState
    ) -> ActivityContent<ExerciseSessionAttributes.ContentState> {
        let staleDate: Date? = if let endDate = state.endDate, state.isRunning {
            endDate
        } else {
            nil
        }
        return ActivityContent(state: state, staleDate: staleDate)
    }
}
