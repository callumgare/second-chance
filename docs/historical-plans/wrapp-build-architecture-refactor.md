# Plan: Wrapp Build Architecture Refactor

**Status: implemented (Phases 1–7), 2026-08-17 → 2026-09-03.**

Frozen record of what this refactor set out to do and why. It is not updated as
the code moves on — read it for the reasoning behind the current shape of
`SecondChance/Builders/`, not as a description of present-day behaviour.

## The problem

Installation was spread across three types with no clear ownership:

- `InstallationService.performInstallation(context:)` — the nominal entry point,
  which held the disk-source flow inline.
- `GameInstaller` — a second orchestrator, called both by `InstallationService`
  and directly by `InstallationViewModel` (the Her-download path bypassed
  `performInstallation` entirely).
- `WrapperBuilder` — bundle construction, plus a large block of dead code.

Concrete consequences:

- **The game was detected twice per build.** `InstallationService` called
  `GameDetector`, then `GameInstaller` called it again.
- **`.savingApp` progress was never published on the disk flow** — the UI had a
  step that never appeared.
- **The Her-download path skipped signing and published no bus events**, so it
  was invisible to the integration tests.
- **The Steam path leaked.** Its stub built a base wrapper and installed the
  Steam client *before* throwing "not implemented", leaving a temp wrapp behind.
- Services reached for each other through `.shared`, so nothing could be tested
  in isolation.
- `InstallationViewModel` called `exit()` in five places, making it unsafe to
  instantiate in a unit test.

## The target

One builder per installation source, each owning its flow end-to-end, over a
shared helper for source-independent work:

```
WrappBuildViewModel / CLIBuilder
            │  (both go through the WrappBuildStrategy protocol)
            ▼
DiskWrappBuilder · HerDownloadWrappBuilder · SteamWrappBuilder
            │
            ▼
WrappBuildHelper  ·  GameInstallerRunner  ·  ISOMounter
            │
            ▼
WineManager · CacheManager · GameDetector · AutoItService · ScummVMService
```

Design rules adopted:

- **A builder owns its flow and its resources.** Whatever a builder creates
  (mounted ISOs, the temp wrapp) it tears down on both the success and the error
  path. The helper provides cleanup *primitives*; it never decides when to call
  them.
- **The helper never calls a builder.** One direction only.
- **Source-specific work does not go in the helper.** Disk layout and CD-ROM
  mounting live in `DiskWrappBuilder` because no other source uses them.
- **Detect the game once**, then thread `GameInfo` through.
- **The bus events are the contract.** `AppEvent` / `WrappBuildEvent` is what
  the UI renders and what the integration tests assert on.

## Phases as executed

| Phase | What it did |
| --- | --- |
| 1 | Extracted `ISOMounter` and `GameInstallerRunner`; moved `InstallerType` to `Models/` |
| 2 | Replaced the `InstallationContext` / `InteractiveContext` / `NonInteractiveContext` trio with one env-var-first `WrappBuildInput` |
| 3 | Constructor injection throughout (`wineManager` / `cacheManager` / `bus`), removing `.shared` coupling from the build path |
| 4 | Extracted `CLIBuilder`, lifting every `exit()` out of the ViewModel |
| 5 | Created `SecondChance/Builders/`: the `WrappBuildStrategy` protocol, `WrappBuildHelper`, and the three per-source builders. Deleted `InstallationService`, `GameInstaller`, `WrapperBuilder` (~1700 lines, including a 537-line dead block) |
| 6 | Terminology: `Installation*` → `WrappBuild*` / `WrappSource` in code (6a), then the `GameWrapper` target → `WrappTemplate` (6b) |
| 7 | Pruned provenance comments naming deleted types; rewrote `AGENTS.md` and `SecondChanceTests/README.md` against the actual code |

## What the dead block in `WrapperBuilder` was

`setupWineFramework`, `fixWineRpaths`, `createBashLauncher`, the download/extract
chain, and `createLauncherExecutable` — all uncalled, because the WrappTemplate
target ships a pre-compiled launcher. Deleting them was safe and removed the
largest single source of confusion in the file.

## Lessons worth carrying forward

- **Every `bus.publish` must move with the orchestration code it belongs to.**
  Merging `GameInstaller`'s flow into the builders initially kept the
  `input.onGameDetected` callback but dropped the `.gameDetected` bus publish.
  The build still succeeded; only the integration test noticed
  (`RecordingEventSubscriber` saw "Detected game nil"). Unit tests and a green
  build cannot catch this class of regression.
- **Verify a mechanical rename mechanically.** For the Phase 6a sweep, the same
  rename script was applied to the `HEAD` version of every touched file and
  diffed against the working tree; the only differences left were the intended
  prose edits. That proves no accidental semantic change across ~380 sites in a
  way that reading the diff does not.
- **A rename can reach further than the code.** Phase 6b changed
  `PRODUCT_NAME`, so it also changed the produced game app's executable name —
  which the GamePuppeteer window-owner heuristic matched on by string.

## Known follow-ups left open

- `WrappBuildError.userCancelled` vs `.userCancelledBeforeStart` is the only
  thing distinguishing "cancelled the first dialog" (return to welcome) from
  "cancelled later" (show the error screen). It works, but the distinction lives
  in the error type rather than in the flow.
- `GameInstallerRunner` still has one force unwrap (`gameExe!`).
- `SteamWrappBuilder` is a deliberate not-implemented stub.
- The produced game app's running process is named `WrappTemplate`. Renaming the
  executable per-game during configuration would read better in Activity
  Monitor.
