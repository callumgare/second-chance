# AGENTS.md

Guidance for AI coding agents working on the Second Chance codebase.

## What This Is

Second Chance is a native macOS app (Swift/SwiftUI) that wraps pre-Unity Nancy Drew PC games to run on modern Macs via [Wine](https://www.winehq.org/) and [ScummVM](https://www.scummvm.org/). The user points the app at a game installer (CD, Her Interactive download, or Steam) and it produces a standalone `.app` bundle containing the Wine/ScummVM engine plus the installed game.

Read `README.md` for the full project background before making non-trivial changes.

## Build, Run, Test

All commands run from the repo root. The project uses **fish shell** on macOS.

```bash
./build.sh                  # Build Second Chance.app (use --quiet to suppress output)
./run.sh                    # Build (if needed) and launch Second Chance.app
./run.sh --rebuild          # Force rebuild app + any game wrapp
./run.sh --clear-wine-cache # Clear cached Wine prefix

arch -x86_64 ./run-tests.sh unit              # Unit tests (~6s) — fast feedback loop
arch -x86_64 ./run-tests.sh i <game-slug>     # Integration test for one game
arch -x86_64 ./run-tests.sh integration       # All games (hours, needs real installers)
```

**`run-tests.sh` must be run under Rosetta.** It takes its destination from
`uname -m`, and the WrappTemplate target is `ARCHS = x86_64` (Wine is 32-bit),
so a native arm64 run fails at link with `ld: symbol(s) not found for
architecture x86_64` for every swift-log symbol. That shows up as exit 65 and
`** TEST BUILD FAILED **`, which looks like a failing test but is a link
failure. `./build.sh` needs no prefix — it already wraps xcodebuild in
`arch -x86_64`.

Never run an unfiltered `xcodebuild test`. With real ISOs in `installers/` the
integration suite does not skip and the run takes hours.

Build output lands in `DerivedData/Build/Products/Debug/Second Chance.app`. Game
wrapps are built into `built-apps/`. See `SecondChanceTests/README.md` for the
full test story.


## Documentation

`docs/` holds per-feature documentation. Read the one that covers what you are
touching — the rows say _when_ to read, not what is in them:

| Doc                                                | Read it when                                                                                                                                                               |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [docs/wrapp-build.md](docs/wrapp-build.md)         | You are touching how a wrapp gets built — the builders, the shared helper, `WrappBuildInput`, the bus events, headless mode, or the template                                |
| [docs/historical-plans/](docs/historical-plans/)   | You want the reasoning behind a past design decision. Frozen records of what was intended at a moment — never cite one as current behaviour                                |
| [docs/historical-plans/2026-09-03-wrapp-build-architecture-refactor.md](docs/historical-plans/2026-09-03-wrapp-build-architecture-refactor.md) | You want to know why the wrapp build is split into per-source builders over a shared helper, and what the `InstallationService` / `GameInstaller` / `WrapperBuilder` arrangement it replaced got wrong |

Adding a doc means adding its row here, and this table is the only place the
list lives. A test asserts the two match, so a doc without a row fails rather
than going unnoticed. The check is recursive, and a row naming a directory
covers every doc beneath it — with one exception: each historical plan gets its
own row as well, so a frozen plan stays findable from this table rather than
only by browsing the directory.

## Keeping the docs current

Documentation is part of a change, not a follow-up to it.

- A change that makes a statement in `docs/` wrong is not finished until that
  statement is fixed.
- A change that adds a concept someone would need explained — a new dialect, a
  new attribute namespace, a new output style — gets it documented in the
  relevant doc, not only in code comments.
- A new doc gets a row in the table above.
- `AGENTS.md` itself changes when a repo-wide convention or invariant does: a
  new lint rule, a new mocking boundary, a new directory with rules of its own.
- When finished implementing them plans should be added to `docs/historical-plans/`
- The filename for historical plans leads with the date of implementation, in
  the form `YYYY-MM-DD-`, so the directory sorts chronologically —
  `2026-09-03-wrapp-build-architecture-refactor.md`. `DocsTableTests`
  enforces this, including that the date is a real one.
- Frozen plans under `docs/historical-plans/` are exempt from all of the above.
  They are not updated as the code moves on. If one has to be edited because it
  is actively misleading someone, mark the edit inline as post-implementation,
  dated, with who changed it and why — never a silent rewrite.

Reach for a doc when the material is one feature deep; reach for `AGENTS.md`
when it applies across the repo. Link between them rather than repeating.

## Tech Stack

- **Swift 5.0** / **SwiftUI**, deployment target **macOS 15.0** (some targets 15.6)
- Xcode project (`SecondChance.xcodeproj`), no SPM package manifest
- Uses Swift Testing framework (`@Test`, `#expect`) — not XCTest
- Unsandboxed app (required for Wine); entitlements enable dyld env vars, unsigned executable memory, and disable library validation

## Architecture

A **wrapp** is the `.app` this tool produces: one game, plus the engine to run
it. Building one is a *wrapp build*; the thing it is built from is a *source*
(disk, Her download, Steam).

```
Views (SwiftUI)  →  WrappBuildViewModel (@MainActor)      CLIBuilder (headless)
                                    │                            │
                                    └────────── both via ────────┘
                                          WrappBuildStrategy
                                                 │
             ┌───────────────────────────────────┼───────────────────────────┐
    DiskWrappBuilder              HerDownloadWrappBuilder          SteamWrappBuilder
             └───────────────────────────────────┼───────────────────────────┘
                                                 ↓
                    WrappBuildHelper · GameInstallerRunner · ISOMounter
                                                 ↓
        WineManager · CacheManager · GameDetector · AutoItService · ScummVMService
                                                 ↓
                  Models (GameInfo, WrappBuildState, WrappSource, AppEvent, …)
```

Progress and results flow the other way, as typed events on `EventBus.app`.

[docs/wrapp-build.md](docs/wrapp-build.md) walks the whole flow
step by step, including the resource-ownership rules and both injection seams.

### Key abstractions

- **`WrappBuildStrategy`** (`Builders/WrappBuildStrategy.swift`): one method,
  `build(input:) async throws -> URL`. **Adding a source means adding a builder
  that conforms to this**, not adding a branch to an existing one. The ViewModel
  and `CLIBuilder` both dispatch through the protocol, so a new source needs no
  changes at either call site.
- **A builder owns its flow and its resources.** Whatever it creates — mounted
  ISOs, the temp wrapp — it tears down on the success *and* error paths.
  `WrappBuildHelper` supplies cleanup *primitives* (`removeTempWrapp`); it never
  decides when to call them. The helper never calls a builder: one direction only.
- **Source-specific work stays out of the helper.** Disk layout and CD-ROM
  mounting live in `DiskWrappBuilder` because no other source uses them.
- **`WrappBuildHelper`** (`Builders/WrappBuildHelper.swift`): the
  source-independent operations every builder shares — base wrapp construction
  from the template, engine cleanup, `Info.plist`/`AppSettings.plist`
  configuration, and the sign/save/launch tail.
- **`WrappBuildInput`** (`Services/WrappBuildInput.swift`): all I/O for a build
  in one type, resolved env-var-first — when the env var is set it replaces the
  `NSOpenPanel` that would otherwise prompt. This is what lets the same code
  path serve the GUI and headless runs.
- **`EventBus.app` / `AppEvent`** (`Models/AppEvent.swift`): the build publishes
  `WrappBuildEvent`s; the UI renders them and the integration tests assert on
  them. **The events are the contract** — when moving orchestration code, every
  `bus.publish` moves with it, or the flow silently stops reporting.
- **Detect the game once.** `DiskWrappBuilder` runs `GameDetector` and threads
  `GameInfo` through; nothing downstream re-detects.
- **Services are singletons** (`XxxManager.shared`) but the build path takes them
  by constructor injection with `.shared` defaults. Keep that pattern for new
  services: injectable for tests, convenient in production.
- **`GameInfoProvider`**: static database of all 30+ Nancy Drew games with
  metadata (engine, disk count, exe paths, Steam DRM). Add new games here.
- **`GameEngine` enum** (`wine`, `scummvm`, `wineSteam`, `wineSteamSilent`):
  determines which engine the wrapp uses.

### Wrapp build state machine

`WrappBuildState` (`Models/WrappBuildState.swift`) drives the UI and progress
reporting: `idle → detectingGame → settingUpWrapp → copyingInstaller →
installingGame → configuringWrapp → savingApp → completed` (or `error`). Each
in-flight state carries optional `substep` and `elapsedSeconds`; the ViewModel
hides both for the first 5 s so fast steps don't flash.

States reach the UI as `.progress(WrappBuildState)` events on the bus, not by
direct assignment.

## Code Conventions

- **Async/await** throughout — services use `async throws` methods. Run UI updates on `@MainActor`.
- **Logging**: All logging goes through [swift-log](https://github.com/apple/swift-log) — `import Logging`, then `private nonisolated let logger = Logger(label: "<subsystem>.<Category>")`. Subsystems: `au.gare.callum.second-chance.SecondChance` (main app), `au.gare.callum.second-chance.WrappTemplate`, `au.gare.callum.second-chance.GamePuppeteer` — all siblings under the `au.gare.callum.second-chance` prefix. Use `.notice` for info, `.error` for warnings/recoverable errors, `.critical` for serious/unexpected failures (no `.fault` — that's the OSLog name). No `privacy:` annotations, no `os.Logger`, no `print()`. Every executable calls `AppLogging.bootstrap(subsystem:)` as its **first** statement (`SecondChanceApp.init()`, `WrappTemplate`'s `main()`, `GamePuppeteer`'s top of `main.swift`) — a `Logger` created before bootstrap is silently orphaned to swift-log's default stdout handler and never reaches the store. Log records fan out in-process via `MultiplexLogHandler` to `LogStore` (in-memory ring, 50k entries) and OSLog (crash-durable, the only place `privacy: .public` still exists — inside `OSLogHandler`). Terminal stderr, the floating log window (`LogWindow`, instant history + live batches), and Save Logs (`LogExporter`, lossless where `log show` dropped `.debug` entries) all read from `LogStore`; no process shells out to `/usr/bin/log` except `SystemLogReader.fetch(pid:since:)` in integration tests. Subprocess output (Wine, ScummVM, winetricks) is captured line-by-line via `ProcessLineLogger`/`TaggedProcess` in `Shared/Logging/`. Integration tests still read OSLog via `log show` after a 2-second flush delay — that's why OSLog stays in the multiplex.
- **Error handling**: The codebase has many `try?` that silently swallow errors. For new code, prefer explicit `do/catch` and log failures. Cleanup operations may use `try?` but should log.
- **No force unwraps (`!`)** in new code — use `guard let` / `compactMap`. Existing force unwraps (e.g. `gameExe!` in `GameInstallerRunner`) are flagged for removal.
- **File paths**: Never hardcode absolute user paths (e.g. `/Users/...`). Use `Bundle.main.url(forResource:)`, `FileManager` search paths, or environment variables.
- **Swift Testing**: Write tests with `@Test func`, `#expect`, `#require`. Mark tests needing fixtures with `#skip("reason")` rather than silent early-return.

## Gotchas

- **Non-interactive mode**: `NON_INTERACTIVE=true` plus `INSTALLATION_SOURCE`
  (`disk` | `her-download` | `steam`) and `OUTPUT_PATH`; `disk` also needs
  `DISK_1_PATH` (and optionally `DISK_2_PATH`). `HER_INSTALLER_PATH`,
  `LAUNCH_GAME`, `LAUNCH_GAME_ARGS` and `PATCH_FAILURE_POLICY` are read by
  `WrappBuildInput` when the corresponding prompt would appear. **`CLIBuilder`
  owns every `exit()`** — no code path in `WrappBuildViewModel` terminates the
  process, so the ViewModel is safe to instantiate in tests regardless of
  environment.
- **Headless stderr is TTY-gated.** `LogStore` only mirrors to stderr when
  `isatty`, so piping or redirecting a headless run's output shows nothing. Run
  it bare in a terminal to see logs.
- **Wine prefix caching**: `WineManager` caches prefixes in `~/Library/Caches/SecondChance/wine-prefix-cache`, keyed by bundle version (or `"dev"` in DEBUG). Use `--clear-wine-cache` or `run.sh --clear-wine-cache` if Wine setup misbehaves after code changes.
- **`STRICT_INSTALL=true`** env var disables the silent→interactive installer
  retry fallback in `GameInstallerRunner`. The `--skip-installer` debug flag
  skips running the installer entirely (useful for testing wrapp construction).
- **Disk path resolution**: installers land in
  `Contents/SharedSupport/prefix/drive_c/nancy-drew-installer/{disk-1,disk-combined}`,
  with multi-disk games merged into `disk-combined`. This lives in
  `DiskWrappBuilder` — it is deliberately not in the shared helper, because no
  other source has disks.
- **The template is `WrappTemplate.app`**, embedded in
  `Second Chance.app/Contents/Resources/`. `WrappBuildHelper` copies it per game
  and rewrites `CFBundleIdentifier` from
  `au.gare.callum.SecondChance.WrappTemplate` to
  `au.gare.callum.SecondChance.nancy-drew.<slug>`. Because
  `PRODUCT_NAME = $(TARGET_NAME)`, the produced game's executable is
  `Contents/MacOS/WrappTemplate` — GamePuppeteer matches on that name, so
  renaming the target means updating its window-owner heuristic too.
- **Bundled resources**: `WrappTemplate.app` template, Wine engine, `winetricks`, AutoIt, and ScummVM are bundled. Test that features work with bundled paths, not just system-installed equivalents.

## Testing

**`SecondChanceTests/README.md` is the detailed guide** — suites, filtering,
GamePuppeteer permissions and its exit codes, reports. In short:

- **Unit tests** live in `SecondChanceTests/`, using Swift Testing.
  `GameDetectorTests` is the model to follow (35+ parameterized tests). A new
  suite also needs an `-only-testing:` line in `run-tests.sh`'s `unit` case, or
  the fast loop won't run it.
- **Integration tests** need real ISOs in `installers/<slug>/disk-1.iso` and run
  the actual build flow; they disable themselves when the ISOs are absent.
  Prefer unit tests for fast feedback.
- **Only the integration test can catch a dropped bus event.** A build with a
  missing `bus.publish` still produces a correct `.app`, so it passes the build
  and the unit tests. Run it after touching orchestration.
- **Test fixtures** are in `TestFixtures/` and `installers/`. Make skips
  explicit rather than returning early, so a skipped test reads as skipped.
- **Priority test targets** (untested but high-value): `CacheManager`,
  `WrappBuildInput`'s env-var resolution and validation, `WrappBuildHelper` path
  helpers.

## Things Currently In Flux

- **Steam is a deliberate stub.** `SteamWrappBuilder.build` throws
  `WrappBuildError.steamNotFullyImplemented` *before* creating anything, so a
  failed attempt leaves no temp wrapp. Implementing it means the whole flow —
  install the Steam client into the wrapp, let the user install through Steam's
  UI, then locate and configure the game — not a partial version.
- **Her download works end-to-end** through the same helpers as disk (it signs
  and publishes the same events), but has far less real-world mileage than the
  disk path.
- `GameInstallerRunner` still has one force unwrap (`gameExe!`).
- The produced game app's process is named `WrappTemplate` in Activity Monitor.
  Renaming the executable per-game during configuration would read better.
