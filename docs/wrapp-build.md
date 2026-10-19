# How a wrapp build works

A **wrapp** is the `.app` Second Chance produces: one game plus the engine that
runs it. This is the mechanics of building one — the flow, who owns what, and
the two seams that let the same code serve the GUI, headless runs, and tests.

For the vocabulary and the repo-wide conventions, see `AGENTS.md`. For why the
code is shaped this way, see
[historical-plans/2026-09-03-wrapp-build-architecture-refactor.md](historical-plans/2026-09-03-wrapp-build-architecture-refactor.md).

## The shape

```
WrappBuildViewModel (GUI)          CLIBuilder (headless)
         │                                  │
         └──────── WrappBuildStrategy ──────┘
                          │
    ┌─────────────────────┼──────────────────────┐
DiskWrappBuilder   HerDownloadWrappBuilder   SteamWrappBuilder
    └─────────────────────┼──────────────────────┘
                          ↓
      WrappBuildHelper · GameInstallerRunner · ISOMounter
```

One builder per source. `WrappBuildStrategy` is a single method:

```swift
func build(input: WrappBuildInput) async throws -> URL
```

Both entry points dispatch through the protocol, so **adding a source means
adding a builder, not adding a branch.** Neither call site changes.

## The disk build, step by step

`DiskWrappBuilder.build(input:)` is the complete and best-exercised path. The
other builders are the same shape with less in the middle.

| Step | What happens | Event published |
| --- | --- | --- |
| 1 | — | `.started(source: .disk)` |
| 2 | `input.getDisk1Path()`; mount it if it's an ISO | `.isoMounted` |
| 3 | `GameDetector.detectGame(fromDisk:)` → slug → `GameInfo` | `.progress(.detectingGame)`, `.gameDetected` |
| 4 | Disk 2, only when `gameInfo.diskCount > 1` | `.isoMounted` |
| 5 | — | `.disksResolved` |
| 6 | `helper.createTemporaryWrappPath()`, then `createBaseWrapp` copies `WrappTemplate.app` | `.progress(.settingUpWrapp)` |
| 7 | `copyGameDisks` lays out `disk-1` / `disk-2` / `disk-combined`, stripping extended attributes and making the copies writable (a CD's directories are read-only, which left copies nothing could delete) | `.progress(.copyingInstaller)` |
| 8 | Route on `gameInfo.gameEngine` into `installGameWithWine` or `installGameWithScummVM` | `.progress(.installingGame)`, `.engineRouted`, `.installerResolved`, `.gameExeDetected`, then `.patchApplied` / `.patchFailed` per patch |
| 9 | `cleanupUnusedEngine` strips the engine this game doesn't use | — |
| 10 | `configureWrapp` rewrites `Info.plist` / `AppSettings.plist` / game INI | `.progress(.configuringWrapp)`, `.wrappConfigured` |
| 11 | `helper.finalize` — sign, resolve output dir, move | `.signed`, `.progress(.savingApp)`, `.completed` |
| 12 | Unmount ISOs; launch if requested | — |

**Step 3 happens exactly once.** `GameInfo` is threaded through every later
step; nothing downstream re-detects. (An earlier design detected twice.)

Step 9 is skipped when `DebugSettings.shared.skipInstaller` is set — Wine may
still be needed to run the installer later.

## Who owns what

The division that keeps this from re-tangling:

- **A builder owns its flow and its resources.** Whatever it creates — mounted
  ISOs, the temp wrapp — it tears down on the success path *and* in `catch`
  before rethrowing. `DiskWrappBuilder.build` is one big `do/catch` for exactly
  this reason.
- **`WrappBuildHelper` provides cleanup primitives, never policy.** It exposes
  `createTemporaryWrappPath` / `unregisterTemporaryWrapp` / `removeTempWrapp`
  over an internal `temporaryWrapps` set; the builder decides when to call them.
  Note the asymmetry on success: `finalize` *moves* the wrapp to its final home,
  which makes it non-temporary, so the builder calls `unregisterTemporaryWrapp`
  (not `removeTempWrapp`) afterwards. `removeTempWrapp` stops the wrapp's
  Wine session before deleting it: a build that failed partway can leave one
  running, and once the wrapp is gone so is the wineserver that could end it.
- **The helper never calls a builder.** One direction only.
- **Source-specific work stays out of the helper.** Disk layout and CD-ROM
  mounting live in `DiskWrappBuilder` because no other source has disks.
  Driving Steam lives in `Shared/Steam/` and `SteamWrappBuilder`
  ([steam.md](steam.md)); the helper only installs the Steam client
  (`installSteamClient`), as it installs Wine's other pieces.
- **Resources created and consumed inside one function** are cleaned up inside
  that function, so builders never see them.

## Seam 1: `WrappBuildInput` — where all I/O lives

Every prompt, path, and confirmation goes through one object. Each method checks
an environment variable **first**; if set, it is used with no UI. If unset, the
user is prompted.

| Method | Env var | Fallback |
| --- | --- | --- |
| `getDisk1Path()` | `DISK_1_PATH` | NSOpenPanel (disk/ISO) |
| `getDisk2Path(gameInfo:)` | `DISK_2_PATH` | NSOpenPanel (disk/ISO) |
| `getHerInstallerPath()` | `HER_INSTALLER_PATH` | NSOpenPanel (.exe) |
| `requestVolumeAccess()` | — (skipped when paths came from env) | NSOpenPanel grant-access |
| `getOutputPath(gameName:)` | `OUTPUT_PATH` | NSOpenPanel save dialog |
| `shouldLaunchGame()` | `LAUNCH_GAME`, `LAUNCH_GAME_ARGS` | `(false, [])` |
| `confirmPatchFailure()` | `PATCH_FAILURE_POLICY` | NSAlert |

There are **no separate interactive/non-interactive classes**. Headless is just
"every env var set, so nothing prompts."

The `environment` dictionary is a constructor parameter defaulting to
`ProcessInfo.processInfo.environment` — which is what makes the table above a
seam rather than a hard dependency on the real process environment.

Two subtleties:

- `requestVolumeAccess` returns the mount point unchanged when the disk paths
  came from env vars. A modal sheet under a `.prohibited` activation policy is
  invisible *and* unfocusable, so a headless run that prompted would hang
  forever. `confirmPatchFailure` short-circuits for the same reason.
- Cancelling the *first* dialog throws `.userCancelledBeforeStart`, not
  `.userCancelled`. The ViewModel routes the former back to the welcome screen
  (nothing had happened yet) and the latter to the error screen (work is being
  abandoned). For Steam the first dialog is the game picker, which comes
  after Steam has signed in: the builder cleans up its temporary wrapp as on
  any failure, but to the user it is still backing out before they began.

## Seam 2: the ViewModel's input factory

`WrappBuildViewModel` does not construct its input directly. It takes a factory:

```swift
typealias WrappBuildInputFactory = (WrappBuildViewModel) -> WrappBuildInput

init(makeInput: @escaping WrappBuildInputFactory = { WrappBuildInput(viewModel: $0) })
...
private func runBuild(_ builder: WrappBuildStrategy) async {
    let input = makeInput(self)
```

Production uses the default. Integration tests substitute an input carrying
fixed paths, which is what lets a test drive the **real** `buildFromDisk()`
entry point — ViewModel, bus, and all — with no global state and no chance of a
panel appearing:

```swift
WrappBuildViewModel(makeInput: {
    WrappBuildInput(disk1: disk1, disk2: disk2, outputDir: outputDir, viewModel: $0)
})
```

That convenience initializer (test target only, in
`SecondChanceTests/Integration/IntegrationTestInput.swift`) just packs typed
values into an in-memory environment dictionary, so every lookup in the table
above takes its env-var branch.

## Events are the contract

Builds report progress and results only by publishing `WrappBuildEvent`s on
`EventBus.app`. The UI renders them, `AutomationBridge` serialises them to its
socket, and the integration test asserts on them via
`RecordingEventSubscriber`.

**When moving orchestration code, every `bus.publish` moves with it.** A build
missing a publish still produces a correct `.app` — it passes the build and the
unit tests, and only the integration test notices. This has happened once
already; see the historical plan.

`.progress(WrappBuildState)` carries the same state enum the UI renders, so
step display and the event stream can't drift apart. The ViewModel hides
substeps and elapsed time for the first 5 s so fast steps don't flash.

## Headless runs

`CLIBuilder` (not the ViewModel) owns headless mode. `NON_INTERACTIVE=true`
enables it; `validatedSource()` checks the environment *before* the UI starts
and exits 1 with a logged reason if it's misconfigured. **Every `exit()` in the
build path lives in `CLIBuilder`** — no code path in `WrappBuildViewModel`
terminates the process, which is what makes the ViewModel safe to instantiate in
a unit test.

Required: `INSTALLATION_SOURCE` (`disk` | `her-download` | `steam`) and
`OUTPUT_PATH`; `disk` also needs `DISK_1_PATH`, and `steam` needs
`STEAM_GAME_SLUG` (plus `STEAM_LAUNCH_MODE=steam|direct` for a DRM-free game,
default `direct`) and a saved Steam sign-in, since a headless build can't sign
in — it fails with `steamSignInRequired` rather than wait.

An installer or patcher that prints Wine's `nodrv_CreateWindow` error found
no desktop to open its windows on, so `runWine` throws `WineError.noDisplay`
whatever its exit code (AutoIt in that state exits 0 without running its
script). `GameInstallerRunner` then stops the Wine session and runs that step
once more with a fresh desktop (a failed install attempt likewise gets a fresh
session before the next one): on a loaded machine a program has failed to
find a desktop `WineDesktop` had just reported ready, and every program after
it in the same session failed the same way.

An installer killed partway can exit 0 with the game's exe already unpacked,
so neither the exit code nor finding the exe proves the install finished.
Nor does `wine start /wait` returning: InstallShield 12's `setup.exe`
relaunches itself from Temp and exits while the copy carries on, so after a
clean exit the build first waits (`wineserver -w`, within the install timeout)
until the prefix has no Windows processes left. Then `GameInstallerRunner` checks the record each installer
family writes only once it has finished (`InstallCompletion`), and fails the
attempt with `WrappBuildError.installIncomplete` when it is missing:

| Installer     | Finished when                                                                  |
| ------------- | ------------------------------------------------------------------------------ |
| Inno Setup    | Its `/LOG` has `Installation process succeeded.`                               |
| MSI           | Its `/l*` log has the `INSTALL` action ending with `Return value 1.`           |
| InstallShield | Its uninstall log, `setup.ilg`, is in the game exe's folder or one above it (InstallShield 6), or under `Program Files (x86)\InstallShield Installation Information\{GUID}` (7 and later) |

InstallShield's `/f2` result file and its uninstall registry key are no use
for this: both say success seconds into an install that is then killed. An
installer of unknown type gets no check. Either way, the size and file count
of the game exe's folder are logged (`Installed: …`).

A headless build makes one install attempt. The GUI's fallback, retrying with
the installer's interactive wizard when the silent install fails, would wait
for a click that never comes, so headless runs fail instead and say why.

Note that `LogStore` mirrors to stderr only when `isatty`, so piping a headless
run's output shows nothing — unless `SECOND_CHANCE_LOG_STDERR=1` forces the
mirror on (`0` forces it off).

**Progress for whoever started the build.** When `SECOND_CHANCE_PROGRESS_PATH`
is set, `CLIBuilder` attaches a `ProgressFileWriter`: an `EventBus.app`
subscriber like any other, which appends one JSON object per line to that file —

```
{"event":"stage","stage":"installingGame","text":"Game installing","fraction":0.5}
{"event":"completed","path":"/…/Nancy Drew - X.app"}
{"event":"failed","message":"…"}
```

`stage` is a stable name for the `WrappBuildState` case and `text` is what the
progress view would say. This is how `sc wrapp build` shows the build stage
([dev-cli.md](dev-cli.md)); the integration test writes the same stream (from
`TEST_RUNNER_PROGRESS_PATH`) with extra per-game `"event":"game"` lines.
Because the writer is a bus subscriber, a dropped `bus.publish` shows up there
too. The record format is a contract with `ProgressRecord` in `Tools/sc`.

Headless doesn't mean windowless: installers and Wine itself still need a
WindowServer connection. A shell started over SSH has none — it sits in
launchd's `Background` session — so a build run there fails at the installer
step. `sc` commands that build or run wrapps re-run themselves in the
logged-in user's `Aqua` session instead (as a one-off LaunchAgent, under a pty
so the stderr mirror still fires) and pass back the output and exit code;
`./sc in-gui-session -- <command>` does the same for any command.

## The template

`WrappTemplate.app` is built as its own target and embedded at
`Second Chance.app/Contents/Resources/WrappTemplate.app`. `createBaseWrapp`
copies it wholesale — both engines included — and `cleanupUnusedEngine` later
strips whichever one this game doesn't need.

`configureWrapp` rewrites the copy's bundle identifier from
`au.gare.callum.SecondChance.WrappTemplate` to
`au.gare.callum.SecondChance.nancy-drew.<slug>`.

Because the target sets `PRODUCT_NAME = $(TARGET_NAME)`, the produced game's
executable is `Contents/MacOS/WrappTemplate`. WrappPuppeteer doesn't rely on that
name — it tracks the wrapp by the PID it launched and finds the game by the
game's own process name — so the target can be renamed without touching it.

## Adding a source

1. Add a case to `WrappSource`.
2. Add a builder conforming to `WrappBuildStrategy`, owning its own resources on
   both paths.
3. Add a `buildFrom…` method on the ViewModel that calls `runBuild(_:)`.
4. Publish the same events the disk flow does — that is what the UI and tests
   read.
5. Add any new prompt to `WrappBuildInput` with an env-var override, or headless
   runs will hang on it.

Do **not** ship a partial source. A builder that creates a temp wrapp and then
gives up has to remove it: an early Steam builder installed the Steam client
and then threw, leaking the wrapp every time. `SteamWrappBuilder` also stops
Steam on its failure path, as anything left running would hold the Wine
session (and the Steam lock) open.
