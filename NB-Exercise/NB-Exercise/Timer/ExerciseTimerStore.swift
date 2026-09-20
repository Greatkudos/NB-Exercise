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
//    3. Calls into an optional `WorkoutRecorder` at every lifecycle point,
//       which records the session to HealthKit and publishes the live metrics
//       the view shows under the countdown. Optional so the timer still runs
//       in previews and tests without a Health dependency.
//
//  The timing approach is unchanged from Nexus and worth preserving: elapsed
//  time is derived from an absolute `endDate`, never accumulated tick by
//  tick, so a dropped or delayed tick can't make the clock drift.
//

import Foundation
import Observation
import UserNotifications
import AudioToolbox
import UIKit

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
    static let maxMinutes = 60

    /// Durations offered as one-tap presets, alongside the slider.
    static let presets = [5, 10, 20, 30, 45, 60]

    private static let endNotificationID = "com.maldeus.NBExercise.exerciseTimerEnd"

    // MARK: - Motivation

    /// Shows encouragement under the countdown while a session runs.
    /// Persisted, and on by default — some people find it carries them
    /// through the last five minutes, and some find it nagging.
    var showsMotivation: Bool {
        didSet {
            UserDefaults.standard.set(showsMotivation, forKey: Self.motivationKey)
            if showsMotivation {
                if isRunning { motivation.resume() }
            } else {
                motivation.reset()
                completionMessage = nil
            }
            motivationalMessage = motivation.message
        }
    }

    /// The line currently shown under the countdown, or `nil` for none.
    private(set) var motivationalMessage: String?

    /// The sign-off for a session that reached zero, picked at random when
    /// it finishes. Cleared when the next session starts.
    private(set) var completionMessage: String?

    /// Chooses the line. `@ObservationIgnored` because the view reads the
    /// published `motivationalMessage`, not the provider's internals — which
    /// churn on every tick.
    @ObservationIgnored private var motivation = MotivationProvider()

    private static let motivationKey = "ExerciseTimer.showsMotivation"

    // MARK: - Screen

    /// Holds the screen awake while a session runs, so the countdown is still
    /// there when the user looks back at it between sets. Persisted, and on by
    /// default — a timer that blanks a minute in is the more surprising
    /// behaviour, and the battery cost is something the user can opt out of.
    var keepsScreenAwake: Bool {
        didSet {
            UserDefaults.standard.set(keepsScreenAwake, forKey: Self.screenAwakeKey)
            updateScreenWakeLock()
        }
    }

    private static let screenAwakeKey = "ExerciseTimer.keepsScreenAwake"

    init() {
        // `bool(forKey:)` would read a missing value as false, which would
        // ship these features switched off.
        showsMotivation =
            UserDefaults.standard.object(forKey: Self.motivationKey) as? Bool ?? true
        keepsScreenAwake =
            UserDefaults.standard.object(forKey: Self.screenAwakeKey) as? Bool ?? true
    }

    /// Suppresses the system idle timer only while a session is actually
    /// running. Apple's guidance is to hold it for as short a window as
    /// possible, so pausing, resetting or finishing hands it straight back —
    /// and the timing itself doesn't depend on it, since `remaining` is
    /// derived from `endDate` and the end alert is a scheduled notification.
    private func updateScreenWakeLock() {
        UIApplication.shared.isIdleTimerDisabled = keepsScreenAwake && isRunning
    }

    // MARK: - Recording seam

    /// Records the session to HealthKit while the timer runs. Injected in
    /// `NBExerciseApp`; still optional so previews and tests can run the timer
    /// without touching Health. Every call site below tolerates `nil`.
    var recorder: (any WorkoutRecorder)?

    /// Whether a recording is currently attached and live — drives the "REC"
    /// affordance in the timer view.
    var isRecording: Bool { recorder?.state.isActive ?? false }

    /// The live figures for the session in progress, for the metrics strip
    /// under the countdown. `.empty` when nothing is recording.
    ///
    /// Reading through to the recorder rather than mirroring its values means
    /// a view touching this observes the recorder directly, so each sample
    /// HealthKit collects invalidates only the strip.
    var liveMetrics: LiveWorkoutMetrics { recorder?.metrics ?? .empty }

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
            // Which milestones are worth announcing depends on the length,
            // so a new duration starts from a clean slate.
            motivation.reset()
            motivationalMessage = nil
            completionMessage = nil
        }
    }

    // MARK: - Transport

    func start() {
        guard !isRunning else { return }
        hasFinished = false
        recordingWarning = nil
        completionMessage = nil

        let resumeFrom: TimeInterval = remaining > 0
            ? remaining
            : TimeInterval(durationMinutes * 60)
        remaining = resumeFrom
        endDate = Date().addingTimeInterval(resumeFrom)
        isRunning = true

        scheduleTicker()
        scheduleEndNotification(in: resumeFrom)
        updateScreenWakeLock()

        // `resume` rather than a full restart: milestones already passed
        // stay passed, so un-pausing doesn't re-announce the halfway mark.
        if showsMotivation {
            motivation.resume()
            motivationalMessage = motivation.message
        }

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
        updateScreenWakeLock()

        // "Keep going" over a stopped clock is the wrong thing to say. The
        // provider keeps its state, so resuming picks up where it left off.
        motivationalMessage = nil

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
        updateScreenWakeLock()

        motivation.reset()
        motivationalMessage = nil
        completionMessage = nil

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
            updateMotivation(remaining: r)
            return
        }

        remaining = 0
        isRunning = false
        hasFinished = true
        self.endDate = nil
        tickerTask?.cancel()
        tickerTask = nil
        playEndAlertSound()
        // The session is over: let the screen lock as it normally would,
        // rather than burning battery on a completion banner.
        updateScreenWakeLock()

        // The countdown slot hands over to the sign-off, and the next
        // session deserves a full deck and a fresh set of milestones.
        motivation.reset()
        motivationalMessage = nil
        if showsMotivation {
            completionMessage = motivation.congratulate()
        }

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

    // MARK: - Motivation

    private func updateMotivation(remaining: TimeInterval) {
        guard showsMotivation else { return }
        motivation.update(
            remaining: remaining,
            total: TimeInterval(durationMinutes * 60)
        )
        // This runs five times a second and `@Observable` invalidates on
        // every assignment, so only publish when the line actually changes.
        if motivationalMessage != motivation.message {
            motivationalMessage = motivation.message
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
