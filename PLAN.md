# NB-Exercise — Template Build Plan

Exercise app for iPhone and iPad: a timer to set the length of an exercise, a
podcast player to listen while working out, and stats drawn from workout
activity data recorded by iPhone or Apple Watch.

Status: **all 20 source files written to `Sources/`. No Xcode project yet, so
nothing has been compiled.** See "Current state" at the bottom.

## Decisions already made

| Question | Decision |
|---|---|
| HealthKit scope | **Read-only stats** to start. Design must leave an explicit seam so workout *recording* can be added later without rework. |
| Targets | **Single multiplatform iOS app** (iPhone + iPad). No watchOS target yet — Watch data still arrives via the shared Health store. |
| Persistence | **SwiftData.** Port Nexus's podcast logic onto `@Model` types; drop the Core Data KVC layer and the iCloud sync/tombstone machinery. |

## Source material — Nexus

Repo: `/Users/Developer/Documents/GitHub/nexus`

| Component | Path (relative to repo) | Lines | Plan |
|---|---|---|---|
| Focus timer | `Nexus/FocusTimerView.swift` | 271 | Port near-verbatim. `FocusTimerStore` is self-contained: end-date-based ticking (immune to missed ticks), `UNUserNotificationCenter` alert, `AudioServicesPlayAlertSound` on finish. |
| Podcast models | `Nexus/Nexus/PodcastModels.swift` | 57 | Copy directly — pure value types. |
| Feed parser | `Nexus/Nexus/PodcastParser.swift` | 230 | Copy. Needs `String.strippingHTML`. |
| Playback controller | `Nexus/Nexus/PodcastPlaybackController.swift` | 484 | Copy, minus the `.nexusAudioPlaybackDidStart` cross-player pausing (no second player here). Already uses the iOS 27 audio-session APIs — no modernizing needed. |
| Model layer | `Nexus/Nexus/PodcastManager.swift` | 622 | **Rework.** Subscription / episode-state / download / iTunes-search logic is sound, but persistence is Core Data KVC + `SyncTombstone` + iCloud archive. Re-express on SwiftData. |

Helpers to lift: `String.strippingHTML` (`Nexus/Nexus/RSSModels.swift:91`),
`RSSFeedManager.normalizeFeedURL` (`Nexus/Nexus/RSSFeedManager.swift:122`).

## Target structure

```
NBExercise/
  App/
    NBExerciseApp.swift              @main, ModelContainer, app-scope stores
    RootView.swift                   TabView shell: Exercise / Listen / Stats
  Timer/
    ExerciseTimerStore.swift         ported FocusTimerStore + recorder hooks
    ExerciseTimerView.swift          ported FocusTimerView
  Podcasts/
    PodcastModels.swift              copied value types
    PodcastParser.swift              copied
    PodcastPlaybackController.swift  copied, decoupled
    PodcastPersistence.swift         @Model Subscription, EpisodeState
    PodcastStore.swift               replaces PodcastManager, SwiftData-backed
    PodcastsView.swift               subscription list, episodes, now-playing bar
  Workouts/
    WorkoutSummary.swift             app value types, no HealthKit in the signature
    WorkoutDataSource.swift          protocol — the read seam
    WorkoutRecorder.swift            protocol — the future write seam (no impl yet)
    HealthKitWorkoutStore.swift      read-only HKHealthStore implementation
    SampleWorkoutStore.swift         canned data for previews + simulator
    WorkoutStatsView.swift           rings, weekly totals, recent workouts
  Support/
    String+HTML.swift
```

## The seam for recording later

This is the part that matters for "we may change to recording at a later date".

`WorkoutSummary` and friends are **our own value types**, not `HKWorkout`, so
nothing above the store layer imports HealthKit. Reading goes through:

```swift
protocol WorkoutDataSource: Sendable {
    func requestAuthorization() async throws
    func recentWorkouts(limit: Int) async throws -> [WorkoutSummary]
    func weeklyTotals() async throws -> ActivityTotals
    func dailyRings(days: Int) async throws -> [DailyRings]
}
```

Writing gets its protocol declared now but left unimplemented:

```swift
protocol WorkoutRecorder: AnyObject {
    var state: RecordingState { get }
    func start(_ activity: ExerciseActivity) async throws
    func pause() async
    func resume() async
    func end() async throws -> WorkoutSummary?
}
```

`ExerciseTimerStore` holds an `optional recorder: WorkoutRecorder?` that is
`nil` today and calls the lifecycle hooks at the right moments anyway. Adding
recording later means writing one `HKWorkoutSession`-backed conformance and
injecting it — no changes to the timer or any view.

## Build order

0. Create the Xcode project (see risk note below).
1. Project config: HealthKit entitlement, `NSHealthShareUsageDescription`,
   `UIBackgroundModes = [audio]` for podcast playback, iPhone + iPad families.
2. `Support/` helpers, then the tab shell so there's something runnable.
3. Timer: port the store and view, rename to Exercise*, wire the recorder hooks.
4. Workouts: value types, both protocols, sample store, then the read-only
   HealthKit implementation, then the stats view.
5. Podcasts: models, parser, playback controller, SwiftData layer, store, views.
6. Build and verify it runs on an iPhone and an iPad simulator.

## Risk note — project creation

`XcodeNewTarget` was tried **twice** against a workspace containing **zero**
projects. Both times Xcode crashed with `MCP error -32000: Connection
closed`, and both times nothing was written to disk. Confirmed: that tool
adds targets to *existing* projects and cannot bootstrap one. **Do not call
it again until a `.xcodeproj` exists.**

Create the project shell by hand in Xcode instead —
File ▸ New ▸ Project ▸ Multiplatform ▸ App, product name `NBExercise`,
Storage: SwiftData, Testing: Swift Testing, Organization `com.maldeus`,
**"Create Git repository" unchecked** (this folder is already a repo).

Product name is `NBExercise`, not `NB-Exercise`: a hyphen can't appear in a
Swift module name, and Xcode would silently sanitize it to `NB_Exercise`.

## Current state

All 20 files are written to `Sources/`, mirroring the target structure above.
**None of it has been through a compiler** — there's no project to build it
in. Expect a first-build error pass.

### Remaining steps

1. Create the project (see risk note). Delete the template's generated
   `NBExerciseApp.swift`, `ContentView.swift`, and `Item.swift` — `Sources/`
   supplies all three roles.
2. Add the `Sources/` tree to the target (drag into the navigator, "Create
   groups", target membership ticked).
3. Target config, none of which is applied yet:
   - `com.apple.developer.healthkit` entitlement.
   - `NSHealthShareUsageDescription` — e.g. "NBExercise reads your workouts
     and activity data to show your exercise stats."
   - `UIBackgroundModes` = `[audio]`, or playback stops when the screen
     locks.
   - `TARGETED_DEVICE_FAMILY` = `1,2` (iPhone + iPad). The multiplatform
     template may also offer a Mac destination — remove it. `UIKit` and
     `AVAudioSession` are imported unconditionally in the podcast layer.
4. Build and fix. Known places to check first:
   - `HealthKitWorkoutStore.dailyRings` uses `exerciseTimeGoal` /
     `standHoursGoal`, the iOS 16+ optional goal properties. If the SDK
     disagrees, the legacy `appleExerciseTimeGoal` / `appleStandHoursGoal`
     are the fallback.
   - `RootView` uses the `Tab(_:systemImage:value:)` builder and
     `.tabViewStyle(.sidebarAdaptable)` (iOS 18+).
   - `PodcastStore` uses `#Predicate` with a captured `Set` in
     `loadStates(for:)`; SwiftData predicate support for `contains` on a
     captured collection is worth verifying.
5. Run on an iPhone and an iPad simulator.

### Deliberately not built

`WorkoutRecorder` has no conformance — by design, per the read-only
decision. Also skipped from the Nexus podcast feature set: the downloads
manager screen, per-feed settings, and a full-screen player.
`PodcastStore` already carries the download and queue logic, so those are
additive.
