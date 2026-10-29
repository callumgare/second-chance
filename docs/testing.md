# Testing

How the test suite is run, what each layer covers, and the handful of things
about this setup that will waste an afternoon if you don't know them.

Tests are Swift Testing (`@Test` / `#expect`), driven by `./sc test`
([dev-cli.md](dev-cli.md)). The app has no `Package.swift`, so `swift test`
does not work for it — everything goes through `xcodebuild` against the
`SecondChance` scheme. (`Tools/sc`, the CLI itself, is a Swift package with its
own tests; `sc test unit` runs those too.)

The tests run inside `Second Chance.app`, their test host. Under test it opens
no window and stays out of the Dock and the foreground (`TestHost`), so a run
doesn't take over the Mac; it also keeps no run log and leaves the welcome
screen's first-launch greeting alone.

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

# Build here, launch in a tart VM (another macOS version, say)
./sc test integration ghost-dogs --vm sc-sequoia
```

Other options: `--logs collapsed|full|raw` for how output is shown,
`--wrapps-dir` for where prebuilt wrapps are, and `--open-report
failures|always|never`. In a terminal the run is shown live — a progress bar,
what's running now, and a table of suites (or games) — with the full xcodebuild
output kept in `DerivedData/sc-logs/`.

Never run a bare `./sc test` or an unfiltered `xcodebuild test` by accident:
with real ISOs present in `installers/`, the integration suite does not skip
and the run takes hours.

## Test structure

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
in `Tools/sc/Sources/SCKit/Support/TestRunner.swift`: `DiskInstallIntegrationTests`
(real installs) and `ExiftoolServiceTests` / `ExiftoolServiceIntegrationTests`
(they shell out to the bundled exiftool). A new suite therefore runs by default;
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
`SteamInstallIntegrationTests` (`steam`) and
`HerDownloadInstallIntegrationTests` (`her-download`). A game tested more than
one way is a row per source in the table, with a Source column. Swift Testing
would run the suites side by side, so each per-game test runs inside
`IntegrationSerial`, which lets one game build and launch at a time across
them all.

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
- always builds: `--refresh-wrapp` applies to the disk suite's wrapps only;
- downloads every game it tests, so it's slow, and run often could trip
  Steam's rate limits. It is in `TestRunner.unitExclusions`.

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

## WrappPuppeteer

`WrappPuppeteer` (a CLI tool wrapped as an `.app`) drives the launch-and-quit
phase. It is a **build dependency of the SecondChanceTests target**, so
`sc test` builds it for you — no separate build step. If the bundle is
missing, the launch phase is skipped and the build assertions still run.

**It needs no permissions.** It never captures or clicks another app's
windows itself: it starts the wrapp with `SECOND_CHANCE_PUPPET_DIR` naming a
private directory, and the wrapp and the game then serve their own windows on
sockets there — the wrapp its info window on `wrapp.sock`, a helper inside
the game process the game window on `game.sock` — since a process may
capture and click its own windows without Screen Recording or Accessibility.
[wine-in-process-helpers.md](wine-in-process-helpers.md#puppet-control) has
how the helper gets into each engine and what the sockets accept. If
WrappPuppeteer happens to have Screen Recording, a failed run also saves a
full-screen screenshot; nothing else changes.

**It doesn't touch the player's saves and settings.** A wrapp keeps those in
`~/Library/Application Support/<bundle id>/` (and ScummVM's in
`~/Library/Preferences/<bundle id>.ini`), which a test's wrapp, with the same
bundle id, would share with the player's. WrappPuppeteer sets
`SECOND_CHANCE_DATA_DIR` to an empty `data` folder in its private directory,
and the wrapp keeps them there instead, so each launch starts as on a fresh
Mac: the save warning shows, and no setting the player chose changes the
test. Before, Warnings at Waverly Academy failed every run on one Mac whose
`Waverly.INI` there said to play in a window.

Its exit codes (`WrappPuppeteer/Core/PuppetResult.swift`):

| Code | Meaning |
| --- | --- |
| 0 | passed — game launched and quit cleanly |
| 1 | failed |
| 2 | forced quit |

**A game the Mac was too busy to test is `overloaded`, not failed.** Before
each game the test checks `SystemLoad`; while other programs keep all but one
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
waiting for focus. Before each game the test asks `ScreenState`
(`Shared/ScreenState.swift`), and if nothing can come to the front, records
why and moves on without building it. The table shows those games as `locked`,
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
exited (`ProcessControl.isAlive`). The `--timeout` that
`AppPuppetRunner.run(timeout:)` passes is only logged. The wrapp's "save
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
`/tmp` (`game-window-detected-*.png` once the game is up,
`exit-not-found-*.png`), naming it in its log — plus a full-screen screenshot
(`game-not-focused-*.png`, `info-window-still-open-*.png`, …) if it happens to
have Screen Recording. The per-attempt captures, deleted as they are
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
waiting for a game it never started. Its force-quit checks that the process
really went and sends SIGKILL when `forceTerminate()` didn't do it.

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

- **`WrappPuppeteer/Core/`** — reusable automation with no knowledge of Nancy
  Drew, wrapps or engines: the control-socket client (`InProcessControl`),
  OCR (`TextRecognizer`), template matching (`TemplateMatcher`), screen
  fingerprints (`ImageFingerprint`), checking a picture's bars
  (`PictureFrameCheck`), recording a window (`WindowRecorder`),
  window listing (`WindowFinder`), focus (`FocusDetector`), processes
  (`ProcessControl`, `ProcessFinder`, `ProcessCleanup`), the click ring
  (`InputAutomation`), the optional full-screen screenshot (`ScreenCapture`)
  and exit codes.
- **`WrappPuppeteer/NancyDrew/`** — everything specific to driving a game: reading
  the wrapp's `AppSettings.plist` and mapping its engine to process names, kill
  commands and a focus strategy (`Wrapp`); the wrapp's "save regularly" window
  (`InfoWindow`); where the Exit button and Her Interactive logo are and how to
  recognise them (`MainMenuScreen`); each game's splash screens
  (`SplashScreen`, with its reference images in `NancyDrew/assets/splash/`); and
  the launch → menu → Exit flow itself (`NancyDrewQuitScenario`).

Core never names a game. When a game-specific fact would make a utility work
better, Core takes it as a parameter and the scenario supplies it — for
example the quit-button search is narrowed by
`MainMenuScreen.quitButtonMatchOptions`, a `TemplateMatchOptions` that limits
the search to the bottom-right corner, sizes the template relative to the
screen, and uses red-emphasis greyscale because the button is red. Called
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
they've finished appearing. None is clicked once Exit has been, and a capture
that isn't clicked still goes to the OCR, so a menu wrongly taken for a splash
screen still has its Exit found. The Her Interactive logo is also still
clicked where OCR reads "interactive", which catches it in a game with no
references.

**In a DirectDraw game the cursor lock decides how soon that is.** The first
click must not come before the wrapp's cursor lock has finished (see above),
a quarter of a second after the window reaches its fullscreen Space — about
2 s after it appears, while the Her Interactive logo is still up. While the
lock is still working the scenario doesn't click at all, and captures again
instead, so a click never lands on the screen that replaced the one it was
meant for. The Direct3D and ScummVM games have no lock to wait for.

From the game's window appearing to the Exit click took 3.3–13 s across all
33 games, 4.1 s for half of them, where waiting out the screens took up to a
minute (Labyrinth of Lies' and Sea of Darkness's intros run 50 s). The slowest
is Secrets Can Kill Remastered, black for its first six seconds with nothing
there to click.

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

The references are files in `WrappPuppeteer/NancyDrew/assets/splash/`:
`splash-any-<what it shows>.png` for the screens many games share — the Her
Interactive logos and intro, the glowing "Nancy Drew" — and
`splash-<game slug>-<what it shows>.png` for one game's own, mostly title
cards. A game is matched against its own and every `any` one. They're copied
flat into the app's resources, so the names must be unique; WrappPuppeteer
reads them from the source tree when it runs from a build inside it, so one
just made is used without rebuilding. Each is a recorded frame with its bars
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
  WrappPuppeteer/NancyDrew/assets/splash/splash-<slug>-her-logo.png

# Check every frame: SPLASH, the nearest reference and its distance, and
# anything light where the bars beside a 4:3 picture should be
$WP --classify <slug> /tmp/rec
```

Some of the splash frames should say `SPLASH`, early on, and every frame from
the menu on should not, with room to spare. A new `any` reference needs
checking against every game's recording, since every game is matched against
it. `--record` also works on a normal run
(without `--record-seconds`), to see afterwards what each click did. The
record directory's path must not contain spaces: the game's control socket
takes the path a capture is saved to as one word.

### The picture's bars and shape

On a display of another shape than the game's, the wrapp shows the game's
picture at its own shape, centred, with black bars beside it
([mode scaling](wine-in-process-helpers.md#mode-scaling) does it for a
Direct3D game, cnc-ddraw for a DirectDraw one, ScummVM for its own). Nothing
else in the run would notice a bar left light grey, or a picture stretched to
the display's shape: the game still plays. So the first capture Exit is found
in — the menu, fully drawn, which every run reaches — is checked for it
(`PictureFrameCheck`).

Every game draws a 4:3 picture (`Wrapp.pictureAspect`), so everything
outside a 4:3 area centred in the capture must be dark. A bar fails once 2%
of it isn't (a cursor out in a bar stays well under that), and the failure
says which way. The top 4% of the side bars is left out: White Wolf gives its
window a title bar once play starts, and a capture of a fullscreen window with
one shows it across the top, under where the menu bar goes.

- **nearly all of it one flat colour** — the bar was left undrawn, showing
  the window's own background: `the right bar is #ececec, not black`.
- **anything else** — the picture reaches out over where the bar should be:
  `the picture reaches into the left bar (100% of it isn't dark), so it's
  stretched or not 4:3`.

A pass logs `🖼️  The picture is framed rightly in 2560x1440`; a failure saves
the capture to `/tmp/picture-frame-*.png` and names it in the log. On a 4:3
display there are no bars, and the check passes by having nothing to find.
`--classify` prints the same check for each frame (`light-in-bars:`).

Splash screens aren't used for this: the scenario often skips them by
clicking the Her Interactive logo before any is recognised, and the shared
`any` references don't keep one shape, since games frame them differently.

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

Suites run **concurrently**, so their lines interleave: the tests printed after
`Suite "X" started` mostly belong to other suites. Don't read a block of output
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
