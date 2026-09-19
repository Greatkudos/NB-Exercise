//
//  ExerciseTimerStore.swift
//  NBExercise
//
//  Ported from Nexus's `FocusTimerStore`, with three changes:
//
//    1. `@Observable` instead of `ObservableObject`, so SwiftUI invalidates
//       only the views reading a given property — the countdown updates five
//       times a second, and the duration slider shouldn't redraw with it.
//    2. A selectable `ExerciseActivity` and a longer maximum, since an
//       exercise session isn't bounded by a 25-minute pomodoro.
//    3. Calls into an optional `WorkoutRecorder` at every lifecycle point.
//       That reference is `nil` today — see `WorkoutRecorder.swift`. The
//       hooks exist now so switching recording on later is an injection
//       rather than a rewrite of this file.
//
//  The timing approach is unchanged from Nexus and worth preserving: elapsed
//  time is derived from an absolute `endDate`, never accumulated tick by
//  tick, so a dropped or delayed tick can't make the clock drift.
//

import Foundation
import Observation
import UserNotifications
import AudioToolbox

@MainActor
@Observable
final class ExerciseTimerStore {

    // MARK: - Configuration

    var activity: ExerciseActivity = .other

    private(set) var durationMinutes: Int = 20
    private(set) var remaining: TimeInterval = 20 * 60
    private(set) var isRunning: Bool = false
    private(set) var hasFinished: Bool = false

    /// Set when the recorder refuses to start. The timer keeps running
    /// regardless — a Health failure must never cost the user their session.
    private(set) var recordingWarning: String?

    static let minMinutes = 1
    static let maxMinutes = 120

    /// Durations offered as one-tap presets, alongside the slider.
    static let presets = [10, 20, 30, 45, 60]

    private static let endNotificationID = "com.maldeus.NBExercise.exerciseTimerEnd"

    // MARK: - Recording seam

    /// Records the session to HealthKit while the timer runs. `nil` today:
    /// the app is read-only. Every call site below tolerates that, so
    /// assigning a real recorder is the only change needed to turn recording
    /// on. See `WorkoutRecorder.swift`.
    var recorder: WorkoutRecorder?

    /// Whether a recording is currently attached and live — drives the "REC"
    /// affordance in the timer view.
    var isRecording: Bool { recorder?.state.isActive ?? false }

    // MARK: - Internal timing state

    private var endDate: Date?
    private var tickerTask: Task<Void, Never>?

    // MARK: - Duration

    func setDuration(_ minutes: Int) {
        let clamped = min(max(minutes, Self.minMinutes), Self.maxMinutes)
        durationMinutes = clamped
        // Changing the dial mid-session shouldn't yank the clock out from
        // under a running timer; the new length applies to the next one.
        if !isRunning {
            remaining = TimeInterval(clamped * 60)
            hasFinished = false
        }
    }

    // MARK: - Transport

    func start() {
        guard !isRunning else { return }
        hasFinished = false
        recordingWarning = nil

        let resumeFrom: TimeInterval = remaining > 0
            ? remaining
            : TimeInterval(durationMinutes * 60)
        remaining = resumeFrom
        endDate = Date().addingTimeInterval(resumeFrom)
        isRunning = true

        scheduleTicker()
        scheduleEndNotification(in: resumeFrom)

        // Resume an existing recording rather than starting a second one when
        // the user un-pauses.
        Task { [recorder, activity] in
            guard let recorder else { return }
            if recorder.state == .paused {
                await recorder.resume()
            } else {
                do {
                    try await recorder.start(activity)
                } catch {
                    self.recordingWarning =
                        "Couldn't record this session to Health: \(error.localizedDescription)"
                }
            }
        }
    }

    func pause() {
        guard isRunning else { return }
        // Snapshot the live remaining time before tearing down the ticker so
        // resuming continues from exactly where we paused.
        if let endDate {
            remaining = max(0, endDate.timeIntervalSinceNow)
        }
        endDate = nil
        isRunning = false
        tickerTask?.cancel()
        tickerTask = nil
        cancelEndNotification()

        Task { [recorder] in await recorder?.pause() }
    }

    /// Stops and clears the session without saving it.
    func reset() {
        tickerTask?.cancel()
        tickerTask = nil
        endDate = nil
        isRunning = false
        hasFinished = false
        recordingWarning = nil
        remaining = TimeInterval(durationMinutes * 60)
        cancelEndNotification()

        // A reset is an abandonment, not a completion — discard rather than
        // save, so a mis-tap doesn't litter Health with 4-second workouts.
        Task { [recorder] in await recorder?.discard() }
    }

    // MARK: - Ticking

    private func scheduleTicker() {
        tickerTask?.cancel()
        // The store is @MainActor, so the Task inherits that isolation.
        // Remaining time is computed from `endDate`, so a missed tick can't
        // drift the clock — it just updates late.
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                guard let self else { return }
                self.tick()
                if !self.isRunning { return }
            }
        }
    }

    private func tick() {
        guard let endDate else { return }
        let r = endDate.timeIntervalSinceNow
        guard r <= 0 else {
            remaining = r
            return
        }

        remaining = 0
        isRunning = false
        hasFinished = true
        self.endDate = nil
        tickerTask?.cancel()
        tickerTask = nil
        playEndAlertSound()

        // The scheduled notification is either firing now or has already
        // fired — clear any delivered copy so the user doesn't meet a stale
        // banner next time they unlock.
        cancelEndNotification()

        // Finishing the countdown is a completed session: save it.
        Task { [recorder] in
            guard let recorder else { return }
            do { try await recorder.end() }
            catch {
                self.recordingWarning =
                    "Couldn't save this session to Health: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Alert / notification

    /// Plays a short alert immediately, for when the timer finishes with the
    /// app foregrounded. The scheduled notification covers backgrounded or
    /// locked.
    private func playEndAlertSound() {
        // System sound 1005 = "Tritone". Respects notification volume;
        // suppressed in Silent mode unless the user has overridden that.
        AudioServicesPlayAlertSound(SystemSoundID(1005))
    }

    /// Schedules a local notification so the user is alerted even with the
    /// app backgrounded or the screen off. Permission is requested lazily on
    /// first start — if declined, the in-app alert still plays.
    private func scheduleEndNotification(in seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let activityName = activity.displayName
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                guard granted else { return }
            } catch {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "\(activityName) complete"
            content.body = "Time's up — nice work."
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: seconds,
                repeats: false
            )
            try? await center.add(
                UNNotificationRequest(
                    identifier: Self.endNotificationID,
                    content: content,
                    trigger: trigger
                )
            )
        }
    }

    private func cancelEndNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.endNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.endNotificationID])
    }
}
