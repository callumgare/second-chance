# SecondChance Tests

Swift Testing (`@Test` / `#expect`), run through `run-tests.sh`. There is no
`Package.swift`, so `swift test` does not work here — everything goes through
`xcodebuild` against the `SecondChance` scheme.

## Quick Start

**Run these under Rosetta.** `run-tests.sh` picks its destination from
`uname -m`, and the WrappTemplate target is `ARCHS = x86_64` (Wine is 32-bit),
so a native arm64 run dies at link with `ld: symbol(s) not found for
architecture x86_64` for every swift-log symbol. That surfaces as exit 65 and
`** TEST BUILD FAILED **`, which reads like a failing test but is a link
failure. (`./build.sh` needs no prefix — it already wraps xcodebuild in
`arch -x86_64`.)

```bash
# Unit tests only (fast, ~6s, no installers needed)
arch -x86_64 ./run-tests.sh unit

# Integration tests — one game
arch -x86_64 ./run-tests.sh integration stay-tuned
arch -x86_64 ./run-tests.sh i stay-tuned          # short form

# Integration tests — all games (hours)
arch -x86_64 ./run-tests.sh integration

# Everything
arch -x86_64 ./run-tests.sh

# Skip the rebuild and reuse the existing build
arch -x86_64 ./run-tests.sh --no-rebuild i stay-tuned
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

Those seven are what `run-tests.sh unit` selects. `ExiftoolServiceTests` is
deliberately outside that filter — it shells out to the bundled exiftool.

### Integration tests (`SecondChanceTests/Integration/`)

Slow (~1.5 min for a cached ScummVM game, minutes for a Wine install), and they
need real ISOs at `installers/<slug>/disk-1.iso` (gitignored). Absent ISOs, the
suite disables itself via `.disabled(if: !InstallersPresent.check())`.

Each game runs the **real** build flow — real Wine/ScummVM install, real file
copies — and asserts on the events the flow publishes:

- Disks resolved, and the game detected from the disk fingerprint
- Engine routed correctly (Wine vs ScummVM)
- Game exe path detected, matching `GameInfoProvider.internalGameExePath`
- The wrapp's `Info.plist`/`AppSettings.plist` carry the right `GameExePath`,
  `GameEngine`, `GameSlug`
- The full event sequence in order, ending in `signed` then `completed`
- If `GamePuppeteer.app` is present: the game launches, reaches its main menu,
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
arch -x86_64 ./run-tests.sh integration stay-tuned

# Directly
TEST_RUNNER_TEST_GAMES=stay-tuned,blackmoor-manor \
  arch -x86_64 xcodebuild test-without-building -scheme SecondChance \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:SecondChanceTests/DiskInstallIntegrationTests
```

`TEST_RUNNER_SKIP_BUILD=1` is the env form of `--test-existing-wrapp`.

## GamePuppeteer

`GamePuppeteer` (a CLI tool wrapped as an `.app` so it can hold TCC grants)
drives the launch-and-quit phase. It is a **build dependency of the
SecondChanceTests target**, so `run-tests.sh` builds it for you — no separate
build step. If the bundle is missing, the launch phase is skipped and the build
assertions still run.

It needs `DerivedData/Build/Products/Debug/GamePuppeteer.app` granted
**System Settings → Privacy & Security → Accessibility** *and* **Screen
Recording**.

Its exit codes (`GamePuppeteer/Configuration.swift`):

| Code | Meaning |
| --- | --- |
| 0 | passed — game launched and quit cleanly |
| 1 | failed |
| 2 | forced quit |
| 3 | Accessibility permission denied |
| 4 | Screen Recording permission denied |
| 5 | Screen Recording granted but a relaunch is required |

**Codes 3–5 are permission problems, not regressions.** Any rebuild of
`GamePuppeteer.app` produces a newly ad-hoc-signed binary and drops its TCC
grants, so an unrelated edit can cause them — anything under `Shared/` compiles
into GamePuppeteer and will rebuild it. Re-grant the permission (`reset-tcc.sh`
clears stale entries) rather than looking for a bug in the build code. The
tell-tale: the run reports a single issue, and every wrapp-build event assertion
passed before it.

Launch timeout defaults to 90 s (`GamePuppetRunner.run(timeout:)`).

## Reports

`run-tests.sh` writes `test-results/<timestamp>.xcresult`, converts it with
`xchtmlreport` into `test-results/index.html`, and opens it. Per-run logs and
GamePuppeteer output are attached to the test case inside the `.xcresult`.

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
case, or the fast loop won't run it. Integration coverage for a new game needs
only its ISOs dropped into `installers/<slug>/`; the suite enumerates games from
`GameInfoProvider`.

Mark tests needing absent fixtures with an explicit skip rather than returning
early, so a skipped test is visible as skipped.
