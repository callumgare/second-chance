# AGENTS.md

Guidance for AI coding agents working on the Second Chance codebase.

## What This Is

Second Chance is a native macOS app (Swift/SwiftUI) that wraps pre-Unity Nancy Drew PC games to run on modern Macs via [Wine](https://www.winehq.org/) and [ScummVM](https://www.scummvm.org/). The user points the app at a game installer (CD, Her Interactive download, or Steam) and it produces a standalone `.app` bundle containing the Wine/ScummVM engine plus the installed game.

Read `README.md` for the full project background before making non-trivial changes.

## Build, Run, Test

All commands run from the repo root through `./sc`, the developer CLI (a Swift
package in `Tools/sc/` — [docs/dev-cli.md](docs/dev-cli.md)). The project uses
**fish shell** on macOS.

```bash
./sc app build                     # Build Second Chance.app
./sc app run                       # Build (incrementally) and launch it
./sc wrapp build <game-slug>       # Build a game's wrapp headlessly
./sc wrapp run <game-slug>         # Launch it (building it first if needed)
./sc clean wine-prefixes           # Clear the cached Wine prefix

./sc test unit                     # Unit tests (~6s) — fast feedback loop
./sc test integration <game-slug>  # Integration test for one game
./sc test integration              # All games (hours, needs real installers)

./sc release                       # Version, changelog, notes and a Release build
./sc release --dry-run             # Show what a release would contain
./sc release --build-only          # Build the next version; commit, tag and change nothing
```

Commands that need the app build it first; `--skip-app-build` reuses the build in
`DerivedData/`. Piped or redirected, `sc` prints the tools' raw output
(`--logs raw`); every step's full log is also kept in `DerivedData/sc-logs/`.

**Every build passes `ONLY_ACTIVE_ARCH=NO`, and that is load-bearing.** The
WrappTemplate target is `ARCHS = x86_64` (Wine is 32-bit) while everything else
is universal, so an active-arch-only build on Apple Silicon emits swift-log for
arm64 alone. WrappTemplate then fails with `unable to resolve module dependency:
'Logging'`, or at link with `ld: symbol(s) not found for architecture x86_64`
for every swift-log symbol — which surfaces as exit 65 and `** TEST BUILD
FAILED **`, looking like a failing test when it is really a build failure.
`sc` and CI both set the flag (`Tools/sc/Sources/SCKit/Support/Xcode.swift` is
sc's only xcodebuild call site), so neither needs a Rosetta wrapper. If you
invoke `xcodebuild` directly, pass it yourself. Do not reach for `arch -x86_64`
instead: the process architecture does not reliably decide what the build
system picks for the package products, which made it work on some machines and
fail on others.

**Never run a bare `./sc test`** (or an unfiltered `xcodebuild test`): it runs the
integration suite too, which with real ISOs in `installers/` takes hours. Name
the suite — `./sc test unit`, or `./sc test integration <game-slug>`.

Build output lands in `DerivedData/Build/Products/Debug/Second Chance.app`. Game
wrapps are built into `built-apps/`. See [docs/testing.md](docs/testing.md) for
the full test story.


## Documentation

`docs/` holds per-feature documentation. Read the one that covers what you are
touching — the rows say _when_ to read, not what is in them:

| Doc                                                | Read it when                                                                                                                                                               |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [docs/wrapp-build.md](docs/wrapp-build.md)         | You are touching how a wrapp gets built — the builders, the shared helper, `WrappBuildInput`, the bus events, headless mode, or the template                                |
| [docs/dev-cli.md](docs/dev-cli.md)                 | You are using or changing `./sc` — its commands, `--logs` output modes, `--debug` values, the GUI-session re-run over SSH, `--on` for remote Macs, or the progress stream it reads from the app |
| [docs/testing.md](docs/testing.md)                 | You are writing or running tests — the unit/integration split, the Rosetta requirement, which suites the unit run excludes, WrappPuppeteer's permissions and exit codes, or reading a run's output |
| [docs/logging.md](docs/logging.md)                 | You are adding or changing log lines, reading a log to find why a build or launch failed, or touching `Shared/Logging/` — levels, where each log lives, the env vars that control them, and how subprocess output is classified |
| [docs/releasing.md](docs/releasing.md)             | You are cutting a release or changing `sc release` — what it writes, how `CHANGELOG.md` and the release notes are generated (Claude Code's rewrite for players, the pause to edit them) and why not to edit the changelog by hand, its rollback on failure, the commit, tag and publish prompt, and the signing caveat |
| [docs/updates.md](docs/updates.md)                 | You are touching how the app updates itself — Sparkle, `AppUpdater`, `SecondChance/Info.plist`, the appcast `sc release` publishes, or the key updates are signed with |
| [docs/game-patches.md](docs/game-patches.md)       | You are touching the official Her Interactive game patches — the manifest, which patches apply to which game and edition, how they are downloaded, or how they are applied during a wrapp build                |
| [docs/steam.md](docs/steam.md)                     | You are touching anything Steam: `Shared/Steam/`, the shared sign-in and what it is made of, the one-wrapp-at-a-time lock, installing a game through Steam, Steam's file formats or logs, or the real-Steam smoke test |
| [docs/wine-in-process-helpers.md](docs/wine-in-process-helpers.md) | You are touching what runs inside the game's Wine process — native fullscreen or the cnc-ddraw cursor lock in `WrappTemplate/InProcessHelpers/`, how they are loaded and armed, or cnc-ddraw's `ddraw.ini` settings — or a game's first click seems to do nothing |
| [docs/historical-plans/](docs/historical-plans/)   | You want the reasoning behind a past design decision. Frozen records of what was intended at a moment — never cite one as current behaviour                                |
| [docs/historical-plans/2026-10-20-steam-support.md](docs/historical-plans/2026-10-20-steam-support.md) | You want to know why Steam works as it does — what a Steam sign-in turned out to be made of, why each wrapp has its own Steam but shares one sign-in, and which plan decisions testing overturned |
| [docs/historical-plans/2026-10-16-logging-overhaul.md](docs/historical-plans/2026-10-16-logging-overhaul.md) | You want to know why the logs are structured as they are — how the failures that hid their causes were found, what was wrong, and which changes were chosen |
| [docs/historical-plans/2026-10-16-install-completion-check.md](docs/historical-plans/2026-10-16-install-completion-check.md) | You want to know why a build asks each installer whether it finished rather than measuring the install, and what each installer family leaves behind when it is killed partway |
| [docs/historical-plans/2026-10-16-dev-cli.md](docs/historical-plans/2026-10-16-dev-cli.md) | You want to know why the build/run/test/release shell scripts became one Swift CLI, how its API was designed, and which libraries were weighed for it |
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
- In any files that are commited (unlike files such as this in the .local dir) you should never refer to details specific
to the current user's setup such as file paths outside the source code repo or remote machines they may connect to for testing. 

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
- **Logging**: All logging goes through [swift-log](https://github.com/apple/swift-log) — `import Logging`, then `private nonisolated let logger = Logger(label: "<subsystem>.<Category>")`. Subsystems: `au.gare.callum.second-chance.SecondChance` (main app), `au.gare.callum.second-chance.WrappTemplate`, `au.gare.callum.second-chance.WrappPuppeteer` — all siblings under the `au.gare.callum.second-chance` prefix. Levels mean something — [docs/logging.md](docs/logging.md#levels) has the rules: `.debug` for detail only useful when digging (it is kept everywhere but not shown on the terminal), `.notice` for the normal story of a run, `.warning` for something unusual the run survives, `.error` for a failure, `.critical` for one that ends the build or the game (no `.fault` — that's the OSLog name). No `privacy:` annotations, no `os.Logger`, no `print()`. Every executable calls `AppLogging.bootstrap(subsystem:)` as its **first** statement (`SecondChanceApp.init()`, `WrappTemplate`'s `main()`, `WrappPuppeteer`'s top of `main.swift`) — a `Logger` created before bootstrap is silently orphaned to swift-log's default stdout handler and never reaches the store. Log records fan out in-process via `MultiplexLogHandler` to `LogStore` (in-memory ring, 50k entries) and OSLog (crash-durable, the only place `privacy: .public` still exists — inside `OSLogHandler`) — except when `OS_ACTIVITY_DT_MODE` is set (Xcode, `xcodebuild test`), where os_log would copy every entry to stderr a second time, so only LogStore's copy is written — and the variable is unset at bootstrap, so the wrapp and WrappPuppeteer started from a test still write to OSLog. Terminal stderr, the floating log window (`LogWindow`, instant history + live batches), and Save Logs (`LogExporter`, lossless where `log show` dropped `.debug` entries) all read from `LogStore`; no process shells out to `/usr/bin/log` except `SystemLogReader.fetch(pid:since:)` in integration tests. Subprocess output (Wine, ScummVM, winetricks) is captured line-by-line via `ProcessLineLogger`/`TaggedProcess` in `Shared/Logging/`, each line at the level `SubprocessLineClassifier` picks from its content rather than from the pipe it came down. Integration tests still read WrappPuppeteer's and the wrapp's OSLog via `log show` (rendered in the compact format, with the process in front of the category) — that's why OSLog stays in the multiplex; the test host's own build log is attached straight from `LogStore`.
- **Error handling**: The codebase has many `try?` that silently swallow errors. For new code, prefer explicit `do/catch` and log failures. Cleanup operations may use `try?` but should log.
- **No force unwraps (`!`)** in new code — use `guard let` / `compactMap`. Existing force unwraps are flagged for removal.
- **File paths**: Never hardcode absolute user paths (e.g. `/Users/...`). Use `Bundle.main.url(forResource:)`, `FileManager` search paths, or environment variables.
- **Swift Testing**: Write tests with `@Test func`, `#expect`, `#require`. Mark tests needing fixtures with `#skip("reason")` rather than silent early-return.

## Gotchas

- **Non-interactive mode**: `NON_INTERACTIVE=true` plus `INSTALLATION_SOURCE`
  (`disk` | `her-download` | `steam`) and `OUTPUT_PATH`; `disk` also needs
  `DISK_1_PATH` (and optionally `DISK_2_PATH`), and `steam` needs
  `STEAM_GAME_SLUG` (`STEAM_LAUNCH_MODE=steam|direct` for a DRM-free game) and
  a saved Steam sign-in ([docs/steam.md](docs/steam.md)). `HER_INSTALLER_PATH`,
  `LAUNCH_GAME`, `LAUNCH_GAME_ARGS`, `PATCH_FAILURE_POLICY` and
  `EXPECTED_GAME_SLUG` (fail if the disc is another game) are read by
  `WrappBuildInput` when the corresponding prompt would appear. **`CLIBuilder`
  owns every `exit()`** — no code path in `WrappBuildViewModel` terminates the
  process, so the ViewModel is safe to instantiate in tests regardless of
  environment.
- **Headless stderr is TTY-gated.** `LogStore` only mirrors to stderr when
  `isatty`, so piping or redirecting a headless run's output shows nothing —
  unless `SECOND_CHANCE_LOG_STDERR=1` forces it (`0` forces it off), which is
  what `sc wrapp build` does, since it reads the app's output through a pipe.
- **Over SSH, Wine needs the GUI session.** An SSH shell is in launchd's
  `Background` session with no WindowServer, so Wine's graphics driver can't
  load (`nodrv_CreateWindow … no driver could be loaded`), installers exit 1,
  and the build fails with `Wine execution failed with exit code 1`, which looks
  like a broken installer. `sc` commands that open windows re-run themselves in
  the console user's `Aqua` session under a pty and stream the output back;
  anything else can be wrapped in `./sc in-gui-session -- <command>`. Someone
  must be logged in at that Mac's console. That run is a LaunchAgent, so it
  outlives a dropped connection; `./sc attach` (or `./sc --on <host> attach`)
  picks it up again.
- **Wine prefix caching**: `WineManager` caches prefixes in `~/Library/Caches/SecondChance/wine-prefix-cache`, keyed by bundle version (or `"dev"` in DEBUG) plus the bundled Wine engine's version (`Contents/SharedSupport/wine/version`), so a Wine upgrade starts a fresh prefix by itself. Caching a prefix removes every other key's. Other changes to how the prefix is set up (winetricks verbs, `ddraw.ini`) don't change the key: run `./sc clean wine-prefixes` (or pass the app `--clear-wine-cache`) after those, or if Wine setup misbehaves after code changes.
- **`STRICT_INSTALL=true`** env var disables the silent→interactive installer
  retry fallback in `GameInstallerRunner`; headless builds (`NON_INTERACTIVE`)
  never take it either, since the interactive installer is a wizard nobody is
  there to click through. An unattended install times out after
  `SECOND_CHANCE_INSTALL_TIMEOUT` seconds (default 1800). The `--skip-installer` debug flag
  skips running the installer entirely (useful for testing wrapp construction).
  Through `sc` these are `--debug strict-install` and `--debug skip-installer`;
  the `SECOND_CHANCE_*` switches below are `--debug` values on `sc wrapp run`
  too ([docs/dev-cli.md](docs/dev-cli.md#debug-options) has the table).
- **`SECOND_CHANCE_WINEDEBUG`** sets Wine's `WINEDEBUG` for every Wine process
  Second Chance or a wrapp starts (`WineEnvironment`); unset, it is
  `-all,err+all` — only Wine's `err:` lines, which is where it names the cause
  of most failures.
  Wrapp output lands in the wrapp's log, so `SECOND_CHANCE_WINEDEBUG=+seh,+d3d9
  open -n "<wrapp>.app"` traces a single launch — `open` passes the shell's
  environment through. Channels like `+d3d9` log per frame, so keep runs short.
  More debug switches read the same way: `SECOND_CHANCE_KEEP_IN_DOCK=1`
  skips the wrapp hiding itself from the Dock once the game starts,
  `SECOND_CHANCE_NATIVE_FULLSCREEN=0` leaves native fullscreen unarmed, and
  `SECOND_CHANCE_CURSOR_LOCK=0` leaves cursor lock unarmed (next bullet).
  For Second Chance itself, `SECOND_CHANCE_UPDATES=1` turns on the update
  checks a Debug build leaves off ([docs/updates.md](docs/updates.md)).
- **cnc-ddraw swallows the first click unless the wrapp locks the cursor.**
  Wine games draw through cnc-ddraw in windowed mode, which only takes hold of
  the mouse on the first button release inside the window — eating it, while
  handing the game a stale cursor position — and lets go whenever the app is
  deactivated. A helper running inside the game process posts a middle click
  (which the games ignore, so the publisher logo isn't skipped) until Wine's
  cursor state shows the lock, and again on every return to the app.
  `WineEnvironment` arms it alongside native fullscreen; both live in
  `WrappTemplate/InProcessHelpers/`. Read
  [docs/wine-in-process-helpers.md](docs/wine-in-process-helpers.md) before
  touching either, or cnc-ddraw's `ddraw.ini` settings in `WineManager`.
- **Wrapps start Wine's desktop before the game.** Left to Wine, a game's
  first desktop access starts `explorer.exe /desktop` and waits only 10 s for
  it; on a loaded machine under Rosetta that runs out, and the game carries on
  with no display adapters — Secrets Can Kill Remastered then crashes on a null
  Direct3D object exactly 10 s in. `WineDesktop` (`Shared/Wine/`) starts the
  desktop itself and waits until it has registered the display devices,
  which it detects through the volatile `HKLM\HARDWARE\DEVICEMAP\VIDEO` key.
  It waits up to 600 s, since with every core busy a fresh session has taken
  two and a half minutes to bring it up, and what runs without it is sure to
  fail; each check is itself a Wine program and gets 120 s, because one cut
  short at 20 s never saw the desktop ready, and the checks back off to one
  every 10 s as the wait grows, so they don't take the CPU the desktop needs. `GameLauncher` does this
  before the game, and `GameInstallerRunner` before every installer and
  patcher, which fail the same way: with an exit code rather than a crash, or
  for AutoIt with no window and an exit 0 before its script runs. A program
  that still prints `nodrv_CreateWindow` fails with `WineError.noDisplay`,
  and a build then restarts the Wine session and retries that step once
  ([docs/wrapp-build.md](docs/wrapp-build.md)). Wine runs that
  desktop through `start.exe /exec`, which is itself a Windows program waiting
  on explorer, so the two would keep the whole Wine session alive after the
  game quits; `WineDesktop.release()` ends the `start.exe` once the programs
  are done and explorer then closes normally. A build releases it before
  `wineserver -w`, which would otherwise wait for ever. `SECOND_CHANCE_PRESTART_DESKTOP=0`
  restores Wine's on-demand start, for comparison. Anything that runs `wine`
  and reads its output must not wait for EOF on a pipe: Wine's background
  services inherit the child's stdout and hold the pipe open.
- **Wine can't start on a Mac whose performance cores are all busy.** With
  other programs on every performance core, Wine (under Rosetta) is left the
  efficiency cores and takes minutes to bring its desktop up, or never does;
  with a couple of performance cores free it starts in seconds, so it is a
  cliff, not a slope. `SystemLoad` (`Shared/`) measures it — other programs'
  CPU in cores, against the performance-core count, heavy at all but one;
  the load average is useless here, since starved Wine threads push it past
  100. Every log header carries a `load:` line; a wrapp's loading window warns
  while the Mac is heavily loaded (`SystemLoadMonitor`) instead of declaring a
  possible launch failure; and the integration test reports such a game as
  `overloaded` rather than testing it, unless run with `--ignore-load`.
- **A badly starting Wine game leaves a diagnostics bundle** in
  `~/Library/Logs/SecondChance/diagnostics/<slug>-<time>-<reason>/`
  (`StartupDiagnostics`): no window 8 s after the game process appears
  (`slow-start`), Wine's unhandled-exception line (`crash`), still no window at
  25 s (`hang`), an exit before any window (`exited-before-window`), Wine's
  launcher exiting before the game's exe appears (`exited-before-game`), or the
  game quitting within 15 s of its window (`quit-early`). Each holds a `sample` of the game
  process's thread stacks and of every other Wine process (`explorer.exe`,
  `wineserver`, …) taken at the same moment, `top`, the process list (taken
  first, before a crashing game can exit), display/lock/screen-sharing
  state, the game's system log, the last 300 Wine output lines and the wrapp's
  whole log so far; the newest 10 are kept and the wrapp log names the folder.
  Every launch also keeps its log in
  `~/Library/Logs/SecondChance/<slug>/launch-<time>.log` (newest 10). `SECOND_CHANCE_DIAGNOSTICS=0`
  turns it off and `SECOND_CHANCE_DIAG_SLOW_SECONDS` moves the threshold — set
  it to `1` to force a bundle and check the capture works.
- **A Wine wrapp waits on a dialog before it starts the game.** Launched by
  hand (`open`, its `Contents/MacOS/WrappTemplate`, `sc wrapp run`), a wrapp
  whose engine is Wine shows a save-progress warning and starts nothing until
  someone clicks **I Understand**, so a script that launches a wrapp and waits
  for the game waits for ever on an unattended Mac. The wrapp skips the dialog
  when `~/Library/Application Support/<bundle id>/dont-show-save-warning`
  exists (`InfoWindowController`). Create it for the experiment and remove it
  afterwards: WrappPuppeteer expects to dismiss that dialog, and fails with
  `Failed to dismiss info window` when it never appears.
- **Disk path resolution**: installers land in
  `Contents/SharedSupport/prefix/drive_c/nancy-drew-installer/{disk-1,disk-combined}`,
  with multi-disk games merged into `disk-combined`. This lives in
  `DiskWrappBuilder` — it is deliberately not in the shared helper, because no
  other source has disks.
- **A new file in `WrappTemplate/` must be listed to be built.** Unlike
  `SecondChance/` and `Shared/`, the WrappTemplate target takes only the files
  named in its `membershipExceptions` list in `project.pbxproj` (Xcode's
  synchronized-folder exception set, used here as an allow-list). A file left
  off it isn't compiled, and the build fails with `cannot find type … in
  scope` wherever it's used. Add it to the list (or tick the target in Xcode's
  File inspector).
- **The template is `WrappTemplate.app`**, embedded in
  `Second Chance.app/Contents/Resources/`. `WrappBuildHelper` copies it per game
  and rewrites `CFBundleIdentifier` from
  `au.gare.callum.SecondChance.WrappTemplate` to
  `au.gare.callum.SecondChance.nancy-drew.<slug>`. Because
  `PRODUCT_NAME = $(TARGET_NAME)`, the produced game's executable is
  `Contents/MacOS/WrappTemplate`. WrappPuppeteer doesn't depend on that name: it
  finds the wrapp by the PID it launched and the game by its own process name.
- **Second Chance has an Info.plist file; the other targets don't.**
  `SecondChance/Info.plist` holds only Sparkle's keys, which `INFOPLIST_KEY_`
  build settings can't express, and Xcode merges it with the generated keys.
  Other keys still go in build settings. The file is excluded from the
  target's synchronized folder, so it isn't copied in as a resource.
- **Bundled resources**: `WrappTemplate.app` template, Wine engine, `winetricks`, AutoIt, and ScummVM are bundled. Test
  that features work with bundled paths, not just system-installed equivalents.

## Terminology

The Nancy Drew games have a set of common abbrevations use for each game
(https://nancydrew.fandom.com/wiki/User_blog:BanaBerry/Nancy_Drew_Game_Abbreviations). For example
`Treasure in the Royal Tower` is `TRT` and `The Haunted Carousal` is `CAR`. These abbreviations are hard for me to
remember so Second Chance avoids these whenever possible and instead uses our shortenings. The full list can be found in
SecondChance/Services/GameInfoProvider.swift where the id property is the shortening we use for each game. For us
`Treasure in the Royal Tower` is `royal-tower` and `The Haunted Carousal` is `haunted-carousel`. Not as short but much
more self-explanatory.

## Testing

**[docs/testing.md](docs/testing.md) is the detailed guide** — suites,
filtering, WrappPuppeteer permissions and its exit codes, reports. In short:

- **Unit tests** live in `SecondChanceTests/`, using Swift Testing.
  `GameDetectorTests` is the model to follow (35+ parameterized tests). A new
  suite runs in `sc test unit` automatically — the unit run excludes a short
  list (`TestRunner.unitExclusions` in `Tools/sc`) rather than listing what to
  include. A slow or environment-dependent suite needs adding to that list.
- **Integration tests** need real ISOs in `installers/<slug>/disk-1.iso` and run
  the actual build flow; they disable themselves when the ISOs are absent.
  Prefer unit tests for fast feedback.
- **Only the integration test can catch a dropped bus event.** A build with a
  missing `bus.publish` still produces a correct `.app`, so it passes the build
  and the unit tests. Run it after touching orchestration.
- **WrappPuppeteer keeps its utilities generic.** `WrappPuppeteer/Core/` must not
  know about Nancy Drew, wrapps or engines; what is specific to driving a game
  lives in `WrappPuppeteer/NancyDrew/` and configures Core through parameters.
  [docs/testing.md](docs/testing.md#wrapppuppeteer) has the details.
- **Test fixtures** are in `TestFixtures/` and `installers/`. Make skips
  explicit rather than returning early, so a skipped test reads as skipped.
- **Priority test targets** (untested but high-value): `CacheManager`,
  `WrappBuildInput`'s env-var resolution and validation, `WrappBuildHelper` path
  helpers.

## Releasing

**Commit messages are load-bearing.** `./sc release` derives the next
version from the [conventional commits](https://www.conventionalcommits.org)
since the last tag, using [cocogitto](https://docs.cocogitto.io) configured in
`cog.toml`, so a malformed message is a message that silently disappears from
the release notes and doesn't count toward the version.

Run `./sc setup` once per clone. It installs cog's
`commit-msg` hook (and checks the tools `sc` needs), which rejects a non-conventional message at commit time —
git hooks live in `.git/` and so can't be committed, which is why this isn't
automatic.

Only three things move the version: `feat` bumps the minor, `fix` bumps the
patch, and a breaking change (`feat!:` or a `BREAKING CHANGE:` footer) bumps
the minor while the project is pre-1.0 and the major after. **`refactor`,
`docs`, `test`, `ci`, `chore` and `style` bump nothing** — a batch containing
none of feat/fix/breaking produces no release at all, and `sc release` says so
rather than inventing a version. Pass `--version X.Y.Z` to force one.

What `sc release` writes, how it treats `CHANGELOG.md`, and how it commits,
tags and publishes is in [docs/releasing.md](docs/releasing.md).

**A release needs the Sparkle signing key in the login keychain** of the Mac
running it. `sc release` refuses to sign without it. The key can't be kept in
iCloud Keychain, because Sparkle's tools only read the login keychain. It is
backed up as a Passwords entry and imported once on each releasing Mac.
[docs/updates.md](docs/updates.md#the-signing-key) has why and how.

## Things Currently In Flux

- **Steam works.** Steam wrapps build and launch (`SteamWrappBuilder`,
  `WrappTemplate/WrappSteam.swift`), the Steam option is on the welcome
  screen, and `sc test integration --source steam` tests them. Steam
  touches the microphone and the local network at start-up and waits on any
  macOS prompt that raises: an app bundle gets none, a bare CLI like `sc`
  does, so `sc wrapp build` starts the app as its own responsible process
  ([docs/steam.md](docs/steam.md)).
- **Her download works end-to-end** through the same helpers as disk (it signs
  and publishes the same events), but has far less real-world mileage than the
  disk path.
- The produced game app's process is named `WrappTemplate` in Activity Monitor.
  Renaming the executable per-game during configuration would read better.

## Additional Info

If the file `.local/AGENTS.md` exists please read that and follow any instructions there too.
