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
| 7 | `copyGameDisks` lays out `disk-1` / `disk-2` / `disk-combined` | `.progress(.copyingInstaller)` |
| 8 | Route on `gameInfo.gameEngine` into `installGameWithWine` or `installGameWithScummVM` | `.progress(.installingGame)`, `.engineRouted`, `.installerResolved`, `.gameExeDetected` |
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
  (not `removeTempWrapp`) afterwards.
- **The helper never calls a builder.** One direction only.
- **Source-specific work stays out of the helper.** Disk layout and CD-ROM
  mounting live in `DiskWrappBuilder` because no other source has disks.
  (`WrappBuildHelper.installSteamClient` is the one exception in waiting: it
  sits in the helper but currently has no callers, since `SteamWrappBuilder`
  throws before it would be used.)
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
  abandoned).

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
`OUTPUT_PATH`; `disk` also needs `DISK_1_PATH`.

Note that `LogStore` mirrors to stderr only when `isatty`, so piping a headless
run's output shows nothing. Run it bare in a terminal to see logs.

## The template

`WrappTemplate.app` is built as its own target and embedded at
`Second Chance.app/Contents/Resources/WrappTemplate.app`. `createBaseWrapp`
copies it wholesale — both engines included — and `cleanupUnusedEngine` later
strips whichever one this game doesn't need.

`configureWrapp` rewrites the copy's bundle identifier from
`au.gare.callum.SecondChance.WrappTemplate` to
`au.gare.callum.SecondChance.nancy-drew.<slug>`.

Because the target sets `PRODUCT_NAME = $(TARGET_NAME)`, the produced game's
executable is `Contents/MacOS/WrappTemplate`. GamePuppeteer matches on that name
when hunting for the game window, so renaming the target means updating that
heuristic too.

## Adding a source

1. Add a case to `WrappSource`.
2. Add a builder conforming to `WrappBuildStrategy`, owning its own resources on
   both paths.
3. Add a `buildFrom…` method on the ViewModel that calls `runBuild(_:)`.
4. Publish the same events the disk flow does — that is what the UI and tests
   read.
5. Add any new prompt to `WrappBuildInput` with an env-var override, or headless
   runs will hang on it.

Do **not** ship a partial source. `SteamWrappBuilder` throws
`.steamNotFullyImplemented` *before* creating anything, precisely so a failed
attempt leaves no temp wrapp behind; an earlier version built a wrapp and
installed the Steam client before giving up, and leaked it every time.
