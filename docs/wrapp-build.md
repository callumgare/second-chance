# How a wrapp build works

A **wrapp** is the `.app` Second Chance produces: one game plus the engine that
runs it. This is the mechanics of building one — the flow, who owns what, and
the two seams that let the same code serve the GUI, headless runs, and tests.

For the vocabulary and the repo-wide conventions, see `AGENTS.md`. For why the
code is shaped this way, see
[historical-plans/2026-09-03-wrapp-build-architecture-refactor.md](historical-plans/2026-09-03-wrapp-build-architecture-refactor.md).

## The shape

```text
WrappBuildViewModel (GUI)  ←  CLIBuilder (headless)
          │
          └───────────────┐
                  WrappBuildStrategy
                          │
    ┌──────────────────┬──┴─────────────────┬─────────────────────┐
DiskWrappBuilder  HerDownloadWrappBuilder  SteamWrappBuilder  BigFishWrappBuilder
    └──────────────────┴──┬─────────────────┴─────────────────────┘
                          ↓
      WrappBuildHelper · GameInstallerRunner · ISOMounter
```

One builder per source. `WrappBuildStrategy` is a single method:

```swift
func build(input: WrappBuildInput) async throws -> URL
```

The ViewModel dispatches through the protocol, and a headless run builds
through the same ViewModel, so **adding a source means adding a builder, not
adding a branch.** Neither the ViewModel nor `CLIBuilder` changes.

## Before any build: Rosetta

Wine is x86_64, so on Apple silicon it runs under Rosetta, which macOS
doesn't install until something asks for it, and Second Chance, being
universal, never does. Without it every Wine program fails with exit 126
("Bad CPU type in executable" from the `sh` that starts it), so the first
step of every build is `WineError.executionFailed`. So before a builder runs,
both entry points call `input.ensureRosetta()`, which runs an x86_64 program
to see whether one can run (`Rosetta.isInstalled`). When it can't, the person
is offered Rosetta: `softwareupdate --install-rosetta` through `osascript`,
which asks for an administrator's password, shown as "Installing Rosetta"
under `.settingUpWrapp`. Declining, or cancelling the password prompt, goes
back to the welcome screen. A headless run fails with
`WrappBuildError.rosettaMissing`, which says how to install it.

A wrapp has no such check: its executable is x86_64 only, so without
Rosetta none of its code runs, and macOS offers to install Rosetta when it
is opened, as for any Intel app.

## The disk build, step by step

`DiskWrappBuilder.build(input:)` is the complete and best-exercised path. The
other builders are the same shape with less in the middle.

| Step | What happens | Event published |
| --- | --- | --- |
| 1 | — | `.started(source: .disk)` |
| 2 | `input.getDisk1Path()`; mount it if it's a file rather than a folder | `.isoMounted` |
| 3 | Turn down an installed game (`GameDetector.isInstalledGame`), then `GameDetector.detectGame(fromDisk:)` → slug → `GameInfo`, then, for a Wine game, find its installer (`GameDetector.installerLookup`) | `.progress(.detectingGame)`, `.gameDetected` |
| 4 | `helper.createTemporaryWrappPath()`, `ensureRoomToBuild` (the build fails at once, as `notEnoughSpace`, unless twice each disc plus 3 GB is free), then `createBaseWrapp` clones `WrappTemplate.app` | `.progress(.settingUpWrapp)` |
| 5 | `copyGameDisks` copies `disk-1` in one pass (`DiscCopy`, through `copyfile`): contents only, so no extended attributes (which would fail codesign) and none of a CD's read-only modes (which left copies nothing could delete). Cancelling stops it, and the bytes copied show on the progress bar. The copies stay in the finished wrapp, mounted as CD drives, because some games check for their disc before they will play | `.progress(.copyingInstaller)`, `.stepProgress` |
| 6 | Disk 2, only when `gameInfo.diskCount > 1`, and only now: a Mac has one drive, so disc 1 has to be copied before it comes out. Then `disk-2` and `disk-combined` | `.isoMounted`, `.disksResolved` |
| 7 | Route on `gameInfo.gameEngine` into `installGameWithWine` or `installGameWithScummVM` | `.progress(.installingGame)`, `.engineRouted`, `.installerResolved`, `.gameExeDetected`, then `.patchApplied` / `.patchFailed` per patch |
| 8 | `cleanupUnusedEngine` strips the engine this game doesn't use | — |
| 9 | `configureWrapp` rewrites `Info.plist` / `AppSettings.plist` / game INI | `.progress(.configuringWrapp)`, `.wrappConfigured` |
| 10 | `helper.finalize` — take the quarantine off, sign, ask where to save (`getSaveLocation`), move it there (`saveWrapp`) | `.signed`, `.progress(.savingApp)`, `.completed` |
| 11 | Unmount ISOs; launch if requested | — |

**The game's program is where its `GameInfo` says**, or else the install's
one new `game.exe`. Failing both, a build uses the one new program that
isn't an uninstaller, a setup program or the like, and with several asks
which starts the game (`WrappBuildInput.chooseGameProgram`), listing them
likeliest first (`GameInstallerRunner.rankedGamePrograms`): the shallowest,
as a game's own program sits at the top of its folder and its helpers
beneath, then the largest, then by name, with uninstallers and the like
last. A headless build takes the first.

**`finalize` takes `com.apple.quarantine` off the wrapp.** A Second Chance
unpacked from a download carries the quarantine on every file in it,
`WrappTemplate.app` included, and `cp -a` copies it into the wrapp. macOS
then runs the wrapp translocated — from a read-only copy — so its prefix is
the cache's half-symlinked copy (`getWinePrefix`), where Steam can't update
itself or write its logs, and its launch never got past starting Steam. The
same reasoning as [`AppMover`](updates.md#moving-to-applications) applies:
Second Chance made the wrapp itself, so the quarantine guards nothing.

**Step 3 happens exactly once.** `GameInfo` is threaded through every later
step; nothing downstream re-detects. (An earlier design detected twice.)

**How a game is recognised.** `GameDetector` gathers the names a disc gives
itself into one fingerprint and matches it against the games' titles: the
product name in `setup.exe`'s version info (`WindowsExecutable`), the
subject of an `.msi`'s summary information (`MSISummary`), `setup.ini`'s
`AppName` and `Product`, `autorun.inf`'s label, and the volume name. Some
discs name the game in only one of these: Castle Malloy's only in its MSI's
subject. A Her download adds the names its installer carries as plain text
(`embeddedInstallerSignals`). The same version info tells InstallShield from
Inno Setup (`GameInstallerRunner.detectInstallerType`). Both readers are
Swift, in `Packages/SecondChanceKit/Sources/SecondChanceKit/Windows/` and `SecondChance/Services/`, and read only as
much of the file as they need.

A disc or Her download whose game isn't recognised (`GameInfo.unknownGame`,
"Other") stops at step 3 to ask (`input.askAboutUnrecognisedGame`): choose
another disc or download, which unmounts this one and goes back to step 2;
install it anyway, as Other; or cancel, back to the welcome screen. Only the
game that is finally chosen publishes `.gameDetected`. A headless run never
asks, and installs it as Other, as it always has.

**A disc image is any file.** The disc picker offers folders and `.iso`
files, but which files count as `.iso` is up to the apps on the Mac, and
`DISK_1_PATH` can name anything, so whatever is chosen that isn't a folder is
mounted (`ISOMounter.mount`), whatever its name. One that won't mount fails
with a `DiscImageError` saying why, from the image's own bytes
(`ISOMounter.diagnoseImage`): `incomplete` (shorter than its header says),
`rawCDImage` (a BIN, often renamed `.iso`, which hdiutil can't mount),
`notADiscImage` (no ISO 9660 header) or `wontOpen`. The case is the failure
report's kind, so even a basic report says which; hdiutil's own words are in
the log.

**An installed game isn't a disc.** Someone may choose the folder of a game
already installed, from an old PC or a copy found online, rather than its
disc. Step 3 turns that down first, before detection, with
`installedGameNotInstaller`: a folder with one of the games' own programs
(the last part of `internalGameExePath`, or `steamExePath`) at its top
level. No disc has one there, though many carry the game's files in folders
— Phantom of Venice's holds a whole installed copy. An installer beside it
doesn't make it a disc: the InstallShield games (Haunted Carousel to Blue
Moon) leave a `Setup.exe` in the installed folder, a stub that fails with
"The InstallShield Engine (iKernel.exe) could not be launched".

**A disc with no installer by name** might be one Second Chance doesn't
know: a special edition, or one in another language. For a Wine game, step 3
finds the installer before anything is copied. With none by name, but other
programs, it asks (`input.askAboutUnidentifiedInstaller`): try one of them,
picked from a list when there are several, which `installGameWithWine` then
runs as the installer (`installerName`); choose another disc, back to step 2;
or cancel. A headless run tries the first, as it always has. A disc with no
program at all fails there with `installerNotFound`. A ScummVM game needs no
installer, so isn't asked about.

Step 9 is skipped when `DebugSettings.shared.skipInstaller` is set — Wine may
still be needed to run the installer later.

A Her Interactive Windows download takes the same steps, with the installer
unpacked into `disk-1` in place of steps 2–7. Both engines install under
Wine, so step 8 always runs `installGameWithWine`, and ScummVM then plays the
installed folder. A Mac download replaces steps 7–8 with taking the game out
of its Cider app. [her-download.md](her-download.md) has both.

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
  Quitting Second Chance mid-build does the same for every temporary wrapp
  still registered, first (`endWineInTemporaryWrapps`, from
  `applicationShouldTerminate`): each running session is asked to stop and
  forced only if it won't (`shutDown(gracePeriod: 1)`, since an installer
  partway through won't finish by itself), after any Steam is stopped.
- **The helper never calls a builder.** One direction only.
- **Source-specific work stays out of the helper.** Disk layout and CD-ROM
  mounting live in `DiskWrappBuilder` because no other source has disks.
  Taking a game out of a Her Interactive Mac download lives in `CiderPackage`,
  used only by `HerDownloadWrappBuilder` ([her-download.md](her-download.md)).
  The helper's part in a Her build is a primitive both builders use:
  `installAnswerFile` copies the answer file for the build's source.
  Driving Steam lives in `Packages/SecondChanceKit/Sources/SecondChanceKit/Steam/` and `SteamWrappBuilder`
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
| `getDisk2Path(gameInfo:disk1:)` | `DISK_2_PATH` | Disc 1 in the drive: it is ejected, and an alert asks for disc 2, answered by disc 2 being put in (`DiscMountWatcher`, as Disk Arbitration reports the mount even while the alert is up), or by Continue; else NSOpenPanel |
| `getHerInstallerPath()` | `HER_INSTALLER_PATH` | NSOpenPanel (.exe, .dmg, or the installer .app in an opened .dmg) |
| `bigFishGameFromEnvironment(among:)` | `BIG_FISH_GAME_SLUG` | nil: the game is picked once the Game Manager has signed in |
| `chooseBigFishGame(from:)` | — (headless always names the game) | NSAlert with a popup of the editions the account owns |
| `isBigFishTrial` | `BIG_FISH_TRIAL=1` (tests only) | false: the full game |
| `bigFishTestSignIn` | `BIG_FISH_TEST_SIGN_IN=1` with `BIG_FISH_EMAIL`, `BIG_FISH_PASSWORD` (tests only) | nil: the person signs in in the Game Manager's window |
| `getSaveLocation(for:)` | `OUTPUT_PATH` (an app already there is replaced) | NSOpenPanel save dialog, opening in `/Applications`, or `~/Applications` for someone who can't write there; it turns down a folder that can't be written to while it is still open. Cancelling it doesn't throw the install away: the person is asked whether to choose a place again or start over. A folder that already has the game's app asks before replacing it, and while that copy is open, asks them to quit it first |
| `shouldLaunchGame()` | `LAUNCH_GAME`, `LAUNCH_GAME_ARGS` | `(false, [])` |
| `confirmPatchFailure()` | `PATCH_FAILURE_POLICY` | NSAlert |

There are **no separate interactive/non-interactive classes**. Headless is just
"every env var set, so nothing prompts."

The `environment` dictionary is a constructor parameter defaulting to
`ProcessInfo.processInfo.environment` — which is what makes the table above a
seam rather than a hard dependency on the real process environment.

Two subtleties:

- Nothing that would prompt does so in a headless run: a modal sheet under a
  `.prohibited` activation policy is invisible *and* unfocusable, so a run
  that prompted would hang forever. `confirmPatchFailure` short-circuits for
  this reason.
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
}, bus: bus)
```

The ViewModel's other parameter is the bus its builds report on. The app's
window leaves it as `EventBus.app`; an integration test gives each build a bus
of its own, so one build's events never reach another's recorder. The
ViewModel hands that bus to its builders, and to a `WrappBuildHelper` and
`GameInstallerRunner` of its own, since `.shared` ones report on
`EventBus.app`.

That convenience initializer (test target only, in
`SecondChanceTests/Integration/IntegrationTestInput.swift`) just packs typed
values into an in-memory environment dictionary, so every lookup in the table
above takes its env-var branch.

## Events are the contract

Builds report progress and results only by publishing `WrappBuildEvent`s on
the bus they were given: `EventBus.app` in the app and headless, or a test's own.
Nothing on the build path publishes to `EventBus.app` itself (`BuildBusTests`
checks), as that would reach the app's window rather than whoever started the
build. The UI renders them, `AutomationBridge` serialises them to its
socket, and the integration test asserts on them via
`RecordingEventSubscriber`.

**When moving orchestration code, every `bus.publish` moves with it.** A build
missing a publish still produces a correct `.app` — it passes the build and the
unit tests, and only the integration test notices. This has happened once
already; see the historical plan.

`.progress(WrappBuildState)` carries the same state enum the UI renders, so
step display and the event stream can't drift apart. The ViewModel hides
substeps and elapsed time for the first 5 s so fast steps don't flash.

`.instructions(String?)` is for what the person has to *do* for the build to
go on — sign in to Steam's window, click through an installer that runs
interactively (with the game's `installInstructions`). The progress screen
shows it at once, prominently, until the next `.instructions(nil)`.

`.stepProgress(StepProgress?)` is how far the current step has got, where the
build can measure it rather than guess: so far, Steam's downloads
([steam.md](steam.md)). It carries a fraction, which fills the progress bar in
place of the step's fixed share of the build, and its figures ("1.2 GB of
2.4 GB"), shown under the step. Each new step clears it, so publish it after
the step's `.progress`. `ProgressFileWriter` writes it as a `step-progress`
record, which `sc wrapp build` shows after the stage.

## Running Wine

Every Wine, `wineserver` and winetricks process — the build's and the wrapp's
— starts in one place, `Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/WineProcess.swift`. `Wine(wrapp:prefix:)`
names one wrapp's Wine and the prefix it runs in (the wrapp's own unless given
another), and a `WineCommand` says what to run: `.program(exe, args)`,
`.start(exe, args)` for `wine start /wait`, `.wine(args)` for a builtin such as
`reg`, `.wineserver(args)`, or `.script(url, args)` for winetricks. Then:

- `wine.run(command)` waits for it, logs it (see
  [logging.md](logging.md#subprocess-runs)), and throws `WineError` for a
  non-zero exit, a signal, a timeout, a stall or `nodrv_CreateWindow`. A
  timeout, a stall or cancelling the task stops the whole Wine session
  (`OnTimeout.stopSession`), as a program stuck on another Windows program is
  only freed by ending both; `.stopProgram` stops just the one.
- `wine.output(of: command)` returns what it printed. It's captured to a file,
  never a pipe: Wine's background services inherit a pipe and hold it open,
  so reading one to its end can wait for ever. Its timeout stops only it.
- `wine.start(command)` doesn't wait: the game, Steam, the desktop. It returns
  a `WineProcess` to watch or end.

Each process starts with `runWithoutCrashHandler()`, gets stdin from
`/dev/null` (unless it runs in the terminal), and has its output logged line by
line with its pid. Facades on `Wine` cover the rest: `wine.registry` sets,
imports and reads registry values with named keys (`.x11Driver`,
`.wineDrives`, `.videoDeviceMap`), `wine.server` checks on, waits for and ends
the prefix's session (`shutDown(gracePeriod:)` escalates from waiting to
`-k` to `-k9`, telling an `onStep` callback as it goes, and goes to `-k`
early, untold, once only the server and Wine's services and desktop are
left, rather than wait out their 3 s linger; `kill()` follows
`-k9` by killing the programs working in the prefix's folder, which `-k9`,
killing the server alone, leaves running for good), and `Winetricks` (app only, as only Second Chance bundles it)
installs a verb. Each `wine.server` call does nothing for a ScummVM wrapp,
which has no Wine. Everything that waits is `async`; the wrapp's `main()` and
GCD queues call it through `Blocking.wait` (`Packages/SecondChanceKit/Sources/SecondChanceKit/Blocking.swift`), the
build's blocking work goes the other way through `Blocking.run`, and a
SwiftLint rule (`wine_path_outside_library`) keeps Wine's own folder inside
`Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/`.

## The prefix cache

`WineManager` caches prefixes in
`~/Library/Caches/SecondChance/wine-prefix-cache`, keyed by bundle version (or
`"dev"` in DEBUG) plus the bundled Wine engine's version
(`Contents/SharedSupport/wine/version`), so a Wine upgrade starts a fresh
prefix by itself. Caching a prefix removes every other key's. Builds in one
process that find the cache empty make the prefix one at a time
(`WineManager.prefixCreation`): the first makes and caches it, and the rest
then copy it; a prefix is renamed into the cache whole, so none is ever taken
half-copied. Other changes to how the prefix is set up (winetricks verbs,
`ddraw.ini`, registry settings such as `EmulateModeset`) don't change the key:
run `./sc clean wine-prefixes` (or pass the app `--clear-wine-cache`) after
those, or if Wine setup misbehaves after code changes.

## Cancelling

The progress screen's **Cancel** asks for confirmation, then cancels the
build's task (`WrappBuildViewModel.cancelBuild`). The builders need nothing of
their own for it: a running Wine program ends its Wine session when its task is
cancelled (`Wine.run`), Steam's waits are `Task.sleep`s, and
`helper.finalize` checks before signing and saving, so the build throws and
each builder cleans up as it does after any failure. The ViewModel ignores the
resulting `.failed` and goes back to the welcome screen once the build has
returned; a build that had already saved its app finishes normally.

## How an installer is run

Each attempt at a game's installer is decided before it starts, by
`InstallerPlan`, from the installer's type, which attempt it is, whether the
disc's InstallShield answer file (`setup.iss`) was copied in, and the game.
What runs, its arguments, whether AutoIt drives it and whether the person
sees its wizard all come from the plan, so they can't disagree, and
`InstallerPlanTests` covers them without running anything. The first attempt
is unattended where it can be; the second, after a failure, is the
installer's own wizard. The patches applied after the install are in
`GameInstallerRunner+Patches.swift` ([game-patches.md](game-patches.md)).

## A stalled install

An unattended install (silent, or driven by AutoIt) gets a timeout,
`SECOND_CHANCE_INSTALL_TIMEOUT` seconds and 30 minutes by default, since nobody
is watching it. But an install that has stopped getting anywhere gives up long
before that. `InstallStallWatch` watches the installer, and then the wait for
the Wine processes it leaves running (an InstallShield `setup.exe` can exit in
seconds and leave the whole install to them), for signs of progress:
Wine's programs using the CPU or a new one starting (`LaunchActivityMonitor`),
a line of Wine's output or of the installer's own log, and a change in the
size of `drive_c`'s `Program Files (x86)` or `users` (where Temp is). The
folders and the log matter: under load an Inno Setup install copied the game
for over two minutes at 0.02 cores, too little to count as Wine working, and
said nothing on its output. If no sign appears for the window
(`SECOND_CHANCE_INSTALL_STALL_SECONDS`, 120 s by default and three times that
while the Mac is heavily loaded), `Wine.run`'s watchdog check looks for a window
a Wine program has on screen. Wine's own hidden windows never are.

- **One is on screen.** The installer is asking something the answer file
  didn't cover. It's brought to the front, the progress screen says to answer
  it there (an `.instructions` event), and the time doesn't count towards the
  timeout. Once there is progress again, the instructions go.
- **None is.** The install has stalled. The Wine session is stopped, with a
  snapshot of its processes in the log, and `Wine.run` throws
  `WineError.stalled`. A GUI build then retries with the installer's wizard
  as for any failed silent install, and the progress step says the install
  got stuck. A headless or `STRICT_INSTALL` build fails at once with
  `WrappBuildError.installStalled`.

When the watch stops it logs the longest the install went without a sign
(`[Install] longest quiet: …`), which is what the window is set from: it must
sit well above that for every game, idle and loaded. Building every disc game
on a test Mac (26 watched installs a pass), the longest gaps were 40 s idle,
before the folders and the log were watched, and 56 s with every core busy
(Lost Queen, while its InstallShield processes finished after `setup.exe` had
exited); all but two games stayed under 15 s. A `setup.exe` frozen with
`kill -STOP` under a 30 s window was stopped 31 s after its last sign, and its
headless build failed with `installStalled` about a minute after the freeze.

## Headless runs

`CLIBuilder` (not the ViewModel) owns headless mode. `NON_INTERACTIVE=true`
enables it; `validatedSource()` checks the environment *before* the UI starts
and exits 1 with a logged reason if it's misconfigured. It then starts the
build on the app window's own `WrappBuildViewModel`, as the welcome screen
would, so a headless build takes the same path as a person's, and exits with
what the ViewModel ended on. **Every `exit()` in the build path lives in
`CLIBuilder`** — no code path in `WrappBuildViewModel` terminates the process,
which is what makes the ViewModel safe to instantiate in a unit test.

The window stays hidden (the app's activation policy is `.prohibited`) unless
`SECOND_CHANCE_SHOW_UI=1` (`sc wrapp build --debug show-ui`), which shows it
going through the screens a person building the game would see. Either way
nothing asks: every answer still comes from the environment.

Required: `INSTALLATION_SOURCE` (`disk` | `her-download` | `steam` | `big-fish`) and
`OUTPUT_PATH`; `disk` also needs `DISK_1_PATH`, `her-download` needs
`HER_INSTALLER_PATH` (the `.exe` or `.dmg`), and `steam` needs
`STEAM_GAME_SLUG` (plus `STEAM_LAUNCH_MODE=steam|direct` for a DRM-free game,
default `direct`) and a saved Steam sign-in, since a headless build can't sign
in — it fails with `steamSignInRequired` rather than wait. `big-fish` needs
`BIG_FISH_GAME_SLUG`, and either `BIG_FISH_TRIAL=1` (the game's free trial,
with no sign-in) or the test harness's account (`BIG_FISH_TEST_SIGN_IN=1` with
`BIG_FISH_EMAIL` and `BIG_FISH_PASSWORD`), or it fails with
`bigFishSignInRequired` ([big-fish.md](big-fish.md#the-build)).

An installer or patcher that prints Wine's `nodrv_CreateWindow` error found
no desktop to open its windows on, so `Wine.run` throws `WineError.noDisplay`
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

A headless build makes one install attempt, and so does one under test
(`TestHost.isRunning`, the integration tests). The GUI's fallback, retrying
with the installer's interactive wizard when the silent install fails, would
wait for a click that never comes, so these fail instead and say why. Under
test it once held a build slot for 50 minutes before the build timed out.

Note that `LogStore` mirrors to stderr only when `isatty`, so piping a headless
run's output shows nothing — unless `SECOND_CHANCE_LOG_STDERR=1` forces the
mirror on (`0` forces it off).

**Progress for whoever started the build.** When `SECOND_CHANCE_PROGRESS_PATH`
is set, `CLIBuilder` attaches a `ProgressFileWriter`: a subscriber to the
ViewModel's bus (`EventBus.app`) like any other, which appends one JSON object per line to that file —

```json
{"event":"stage","stage":"installingGame","text":"Game installing","fraction":0.5}
{"event":"completed","path":"/…/Nancy Drew - X.app"}
{"event":"failed","message":"…"}
```

`stage` is a stable name for the `WrappBuildState` case and `text` is what the
progress view would say. This is how `sc wrapp build` shows the build stage
([dev-cli.md](dev-cli.md)); the integration test writes the same stream (from
`TEST_RUNNER_PROGRESS_PATH`) with extra per-game `"event":"game"` lines, and
follows each game's build with a `tagged` writer on that build's bus, so its
lines also carry the game's `source` and `slug`.
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
strips whichever one this game doesn't need. The copy is `cp -ac`: each file is
an APFS clone, so it is near instant and takes no space until a file changes;
on a volume that can't clone, a full `cp -a` is made instead.

`saveWrapp` never deletes an earlier copy of the game's app before the new one
is safely beside it: it moves the new app into the destination folder under a
hidden name (the step that copies, when the folder is on another volume, and
so the one most likely to fail) and then swaps it in with `replaceItemAt`.

Errors reach the error screen as `WrappBuildError.playerMessage`, never as a
raw `localizedDescription`. Builders publish `.failed(WrappBuildError(error))`,
which keeps a build error as it is, turns a full disk (`ErrorChain.isOutOfSpace`)
into `notEnoughSpace` and anything else unexpected into `internalError`, whose
detail goes to the log while the screen says plainly that something went wrong.

Before that, `verifyTemplateSignatures` runs `codesign --verify` on the
template (under a second). The template's files that aren't Mach-O, such as the
Windows DLLs under `Frameworks/renderer/`, keep their code signatures in
extended attributes, so a copy of Second Chance made with something that drops
them (rsync without `-E`/`-X`, scp, a zip not made with `ditto`) leaves them
unsigned, and the build would otherwise only fail at signing, minutes later,
with "code object is not signed at all". That failure stops the build at once
as `WrappBuildError.templateSignaturesLost`; anything else `--verify` reports is only
logged, since the finished wrapp is signed whole anyway.

`configureWrapp` rewrites the copy's bundle identifier from
`au.gare.callum.SecondChance.WrappTemplate` to
`au.gare.callum.SecondChance.nancy-drew.<slug>`.

### What a wrapp holds

Where things are inside a wrapp is `WrappLayout` (`SecondChanceKit`): its
`Info.plist`, `Resources`, the engines, the prefix and its C: drive, and
`drive_c/nancy-drew-installer`, where the installer is copied. The build, the
wrapp and WrappPuppeteer all find them through it rather than spelling out
the paths. The prefix there is the wrapp's own; a wrapp run from somewhere
it can't write runs in a copy (`getWinePrefix`), so what is inside the prefix
the game runs in is asked of its `Wine`: `driveC`, `documents` and `drives`.

What the build records about the game is `WrappSettings`, in
`Resources/AppSettings.plist`: the `.exe`, the engine, the slug, the source,
where the installer is, and, from Steam, the app ID and the launch mode the
person chose. `configureWrapp` writes it; the wrapp's `loadConfig` and
WrappPuppeteer read it. Its keys are the ones wrapps have always had, so a
new Second Chance or WrappPuppeteer still reads a wrapp built before it; the
slug and source are optional for that reason.

A prefix's drive letters are links in its `dosdevices` folder, made through
`wine.drives` (`WineDrives`). A prefix has only A:, C: and Z:, every other
letter blocked so Wine can't add the Mac's disks; a disc build mounts each
copied disc from D: on, as a CD-ROM drive. A: is the player's saves: each
launch points it at the wrapp's folder in Application Support, and the
Windows user's Documents links to the same place, so a game saving to either
reaches it. A build points both at a folder in `/tmp` that may not exist, so
a wrapp that can't write its prefix still has somewhere they lead.

Because the target sets `PRODUCT_NAME = $(TARGET_NAME)`, the produced game's
executable is `Contents/MacOS/WrappTemplate`. WrappPuppeteer doesn't rely on that
name — it tracks the wrapp by the PID it launched and finds the game by the
game's own process name — so the target can be renamed without touching it.

## Adding a source

1. Add a case to `WrappSource`.
2. Add a builder conforming to `WrappBuildStrategy`, owning its own resources on
   both paths.
3. Add the builder to the ViewModel and a case to its `build(from:)` that
   calls `runBuild(_:)`; the welcome screen's list (`WelcomeView`) and the
   File menu (`InstallCommands`) offer the source.
4. Publish the same events the disk flow does — that is what the UI and tests
   read.
5. Add any new prompt to `WrappBuildInput` with an env-var override, or headless
   runs will hang on it.

Do **not** ship a partial source. A builder that creates a temp wrapp and then
gives up has to remove it: an early Steam builder installed the Steam client
and then threw, leaking the wrapp every time. `SteamWrappBuilder` also stops
Steam on its failure path, as anything left running would hold the Wine
session (and the Steam lock) open; `BigFishWrappBuilder` likewise shuts down
Big Fish's Game Manager.
