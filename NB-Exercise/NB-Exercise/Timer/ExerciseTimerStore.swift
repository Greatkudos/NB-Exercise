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
    /// affordance in the timer view. A watch session is always recording:
    /// that's the only reason the watch started one.
    var isRecording: Bool {
        isRemote ? true : (recorder?.state.isActive ?? false)
    }

    /// The live figures for the session in progress, for the metrics strip
    /// under the countdown. `.empty` when nothing is recording.
    ///
    /// Reading through to the recorder rather than mirroring its values means
    /// a view touching this observes the recorder directly, so each sample
    /// HealthKit collects invalidates only the strip. A watch session has no
    /// local recorder to read through to, so its figures are held here.
    var liveMetrics: LiveWorkoutMetrics {
        isRemote ? remoteMetrics : (recorder?.metrics ?? .empty)
    }

    // MARK: - Live Activity seam

    /// Mirrors the session to the Lock Screen, the Dynamic Island and — the
    /// reason it's here — the Apple Watch Smart Stack. Injected in
    /// `NBExerciseApp` and optional for the same reason the recorder is:
    /// previews and tests run the timer without ActivityKit.
    var liveActivity: ExerciseLiveActivityController?

    /// When the last metrics push went out, for the throttle below.
    private var lastLiveActivityPush: Date?

    /// How often live metrics are pushed while a session runs. The countdown
    /// needs no pushes at all — the Live Activity ticks it locally from
    /// `endDate` — so these exist purely to refresh heart rate and energy, and
    /// ActivityKit meters an app's updates. Half a minute keeps the figures
    /// current without spending the budget in the first two minutes.
    private static let liveActivityUpdateInterval: TimeInterval = 30

    // MARK: - Remote (watch-owned) sessions

    /// True while an Apple Watch is running the session and this store is
    /// mirroring it. Everything on screen works the same way — the countdown,
    /// the metrics strip, the motivation lines, the Live Activity — but the
    /// transport buttons become remote controls, because the watch owns the
    /// `HKWorkoutSession` and only it can pause or end one.
    private(set) var isRemote: Bool = false

    /// The channel back to the watch. Set by `MirroredWorkoutSession` when it
    /// adopts a session, cleared when the session ends.
    var remote: (any RemoteSessionControlling)?

    /// Figures from the watch's last snapshot. Held rather than read through
    /// because there's no local recorder collecting them.
    private var remoteMetrics: LiveWorkoutMetrics = .empty

    /// Promotes a session to the Apple Watch. Injected in `NBExerciseApp`;
    /// optional like the recorder and the Live Activity, so previews and
    /// tests run the timer without HealthKit.
    var watch: (any WatchSessionPromoting)?

    /// Whether the Start on Watch affordance is worth showing.
    var canStartOnWatch: Bool {
        !isRemote && !isRunning && (watch?.isWatchAvailable ?? false)
    }

    /// Asks the watch app to run this session instead of the phone.
    ///
    /// Nothing is started here on success: the watch starts the session and
    /// mirrors it straight back, and this store adopts it through
    /// `applyRemoteSnapshot` like any other watch-driven session. So a failure
    /// is the only thing worth reporting, and it leaves the timer exactly
    /// where it was — the user can just press Start instead.
    func startOnWatch() async {
        guard let watch else { return }
        recordingWarning = nil
        do {
            try await watch.startOnWatch(activity)
        } catch {
            recordingWarning =
                "Couldn't start this on your Apple Watch: \(error.localizedDescription)"
        }
    }

    // MARK: - Internal timing state

    private var endDate: Date?
    private var tickerTask: Task<Void, Never>?

    // MARK: - Duration

    func setDuration(_ minutes: Int) {
        let clamped = min(max(minutes, Self.minMinutes), Self.maxMinutes)
        durationMinutes = clamped
        // Changing the dial mid-session shouldn't yank the clock out from
        // under a running timer; the new length applies to the next one. A
        // watch session counts as running even while paused — its length is
        // the watch's to decide, and the next snapshot would overwrite this.
        if !isRunning && !isRemote {
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
        // The watch owns its session, so this is a request, not a change. The
        // state that comes back in the next snapshot is what moves the UI.
        if isRemote {
            remote?.send(.resume)
            return
        }
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

        // Starts the activity, or updates the existing one when this call is
        // an un-pause. The controller works out which.
        lastLiveActivityPush = Date()
        liveActivity?.start(
            activityName: activity.displayName,
            symbolName: activity.symbolName,
            totalDuration: TimeInterval(durationMinutes * 60),
            state: liveActivityState()
        )

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
        if isRemote {
            remote?.send(.pause)
            return
        }
        guard isRunning else { return }
        // Snapshot the live remaining time before tearing down the ticker so
        // resuming continues from exactly where we paused.
        if let endDate {
            remaining = max(0, endDate.timeIntervalSinceNow)
        }
        stopClock()

        // "Keep going" over a stopped clock is the wrong thing to say. The
        // provider keeps its state, so resuming picks up where it left off.
        motivationalMessage = nil

        // Pushed unthrottled: the button the user just pressed has to flip on
        // the wrist straight away, or they'll press it again.
        pushLiveActivity()

        Task { [recorder] in await recorder?.pause() }
    }

    /// Stops and clears the session without saving it.
    func reset() {
        if isRemote {
            remote?.send(.discard)
            return
        }
        stopClock()
        hasFinished = false
        recordingWarning = nil
        remaining = TimeInterval(durationMinutes * 60)

        motivation.reset()
        motivationalMessage = nil
        completionMessage = nil

        // Nothing worth glancing at afterwards, so the activity goes away
        // immediately rather than lingering on the Lock Screen.
        liveActivity?.cancel()

        // A reset is an abandonment, not a completion — discard rather than
        // save, so a mis-tap doesn't litter Health with 4-second workouts.
        Task { [recorder] in await recorder?.discard() }
    }

    /// Ends the session now and saves what was done.
    ///
    /// This is what the Live Activity's End button calls, and it's
    /// deliberately not `reset()`: someone stopping ten minutes into a twenty
    /// minute walk has still walked for ten minutes and should get the credit.
    /// Reaching zero on its own goes through `tick()`, which does the same
    /// save.
    func finish() {
        if isRemote {
            remote?.send(.finish)
            return
        }

        // Nothing has run, so there's nothing to save — and no activity to
        // end. Guards against a stale button in an activity the app has
        // already moved on from.
        guard isRunning || remaining < TimeInterval(durationMinutes * 60) else {
            return
        }

        stopClock()

        // The final card, before the counters go back to their idle values.
        liveActivity?.end(liveActivityState(hasFinished: true))

        remaining = TimeInterval(durationMinutes * 60)
        hasFinished = false
        motivation.reset()
        motivationalMessage = nil
        completionMessage = nil

        Task { [recorder] in
            guard let recorder else { return }
            do { try await recorder.end() }
            catch {
                self.recordingWarning =
                    "Couldn't save this session to Health: \(error.localizedDescription)"
            }
        }
    }

    /// Stops the countdown and hands back everything held only while it runs.
    /// Leaves `remaining` alone — each caller has its own idea of what should
    /// be left on the clock afterwards.
    private func stopClock() {
        tickerTask?.cancel()
        tickerTask = nil
        endDate = nil
        isRunning = false
        cancelEndNotification()
        updateScreenWakeLock()
    }

    // MARK: - Remote sessions

    /// Takes the watch's latest snapshot as the truth for this screen.
    ///
    /// Adoption and update are one code path on purpose. HealthKit will hand
    /// this app a mirrored session it has never seen before — after the two
    /// devices reconnect, or after launching the app headlessly part-way
    /// through a workout — so there's no "session started" moment to hang
    /// setup off. Every snapshot is complete, so the first one to arrive is
    /// enough to reconstruct the whole screen whenever it arrives.
    func applyRemoteSnapshot(_ snapshot: ExerciseSessionSnapshot) {
        let isAdopting = !isRemote
        let wasRunning = isRunning

        if isAdopting {
            // Apple Watch runs one workout session at a time and the watch's
            // has won. Discard rather than save what was going here: a few
            // seconds of phone-side session isn't a workout, and two
            // overlapping records of one walk is worse than none.
            if recorder?.state.isActive == true {
                Task { [recorder] in await recorder?.discard() }
            }
            isRemote = true
            recordingWarning = nil
            completionMessage = nil
            motivation.reset()
        }

        activity = snapshot.activity
        durationMinutes = min(
            max(Int((snapshot.totalDuration / 60).rounded()), Self.minMinutes),
            Self.maxMinutes
        )
        endDate = snapshot.endDate
        remaining = max(0, snapshot.remaining)
        isRunning = snapshot.isRunning
        hasFinished = snapshot.hasFinished
        remoteMetrics = LiveWorkoutMetrics(
            elapsed: snapshot.elapsed,
            heartRate: snapshot.heartRate,
            activeEnergyBurnedKilocalories: snapshot.activeEnergyBurnedKilocalories,
            distanceMeters: snapshot.distanceMeters
        )

        if isRunning {
            // The phone ticks its own clock from `endDate`, so the countdown
            // stays smooth between the watch's pushes rather than jumping
            // every few seconds — and stays right through a gap in contact.
            if tickerTask == nil { scheduleTicker() }
            if (isAdopting || !wasRunning) && showsMotivation {
                motivation.resume()
                motivationalMessage = motivation.message
            }
        } else {
            tickerTask?.cancel()
            tickerTask = nil
            // "Keep going" over a stopped clock is the wrong thing to say.
            motivationalMessage = nil
        }
        updateScreenWakeLock()

        if isAdopting {
            // The session reaches the Lock Screen and the Smart Stack the
            // same way a local one does. Nothing downstream needs to know a
            // watch started it.
            lastLiveActivityPush = Date()
            liveActivity?.start(
                activityName: activity.displayName,
                symbolName: activity.symbolName,
                totalDuration: TimeInterval(durationMinutes * 60),
                state: liveActivityState()
            )
        } else if wasRunning != isRunning {
            // Unthrottled for the same reason a local pause is: the user is
            // waiting to see the button they pressed take effect. Metrics
            // ride the throttle in `tick()`.
            pushLiveActivity()
        }
    }

    /// Lets go of a watch session. The watch has already saved or discarded
    /// the workout by the time this runs — all that's left is to put this
    /// screen back.
    func endRemoteSession(_ snapshot: ExerciseSessionSnapshot?) {
        guard isRemote else { return }

        stopClock()

        // Applied before the final card is built so it carries the watch's
        // closing figures rather than whatever the last push happened to say.
        if let snapshot {
            remaining = max(0, snapshot.remaining)
            hasFinished = snapshot.hasFinished || hasFinished
            remoteMetrics = LiveWorkoutMetrics(
                elapsed: snapshot.elapsed,
                heartRate: snapshot.heartRate,
                activeEnergyBurnedKilocalories: snapshot.activeEnergyBurnedKilocalories,
                distanceMeters: snapshot.distanceMeters
            )
        }

        // Built while `isRemote` is still true, so `liveMetrics` still reads
        // the watch's figures and not an empty local recorder.
        liveActivity?.end(liveActivityState())

        isRemote = false
        remote = nil
        remoteMetrics = .empty
        motivationalMessage = nil

        // A session that ran to zero keeps its finished state and its empty
        // clock, matching what `tick()` leaves behind locally — the
        // completion banner is the only confirmation this device gives. One
        // stopped early has nothing to show, so the dial goes back to full.
        if !hasFinished {
            remaining = TimeInterval(durationMinutes * 60)
        }
        updateScreenWakeLock()
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
            pushLiveActivityIfDue()
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
        // A watch session saves itself and sends a final snapshot when it's
        // done, which `endRemoteSession` acts on. Ending the Live Activity or
        // the recorder from here would duplicate that at best and race it at
        // worst — and there's no local recorder to end in the first place.
        guard !isRemote else { return }

        cancelEndNotification()

        // Leaves the sign-off on the Lock Screen and the watch briefly, so a
        // glance right after the session still shows how it went.
        liveActivity?.end(liveActivityState())

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

    // MARK: - Live Activity

    /// Snapshots the session for the Live Activity.
    ///
    /// `endDate` goes across rather than a formatted countdown so the activity
    /// can tick its own clock — see `ExerciseSessionAttributes`.
    private func liveActivityState(
        hasFinished: Bool? = nil
    ) -> ExerciseSessionAttributes.ContentState {
        let metrics = liveMetrics
        return ExerciseSessionAttributes.ContentState(
            endDate: endDate,
            remaining: remaining,
            isRunning: isRunning,
            hasFinished: hasFinished ?? self.hasFinished,
            heartRate: metrics.heartRate,
            activeEnergyBurnedKilocalories: metrics.activeEnergyBurnedKilocalories,
            distanceMeters: metrics.distanceMeters,
            // The countdown has handed over to the sign-off by the time
            // there's a completion message, matching what the app shows.
            message: motivationalMessage ?? completionMessage
        )
    }

    /// Pushes the current state immediately. For transport changes, where the
    /// user is waiting to see the button they pressed take effect.
    private func pushLiveActivity() {
        guard let liveActivity else { return }
        lastLiveActivityPush = Date()
        liveActivity.update(liveActivityState())
    }

    /// Pushes the current state if the throttle has elapsed. Called from the
    /// 200ms ticker, which is far too often to push on every tick.
    private func pushLiveActivityIfDue() {
        if let last = lastLiveActivityPush,
           Date().timeIntervalSince(last) < Self.liveActivityUpdateInterval {
            return
        }
        pushLiveActivity()
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
