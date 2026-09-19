//
//  HealthKitWorkoutRecorder.swift
//  NBExercise
//
//  Records the timed session as a real HealthKit workout, and publishes the
//  live metrics the Exercise tab shows while it runs.
//
//  An `HKWorkoutSession` on iOS is what makes live data possible at all: the
//  session's `HKLiveWorkoutBuilder` streams samples in as they're collected,
//  where the read path in `HealthKitWorkoutStore` can only query for workouts
//  that have already finished.
//
//  Two device caveats worth knowing, both surfaced as a dash in the UI rather
//  than a zero:
//
//    - iPhone and iPad have no heart-rate sensor. Heart rate appears only with
//      a paired Apple Watch or an external monitor.
//    - Energy on iPhone is estimated from motion, not measured. It's the
//      right order of magnitude, not a calorimeter reading.
//
//  Not yet wired up (deliberately out of scope here):
//    - A Live Activity, so the session stays visible on the Lock Screen. The
//      `audio` background mode the app already declares for podcast playback
//      keeps the process alive during a session with audio playing, but a
//      silent session backgrounded for a long stretch can still be suspended.
//    - `startWatchApp(with:)` to promote the session to the Watch, which is
//      where heart rate would actually come from.
//

import Foundation
import HealthKit
import Observation

/// The live implementation of `WorkoutRecorder`.
///
/// `NSObject` because `HKWorkoutSessionDelegate` and
/// `HKLiveWorkoutBuilderDelegate` are Objective-C protocols. The delegate
/// methods are `nonisolated` — HealthKit calls them from its own queues — and
/// each hops to the main actor before touching observable state.
@MainActor
@Observable
final class HealthKitWorkoutRecorder: NSObject, WorkoutRecorder {

    private(set) var state: RecordingState = .idle
    private(set) var metrics: LiveWorkoutMetrics = .empty

    private let store = HKHealthStore()

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    /// The activity the live session is recording, kept so the saved summary
    /// can be mapped back without re-reading the sample.
    private var activity: ExerciseActivity = .other

    /// Which distance metric is meaningful for the current activity, resolved
    /// once at start rather than on every sample callback.
    private var distanceType: HKQuantityType?

    // MARK: - Authorization types

    /// Recording writes workouts, so unlike the read path this needs a share
    /// set. `NSHealthUpdateUsageDescription` covers it in Info.plist.
    private let shareTypes: Set<HKSampleType> = [HKQuantityType.workoutType()]

    /// The builder only reports statistics for types the user has authorised,
    /// so the live metrics depend on this set matching what's displayed.
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

    // MARK: - Lifecycle

    func start(_ activity: ExerciseActivity) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw RecordingError.healthDataUnavailable
        }
        // A second start while one is live would orphan the first session,
        // leaving it collecting with nothing able to end it.
        guard session == nil else { return }

        state = .starting
        metrics = .empty
        self.activity = activity
        distanceType = Self.distanceType(for: activity)

        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)

            let configuration = HKWorkoutConfiguration()
            configuration.activityType = activity.hkWorkoutActivityType
            // `.unknown` rather than guessing indoor/outdoor: the app never
            // asks, and a wrong guess changes HealthKit's calorie model.
            configuration.locationType = .unknown

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

            // One start date for both, so the saved workout's duration and the
            // builder's elapsed time agree.
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)

            state = .running
        } catch {
            // Clear the half-built session so the next start is clean rather
            // than hitting the `session == nil` guard above forever.
            tearDown()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func pause() async {
        guard let session, state == .running else { return }
        // State is set by the delegate callback, not here — HealthKit is the
        // source of truth for whether the pause actually took.
        session.pause()
    }

    func resume() async {
        guard let session, state == .paused else { return }
        session.resume()
    }

    @discardableResult
    func end() async throws -> WorkoutSummary? {
        guard let session, let builder else { return nil }

        state = .ending
        let end = Date()
        session.end()

        do {
            try await builder.endCollection(at: end)
            let workout = try await builder.finishWorkout()
            tearDown()
            state = .idle
            // `finishWorkout()` returns nil when there was nothing worth
            // saving, which the protocol passes straight through.
            return workout.map { HealthKitWorkoutStore.summary(from: $0) }
        } catch {
            tearDown()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func discard() async {
        guard let session, let builder else { return }
        session.end()
        // Discarding stops collection and throws the samples away, so there's
        // no `endCollection` to await first.
        builder.discardWorkout()
        tearDown()
        state = .idle
    }

    /// Releases the session and builder. Delegates are cleared explicitly:
    /// a finished session can still deliver a trailing callback, and applying
    /// it would resurrect state for a session that no longer exists.
    private func tearDown() {
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
        distanceType = nil
    }

    // MARK: - Live metrics

    /// Re-reads the builder's running statistics. Called on every collection
    /// callback, so it stays a straight read with no allocation beyond the
    /// value type itself.
    private func refreshMetrics(from builder: HKLiveWorkoutBuilder) {
        // Most recent, not average: this is the "right now" figure on screen.
        let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
        let heartRate = builder
            .statistics(for: HKQuantityType(.heartRate))?
            .mostRecentQuantity()?
            .doubleValue(for: beatsPerMinute)

        let energy = builder
            .statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())

        let distance = distanceType
            .flatMap { builder.statistics(for: $0) }?
            .sumQuantity()?
            .doubleValue(for: .meter())

        metrics = LiveWorkoutMetrics(
            elapsed: builder.elapsedTime,
            heartRate: heartRate,
            activeEnergyBurnedKilocalories: energy,
            distanceMeters: distance
        )
    }

    /// Maps HealthKit's session state onto the app's own.
    ///
    /// `.notStarted` and `.prepared` are folded into `.starting`: from the
    /// timer's point of view both mean "asked for, not yet collecting".
    private func apply(_ sessionState: HKWorkoutSessionState) {
        switch sessionState {
        case .notStarted, .prepared: state = .starting
        case .running: state = .running
        case .paused: state = .paused
        case .stopped: state = .ending
        case .ended: state = .idle
        @unknown default: break
        }
    }

    // MARK: - Mapping

    /// Which distance quantity the activity actually produces. Strength work
    /// and yoga have none, so they get nil rather than a misleading zero.
    private static func distanceType(for activity: ExerciseActivity) -> HKQuantityType? {
        switch activity {
        case .walking, .running, .hiking:
            return HKQuantityType(.distanceWalkingRunning)
        case .cycling:
            return HKQuantityType(.distanceCycling)
        case .swimming:
            return HKQuantityType(.distanceSwimming)
        case .rowing, .elliptical, .strength, .yoga,
             .coreTraining, .highIntensityIntervalTraining, .other:
            return nil
        }
    }

    enum RecordingError: LocalizedError {
        case healthDataUnavailable

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable:
                return "This device doesn't support Health data."
            }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension HealthKitWorkoutRecorder: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor [weak self] in
            // Ignore callbacks from a session we've already let go of.
            guard let self, self.session === workoutSession else { return }
            self.apply(toState)
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
            self.tearDown()
            self.state = .failed(message)
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension HealthKitWorkoutRecorder: HKLiveWorkoutBuilderDelegate {

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
        // Pause and resume events reach the UI through the session delegate
        // above, so there's nothing to do with the builder's copy.
    }
}

// MARK: - Activity mapping

private extension ExerciseActivity {
    /// The HealthKit type to record as. The inverse of the mapping in
    /// `HealthKitWorkoutStore`, which narrows HealthKit's types down to these.
    var hkWorkoutActivityType: HKWorkoutActivityType {
        switch self {
        case .walking: return .walking
        case .running: return .running
        case .cycling: return .cycling
        case .hiking: return .hiking
        case .swimming: return .swimming
        case .rowing: return .rowing
        case .elliptical: return .elliptical
        case .strength: return .traditionalStrengthTraining
        case .yoga: return .yoga
        case .coreTraining: return .coreTraining
        case .highIntensityIntervalTraining: return .highIntensityIntervalTraining
        case .other: return .other
        }
    }
}
