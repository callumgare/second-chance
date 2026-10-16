# Testing

How the test suite is run, what each layer covers, and the handful of things
about this setup that will waste an afternoon if you don't know them.

Tests are Swift Testing (`@Test` / `#expect`), driven by `run-tests.sh`. There
is no `Package.swift`, so `swift test` does not work here — everything goes
through `xcodebuild` against the `SecondChance` scheme.

For the repo-wide conventions see `AGENTS.md`; for the build flow these tests
exercise, see [wrapp-build.md](wrapp-build.md).

## Quick Start

These run natively — no Rosetta wrapper. `run-tests.sh` passes
`ONLY_ACTIVE_ARCH=NO`, which is what makes them work: the WrappTemplate target
is `ARCHS = x86_64` (Wine is 32-bit), so an active-arch-only build on Apple
Silicon emits swift-log for arm64 alone and WrappTemplate then dies with
`unable to resolve module dependency: 'Logging'`, or at link with `ld: symbol(s)
not found for architecture x86_64` for every swift-log symbol. That surfaces as
exit 65 and `** TEST BUILD FAILED **`, which reads like a failing test but is a
build failure. See the README's *Building* section for the full story.

```bash
# Unit tests only (fast, ~6s, no installers needed)
./run-tests.sh unit

# Integration tests — one game
./run-tests.sh integration stay-tuned
./run-tests.sh i stay-tuned          # short form

# Integration tests — all games (hours)
./run-tests.sh integration

# Everything
./run-tests.sh

# Skip the rebuild and reuse the existing build
./run-tests.sh --no-rebuild i stay-tuned
```

Other flags: `--raw-logs` (skip xcbeautify), `--quiet`, and
`--test-existing-wrapp` (skip the install and drive a prebuilt app from
`built-apps/` — note those must have been built since the WrappTemplate
rename, or their executable name won't match).

Never run an unfiltered `xcodebuild test`: with real ISOs present in
`installers/`, the integration suite does not skip and the run takes hours.

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

Those nine are what `run-tests.sh unit` selects. `ExiftoolServiceTests` is
deliberately outside that filter — it shells out to the bundled exiftool.

**The `unit` case is an explicit `-only-testing:` allowlist, not a wildcard.**
A new suite that isn't listed there does not fail — it simply never runs, and
the run still reports success. If a suite you just wrote doesn't appear in the
output, that is the first thing to check.

### Integration tests (`SecondChanceTests/Integration/`)

Slow (~1.5 min for a cached ScummVM game, minutes for a Wine install), and they
need real ISOs at `installers/<slug>/disk-1.iso` (gitignored). Absent ISOs, the
suite disables itself via `.disabled(if: !InstallersPresent.shouldRun())` — so
a plain `xcodebuild test` on a machine without them skips rather than fails.

`./run-tests.sh integration` is different: asking for the suite by name sets
`TEST_RUNNER_REQUIRE_INSTALLERS=1`, the suite always runs, and a game whose ISO
is missing fails its `#require` with the path it looked at. A skipped suite
there would report a pass having tested nothing.

The tests find the repo, and so `installers/`, through `TestPaths.repoRoot`.
That defaults to `#filePath`, which is fixed at compile time and wrong on any
machine the build was copied to, so run-tests.sh passes the real location as
`TEST_RUNNER_REPO_ROOT`. Calling `xcodebuild` directly on a copied build, pass
it yourself.

Each game runs the **real** build flow — real Wine/ScummVM install, real file
copies — and asserts on the events the flow publishes:

- Disks resolved, and the game detected from the disk fingerprint
- Engine routed correctly (Wine vs ScummVM)
- Game exe path detected, matching `GameInfoProvider.internalGameExePath`
- The wrapp's `Info.plist`/`AppSettings.plist` carry the right `GameExePath`,
  `GameEngine`, `GameSlug`
- The full event sequence in order, ending in `signed` then `completed`
- If `WrappPuppeteer.app` is present: the game launches, reaches its main menu,
  and quits cleanly

`RecordingEventSubscriber` captures the bus events; the assertions read it.
**The bus events are the integration contract** — when moving orchestration
code between types, every `bus.publish` has to move with it, or the flow still
succeeds while the test sees nothing.

## Filtering games

`TEST_RUNNER_TEST_GAMES` (the `TEST_RUNNER_` prefix is what makes xcodebuild
forward it into the test environment) limits which games run:

```bash
# Via run-tests.sh, which adds the prefix for you
./run-tests.sh integration stay-tuned

# Directly
TEST_RUNNER_TEST_GAMES=stay-tuned,blackmoor-manor \
  xcodebuild test-without-building -scheme SecondChance \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:SecondChanceTests/DiskInstallIntegrationTests
```

A slug that matches no game fails the "Every requested game slug names a known
game" test, rather than filtering the per-game test down to zero cases — which
would pass having run nothing.

`TEST_RUNNER_SKIP_BUILD=1` is the env form of `--test-existing-wrapp`.

## WrappPuppeteer

`WrappPuppeteer` (a CLI tool wrapped as an `.app` so it can hold TCC grants)
drives the launch-and-quit phase. It is a **build dependency of the
SecondChanceTests target**, so `run-tests.sh` builds it for you — no separate
build step. If the bundle is missing, the launch phase is skipped and the build
assertions still run.

It needs `DerivedData/Build/Products/Debug/WrappPuppeteer.app` granted
**System Settings → Privacy & Security → Accessibility** *and* **Screen
Recording**.

Its exit codes (`WrappPuppeteer/Core/PuppetResult.swift`):

| Code | Meaning |
| --- | --- |
| 0 | passed — game launched and quit cleanly |
| 1 | failed |
| 2 | forced quit |
| 3 | Accessibility permission denied |
| 4 | Screen Recording permission denied |
| 5 | Screen Recording granted but a relaunch is required |

**Codes 3–5 are permission problems, not regressions.** Re-grant the permission
(`reset-tcc.sh` clears stale entries) rather than looking for a bug in the build
code. The tell-tale: the run reports a single issue, and every wrapp-build event
assertion passed before it.

WrappPuppeteer is signed with an Apple Development certificate, so TCC ties its
grants to the bundle ID and the certificate's name rather than to the binary's
hash — an ordinary rebuild keeps them. A fresh grant is needed when either of
those changes: a new bundle ID (the target was renamed), or a build signed by a
different Apple account, such as on another machine. (Before the project signed
with a certificate, it was ad-hoc signed and every rebuild dropped the grants.)
`codesign -dr- DerivedData/Build/Products/Debug/WrappPuppeteer.app` shows the
requirement TCC checks against.

Launch timeout defaults to 90 s (`AppPuppetRunner.run(timeout:)`).

### Core and the Nancy Drew scenario

The game draws its menus with DirectX inside Wine (or with ScummVM), so there
is no accessibility tree to query: WrappPuppeteer finds things on screen with OCR
and template matching and clicks by coordinates. It is split in two, and the
dependency only runs one way:

- **`WrappPuppeteer/Core/`** — reusable automation with no knowledge of Nancy
  Drew, wrapps or engines: screenshots (`ScreenCapture`), OCR
  (`TextRecognizer`), template matching (`TemplateMatcher`), window listing
  (`WindowFinder`), Accessibility (`Accessibility`), focus (`FocusDetector`),
  processes (`ProcessControl`, `ProcessFinder`, `ProcessCleanup`), input,
  permissions and exit codes.
- **`WrappPuppeteer/NancyDrew/`** — everything specific to driving a game: reading
  the wrapp's `AppSettings.plist` and mapping its engine to process names, kill
  commands and a focus strategy (`Wrapp`); the wrapp's "save regularly" window
  (`InfoWindow`); where the Exit button and Her Interactive logo are and how to
  recognise them (`MainMenuScreen`); and the launch → menu → Exit flow itself
  (`NancyDrewQuitScenario`).

Core never names a game. When a game-specific fact would make a utility work
better, Core takes it as a parameter and the scenario supplies it — for
example the quit-button search is narrowed by
`MainMenuScreen.quitButtonMatchOptions`, a `TemplateMatchOptions` that limits
the search to the bottom-right corner, sizes the template relative to the
screen, and uses red-emphasis greyscale because the button is red. Called
without options, `TemplateMatcher` searches the whole screen at the template's
own size.

The scenario clicks Exit, then parks the cursor at the left edge with a real
mouse-move event — the game draws its own cursor, and left over the button it
hides the label from the next OCR pass. If the game is still on the menu, it
clicks Exit again. A Wine game should quit on the first click: a log showing
"Clicking 'Exit Game' button again" on every run means the wrapp's cursor lock
isn't taking, and cnc-ddraw is swallowing the first click — see
[wine-in-process-helpers.md](wine-in-process-helpers.md#cursor-lock).

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
`WRAPP_PUPPETEER_PERMISSION_WAIT_SECONDS` overrides how long the permission gate
waits for a grant.

## Reading the output

Suites run **concurrently**, so their lines interleave: the tests printed after
`Suite "X" started` mostly belong to other suites. Don't read a block of output
as one suite's results, and don't conclude a suite ran from its `started` line
alone — match on the test names, or on `Suite "X" passed`.

A suite that was filtered out produces no output at all, which looks
indistinguishable from a clean run unless you go looking for it.

## Reports

`run-tests.sh` writes `test-results/<timestamp>.xcresult`, converts it with
`xchtmlreport` into `test-results/index.html`, and opens it. Per-run logs and
WrappPuppeteer output are attached to the test case inside the `.xcresult`.

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

A new unit suite also needs an `-only-testing:` line in `run-tests.sh`'s `unit`
case, or the fast loop won't run it — and add it to the list above while you are
there. Integration coverage for a new game needs only its ISOs dropped into
`installers/<slug>/`; the suite enumerates games from `GameInfoProvider`.

Adding a file under `docs/` also means adding its row to AGENTS.md's
Documentation table: `DocsTableTests` asserts the two match in both directions,
so an unlisted doc fails the unit run.

Mark tests needing absent fixtures with an explicit skip rather than returning
early, so a skipped test is visible as skipped.
