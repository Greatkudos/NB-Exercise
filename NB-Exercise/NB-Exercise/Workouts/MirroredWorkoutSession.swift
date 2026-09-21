//
//  MirroredWorkoutSession.swift
//  NBExercise
//
//  The companion side of a workout running on the Apple Watch.
//
//  Two directions meet here:
//
//    - Watch to phone. `workoutSessionMirroringStartHandler` fires when the
//      watch calls `startMirroringToCompanionDevice()`, launching this app in
//      the background if it isn't already running. From then on the watch's
//      snapshots arrive on the session delegate, and this drives
//      `ExerciseTimerStore` from them — so the Exercise tab, the Live Activity
//      and the Lock Screen all show a session nobody started on this device.
//
//    - Phone to watch. `startOnWatch(_:)` promotes a session to the wrist with
//      `startWatchApp(with:)`, which is where heart rate actually comes from.
//      Once it lands, the watch mirrors straight back and the first direction
//      takes over.
//
//  What this deliberately does *not* do is record anything. A mirrored session
//  has no `HKLiveWorkoutBuilder` on this side, and the watch is already saving
//  the workout — a second recorder here would write a duplicate and fight the
//  watch for the one session the system allows.
//

import Foundation
import HealthKit
import Observation
import WatchConnectivity
import os

/// How the timer store reaches a session it doesn't own. Kept as a protocol so
/// the store has no dependency on HealthKit, matching the way `WorkoutRecorder`
/// keeps the store clear of it on the local path.
@MainActor
protocol RemoteSessionControlling: AnyObject {
    func send(_ command: ExerciseSessionCommand)
}

/// How the timer store asks for a session to be run on the watch instead of
/// here. Separate from `RemoteSessionControlling` because it's answered before
/// any session exists — and kept as a protocol for the same reason: so the
/// store never imports HealthKit.
@MainActor
protocol WatchSessionPromoting: AnyObject {
    /// Whether there's a watch to promote to. Drives whether the button is
    /// offered at all.
    var isWatchAvailable: Bool { get }

    func startOnWatch(_ activity: ExerciseActivity) async throws
}

@MainActor
@Observable
final class MirroredWorkoutSession: NSObject, WatchSessionPromoting {

    /// The store this drives. Weak: the store outlives this object in
    /// practice, and a strong reference here would close a cycle through
    /// `ExerciseTimerStore.remote`.
    @ObservationIgnored weak var timerStore: ExerciseTimerStore?

    private let store = HKHealthStore()

    /// The mirrored session currently running on the watch, if any.
    @ObservationIgnored private var session: HKWorkoutSession?

    private let log = Logger(
        subsystem: "com.maldeus.NB-Exercise",
        category: "MirroredWorkout"
    )

    /// Types the mirrored session needs authorised on this device. The watch
    /// asks for its own, but authorisation doesn't cross devices, and without
    /// it the mirrored session is refused.
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

    // MARK: - Listening

    /// Starts listening for sessions the watch mirrors over.
    ///
    /// Called from `NBExerciseApp.init()`, and the timing is the point: the
    /// system launches this app in the background to deliver a mirrored
    /// session, and Apple's guidance is to assign the handler as soon as the
    /// app launches or the session is missed. `init()` is the only code that
    /// runs on *every* launch, including headless ones.
    func beginListening() {
        store.workoutSessionMirroringStartHandler = { [weak self] mirroredSession in
            // The system calls this from an arbitrary background queue, and
            // it can call it more than once for a single workout: if the two
            // devices lose contact mid-session the watch reconnects, and each
            // reconnection brings a fresh `HKWorkoutSession` instance.
            Task { @MainActor [weak self] in
                self?.adopt(mirroredSession)
            }
        }
    }

    private func adopt(_ mirroredSession: HKWorkoutSession) {
        // Drop the previous instance's delegate first, so a stale session
        // reconnecting can't deliver snapshots over the live one.
        session?.delegate = nil
        session = mirroredSession
        mirroredSession.delegate = self
        timerStore?.remote = self
        log.debug("Adopted a mirrored session from Apple Watch")
    }

    // MARK: - Promoting a session to the watch

    /// Launches or wakes the watch app and asks it to start `activity`.
    ///
    /// Throws rather than reporting through the store, because the caller
    /// needs to know whether to fall back to recording on the phone.
    func startOnWatch(_ activity: ExerciseActivity) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw MirroringError.healthDataUnavailable
        }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
        try await store.startWatchApp(toHandle: activity.workoutConfiguration)
    }

    /// Whether promoting to the watch is worth offering. False with no watch
    /// paired, or with the watch app not installed on it, where the button
    /// would only ever fail.
    ///
    /// `WCSession` is used for the question and nothing else — the session
    /// data itself travels over HealthKit's own channel, which survives the
    /// phone being backgrounded in a way Watch Connectivity messages don't.
    var isWatchAvailable: Bool {
        guard WCSession.isSupported() else { return false }
        let session = WCSession.default
        if session.activationState == .notActivated {
            session.delegate = self
            session.activate()
            // Nothing to report yet; the next read will have an answer.
            return false
        }
        return session.isPaired && session.isWatchAppInstalled
    }

    enum MirroringError: LocalizedError {
        case healthDataUnavailable

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable:
                return "This device doesn't support Health data."
            }
        }
    }

    // MARK: - Letting go

    private func release(finalSnapshot: ExerciseSessionSnapshot?) {
        guard session != nil else { return }
        session?.delegate = nil
        session = nil
        timerStore?.endRemoteSession(finalSnapshot)
        log.debug("Mirrored session ended")
    }
}

// MARK: - WCSessionDelegate

/// Required only so `WCSession` can be activated for the pairing query in
/// `isWatchAvailable`. No session data crosses this channel — it all travels
/// over HealthKit's mirrored-session channel instead — so these are the three
/// methods iOS demands and nothing more.
extension MirroredWorkoutSession: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Reached when the user switches to a different Apple Watch. Reactivating
    /// is what connects to the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}

// MARK: - RemoteSessionControlling

extension MirroredWorkoutSession: RemoteSessionControlling {

    /// Forwards a transport command to the watch. Fire and forget: the watch
    /// answers with a snapshot, and that — not the success of this send — is
    /// what moves the UI.
    func send(_ command: ExerciseSessionCommand) {
        guard let session else { return }
        let message = ExerciseSessionMessage.command(command)
        Task {
            do {
                try await session.sendToRemoteWorkoutSession(data: message.encoded())
            } catch {
                log.error(
                    "Couldn't send \(command.rawValue, privacy: .public) to the watch: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension MirroredWorkoutSession: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        // Decoded here so only `Sendable` values cross to the main actor.
        //
        // Only the last snapshot matters. While this app is backgrounded
        // HealthKit accumulates the watch's pushes and hands over the whole
        // backlog at once — sometimes minutes of it — and every snapshot is
        // complete, so replaying the older ones would just animate the UI
        // through history before landing on the same place.
        let snapshots = data.compactMap { payload -> ExerciseSessionSnapshot? in
            guard case .snapshot(let snapshot) = try? ExerciseSessionMessage.decoded(from: payload)
            else { return nil }
            return snapshot
        }
        guard let latest = snapshots.last else { return }

        // An end can be buried mid-backlog when a short session finishes while
        // the app was away, so it's looked for across the batch, not just on
        // the snapshot that happens to be last.
        let ended = snapshots.contains { $0.isEnded }

        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            if ended {
                self.release(finalSnapshot: latest)
            } else {
                self.timerStore?.applyRemoteSnapshot(latest)
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            // Transport state comes from the watch's snapshots, which carry
            // the countdown with it. The only transition that matters here is
            // the end — the backstop for a session that stopped without its
            // final snapshot getting through.
            if toState == .ended || toState == .stopped {
                self.release(finalSnapshot: nil)
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        // `Error` isn't Sendable, so the message crosses the boundary instead.
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.session === workoutSession else { return }
            self.log.error("Mirrored session failed: \(message, privacy: .public)")
            self.release(finalSnapshot: nil)
        }
    }
}
