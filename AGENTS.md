# AGENTS.md

Guidance for AI coding agents working on the Second Chance codebase.

## What This Is

Second Chance is a native macOS app (Swift/SwiftUI) that wraps pre-Unity Nancy Drew PC games to run on modern Macs via [Wine](https://www.winehq.org/) and [ScummVM](https://www.scummvm.org/). The user points the app at a game installer (CD, Her Interactive download, or Steam) and it produces a standalone `.app` bundle containing the Wine/ScummVM engine plus the installed game.

Read `OVERVIEW.md` and `README.md` for the full project background before making non-trivial changes.

## Build, Run, Test

All commands run from the repo root. The project uses **fish shell** on macOS.

```bash
./build.sh                  # Build Second Chance.app (use --quiet to suppress output)
./run.sh                    # Build (if needed) and launch Second Chance.app
./run.sh --rebuild          # Force rebuild app + any game wrapper
./run.sh --clear-wine-cache # Clear cached Wine prefix

./run-tests.sh unit                 # Swift unit tests (~5s) — fast feedback loop
./run-tests.sh quick <game-slug>    # Integration smoke test for one game
./run-tests.sh integration          # Full integration tests (2–3 hours, needs real installers)
```

**Important:** `run-tests.sh unit` currently has its `xcodebuild` line **echoed, not executed** (it's commented out for safety). To actually run unit tests, execute directly:

```bash
cd SecondChance && xcodebuild test -scheme SecondChance -destination 'platform=macOS' -derivedDataPath ../DerivedData
```

Build output lands in `DerivedData/Build/Products/Debug/Second Chance.app`. Game wrappers are built into `built-apps/`.

## Tech Stack

- **Swift 5.0** / **SwiftUI**, deployment target **macOS 15.0** (some targets 15.6)
- Xcode project (`SecondChance.xcodeproj`), no SPM package manifest
- Uses Swift Testing framework (`@Test`, `#expect`) — not XCTest
- Unsandboxed app (required for Wine); entitlements enable dyld env vars, unsigned executable memory, and disable library validation

## Architecture

```
Views (SwiftUI)  →  InstallationViewModel (@MainActor)  →  InstallationService
                                                                    ↓
                                                              GameInstaller
                                                                    ↓
                              WineManager · WrapperBuilder · GameDetector · CacheManager
                                                                    ↓
                                                              Models (GameInfo, InstallationState, …)
```

### Key abstractions

- **`InstallationContext` protocol** (`Services/InstallationContext.swift`): The central abstraction. Decouples installation logic from input/output. Two implementations: `InteractiveContext` (GUI, NSOpenPanel) and `NonInteractiveContext` (env vars, stdout). **New installation flows should go through `InstallationService.performInstallation(context:)`**, not call `GameInstaller` directly. If adding a new source (e.g. completing Her/Steam), implement a new `InstallationContext`.
- **Services are singletons** (`XxxManager.shared`, `GameInstaller.shared`, etc.). This is existing technical debt — services reference each other via `.shared`, making isolated unit testing hard. When refactoring, prefer constructor injection but you may keep a `static let shared` convenience.
- **`GameInfoProvider`**: Static database of all 30+ Nancy Drew games with metadata (engine, disk count, exe paths, Steam DRM). Add new games here.
- **`GameEngine` enum** (`wine`, `scummvm`, `wineSteam`, `wineSteamSilent`): Determines which engine the wrapper uses.

### Installation state machine

`InstallationState` (`Models/InstallationState.swift`) drives the UI and progress reporting. States: `idle → detectingGame → settingUpWrapper → copyingInstaller → installingGame → configuringWrapper → savingApp → completed` (or `error`). Each in-flight state carries optional `substep` and `elapsedSeconds`.

## Code Conventions

- **Async/await** throughout — services use `async throws` methods. Run UI updates on `@MainActor`.
- **Logging**: All logging uses `os.Logger` directly — no wrapper, no `print()`. Each file declares its own `private let logger = Logger(subsystem: "com.secondchance", category: "FileName")` (GameWrapper uses `com.secondchance.gamewrapper`, GamePuppeteer uses `com.secondchance.gamepuppeteer`). Use `.notice` for info, `.error` for warnings/recoverable errors, `.fault` for serious/unexpected failures. All string interpolations in log calls **must** use `privacy: .public` (e.g. `"\(value, privacy: .public)"`) — without it, values are redacted in release builds. Progress step changes emit a `━━━ Step Name ━━━` divider via the logger. The floating log window (`LogWindow`) combines `log show` (run once at startup to fetch history) with `log stream` (real-time, no polling delay). Both are filtered by PID and subsystem; a serial dispatch queue ensures history appears first, and hash dedup handles the overlap at the junction. Tests collect logs via `SystemLogReader.fetch(pid:since:)` which runs `log show` after a 2-second flush delay and attaches the result.
- **Error handling**: The codebase has many `try?` that silently swallow errors. For new code, prefer explicit `do/catch` and log failures. Cleanup operations may use `try?` but should log.
- **No force unwraps (`!`)** in new code — use `guard let` / `compactMap`. Existing force unwraps (e.g. `gameExe!` in `GameInstaller`) are flagged for removal.
- **File paths**: Never hardcode absolute user paths (e.g. `/Users/...`). Use `Bundle.main.url(forResource:)`, `FileManager` search paths, or environment variables.
- **Swift Testing**: Write tests with `@Test func`, `#expect`, `#require`. Mark tests needing fixtures with `#skip("reason")` rather than silent early-return.

## Gotchas

- **Non-interactive mode**: Set `NON_INTERACTIVE=true` plus `INSTALLATION_SOURCE`, `DISK_1_PATH`, `OUTPUT_PATH` env vars to run installs headlessly (used by integration tests). The ViewModel calls `exit()` on validation failures, so don't instantiate it in unit tests without care.
- **Wine prefix caching**: `WineManager` caches prefixes in `~/Library/Caches/SecondChance/wine-prefix-cache`, keyed by bundle version (or `"dev"` in DEBUG). Use `--clear-wine-cache` or `run.sh --clear-wine-cache` if Wine setup misbehaves after code changes.
- **`STRICT_INSTALL=true`** env var disables the silent→interactive installer retry fallback. `--skip-installer` debug flag skips running the installer entirely (useful for testing wrapper construction).
- **Disk path resolution**: Installers live in `Contents/SharedSupport/prefix/drive_c/nancy-drew-installer/{disk-1,disk-combined}`. Multi-disk games get merged into `disk-combined`. This resolution logic is duplicated in several places in `GameInstaller` — check there before reinventing.
- **Bundled resources**: `GameWrapper.app` template, Wine engine, `winetricks`, AutoIt, and ScummVM are bundled. Test that features work with bundled paths, not just system-installed equivalents.

## Testing

- **Unit tests** live in `SecondChanceTests/`. Use the Swift Testing framework. `GameDetectorTests` is the model to follow (35+ parameterized tests).
- **Test fixtures** are in `SecondChance/TestFixtures/` and `installers/`. Tests that need real installers will skip if fixtures are absent — make skips explicit with `#skip`.
- Integration tests require actual Nancy Drew installers in `installers/` and take hours; prefer unit tests for fast feedback.
- **Priority test targets** (currently untested but high-value): `CacheManager`, `InstallationContext` validation logic, `WrapperBuilder` path helpers.

## Things Currently In Flux

- The Her Interactive download and Steam install paths are partially implemented. `performInstallation(context:)` is the intended unified entry point but the Her download flow in `InstallationViewModel` still calls `GameInstaller` directly (legacy path).
- ScummVM games currently route through `installGameWithWine`; a separate `installGameWithScummVM` exists but is dead code.
- Several `.md` docs (especially in `SecondChanceTests/`) reference scripts/methods that have been renamed or removed — verify against code before trusting docs.
