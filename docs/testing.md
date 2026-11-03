# Testing

How the test suite is run, what each layer covers, and the handful of things
about this setup that will waste an afternoon if you don't know them.

Tests are Swift Testing (`@Test` / `#expect`), driven by `./sc test`
([dev-cli.md](dev-cli.md)). The app has no `Package.swift`, so `swift test`
does not work for it — everything goes through `xcodebuild` against the
`SecondChance` scheme. (`Tools/sc`, the CLI itself, is a Swift package with its
own tests; `sc test unit` runs those too.)

The tests run inside `Second Chance.app`, their test host. Under test it keeps
no run log, leaves the welcome screen's first-launch greeting alone and opens
no main window (`TestHost`). Each integration-test build has a window of its
own instead (`BuildWindow`), showing that build's screens as a person building
the game would see them. It opens on top without making the test host the
active app (so a game being tested keeps the keyboard), and closes when
the build is done unless the build failed: that one stays on the screen saying
why. Where the repo's `.env` sets `SECOND_CHANCE_HIDE_TEST_UI=1`,
`sc test unit` and `sc test integration` pass it on and the host also opens no
build windows and stays out of the Dock and the foreground — a log window a
test opens is built but never put on screen — so a run doesn't take over a Mac
someone is using. Leave it unset on a test Mac: there the windows show, which
helps explain a failure. `.env` isn't synced by `--on`, so each Mac keeps its
own. A game an integration test launches still comes to the front either way.

For the repo-wide conventions see `AGENTS.md`; for the build flow these tests
exercise, see [wrapp-build.md](wrapp-build.md).

## Quick Start

These run natively — no Rosetta wrapper. `sc` passes
`ONLY_ACTIVE_ARCH=NO`, which is what makes them work: the WrappTemplate target
is `ARCHS = x86_64` (Wine is 32-bit), so an active-arch-only build on Apple
Silicon emits swift-log for arm64 alone and WrappTemplate then dies with
`unable to resolve module dependency: 'Logging'`, or at link with `ld: symbol(s)
not found for architecture x86_64` for every swift-log symbol. That surfaces as
exit 65 and `** TEST BUILD FAILED **`, which reads like a failing test but is a
build failure. AGENTS.md's *Build, Run, Test* section has the full story.

```bash
# Unit tests only (fast, ~6s, no installers needed)
./sc test unit

# Integration tests — one game, or several
./sc test integration stay-tuned
./sc test integration stay-tuned blackmoor-manor

# Integration tests — all games (hours)
./sc test integration

# Build three games at a time (they still launch one at a time)
./sc test integration --build-concurrency 3

# Everything: unit, then integration (hours)
./sc test

# Skip the rebuild and reuse the existing build
./sc test integration stay-tuned --skip-app-build

# Launch-test the wrapps already in built-apps/ instead of installing
# (template: put the latest WrappTemplate into them first)
./sc test integration stay-tuned --refresh-wrapp skip
./sc test integration stay-tuned --refresh-wrapp template

# Build from Steam instead (or as well: --source disk,steam, or all)
./sc test integration thornton-hall --source steam

# Build from each Her Interactive download in installers/<slug>/
./sc test integration scarlet-hand --source her-download

# Build from Big Fish Games: the games the test account in .env owns, or
# every game's free trial, signed out
./sc test integration white-wolf --source big-fish
./sc test integration --source big-fish-trial

# Build here, launch in a tart VM (another macOS version, say)
./sc test integration ghost-dogs --vm sc-sequoia
```

Other options: `--logs collapsed|full|raw` for how output is shown,
`--wrapps-dir` for where prebuilt wrapps are, and `--open-report
failures|always|never`. In a terminal the run is shown live — a progress bar,
what's running now, and a table of suites (or games) — with the full xcodebuild
output kept in `DerivedData/sc-logs/`.

A bare `./sc test` is `./sc test unit`. `./sc test all` and an unfiltered
`xcodebuild test` run the integration suite too, which with real ISOs present
in `installers/` doesn't skip, and takes hours.

## Test structure

### Package tests (`Packages/WrappKit/Tests/`, `Packages/SecondChanceKit/Tests/`)

What needs neither app. `WrappKitTests`: the Windows-program and MSI readers,
process listings and names, the subprocess line reader and watch, load
measurement, shell quoting and the wrapp's settings. `SecondChanceKitTests`:
the VDF reader, the quit check, the in-process helpers' variables and loading
stages. They run with `swift test --package-path Packages/<package>`, which
needs no Xcode build, in well under a second; `sc test unit` runs them as a
step of its own, and CI with it.

`Packages/WrappBuilder/Tests/` are the same kind: every program bundle checked
against the manifest schema, the YAML 1.2 cases, and a check that GameCatalog's
generated table is what the bundles make
([program-bundles.md](program-bundles.md)). `sc test unit` runs them too.

### Unit tests (`SecondChanceTests/*.swift`)

Fast, no installer ISOs required:

- **EventBusTests** — typed event bus ordering and delivery
- **LogStoreTests** — the in-memory log ring and its drain queue
- **LogWindowTests** — log window streaming, filtering, export/import
- **GameDetectorTests** — fingerprint-to-slug matching for all 33 games
- **GameInstallerTests** — installer argument building (MSI, InstallShield, Inno)
- **ErrorViewTests** — the error screen's log actions
- **WrappBuildCancellationTests** — cancel routing (initial dialog → welcome
  screen; later prompts → error screen)
- **DocsTableTests** — keeps AGENTS.md's Documentation table and `docs/` in
  step, in both directions
- **GamePatchCatalogTests** — the game-patch manifest and the catalog that
  reads it: slugs resolve to real games, editions select one patch per source,
  puzzle solvers stay opt-in

plus `GameDetectorIntegrationTests` and `InstallerIntegrationTests` (which use
the mock disk in `TestFixtures/`, not real ISOs) and `ProgressFileWriterTests`
(the progress stream `sc` reads).

**`sc test unit` runs every suite except a denylist**, `TestRunner.unitExclusions`
in `Tools/sc/Sources/SCKit/Support/TestRunner.swift`: `DiskInstallIntegrationTests`,
`SteamInstallIntegrationTests`, `HerDownloadInstallIntegrationTests`,
`BigFishOwnedInstallIntegrationTests` and `BigFishTrialInstallIntegrationTests`
(real installs). A new suite therefore runs by default;
one that is slow or needs the environment set up has to be added to that list.

The exception is a suite that switches itself off unless told where its
setup is. `SteamClientSmokeTests` drives a real Steam and is `.enabled(if:)`
the `TEST_RUNNER_STEAM_SMOKE_*` variables are set, so a normal `sc test unit`
reports it as skipped in no time. [steam.md](steam.md#testing) has how to
run it.

### Integration tests (`SecondChanceTests/Integration/`)

Slow (~1.5 min for a cached ScummVM game, minutes for a Wine install), and they
need real ISOs at `installers/<slug>/disk-1.iso` (gitignored). Absent ISOs, the
suite disables itself via `.disabled(if: !InstallersPresent.shouldRun())` — so
a plain `xcodebuild test` on a machine without them skips rather than fails.

`./sc test integration` is different: asking for the suite by name sets
`TEST_RUNNER_REQUIRE_INSTALLERS=1`, the suite always runs, and a game whose ISO
is missing fails its `#require` with the path it looked at. A skipped suite
there would report a pass having tested nothing.

**Each build source has its own suite**, picked with `--source`:
`DiskInstallIntegrationTests` (`disk`, the default),
`SteamInstallIntegrationTests` (`steam`),
`HerDownloadInstallIntegrationTests` (`her-download`),
`BigFishOwnedInstallIntegrationTests` (`big-fish`) and
`BigFishTrialInstallIntegrationTests` (`big-fish-trial`). A game tested more than
one way is a row per source in the table, with a Source column. All of them go
through one per-game flow, `IntegrationGameRun`, which waits for its turn to
build and then to launch ([below](#building-games-side-by-side)).

#### Building games side by side

Swift Testing runs every game's test at once, across the suites, and
`IntegrationStages` (`SecondChanceTests/Integration/`) decides when each may
go on:

- **Builds** go through `BuildGate`, first come, first served. It lets in as
  many at once as `--build-concurrency` says (`TEST_RUNNER_BUILD_CONCURRENCY`;
  by default one per four performance cores, [below](#how-many-to-build-at-once)),
  and only as many as the disk has room for. Each build reserves
  a quarter more than its game's build took last time
  (`test-results/integration-sizes.json`), or before it has been measured,
  the engine and four times its installers' size (8 GB for a Steam or Big
  Fish game). It
  keeps the reservation until its output is deleted after its launch, so built
  wrapps waiting for their turn on screen hold back new builds. Builds
  reserve no more between them than was free when the first asked, less
  `--disk-margin` (10 GB), and none is let in unless what's free now also
  covers it and what the running builds have still to write. A build is
  always let in when nothing else is under way, so a run never does worse
  than one game at a time; one the disk can't hold even then fails at once.
- **Launches** take `IntegrationStages.launch`, one at a time: a game runs
  full screen and must be in front.
- **Steam** games go one at a time, build and launch together
  (`IntegrationStages.steam`): a wrapp holds Steam's one-wrapp-at-a-time lock
  while it runs, and a build signing in to Steam meanwhile would fail with
  `steamInUse`. Other sources' games build alongside.
- **Owned Big Fish** games go one at a time too, build and launch together
  (`IntegrationStages.bigFish`): each build signs the one test account in and
  out. Big Fish trials sign in to nothing and build alongside the rest.

Each build reports on a bus of its own and tags its log entries with its own
id ([logging.md](logging.md#which-build-an-entry-is-from)), so its events
and its log attachment are its own. The table's **Waited** column is the time
a game spent waiting for either turn ([Filtering games](#filtering-games)).

#### How many to build at once

The default comes from the same eight disc games run at each setting, one
run after another, on an M1 Max (8 performance and 2 efficiency cores):
Ghost Dogs and Stay Tuned (ScummVM), Haunted Carousel, Old Clock, White Wolf,
Captive Curse, Thornton Hall and Secrets Can Kill Remastered (Wine). Seconds:

| Builds at once | 1 | 2 | 3 | 4 | 6 |
| --- | --- | --- | --- | --- | --- |
| Whole run | 437 | 333 | — | 295 | 314 |
| All builds added up | 384 | 530 | 533 (7 games) | 704 | 851 |
| White Wolf's build | 85 | 111 | 147 | 143 | 165 |
| Slowest launch, against its time at 1 | 1.2× (a second run) | 1.4× | 1.6× | 1.7× | 1.5× |
| Programs' CPU, average and peak, in cores | 3.3, 10 | 5.0, 9.7 | — | 5.4, 9.3 | 5.6, 10 |

- **Launches set the floor.** Eight launches one at a time take about 220 s
  between them, and builds overlap the launches even at one build at a time,
  so a run can't get much below 300 s however many build.
- **Two builds save a quarter; more save little.** From one to two the run
  took 24% less. Four took 11% less again, and six took longer than four:
  every build slowed as they shared the cores, White Wolf's from 85 s to
  165 s.
- **Launches slow from three builds.** Haunted Carousel's launch took 40–43 s
  with three or four building behind it, against 25 s alone.
- **Failures weren't from building side by side.** Runs at one build had
  their own failures (a game quitting after a Wine error, a swallowed first
  click, a build killed by SIGKILL). At three, Old Clock's installer waited
  for ever: its window took more than the 20 s the AutoIt script then
  allowed, so nothing clicked Install, and the run took 52 minutes before
  the install timed out. The script now waits for the window for as long as
  the installer runs.
- **The first run of a sweep is slower** (761 s here): it makes the Wine
  prefix that every later build copies.

So `sc` builds one game per four performance cores, at least one: two on
that Mac, one on a Mac with six. That is measured on one Mac only; on a
bigger one, try `--build-concurrency` above the default and see whether the
run's time still drops.

The Her suite tests each download in `installers/<slug>/` named
`her-download*.exe` or `her-download*.dmg`, once per file (a Mac download's
row is `<slug> mac`), and disables itself when there are none. It always
builds, and is in `TestRunner.unitExclusions`.
[her-download.md](her-download.md#testing) has more.

The Steam suite:

- builds each requested game that's on Steam from Steam, headless, and
  launches it with WrappPuppeteer, like the disk suite (a DRM-free game is
  built to launch directly);
- needs a saved Steam sign-in on the Mac it runs on (build a Steam game from
  the app once, or copy `~/Library/Application Support/SecondChance/Steam/`
  over) — without one the suite disables itself and says why;
- reports a game the account doesn't own as `skipped`, not failed. Each
  build signs in to Steam on its own, so the first one to sign in tells the
  suite (a `steamGamesOwned` bus event) which games the account owns, and the
  rest of the run skips the others without building: signing in for every game
  in a full run once got Steam's sign-ins stalled for an hour and a half;
- checks the finished wrapp carries none of the sign-in;
- checks the build's log, and a launch's that starts Steam, have Steam's
  sign-in in them (`SteamSignInWatch.waitingMarker` and `.signedInMarker`),
  so a log keeps saying how far a stalled sign-in got
  ([steam.md](steam.md#building));
- always builds: `--refresh-wrapp` applies to the disk suite's wrapps only;
- downloads every game it tests, so it's slow, and run often could trip
  Steam's rate limits. It is in `TestRunner.unitExclusions`.

The Big Fish suites, both in `TestRunner.unitExclusions`:

- `--source big-fish` builds each game Big Fish sells that the test account
  owns, signed in with `BIG_FISH_EMAIL` and `BIG_FISH_PASSWORD` from `.env`
  (which `sc` passes to the test host only for this suite). Without them the
  suite disables itself and says why. Like the Steam suite, the first build
  tells it (a `bigFishGamesOwned` event) which games the account owns and
  the rest are skipped without building; it checks the wrapp carries no
  trace of the sign-in.
- `--source big-fish-trial` builds every game's free trial, signed out, so
  any game Big Fish sells can be tested without owning it.

Both always build and download every game they test.
[big-fish.md](big-fish.md#testing) has what each checks.

The tests find the repo, and so `installers/`, through `TestPaths.repoRoot`.
That defaults to `#filePath`, which is fixed at compile time and wrong on any
machine the build was copied to, so `sc test` passes the real location as
`TEST_RUNNER_REPO_ROOT`. Calling `xcodebuild` directly on a copied build, pass
it yourself.

Each game runs the **real** build flow — real Wine/ScummVM install, real file
copies — and asserts on the events the flow publishes:

- Disks resolved, and the game detected from the disk fingerprint
- Engine routed correctly (Wine vs ScummVM)
- Game exe path detected, matching `GameInfoProvider.internalGameExePath`
- The wrapp's `Info.plist`/`AppSettings.plist` carry the right `GameExePath`,
  `GameEngine`, `GameSlug`
- Every automatic patch for the game applied (`patchApplied`), and none failed:
  a failed patch doesn't fail the build, so it has to fail the test
- The full event sequence in order, ending in `signed` then `completed`
- If `WrappPuppeteer.app` is present: the game launches, its window goes
  into a macOS fullscreen Space (native fullscreen for Wine, `-f` for
  ScummVM; a game left in a window fails, and so does a Direct3D game's
  borderless window that only covers the screen), it reaches its main menu,
  its first click isn't swallowed by cnc-ddraw, and it quits cleanly
- For a Wine game, its in-process helpers armed in it: the wrapp's log has
  `[Helpers] Native fullscreen armed`, `[Helpers] Cursor lock armed`
  unless the game draws with Direct3D, which doesn't get it
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#which-games-get-it)),
  `[Helpers] Mode scaling armed` unless it draws through cnc-ddraw
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#mode-scaling)),
  and `[Helpers] Quit watch armed`
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#quit-watch))
- Once the launch is done or skipped, and before the wrapp is deleted, a
  disk build pointed at the game the wrapp installed is turned down with
  `installedGameNotInstaller` (`InstalledGameCheck`), as for someone who
  chooses an installed game's folder instead of its disc
  ([wrapp-build.md](wrapp-build.md#the-disk-build-step-by-step)). The Her
  download and Steam suites check the same. A ScummVM wrapp skips it: it
  holds only the copied disc, which is an installer

`RecordingEventSubscriber` captures the bus events; the assertions read it.
**The bus events are the integration contract** — when moving orchestration
code between types, every `bus.publish` has to move with it, or the flow still
succeeds while the test sees nothing.

## Filtering games

`TEST_RUNNER_TEST_GAMES` (the `TEST_RUNNER_` prefix is what makes xcodebuild
forward it into the test environment) limits which games run:

```bash
# Via sc, which adds the prefix for you
./sc test integration stay-tuned

# Directly
TEST_RUNNER_TEST_GAMES=stay-tuned,blackmoor-manor \
  xcodebuild test-without-building -scheme SecondChance \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:SecondChanceTests/DiskInstallIntegrationTests
```

A slug that matches no game fails the "Every requested game slug names a known
game" test, rather than filtering the per-game test down to zero cases — which
would pass having run nothing.

`TEST_RUNNER_SKIP_BUILD=1` makes the suite launch-test the wrapps already in
`TEST_RUNNER_WRAPPS_DIR` (default `built-apps/`) instead of installing; `sc`
sets both for `--refresh-wrapp skip|template` and `--wrapps-dir`.
`TEST_RUNNER_PROGRESS_PATH` asks the suite to write its per-game progress as
JSON lines, which is how `sc` draws the live game table.

The table gives each game's **Build** and **Launch** times, its own work alone:
a game that waited its turn while another game built or launched has that
time in a **Waited** column instead, shown once any game waited. **Disk** is
the most its build took on disk at once, sampled every 15 s: the build's
working wrapp in `$TMPDIR` and what it has saved. `sc` keeps each game's
largest in `test-results/integration-sizes.json` (`IntegrationSizes`), which
stays on each Mac, and passes the file to the suite as
`TEST_RUNNER_SIZE_ESTIMATES_PATH`. The total Swift Testing reports for a
game's test still includes its waiting.

## WrappPuppeteer

`WrappPuppeteer` (a CLI tool wrapped as an `.app`) drives the launch-and-quit
phase. It is a **build dependency of the SecondChanceTests target**, so
`sc test` builds it for you — no separate build step. If the bundle is
missing, the launch phase is skipped and the build assertions still run.

**It needs no permissions.** It never captures or clicks another app's
windows itself: it starts the wrapp with `SECOND_CHANCE_PUPPET_DIR` naming a
private directory, and the wrapp and the game then serve their own windows on
sockets there — the wrapp its info window on `wrapp.sock`, a helper inside
the game process the game window on `game-<pid>.sock` — since a process may
capture and click its own windows without Screen Recording or Accessibility.
[wine-in-process-helpers.md](wine-in-process-helpers.md#puppet-control) has
how the helper gets into each engine and what the sockets accept. If
WrappPuppeteer happens to have Screen Recording, a failed run also saves a
full-screen screenshot; nothing else changes.

**It doesn't touch the player's saves and settings.** A wrapp keeps those in
`~/Library/Application Support/<bundle id>/`
([wrapp-launch.md](wrapp-launch.md#user-files)), which a test's wrapp, with
the same bundle id, would share with the player's. WrappPuppeteer sets
`SECOND_CHANCE_APP_SUPPORT_DIR` to an empty `data` folder in its private
directory, which the wrapp uses in place of Application Support (moving any
old layout found there, as it would the real one), so each launch starts as on
a fresh Mac: the save warning shows, and no setting the player chose changes the
test. Before, Warnings at Waverly Academy failed every run on one Mac whose
`Waverly.INI` there said to play in a window.

Its exit codes (`Packages/PuppeteerCore/Sources/PuppeteerCore/PuppetResult.swift`):

| Code | Meaning |
| --- | --- |
| 0 | passed — game launched and quit cleanly |
| 1 | failed |
| 2 | forced quit |

**A game the Mac was too busy to test is `overloaded`, not failed.** Before
a game's build, and again before its launch, the test checks `SystemLoad`,
leaving out the test host and everything it started, so the run's own
builds don't count; while other programs keep all but one
performance core busy it waits up to a minute (ten seconds after a game
already held back) for that to ease, and if it doesn't, records why and moves
on rather than spending half an hour on a build Wine can't start. The table
shows those games as `overloaded` and `sc` says to quit the busy programs and
rerun them. `--ignore-load` tests them anyway, for deliberate stress runs; the
run then only notes the load. The run itself still fails, since those games
went untested.

**A game the screen kept from the front is `locked`, not failed.** No app can
come to the front while the screen is locked (the frontmost app is then
`loginwindow`) or the display asleep, so a game launched then only times out
waiting for focus. Before each launch the test asks `ScreenState`
(`Packages/SecondChanceKit/Sources/SecondChanceKit/ScreenState.swift`), and if nothing can come to the front, records
why and moves on without launching it; the build, which needs no screen, has
still been tested. The table shows those games as `locked`,
and `sc` says to keep the Mac awake and unlocked (`caffeinate -d`) and rerun
them. If the screen locks during a game, WrappPuppeteer's wait for focus stops
at once with "Game window couldn't become active: the screen is locked". As
with `overloaded`, the run itself still fails.

The scenario's waits are sized for a machine with every core busy, where Wine
runs many times slower; each ends as soon as what it waits for happens, so
they only lengthen a failing run. It waits up to 900 s for the game's process
to appear (the wrapp may first spend up to 600 s waiting for Wine's desktop),
then 300 s for its window, 120 s for that window to come to the front, 180 s
for the wrapp's cursor lock to finish before the first click, 300 s
to find and click Exit and 300 s for the game to quit. The wait for the
window ends early if the game's process exits first: after 10 s more to see
whether the same exe starts again (a launcher stub, such as Steam's DRM, can
re-launch it), the run fails with `<exe> exited before showing a window`
rather than waiting out the 300 s. A zombie (exited, not yet reaped) counts as
exited (`ProcessControl.isAlive`). The phases' limits are bounded together
by `--max-runtime` (2700 s, `AppPuppetRunner.maxRuntime`): a run still going
then fails, killing the wrapp, so a wedged game can't hold up the whole
integration run, and the test gives up waiting for WrappPuppeteer two minutes
after that. WrappPuppeteer writes its exit code to the file the test names
(`--exit-code-file`), as the test, which launched it through LaunchServices,
isn't its parent and can't read its exit status; no file reads as a failure. The wrapp's "save
regularly" warning counts as dismissed only once the wrapp says it has gone
(the window itself stays up, showing a loading message, until the game has
loaded); if the wrapp's click on the button doesn't take, it confirms the
warning directly, and WrappPuppeteer logs that. Once the game's window is up, the window itself must
close within 30 s, or the run fails: the wrapp closes it when it sees the game
start, so one still open means the wrapp missed the game, and players would
have "Loading…" over the game until they quit. This is checked before the
focus wait, since a wrapp that missed the game never brings it to the front
either, and the focus failure would hide the cause. When the game never
comes to the front, or no Exit button or logo turns up in time, the
scenario logs the windows on screen and saves a capture of the game window to
`/tmp` (`game-window-detected-window-*.png` once the game is up,
`exit-not-found-window-*.png`), naming it in its log — plus a full-screen
screenshot (`game-not-focused-screen-*.png`, `exit-not-found-screen-*.png`, …)
if it happens to have Screen Recording, or a log line saying it doesn't. The
integration test attaches each screenshot logged (a `📸` line) to the run's
results, as `screenshot-<attempt>-<slug>-<file>.png`, since `/tmp` doesn't
outlast a restart of the test Mac. The per-attempt captures, deleted as they are
analysed, are of the game window alone, captured by the game: a notification
or another app in front of the game can't reach the OCR, and once the game
has closed its window there is nothing to capture, rather than "Exit" in
whatever app was behind it. Positions found in a capture are window points
(its pixels over its scale), clicked by the game in its own window, so the
display's shape — a notch, the window's position — never comes into it. The
game's fullscreen state comes from the game too. A failed run logs
`WRAPP_PUPPETEER: run_failed: <reason>`, and the integration test quotes that
reason in its failure.

WrappPuppeteer always starts a new instance of the wrapp, and kills any
instance of the same bundle ID still running first. LaunchServices would
otherwise hand back that one: a wrapp left on its "Game Crashed" window by an
earlier run was once "launched" again an hour later, and the run timed out
waiting for a game it never started.

Its force-quit is firm only when it has to be. `forceTerminate()` sends
SIGTERM, which a wrapp takes as Cmd-Q: it ends the game, waits for Wine to
finish, and kills Wine itself after 15 s. WrappPuppeteer gives it 20 s, then
sends SIGKILL. It then ends what the wrapp left of its engine, which is
usually nothing: Wine's session gets 5 s to finish, then `wineserver -k`,
then `-k9`, and ScummVM gets SIGTERM, then SIGKILL after 5 s. Anything still
running from the wrapp's own engine is then killed. All of this touches only
that wrapp's processes, never other Wine or ScummVM on the Mac, because other
games may be building alongside. Only when WrappPuppeteer is itself stopped
does it kill straight away.

**It goes when the test that started it goes.** Started through
LaunchServices, WrappPuppeteer's parent is launchd, not the test, so stopping
a run (`sc attach --stop`, Ctrl-C) or a crashed test host used to leave it —
and the wrapp it was driving, Steam and all — running. The test passes
`--parent-pid <its own pid>`, and WrappPuppeteer kills what it launched and
exits once that process has gone.

### Core and the Nancy Drew scenario

The game draws its menus with DirectX inside Wine (or with ScummVM), so there
is no accessibility tree to query: WrappPuppeteer finds things on screen with OCR
and template matching and clicks by coordinates. It is split in two, and the
dependency only runs one way:

- **`Packages/PuppeteerCore`** (a local package, so its matching can be tested
  with `swift test`, in `Tests/PuppeteerCoreTests`) — reusable automation with no knowledge of Nancy
  Drew, wrapps or engines: the control-socket client (`InProcessControl`),
  OCR (`TextRecognizer`), template matching (`TemplateMatcher`), screen
  fingerprints (`ImageFingerprint`), checking a picture's bars
  (`PictureFrameCheck`), recording a window (`WindowRecorder`),
  window listing (`WindowFinder`), focus (`FocusDetector`), processes
  (`ProcessControl`, `ProcessFinder`, `ProcessCleanup`), the click ring
  (`InputAutomation`), the optional full-screen screenshot (`ScreenCapture`)
  and exit codes.
- **`WrappPuppeteer/NancyDrew/`** — everything specific to driving a game: reading
  the wrapp's `AppSettings.plist` (`WrappSettings`) and mapping its engine to process names, kill
  commands and a focus strategy (`Wrapp`); the wrapp's "save regularly" window
  (`InfoWindow`); reading the game's test from its bundle (`TestData`);
  finding a scenario's `text` and `region` needles (`MainMenuScreen`) and its
  `screen` ones (`SplashScreen`); and the launch, then the scenario's
  handlers until the game ends (`NancyDrewQuitScenario`).

What it looks for and what it does when it sees it are data, not Swift
([needles](#needles), [scenarios](#scenarios)), read by the builder
package (`Packages/WrappBuilder/Sources/WrappBuilder/Testing/`), which knows
bundles and modules but no game.

Core never names a game. When a game-specific fact would make a utility work
better, Core takes it as a parameter and the scenario supplies it — for
example the quit-button search is narrowed by the quit button's needle
(`region:` in `needles/quit-button.yaml`, made a `TemplateMatchOptions` by
`MainMenuScreen.matchOptions`), which limits the search to the bottom-right
corner, sizes the template relative to the screen, and uses red-emphasis
greyscale because the button is red. Called
without options, `TemplateMatcher` searches the whole screen at the template's
own size. Its coarse pass steps across the screen in strides that grow with
the capture's width, over copies of the screen and the template blurred by
half a stride. Unblurred, a button drawn with thin lines, such as White Wolf's
quit button scaled up from 800×600, matches only within a few pixels of its
place, and the stride steps over it; the fine pass compares the originals.

The scenario clicks Exit, then parks the cursor at the left edge with a real
mouse-move event — the game draws its own cursor, and left over the button it
hides the label from the next OCR pass. If the game is still on the menu, it
clicks Exit again — where OCR finds it, or, when it can't (a game too busy to
act on the click may not have moved its drawn cursor either), every 3 s where
it was last found.

**The first click must reach the game.** A DirectDraw game draws through
cnc-ddraw, which swallows the first click in its window unless the wrapp's
cursor lock has already got it to take the cursor
([wine-in-process-helpers.md](wine-in-process-helpers.md#cursor-lock)). A
Direct3D game, which never goes through cnc-ddraw, isn't checked; WrappPuppeteer
reads which a game is from its `.exe`, as the wrapp does. Before
its first click — on a splash screen or on Exit, whichever comes
first — the scenario waits for the cursor lock to finish (up to 180 s) and asks
the game whether it holds the cursor. If it didn't, and does within 3 s of the
click, that click is what cnc-ddraw locked on, and the run fails with "The
game's first click was swallowed" and a `first-click-swallowed-*.png` capture.
A splash screen needs this check: any click skips it, so a swallowed click there would
look like a working one, and would lock the cursor in time for Exit. The
re-clicks on Exit are for a game too busy to see a click, not for this.
To see the check catch it, switch the cursor lock off for the wrapps the test
starts — they are launched through Launch Services, so it goes in the GUI
session's launchd environment, `launchctl setenv SECOND_CHANCE_CURSOR_LOCK 0`
(through `sc in-gui-session` over SSH), and `launchctl unsetenv` afterwards —
and test a DirectDraw game.

Each click shows a blue ring where it landed (the click itself is the game's;
the ring is WrappPuppeteer's own window, at the point's position on screen).
Over a game in native fullscreen that needs two things: WrappPuppeteer runs
as an accessory app, since macOS keeps a regular app's windows out of another
app's fullscreen Space, and `InputControl.showClick(at:)` turns the main run
loop for the ring's fade, since the scenario otherwise only sleeps and AppKit
would never draw the ring.

To check the vision code without launching anything, run it against a saved
screenshot — this needs no permissions:

```bash
DerivedData/Build/Products/Debug/WrappPuppeteer.app/Contents/MacOS/WrappPuppeteer \
  --analyze path/to/screenshot.png
```

`FIND_IMAGE_EXTRA_DEBUGGING=true` makes the template matcher write heatmaps
and search-region/match overlays next to the screenshot. Add
`FIND_IMAGE_DEBUG_PROBE=x,y` (screenshot pixels) to also score the template at
one position and save the images compared there.

### Needles

A **needle** (openQA's word) is something the scenario looks for on the
game's screen, found by its **tags**: a `<name>.yaml`, beside `<name>.png`
for an image. Three kinds:

- `screen`: the whole capture's fingerprint against an image's, as the
  splash screens below are (`SplashScreen`).
- `region`: an image matched in part of the screen, as the quit button is
  (`region: { search, height-fraction, scales, grayscale }`, for
  `TemplateMatcher`).
- `text`: strings read off the screen by OCR, the first found winning:
  "Exit Game" or "Quit", and "interactive" for the Her Interactive logo.

`click: { x, y }` says where to click what matched, as fractions of it (of
the picture, for a `screen` needle); without it, its middle. A folder's
`defaults.yaml` describes every image in it with no file of its own, which is
how the splash folders say "a screen tagged `splash`, clicked 8% in from its
top-left corner" once.

A game's needles are its bundle's `tests/needles/`, then the needles of the
module its scenario is in (`Modules/nancy-drew/needles/`). A bundle's needle
replaces the module's of the same name, and every other is added: Scarlet
Hand's `exit-text.yaml` clicks its Exit at the label's top edge, where its
hotspot is (`click: { x: 0.5, y: 0 }`), and every other game uses the
module's. Within a tag, a `text` needle found wins over a `region` one.
WrappPuppeteer reads them from the source tree when it runs from a build
inside it, so one just made is used without rebuilding, and otherwise from
the copies of `Bundles/` and `Modules/` in its bundle (`TestData`).

### Scenarios

A **scenario** is a set of handlers rather than a list of steps: each waits
for a tag and says what to do when it shows, and on every look at the
game's window they are tried in order. The quit test is the nancy-drew
module's `scenarios/quit-from-menu.yaml`, which every game's manifest names
(`tests: { scenario: "nancy-drew/quit-from-menu" }`):

```yaml
handlers:
  - { id: "black-start", when: "blank", if: "blank-start-takes-click", retry-after: "${splash-retry}",
      do: [{ click: { x: 0.2, y: 0.12 } }] }
  - { id: "splash", when: "splash", retry-after: "${splash-retry}", do: ["click"] }
  - { id: "main-menu", when: "quit", repeat-where-last-seen: 3, do: [{ check: "menu" }, "click", "expect-end"] }
  - { id: "her-logo", when: "her-logo", once: true, do: ["click"] }
```

- **Handlers on whole screens first.** One whose tag has `screen` needles,
  or that waits for `blank` (a capture with nothing on it), is tried in
  milliseconds; the first that acts ends the look. The rest share one read of
  the window (OCR and template matches together) and each acts on what was
  found, in order.
- **Actions**: `click` (the needle's click point), `{ click: { x, y } }` (a
  point of the window), `{ check: "menu" }` (the picture's bars, and
  switching away and back, below), `expect-end` (the click before it
  should end the game: once it has, only that handler runs again) and
  `quit` (ask the program to quit as its app's Quit does, and expect it to
  end).
- **`retry-after`** is how long a screen still showing after its handler
  clicked it waits before another click; **`once`** runs a handler once;
  **`repeat-where-last-seen`** clicks where its needle was last found when
  it isn't found this time, after that many seconds; **`if`** names a
  parameter that must be true.
- **Parameters** are the scenario's `parameters:`, which a bundle's
  `tests.parameters` set: Secrets Can Kill Remastered's
  `blank-start-takes-click: true`. A parameter the scenario doesn't have is
  refused.
- **Launching and quitting are WrappPuppeteer's**, as are the save warning,
  the first-click check and the checks a handler can ask for; a scenario
  only says what to wait for and do in between. `goal` is `program-ends`,
  the only one so far, and `timeout` the seconds it has.

A program with no menu to quit from uses its engine module's
`scenarios/starts-and-quits.yaml` (the wine, scummvm or dosbox module's):
when its bundle's `running` needles show, it quits. SkiFree's is
the text on its slope ("Start", "Chris Pirih"), Lure of the Temptress's the
word under Revolution's logo.

An edition with another title screen adds a needle under the same tag, and
leaves the scenario alone. Handler patches by id and shared fragments of
handlers aren't written yet; they come when a game first needs them.

### Splash screens

Before its main menu a game shows a few screens a click skips: a black
screen while it starts, the Her Interactive logo (still, or the animated
magnifying-glass intro of the later games), the game's title card, and in
some games an intro animation (Ghost of Thornton Hall's runs 28 s). Waiting
them out cost tens of seconds a game, so the scenario clicks past them.

It looks for them from the moment the game says its window is in its
fullscreen Space (which it says once the move there has finished), with no
settling time once the window is focused. Each attempt's capture is first
compared with the game's splash screens (`SplashScreen`), which takes
milliseconds; only a capture that isn't one goes on to the OCR for Exit, which
takes most of a second. A splash screen is clicked near the top-left corner of
the game's picture, where no game's menu has a button, so a menu wrongly
taken for one comes to no harm.

A splash screen is clicked as soon as it's seen. The screen moving on is the
sign the click took, so one still up — the same picture as the one clicked —
is only clicked again 2 s later, as a retry: some take a click only once
they've finished appearing (`retry-after`). None is clicked once Exit has been, and a capture
that isn't clicked still goes to the OCR, so a menu wrongly taken for a splash
screen still has its Exit found. The Her Interactive logo is also still
clicked where OCR reads "interactive", which catches it in a game with no
references.

Clicking past them only saves time: a game whose splash screens go
unrecognised still reaches its menu once they've played, so that doesn't fail
it. But a run that reaches the menu without having clicked past any of the
game's recorded splash screens says so, as a warning
(`WRAPP_PUPPETEER: warning: No splash screen was clicked past…`): the
references may no longer match the game. The test attaches each warning
(`warning-<source>-<slug>.txt`) and `sc` lists them under its table, passed
or not, so one that starts appearing gets noticed.

**In a DirectDraw game the cursor lock decides how soon that is.** The first
click must not come before the wrapp's cursor lock has finished (see above),
a quarter of a second after the window reaches its fullscreen Space — about
2 s after it appears, while the Her Interactive logo is still up. While the
lock is still working the scenario doesn't click at all, and captures again
instead, so a click never lands on the screen that replaced the one it was
meant for. The Direct3D and ScummVM games have no lock to wait for.

From the game's window appearing to the Exit click took 3.3–13 s across all
33 games, 4.1 s for half of them, where waiting out the screens took up to a
minute (Labyrinth of Lies' and Sea of Darkness's intros run 50 s).

**A black start can take a click too.** Secrets Can Kill Remastered from disc
is black for its first five seconds, then shows its logo and title card for
fifteen more. A click in the black skips the lot: its menu came up 4.4 s in,
against 28.6 s unclicked. A game whose bundle sets
`blank-start-takes-click` has a black capture clicked as a splash screen is,
again every 2 s while it stays black. Whether a game's black start takes a click is found with
`--record-click-at` (below); one whose splash screens come within a second or
two gains little.

A screen is recognised by its **fingerprint** (`ImageFingerprint`): the dark
bars around the picture are trimmed off, so the display's shape doesn't
matter, and what's left is shrunk to a 24×18 grid of colours; two
fingerprints' distance is the mean difference per channel. A row or column of
the capture only counts as picture when 15% of it is bright: a game's own
cursor, or a line along the window's edge, can be out in a bar, and shouldn't
stretch the picture to the window's edge. A capture within
`SplashScreen.matchDistance` (0.08) of one of the game's references is that
splash screen. Across recordings of 31 games, no menu came nearer than 0.134
to any reference its game is matched against, and every game had a splash
screen recognised within its first six seconds.

The references are `screen` needles tagged `splash`: the nancy-drew
module's `needles/splash/splash-any-<what it shows>.png` for the screens
many games share — the Her Interactive logos and intro, the glowing "Nancy
Drew", and Big Fish's logo, on its own or above Her Interactive's, which Big
Fish's editions open with — and a game's bundle's
`tests/needles/splash/splash-<game slug>-<what it shows>.png` for its own,
mostly title cards. A game is matched against its own and every `any` one.
A new `any` one changes the module, so raise its release
([modules.md](modules.md)). Each is a recorded frame with its bars
trimmed, 160 pixels wide. An animated screen needs a reference for each look
it has long enough to be caught in.

The later games' intros end on the game's title over a background, which the
menu then adds a thin bar of text to; those frames are too close to the menu
to tell apart, and have no reference. The earlier screens each last several
seconds, so a click lands on one of them. To add or redo a game's:

```bash
WP=DerivedData/Build/Products/Debug/WrappPuppeteer.app/Contents/MacOS/WrappPuppeteer

# Record the game starting: its window from when it's fullscreen, four frames
# a second, named by milliseconds since the window appeared. Nothing is
# clicked, so the game plays through to its menu. Run it where a wrapp may
# take over the screen.
$WP "built-apps/Nancy Drew - <game>.app" --record /tmp/rec --record-seconds 60

# Make a reference from a frame partway through each splash screen
$WP --make-splash-reference /tmp/rec/004960.png \
  Bundles/nancy-drew/<slug>/tests/needles/splash/splash-<slug>-her-logo.png

# Check every frame: SPLASH, the nearest reference and its distance, and
# anything light where the bars beside a 4:3 picture should be
$WP --classify <slug> /tmp/rec

# What a click skips: click the picture 1.5 s after the window goes
# fullscreen (a comma-separated list for more), and see when the menu comes
$WP "built-apps/Nancy Drew - <game>.app" --record /tmp/rec-click --record-seconds 40 --record-click-at 1.5
```

Some of the splash frames should say `SPLASH`, early on, and every frame from
the menu on should not, with room to spare. A new `any` reference needs
checking against every game's recording, since every game is matched against
it. `--record` also works on a normal run
(without `--record-seconds`), to see afterwards what each click did. The
record directory's path must not contain spaces: the game's control socket
takes the path a capture is saved to as one word.

### Switching away and back

The first time Exit is found, before clicking it, the scenario switches
away from the game and back, as a player would. The game's helper hands
activation to the Finder (`yield`, [puppet
control](wine-in-process-helpers.md#puppet-control)), and WrappPuppeteer
then activates the Finder (`ProcessControl.switchTo`), as Cmd-Tab to it
does. The Finder's windows are on the desktop, so the screen slides off the
game's fullscreen Space. Once the game says it is no longer active and its
window is off the screen (`onspace=0`), WrappPuppeteer opens the wrapp as a
click on its Dock icon does (`ProcessControl.reopen`). The game has to be
active again, with its window back on screen, within 15 s: the wrapp brings
it forward ([the Dock](wrapp-launch.md#the-dock)). Active alone isn't
enough, as an app made active needn't take the screen to its window's Space.
The menu's frame is then checked again, below: a Direct3D game whose mode
Wine emulates once came back with its picture half a screen up. A game that
doesn't come back fails the run. A switch away that doesn't happen at all is
the test's problem rather than the game's, so it's only a warning.

WrappPuppeteer used to switch to itself instead: it became a regular app for
the moment and showed a window, which macOS can't show in another app's
fullscreen Space. On macOS 26 that never left the game's Space. macOS made
WrappPuppeteer active, or refused to, but the screen stayed on the game,
which stayed active and key, so every run only warned that it couldn't
switch away. Activating the Finder after the game's hand-over left the
game's Space at once.

### Quitting from the menu

Once a game has passed, the test launches it again and quits it the other way
a player can: through its Quit menu item, as ⌘⌥Q does, rather than the game's
Exit button (`--quit-from-menu`). Once at the menu, the game's helper calls
`-[NSApplication terminate:]`, the menu item's action (`quit`, [puppet
control](wine-in-process-helpers.md#puppet-control)), and the game has to close
within 60 s. That goes through Wine (or ScummVM) rather than the game, and it
once hung for good: with the game's process made an accessory app, White
Wolf's main thread waited in `terminate:` for an answer that never came. A
game that doesn't close fails the run, with a capture of its window. The
relaunch's time is in the **Launch** column too. It's skipped in a VM.

### The picture's bars and shape

On a display of another shape than the game's, the wrapp shows the game's
picture at its own shape, centred, with black bars beside it
([mode scaling](wine-in-process-helpers.md#mode-scaling) does it for a
Direct3D game, cnc-ddraw for a DirectDraw one, ScummVM for its own). Nothing
else in the run would notice a bar left light grey, or a picture stretched to
the display's shape: the game still plays. So the first capture Exit is found
in — the menu, fully drawn, which every run reaches — is checked for it
(`PictureFrameCheck`), and the first after [switching away and
back](#switching-away-and-back).

Every game draws a 4:3 picture (`Wrapp.pictureAspect`), so everything
outside a 4:3 area centred in the capture must be dark. A bar fails once 2%
of it isn't (a cursor out in a bar stays well under that), and the failure
says which way. The top 72 points of the window are left out, for its title
bar (`Wrapp.titleBarHeight`,
[the cursor and the title bar](#the-cursor-and-the-title-bar)).

- **nearly all of it one flat colour** — the bar was left undrawn, showing
  the window's own background: `the right bar is #ececec, not black`.
- **anything else** — the picture reaches out over where the bar should be:
  `the picture reaches into the left bar (100% of it isn't dark), so it's
  stretched or not 4:3`.

Light that comes and goes isn't a framing fault. A game started through
Steam shows Steam's overlay notice in the bottom-right corner for its first
few seconds, over the right bar, so for those games that corner (340 by 120
points, `Wrapp.steamOverlayNoticeSize`) is left out and the check doesn't
wait for the notice to go. For anything else that comes and goes, a capture
that fails is taken again every second, for up to 12 s, and the check fails
only if none of them passes; a run that passes first time doesn't wait.

A pass logs `🖼️  The picture is framed rightly in 2560x1440`; a failure saves
the capture to `/tmp/picture-frame-*.png` and names it in the log. On a 4:3
display there are no bars, and the check passes by having nothing to find.
`--classify` prints the same check for each frame (`light-in-bars:`).

Splash screens aren't used for this: the scenario often skips them by
clicking the Her Interactive logo before any is recognised, and the shared
`any` references don't keep one shape, since games frame them differently.

### The cursor and the title bar

macOS shows a fullscreen window's title bar, and the menu bar above it, while
the cursor rests at the top of the screen. What a test captures can change
with it, so where the cursor is matters to a run even though every click the
test makes goes through the game's socket, not the real cursor. What is known,
from experiments with White Wolf on two displays: a 2560x1440 one without a
notch, and a notched MacBook's, where the game's window is 1512x945 points
(3024x1890 pixels) below the notch's 37-point strip and the menu bar sits in
that strip, beside the notch:

- **A game started with the cursor at the top shows the title bar** from the
  start, every time, on both. WrappPuppeteer therefore moves the cursor to the
  middle of the screen's left edge before it launches the wrapp: away from
  the top, in the bar beside the picture on a widescreen display (see the
  game's own cursor, below), and clear of the Dock and hot corners.
- **Once shown, it stays until the mouse really moves.** What shows and hides
  it differs between the two displays. Mouse moves posted inside the game
  (the puppet socket's `move`) do neither alone on either. A jump of the real
  cursor (`CGWarpMouseCursorPosition`) to the top does nothing alone on the
  display without a notch, but on the notched one, where the top of the
  screen is the menu bar's strip above the game's window, it shows the title
  bar by itself. A jump followed by a few small moves in the game at the same
  height shows it at the top and hides it in the middle on both. None of
  this needs a permission. Posting mouse events from outside the game
  (`CGEventPost`) would need Accessibility, which WrappPuppeteer doesn't have.
- **Someone moving the mouse at the test Mac brings it up too**, over Screen
  Sharing included. Mid-run, nothing undoes that until the mouse moves away
  from the top again.
- **A capture of the game window shows it** across the top. The menu bar
  and title bar are a fixed height in points, whatever the display's size:
  without a notch the title bar sits below a dark strip where the menu bar
  goes, about 30 points down to 60; on the notched display the menu bar is
  outside the window, so the title bar starts at the very top and reaches
  28 points. That is why the [framing check](#the-pictures-bars-and-shape)
  leaves out the top 72 points of the window, which covers both on any
  height of display: every capture taken with it showing on the notched
  display passed the check. A splash reference recorded with it showing has it baked
  in and matches worse without it: White Wolf's `title` reference once did,
  and was recorded again.
- **It doesn't turn the bars white.** With the title bar showing, White
  Wolf's bars stay black on both displays, and on the one without a notch
  even with the mode scaling helper's handling of a
  titled window
  ([mode scaling](wine-in-process-helpers.md#mode-scaling)) taken out. A
  check that brought the title bar up and looked at the bars again was tried
  and dropped, as it couldn't fail. The white right bar that handling fixes,
  seen in two runs with White Wolf's window titled, has an unknown cause; it
  may have been this title bar after all, with something else that run did
  differently, or something else entirely.

The capture leaves out the macOS cursor (`showsCursor = NO` in
`puppet_control.m`), but a game that draws its own cursor, as White Wolf
does, draws it into the picture where the mouse is, and it is in the capture.
A sprite over a splash screen could push its fingerprint further from the
reference, which is the other reason the cursor starts in the bar. It didn't
show in practice: on a notched MacBook display, where the game's window is
3024x1890 below the notch, White Wolf's `title` matched at 0.055 with the
cursor in the middle and at the left edge alike, where a 2560x1440 display
without a notch gives 0.023, so the window's shape counted and the sprite
didn't.

## Testing in a VM

`sc test integration --vm <name>` launches each game in a
[tart](https://tart.run/) macOS VM instead of on this Mac: the way to try a
macOS version this Mac doesn't run, and a run that doesn't take over this
Mac's screen (which may even be locked). The build still happens here, and is
tested here as usual; only the launch-and-quit moves.

**Setting one up.** Cirrus Labs' images are ready-made macOS installs with
SSH on, automatic login, and a passwordless-sudo `admin` user:

```bash
export TART_HOME=<a disk with ~60 GB free per macOS version>   # optional
tart clone ghcr.io/cirruslabs/macos-sequoia-vanilla:latest sc-sequoia
tart set sc-sequoia --cpu 4 --memory 8192
tart run sc-sequoia --no-graphics &                # first boot only, for the key
ssh-copy-id admin@$(tart ip sc-sequoia)            # password: admin
tart stop sc-sequoia
```

The tests sign in with a key only: `SC_VM_SSH_KEY` names one other than
ssh's defaults, `SC_VM_USER` another account. A Tahoe guest
(`macos-tahoe-vanilla`) runs on a Sequoia host too.

**What sc does** (`TestVM` in `Tools/sc`): starts the VM headless if it's
stopped (and stops it again at the end), waits for its address and for SSH,
checks someone is logged in at its console with the screen unlocked, and
installs Rosetta if it's missing — the wrapps' Wine is x86_64, and Rosetta
installs and runs in a macOS guest as on a Mac. It hands the test
`TEST_RUNNER_VM_NAME`, `TEST_RUNNER_VM_SSH_TARGET` and `TEST_RUNNER_VM_SSH_KEY`.

**What the test does** (`VMPuppetRunner`): `AppPuppetRunner.run` hands off to
it when those are set. It copies WrappPuppeteer and the wrapp into
`/tmp/sc-vm-test-<id>/` in the VM with `tar` over SSH — `tar`, because the
template's non-Mach-O files keep their code signatures in extended attributes
(a 3.5 GB wrapp takes about five minutes) — and runs a job script there as a
one-off LaunchAgent in the GUI session, since WrappPuppeteer needs a
WindowServer. The script first opens the wrapp once through LaunchServices and
quits it as soon as its launch log appears: macOS checks the whole bundle of a
freshly copied app the first time it's opened, which on a VM's disk can take
minutes — longer than WrappPuppeteer waits for the save warning (seen as
"Failed to dismiss info window" with no wrapp log at all). Running the binary
directly doesn't count; only an open through LaunchServices does. Then it runs WrappPuppeteer and
saves its and the game's OSLog with `log show`, plus any startup diagnostics
bundle. The test reads those back and judges them with `AppPuppetRunner.judge`,
exactly as a local run is judged. The job, and anything it left running, is
removed afterwards, and at the start of the next run if the test host was
stopped partway.

**What a VM can't test.** Apple's virtualisation gives a guest a GPU with
Metal but no hardware OpenGL: OpenGL there is only the Apple Software
Renderer (legacy GL 2.1). So:

- **Direct3D games can't render.** Wine's Direct3D runs on OpenGL, gets no
  context (`wined3d_caps_gl_ctx_create Failed to find a suitable pixel
  format`), and the game quits before drawing. Their launch is reported
  `skipped` (`VMTarget.launchSkipReason`); their build was still tested. A
  failed build check is never hidden behind `skipped`.
- **DirectDraw games run, but not as on a Mac.** cnc-ddraw's `renderer=auto`
  falls back from Direct3D to a software renderer, which puts "Using slow
  software rendering" on screen and sometimes draws the picture at half size in
  the corner of a Retina window, so a click on what OCR found misses. Their
  results show the helpers, input and quit path work, not the rendering.
- **ScummVM games** run as on a Mac.

**Steam.** A Steam wrapp that launches through Steam needs the shared sign-in
(docs/steam.md), which lives on this Mac. The test copies the store into the
VM's `~/Library/Application Support/SecondChance/Steam/` for the run and
deletes it after, pass or fail. Steam has been seen to sign in from a VM with
it and leave the token as it was; if it ever replaces the token, the test
brings the VM's session back through `SteamSessionStore.capture`, with its
lock and newer-wins rule. A first sign-in in a fresh VM takes a couple of
minutes, while Steam updates itself. Steam plays one game per account at a
time, so don't play a Steam game elsewhere while one is tested.

## Reading the output

Suites run **concurrently**, and so do games within a suite while they
build, so their lines interleave: the tests printed after
`Suite "X" started` mostly belong to other suites, and one game's build log
lines sit among another's. Each game's own log is in its attachment. Don't read a block of output
as one suite's results, and don't conclude a suite ran from its `started` line
alone — match on the test names, or on `Suite "X" passed`.

A suite that was filtered out produces no output at all, which looks
indistinguishable from a clean run unless you go looking for it.

### Captures slow on a test Mac that has been up for weeks

Every screen capture on a Mac — `screencapture`, ScreenCaptureKit, in or out
of process — reports itself to `systemstatusd`, the daemon behind the
menu-bar privacy indicators, and `replayd` waits for each report on a single
queue. Each run of `/usr/sbin/screencapture` leaves state behind in
`systemstatusd` that makes every later report dearer: on macOS 26.2, 500 runs
nearly doubled its cost. After two weeks of integration tests, which ran
`screencapture` for every attempt to find Exit, a test Mac's `systemstatusd`
held 39 MB (fresh, about 10 MB) and took seconds per report, so every capture
on that Mac stalled for 8–16 s. Captures made in-process leave nothing behind.

If captures are slow, check it:
`ps -o etime,time,rss -p $(pgrep -x systemstatusd)`. System Integrity
Protection stops it being restarted any other way, so reboot the Mac.

## Reports

`sc test` writes `test-results/<timestamp>-unit.xcresult` and
`…-integration.xcresult`, converts them with `xchtmlreport` into
`test-results/<timestamp>/index.html`, and opens that when something failed
(`--open-report always|never` to change that). The terminal ends with a table
of suites or games and the totals. Per-run logs and WrappPuppeteer output are
attached to the test case inside the `.xcresult`.

## Test fixtures (`TestFixtures/`)

Mock data for testing without real installers — currently
`scarlet-hand-disk/` (a mock disk structure with `autorun.inf`, `setup.ini`).
Tests that need a fixture skip explicitly when it is absent.

## Adding tests

```swift
import Testing
@testable import SecondChance

@Suite("My New Feature")
struct MyFeatureTests {
    @Test("Handles both inputs", arguments: ["input1", "input2"])
    func handlesInput(input: String) {
        #expect(transform(input) == expected(input))
    }
}
```

A new unit suite runs in `sc test unit` without any registration — add it to
the list above while you are there. A slow or environment-dependent one belongs
in `TestRunner.unitExclusions` instead. Integration coverage for a new game needs only its ISOs dropped into
`installers/<slug>/`; the suite enumerates games from `GameInfoProvider`.

Adding a file under `docs/` also means adding its row to AGENTS.md's
Documentation table: `DocsTableTests` asserts the two match in both directions,
so an unlisted doc fails the unit run.

Mark tests needing absent fixtures with an explicit skip rather than returning
early, so a skipped test is visible as skipped.
