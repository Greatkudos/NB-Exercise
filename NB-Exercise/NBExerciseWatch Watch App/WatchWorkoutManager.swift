//
//  WatchWorkoutManager.swift
//  NBExercise Watch App
//
//  The primary side of a mirrored workout. This is where the session actually
//  lives now: the watch owns the `HKWorkoutSession`, collects the samples, runs
//  the countdown and saves the workout, and the iPhone mirrors it.
//
//  That inversion is the whole point of the watch app. `HealthKitWorkoutRecorder`
//  on the phone can run a session too, but an iPhone has no heart-rate sensor
//  and estimates energy from motion. Here the figures are measured.
//
//  Three things go across to the phone, all through
//  `sendToRemoteWorkoutSession(data:)`:
//
//    - the countdown, as an absolute `endDate` so the phone can tick its own
//      clock smoothly between pushes rather than freezing between them;
//    - the live metrics, which the mirrored session does *not* deliver by
//      itself — there's no `HKLiveWorkoutBuilder` on the companion side;
//    - the transport state, so the phone's buttons show what's true.
//
//  And one thing comes back: `ExerciseSessionCommand`, when the user works the
//  controls on the phone or in the Live Activity.
//
//  The timing approach matches the phone's `ExerciseTimerStore`: `remaining` is
//  always derived from an absolute `endDate`, never accumulated tick by tick,
//  so a dropped or delayed tick can't make the clock drift.
//

import Foundation
import HealthKit
import Observation
import WatchKit
import os

@MainActor
@Observable
final class WatchWorkoutManager: NSObject {

    // MARK: - Configuration

    var activity: ExerciseActivity = .other

    private(set) var durationMinutes: Int = 20

    static let minMinutes = 1
    static let maxMinutes = 60

    /// Durations offered as one-tap presets. A shorter list than the phone's:
    /// six capsules don't fit a watch screen legibly.
    static let presets = [10, 20, 30, 45]

    // MARK: - Session state

    private(set) var remaining: TimeInterval = 20 * 60
    private(set) var isRunning: Bool = false
    private(set) var hasFinished: Bool = false

    /// Whether a workout session exists at all — true while paused, unlike
    /// `isRunning`. Drives which screen the watch shows.
    private(set) var isSessionActive: Bool = false

    /// Set when something in HealthKit refuses. Shown on the wrist; never
    /// stops the countdown, matching the phone's rule that a Health failure
    /// must not cost the user their session.
    private(set) var errorMessage: String?

    // MARK: - Live metrics

    /// Held as loose values rather than the phone's `LiveWorkoutMetrics`,
    /// which lives in a file the watch target has no other reason to compile.
    private(set) var heartRate: Double?
    private(set) var activeEnergyBurnedKilocalories: Double?
    private(set) var distanceMeters: Double?
    private(set) var elapsed: TimeInterval = 0

    // MARK: - HealthKit

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// Resolved once at start rather than on every sample callback.
    private var distanceType: HKQuantityType?

    private let log = Logger(
        subsystem: "com.maldeus.NB-Exercise.watchkitapp",
        category: "Workout"
    )

    private let shareTypes: Set<HKSampleType> = [HKQuantityType.workoutType()]

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        let quantities: [HKQuantityTypeIdentifier] = [
            .activeEnergyBurned,
            .heartRate,
            .distanceWalkingRunning,
            .distanceCycling,
            .distanceSwimming
        ]
        for identifier in quantities {
            types.insert(HKQuantityType(identifier))
        }
        return types
    }

    // MARK: - Timing

    private var endDate: Date?
    private var tickerTask: Task<Void, Never>?

    /// How often the full snapshot goes to the phone while running. The
    /// countdown needs no pushes — the phone ticks it from `endDate` — so this
    /// is paced to the metrics, and the watch's heart-rate sampling during a
    /// workout is roughly this often anyway.
    private static let pushInterval: TimeInterval = 5

    private var lastPush: Date?

    // MARK: - Duration

    func setDuration(_ minutes: Int) {
        let clamped = min(max(minutes, Self.minMinutes), Self.maxMinutes)
        durationMinutes = clamped
        // Changing the dial mid-session shouldn't yank the clock out from
        // under a running timer; the new length applies to the next one.
        guard !isSessionActive else { return }
        remaining = TimeInterval(clamped * 60)
        hasFinished = false
    }

    // MARK: - Starting

    /// Starts a session for the current `activity`.
    func start() async {
        guard session == nil else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "This watch doesn't support Health data."
            return
        }

        errorMessage = nil
        hasFinished = false
        resetMetrics()

        let activity = self.activity
        distanceType = activity.distanceQuantityType

        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)

            let configuration = activity.workoutConfiguration
            let session = try HKWorkoutSession(
                healthStore: store,
                configuration: configuration
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: store,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self

            self.session = session
            self.builder = builder

            // Mirroring is started *before* the activity so the phone catches
            // the whole session. Failing here isn't fatal — the workout is
            // still worth recording on the wrist — so it's logged, not thrown.
            do {
                try await session.startMirroringToCompanionDevice()
            } catch {
                log.error(
                    "Couldn't mirror to iPhone: \(error.localizedDescription, privacy: .public)"
                )
            }

            // One start date for both, so the saved workout's duration and the
            // builder's elapsed time agree.
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)

            isSessionActive = true
            beginCountdown(from: TimeInterval(durationMinutes * 60))

            // Mirroring hands the phone a session object but no state, so
            // without this first push the phone knows a workout exists and
            // nothing about it until the throttle next elapses.
            push()
        } catch {
            tearDown()
            errorMessage = error.localizedDescription
        }
    }

    /// Starts a session the iPhone asked for with `startWatchApp(with:)`.
    /// The configuration carries the activity but not the length, so the
    /// watch's own duration stands.
    func start(with configuration: HKWorkoutConfiguration) async {
        guard session == nil else { return }
        activity = ExerciseActivity(configuration)
        await start()
    }

    // MARK: - Transport

    func pause() {
        guard let session, isRunning else { return }
        // Snapshot the live remaining time before tearing down the ticker so
        // resuming continues from exactly where we paused.
        if let endDate {
            remaining = max(0, endDate.timeIntervalSinceNow)
        }
        stopClock()
        session.pause()
        // Unthrottled: the button the user just pressed has to flip on the
        // phone straight away, or they'll press it again.
        push()
    }

    func resume() {
        guard let session, isSessionActive, !isRunning, !hasFinished else { return }
        session.resume()
        beginCountdown(from: remaining > 0 ? remaining : TimeInterval(durationMinutes * 60))
        push()
    }

    /// Ends the session now and saves what was done.
    ///
    /// Deliberately not `discard()`: someone stopping ten minutes into a twenty
    /// minute walk has still walked for ten minutes and should get the credit.
    func finish() {
        Task { await endSession(saving: true) }
    }

    /// Abandons the session without saving, so a mis-tap doesn't litter Health
    /// with four-second workouts.
    func discard() {
        Task { await endSession(saving: false) }
    }

    /// Guards the two entry points above against a double tap, and against
    /// `tick()` reaching zero at the same moment the user presses stop.
    private var isEnding = false

    /// Ending is one sequence rather than two, because the order matters at
    /// every step and none of it can be left to chance:
    ///
    ///   1. The final snapshot goes out *before* `end()`. Once the session
    ///      ends the remote channel is closing, and the phone would be left
    ///      showing whatever the previous push happened to say.
    ///   2. Mirroring stops only after that snapshot has actually landed.
    ///   3. Teardown comes last, so nothing above is holding a released
    ///      session.
    private func endSession(saving: Bool) async {
        guard let session, let builder, !isEnding else { return }
        isEnding = true
        defer { isEnding = false }

        stopClock()
        isSessionActive = false

        await sendFinalSnapshot(over: session)

        let end = Date()
        session.end()

        if saving {
            do {
                try await builder.endCollection(at: end)
                _ = try await builder.finishWorkout()
            } catch {
                errorMessage = "Couldn't save this session to Health: \(error.localizedDescription)"
            }
        } else {
            // Discarding stops collection and throws the samples away, so
            // there's no `endCollection` to await first.
            builder.discardWorkout()
        }

        try? await session.stopMirroringToCompanionDevice()

        tearDown()
        hasFinished = false
        remaining = TimeInterval(durationMinutes * 60)
        resetMetrics()
    }

    /// The last word to the phone, carrying `isEnded` so it lets go rather
    /// than waiting for updates that will never come.
    ///
    /// Sent while `hasFinished` still holds whatever `tick()` left there, so
    /// a session that ran to zero is distinguishable on the phone from one
    /// stopped early — that's what decides whether it shows the completion
    /// banner.
    private func sendFinalSnapshot(over session: HKWorkoutSession) async {
        let message = ExerciseSessionMessage.snapshot(snapshot(ended: true))
        do {
            try await session.sendToRemoteWorkoutSession(data: message.encoded())
        } catch {
            // Not fatal. The mirrored session moving to `.ended` reaches the
            // phone on its own callback, and that's the backstop for exactly
            // this — it just arrives without the closing figures.
            log.debug(
                "Final snapshot didn't reach iPhone: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Releases the session and builder. Delegates are cleared explicitly: a
    /// finished session can still deliver a trailing callback, and applying it
    /// would resurrect state for a session that no longer exists.
    private func tearDown() {
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
        distanceType = nil
        isSessionActive = false
        isRunning = false
        lastPush = nil
    }

    private func resetMetrics() {
        heartRate = nil
        activeEnergyBurnedKilocalories = nil
        distanceMeters = nil
        elapsed = 0
    }

    // MARK: - Countdown

    private func beginCountdown(from interval: TimeInterval) {
        remaining = interval
        endDate = Date().addingTimeInterval(interval)
        isRunning = true
        scheduleTicker()
    }

    private func stopClock() {
        tickerTask?.cancel()
        tickerTask = nil
        endDate = nil
        isRunning = false
    }

    private func scheduleTicker() {
        tickerTask?.cancel()
        // One second rather than the phone's 200ms: the wrist shows mm:ss, and
        // an active workout session keeps this app running in the background,
        // where watchOS suspends apps that spend too much CPU.
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
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
            pushIfDue()
            return
        }

        remaining = 0
        stopClock()
        hasFinished = true

        // A haptic, not a sound: this is the one alert the user will actually
        // feel if the watch is on their wrist and the phone is in a pocket.
        WKInterfaceDevice.current().play(.notification)

        // Reaching zero is a completed session, so it saves — the same rule
        // the phone's timer follows.
        finish()
    }

    // MARK: - Pushing to the phone

    /// Everything the phone needs to render the session right now.
    private func snapshot(ended: Bool = false) -> ExerciseSessionSnapshot {
        ExerciseSessionSnapshot(
            activity: activity,
            totalDuration: TimeInterval(durationMinutes * 60),
            endDate: endDate,
            remaining: remaining,
            isRunning: isRunning,
            hasFinished: hasFinished,
            isEnded: ended,
            elapsed: elapsed,
            heartRate: heartRate,
            activeEnergyBurnedKilocalories: activeEnergyBurnedKilocalories,
            distanceMeters: distanceMeters
        )
    }

    /// Sends the current state immediately. For transport changes, where the
    /// user is waiting to see the button they pressed take effect.
    private func push() {
        guard let session else { return }
        lastPush = Date()
        let message = ExerciseSessionMessage.snapshot(snapshot())
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: message.encoded())
            } catch {
                // The phone being out of range is ordinary, not exceptional —
                // the watch keeps recording either way, and the next snapshot
                // carries the full state, so nothing needs re-sending.
                log.debug(
                    "Snapshot didn't reach iPhone: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Sends if the throttle has elapsed. Called from the ticker and from every
    /// sample callback, both of which are far too often to push on.
    private func pushIfDue() {
        if let lastPush, Date().timeIntervalSince(lastPush) < Self.pushInterval {
            return
        }
        push()
    }

    // MARK: - Commands from the phone

    private func apply(_ command: ExerciseSessionCommand) {
        switch command {
        case .pause: pause()
        case .resume: resume()
        case .finish: finish()
        case .discard: discard()
        }
    }

    // MARK: - Metrics

    /// Re-reads the builder's running statistics. Called on every collection
    /// callback, so it stays a straight read with no allocation beyond the
    /// values themselves.
    private func refreshMetrics(from builder: HKLiveWorkoutBuilder) {
        // Most recent, not average: this is the "right now" figure.
        let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
        heartRate = builder
            .statistics(for: HKQuantityType(.heartRate))?
            .mostRecentQuantity()?
            .doubleValue(for: beatsPerMinute)

        activeEnergyBurnedKilocalories = builder
            .statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())

        distanceMeters = distanceType
            .flatMap { builder.statistics(for: $0) }?
            .sumQuantity()?
            .doubleValue(for: .meter())

        elapsed = builder.elapsedTime
        pushIfDue()
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WatchWorkoutManager: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            // Ignore callbacks from a session we've already let go of.
            guard let self, self.session === workoutSession else { return }
            // The countdown is this object's own business — HealthKit is only
            // consulted for whether the *recording* is live, which is what the
            // phone needs to know to show "Paused" honestly.
            if toState == .running, !self.isRunning, !self.hasFinished {
                self.push()
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        // Read the message out here: `Error` isn't Sendable, so the string
        // crosses the isolation boundary instead of the error itself.
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            self.stopClock()
            // Most often this is `errorAnotherWorkoutSessionStarted` — the user
            // began a workout in another app, and the watch runs only one at a
            // time. Ours is already over by the time this arrives, so there's
            // no sending a closing snapshot; the phone's mirrored session
            // fails alongside it and releases on its own delegate callback.
            self.tearDown()
            self.errorMessage = message
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        // Decoded out here so only `Sendable` values cross to the main actor.
        let commands = data.compactMap { payload -> ExerciseSessionCommand? in
            guard case .command(let command) = try? ExerciseSessionMessage.decoded(from: payload)
            else { return nil }
            return command
        }
        guard !commands.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            // In order: HealthKit delivers a backlog when the app resumes, and
            // pause-then-resume has to land as resume, not pause.
            for command in commands { self.apply(command) }
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        // The collected types are ignored: re-reading all the statistics is
        // cheap, and it keeps every metric consistent with one another rather
        // than updating them piecemeal.
        Task { @MainActor [weak self] in
            guard let self, self.builder === workoutBuilder else { return }
            self.refreshMetrics(from: workoutBuilder)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Pause and resume events reach the phone through `push()` at the
        // transport points, so there's nothing to do with the builder's copy.
    }
}
