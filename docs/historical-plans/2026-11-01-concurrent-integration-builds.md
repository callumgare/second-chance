# Build integration-test games side by side, launch them one at a time

## What happened

_Written after implementation, above the plan as it was approved. Paths in
the plan are as they were then: `Shared/` has since become
`Packages/SecondChanceKit/`._

Phases 1 to 4 went in as planned: one per-game flow (`IntegrationGameRun`),
a bus and a log tag per build, the blocking steps moved off the main actor,
a prefix cache that builds can share, phase timings in the progress stream,
and `IntegrationStages` in place of `IntegrationSerial`.

Phase 5's sweep, eight disc games at 1 (twice), 2, 3, 4 and 6 builds on an
8-performance-core M1 Max, gave two builds a run 24% shorter than one, four
only 11% shorter again, and six longer than four, while Haunted Carousel's
launch slowed to 1.7× with three or four building behind it. The default is
therefore one build per four performance cores, at least one, set in `sc`
(`IntegrationOptions.resolvedBuildConcurrency`), and the numbers are in
[testing.md](../testing.md#how-many-to-build-at-once). No "quiet launch" rule
was needed at that setting.

What the sweep turned up besides:

- **The prefix cache folder could vanish under a build.** A build's cleanup
  of other keys' entries removed another build's `.incoming-` copy in
  progress; it now leaves a recent one alone (`WineManager`).
- **`sc --on` could send a half-built app.** Syncing this Mac's
  `DerivedData` while another session was building sent a template without
  Wine; products are now sent only with `--skip-app-build`, and a sync that
  stops partway says so.
- **InstallShield's AutoIt script gave up on its window after 20 s.** With
  three builds running, Old Clock's took longer; the script then clicked
  nothing and waited for ever on an installer waiting for that click, and the
  install ran to its 30-minute timeout. It now waits for as long as the
  installer runs, and closes it if the click fails.
- **The install stall watch looks at Wine across the whole Mac.** Its signs
  of progress and its check for an installer window on screen count every
  Wine program, so another build's activity can stand in for this one's.
  Left as it is for now; a build at a time in the app never meets it.

## The plan


### Context

A full `sc test integration` run takes hours. Every per-game test (disk, Her,
Steam) runs its whole body, build then launch, inside `IntegrationSerial`
(`SecondChanceTests/Integration/TestHelpers.swift:319`). That means one game at
a time across all suites.

Launches must stay serial, because games run fullscreen and need focus. Builds
don't need to. The goal is to overlap builds while keeping launches serial,
without:

- **Breaking assertions.** Each build has to see only its own events and logs.
- **Polluting timings.** Time spent queued must not count as build or launch time.
- **Hitting the CPU cliff.** Wine slows sharply once every performance core is
  busy (AGENTS.md).
- **Filling the disk** on the test Mac. Today only one installed game exists at
  a time.

The build gate is therefore limited **both** by CPU slots and by disk bytes. The
right slot count is **found by experiment**, not guessed.

### Phase 1: One per-game flow, not three

The three suites copy roughly 60–70 lines of the same flow:

- load and screen gates
- output dir, recorder and log attachment
- view model and wait
- shared expectations
- the launch tail

Pull that flow into one helper in `SecondChanceTests/Integration/`, e.g.
`IntegrationGameRun`. Each suite passes it:

- its build closure
- its own expectations: Disk's event ordering and `SKIP_BUILD` path, Her's
  leftover-file check, Steam's owned-games and sign-in checks

While doing this, fix the small differences between suites: Steam's load message
uses the reading rather than `.summary`, and its locked path writes no `screen`
event. Doing this first means the following phases change one place, not three.

### Phase 2: Make concurrent builds separable

Builds stay in the test process and keep driving `WrappBuildViewModel`. That
is the decision. Each part below is worth having in the app anyway.

#### 2a. A bus per build

Today `EventBus.app` is hard-coded in places a builder's `bus:` can't reach.

- **`WrappBuildViewModel`:**
  - `init(makeInput:, bus: EventBus<AppEvent> = .app)`.
  - It subscribes to that bus (`WrappBuildViewModel.swift:87`).
  - It builds its three builders (`:55-57`) with that bus, and with a
    `WrappBuildHelper(bus:)` and a `GameInstallerRunner(bus:)` of its own.
    `.shared` is fixed to `.app`.
  - `.shared` stays as the default for `CLIBuilder` and the GUI.
- **`WrappBuildHelper`** tracks temp wrapps for the at-quit
  `cleanupTemporaryWrapps`. Move that registry to a process-wide tracker, so a
  per-build helper's temp wrapp is still cleaned up when the app quits.
- **`WineManager.createWinePrefix`** (`WineManager.swift:175,188,206`) and
  **`WrappBuildInput.ensureRosetta`** (`:496,499`) take the bus as a parameter
  instead of using `.app`.
- **A unit test** runs two fake builds on separate buses and checks each
  recorder sees only its own events.
- **A source-scan check**, alongside `DocsTableTests`: no `EventBus.app` under
  `Builders/` or `Services/`, except `CLIBuilder` and the parameter defaults.
  That stops a new hard-coded publish slipping back in.

#### 2b. Tag log entries with their build

Today `LogContext`'s stage is process-global (`Shared/Logging/FailureSummary.swift:17-46`).
Entries carry metadata, but loggers are file-level globals. So:

- **A build context.** Add `LogContext.$build`, a `@TaskLocal` holding a
  `BuildLogContext`: its id, plus its own lock-protected stage and stage start.
  `enterStage`/`clearStage`/`stage` act on the task-local context when there is
  one, else on today's global. The GUI and CLI behave as now.
- **Metadata from the context.** `AppLogging.bootstrap` installs a swift-log
  `MetadataProvider` that adds `build=<id>`. `LogStore` reads the entry's stage
  from the build context.
- **Contexts that lose task-locals:**
  - `Blocking.run`: capture the context and re-bind it inside the closure.
  - `ProcessLineLogger.attach` and `TaggedProcess`: capture it at attach time
    and pass it as explicit metadata, because `readabilityHandler` queues don't
    inherit it.
  - Audit `Task.detached` on the build path and do the same there.
- **`performBuild`** runs the build inside `LogContext.$build.withValue(...)`.
- **`FailureSummary.render`** only scans entries from its own build when it has
  one.
- **The tests' log attachment** filters on `build=<id>`, not `seq >= logStart`.
  Untagged entries written during a concurrent run go to a separate
  `untagged-*.txt` attachment, so a missed propagation path shows up.
- **Left global:** `FailureReporter.setGame`. Reporting is off in tests, and
  the GUI runs one build at a time.

#### 2c. Take blocking work off the main actor

The app target defaults to `MainActor`, so these synchronous steps would stall
other builds. Move each into `Blocking.run`, with `nonisolated` helpers:

- `cleanupUnusedEngine`'s measure and remove loop (`WrappBuildHelper.swift:172-183`)
- `checkInstallFinished`'s `DirectorySize.measure` (`GameInstallerRunner.swift:939`)
- `findExecutableFiles` (`:1342`)
- patch `copyItem`s (`:546,566,719`)
- moving and removing the unpacked setup (`:289-291`)
- Steam's game-dir move and remove (`SteamWrappBuilder.swift:417,426`)
- `startWineServer`'s `waitUntilExit` (`WineManager.swift:378-389`)

The Debug `[Hang]` watchdog then confirms nothing is left.

#### 2d. Shared resources

- **Prefix cache** (`WineManager.swift:93-153`). Today, two builds that both
  miss the cache race, and `cachePrefix` deletes and copies in place.
  - An in-process async lock around "check, create, cache": the first build
    creates the prefix and the rest wait, then copy it.
  - `cachePrefix` copies into a temp dir inside the cache root, then renames
    it. It writes a `complete` marker last, and `getCachedPrefix` requires
    that marker.
  - It removes only other keys' entries.
  - The `winetricks` download cache is only touched while the prefix is
    created, so the same lock covers it.
- **`WineDesktop`** gives up early when `explorer.exe` isn't running, checked
  across the whole Mac (`Shared/Wine/WineDesktop.swift:89`). Another build's
  explorer would then hide a dead one, and the wait would run to 600 s. Check
  the pid of the explorer it started instead.
- **Steam:** a gate of 1. Its `flock` lock, the Mac-wide `isSteamRunning`
  check and `SteamClientCache` all assume one Steam.
- **`CacheManager`:** every ViewModel `init` overwrites `cachingEnabled` and
  `stagesToRestore` (`WrappBuildViewModel.swift:81-82`). Caching is off in
  tests, so leave it. Add a comment that it isn't concurrency-safe.
- **ISOs:** each game has its own images, and a game is never built twice at
  once, so mounts don't collide.

### Phase 3: Phase timings and sizes in the progress stream

Changes to `GameOutcome` (`DiskInstallIntegrationTests.swift:311`; move it next
to the new helper):

- A `timed(_ phase:, waitingAs:)` that records `queued<Phase>Seconds` and
  `<phase>Seconds` separately.
- `finished` carries `buildSeconds`, `launchSeconds`, `queuedSeconds` and
  `peakBytes`. Keep `seconds` as the elapsed total.
- Measure peak disk use by sampling the output dir and temp wrapp size at each
  phase change and every 30 s during the build. Use a cheap `du`-style walk off
  the main thread.

Changes in sc (`Tools/sc/Sources/SCKit/Support/ProgressStream.swift`,
`TestRunner.swift`):

- Parse the new fields.
- `gameTable` gets **Build** and **Launch** columns in place of **Time**, plus a
  **Queued** column. The total time for the run is printed below the table.
- `GameBoard.current` becomes a set of running games. The status line names the
  game that's launching and counts the ones building.
- `ProgressFileWriter` currently subscribes once, to `.app`, and its `stage`
  records carry no slug. Instead:
  - Let it subscribe to each build's bus, with a `source`/`slug` that it adds
    to every record.
  - `GameBoard` routes `stage` records by slug.
- sc keeps a per-slug size cache, `DerivedData/sc-integration-sizes.json`, of
  the largest `peakBytes` seen. sc passes it in as
  `TEST_RUNNER_SIZE_ESTIMATES_PATH`.

Update sc's `SupportTests.swift` GameBoard tests.

### Phase 4: Stage gates

Replace `IntegrationSerial` with `IntegrationStages` in TestHelpers.

#### Build gate

An actor holding **slots** and **bytes**. FIFO. A game is admitted when all of
these hold:

- A slot is free. The limit is `TEST_RUNNER_BUILD_CONCURRENCY`, default `1`
  until Phase 5 sets it.
- Its reservation fits the budget. The budget is the free space at run start
  (`volumeAvailableCapacityForImportantUsageKey` on the temp dir's volume) minus
  a margin, minus outstanding reservations.
- Free space right now covers the not-yet-used part of the outstanding
  reservations, plus this game's reservation, plus the margin.
- Exceptions:
  - If nothing is in flight, the game is always admitted, so a run never does
    worse than today.
  - If a game alone can't fit, it fails up front with a clear message.

A game's reservation is its estimate × 1.25. The estimate comes from the size
cache, falling back to bundled engine size + 4 × its installer files' size (White
Wolf: 923 MB of disc images, 3.5 GB wrapp).

The reservation is released after the output dir is deleted, not when the build
finishes. So wrapps waiting for a launch keep holding their space, and that
holds back new builds.

- **Steam** builds take one slot from a separate Steam gate of size 1, because
  Steam allows one game at a time.

#### Launch gate

A mutex. The `launching` phase and `InstalledGameCheck` run inside it.

#### Load and screen checks

- **Screen check:** move it to just before the launch gate. A game can still be
  built while the screen is locked.
- **`LoadGate`:** keep it at the build-gate admission point, but fix what it
  counts. It excludes all Wine processes, but counts the test host's non-Wine
  children (`hdiutil`, `ditto`, `codesign`) as "other programs".
  - Add a `SystemLoad.reading(fromPS:excludingDescendantsOf:)` variant. Use
    `ps -o pid,ppid,pcpu,comm` and walk ppid chains.
  - LoadGate uses it, so the run's own builds never make a game `overloaded`.

#### Within the suites

Remove `.serialized` from the per-game parameterized tests. Swift Testing then
runs their arguments concurrently, and the gates take over the job.

Expose `--build-concurrency N` (and `--disk-margin GB` if wanted) on
`IntegrationOptions` (`Tools/sc/Sources/SCKit/Commands/Test.swift`). Pass them
as env vars next to `IGNORE_LOAD` (`TestRunner.swift:128-143`). `--on`
forwards them unchanged.

### Phase 5: Find the slot count by experiment (on the test Mac)

Run the integration suite with the gates in place, on the remote test Mac (not
this one). Use a fixed set of about 8 disc games covering both engines, small
and large installers, and one Direct3D game.

1. **Baseline:** `--build-concurrency 1`, run twice to see the noise.
2. **Sweep:** `--build-concurrency 2, 3, 4`, and 6 if 4 still improves.

Record for each run, from the progress stream and the build logs:

- total wall time (throughput, games/hour)
- per-game `buildSeconds`, and the install step's own time (from `[Stage]`
  lines)
- failures, stalls (`InstallStallWatch`), `noDisplay` retries, `overloaded`
- `SystemLoad` total-CPU samples over the run, including Wine, against the
  performance-core count
- **launch** timings under background builds:
  - WrappPuppeteer time-to-window
  - `slow-start` / `hang` diagnostics bundles
  - launch failures, compared with the baseline

**Pick** the largest N where:

- total time still drops by a meaningful amount (more than 10% per step)
- no new failures or stalls appear
- launch time-to-window stays within about 1.5× the baseline

Express the result as a function of the performance-core count, e.g.
`max(1, perfCores / k)`, so it carries over to other Macs. Make that the
default.

**If launches degrade** before throughput tops out, add a "quiet launch" rule:
the launch gate stops new builds being admitted while it's held. Running builds
continue. Re-measure. Add this rule only if the data shows it's needed.

Write the measurements up in docs/testing.md, in the style of wrapp-launch.md's
Measurements section.

### Phase 6: Docs

- **`docs/testing.md`:**
  - 125-128: `IntegrationSerial` becomes the stage gates.
  - 259-274: when the load and screen checks happen.
  - 65-66: the live display now shows several games at once.
  - 170: each build's event sequence is now taken from its own bus.
  - 621-625: interleaving.
  - New sections: build concurrency and the disk budget, the experiment's
    measurements, the new table columns.
- **`docs/dev-cli.md`:** the new options.
- **AGENTS.md:**
  - In the Architecture and Key abstractions sections: a build's bus is
    injected through the ViewModel, so don't publish to `EventBus.app` from
    the build path.
  - In the Logging convention: log entries carry `build=<id>` through
    `LogContext.$build`, and code that runs off the task re-binds it.
  - The Testing bullets.
- **`docs/logging.md`:** build tagging, and the per-build stage.
- **`docs/wrapp-build.md`:** the bus seam.
- Code comments: `DiskInstallIntegrationTests.swift:18,41`, `LoadGate.swift:12-16`.
- Add this plan to `docs/historical-plans/2026-MM-DD-concurrent-integration-builds.md`
  with a row in the AGENTS.md table.

### Critical files

- `SecondChance/ViewModels/WrappBuildViewModel.swift`, `Builders/WrappBuildHelper.swift`,
  `Services/{GameInstallerRunner,WineManager,WrappBuildInput}.swift`,
  `Builders/SteamWrappBuilder.swift`
- `Shared/Logging/{FailureSummary,AppLogging,LogStore,ProcessLineLogger,TaggedProcess}.swift`,
  `SecondChance/Utilities/ProcessUtilities.swift` (`Blocking.run`),
  `Shared/Wine/WineDesktop.swift`
- `SecondChanceTests/Integration/`: `TestHelpers.swift`, `LoadGate.swift`,
  `RecordingEventSubscriber.swift`, the three `*InstallIntegrationTests.swift`
- `Shared/SystemLoad.swift`
- `SecondChance/Services/ProgressFileWriter.swift`
- `Tools/sc/Sources/SCKit/Support/{TestRunner,ProgressStream}.swift`,
  `Commands/Test.swift`, `Tools/sc/Tests/SCKitTests/SupportTests.swift`

### Verification

- `./sc test unit` and `./sc lint` after each phase. Add unit tests for:
  - build gate admission (slots, bytes, the "nothing in flight" rule, an
    oversize game)
  - descendant exclusion in `SystemLoad`
  - per-build bus isolation: two fake builds on separate buses
  - `LogContext.$build` carried through `Blocking.run` and `ProcessLineLogger`,
    and per-build stage
  - the prefix-cache lock: two concurrent `createWinePrefix` calls with a cold
    cache, using a fake Wine runner if one exists, or else checked in the
    integration run
  - sc's GameBoard with several running games
- After Phase 2: run `./sc test integration <two slugs>` at concurrency 1 on the
  test Mac. Results must be the same as before the change.
- After Phase 4: run concurrency 2 on three games. Check the event traces and
  log attachments each contain only their own game, the reservations are
  released, and the disk was never short of space.
- Phase 5 is itself the end-to-end check. Commit each phase and carry on.
