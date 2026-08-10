# SecondChance Tests

## Quick Start

```bash
# All tests (unit + integration for all games)
./run-tests.sh

# Unit tests only (fast, ~5s, no installers needed)
./run-tests.sh unit

# Integration tests — all games
./run-tests.sh integration

# Integration tests — one game
./run-tests.sh integration secrets-can-kill

# Skip rebuilding if already built
./run-tests.sh --no-rebuild integration secrets-can-kill
```

## Test Structure

### Unit tests (`SecondChanceTests/*.swift`)

Fast, no installer ISOs required. Cover pure logic:

- **EventBusTests** — typed event bus ordering and delivery
- **ContextualLoggerTests** — step/source context stamping
- **LogCorrelatorTests** — formatting (headers, indentation, level prefixes)
- **GameDetectorTests** — fingerprint-to-slug matching for all 33 games
- **GameInstallerTests** — installer argument building (MSI, InstallShield, Inno)

### Integration tests (`SecondChanceTests/Integration/`)

Slow (~minutes per game), require real ISOs in `installers/<slug>/disk-1.iso` (gitignored).

Each game runs through the real installation flow and asserts:
- Game detected correctly from the disk fingerprint
- Engine routed correctly (Wine vs ScummVM)
- Game exe path detected and matches `GameInfoProvider.internalGameExePath`
- Wrapper `AppSettings.plist` contains correct `GameExePath`, `GameEngine`, `GameSlug`
- Full event sequence emitted in the expected order
- If `GamePuppeteer.app` is built: game launches, shows the main menu, and exits cleanly

## Filtering games

The `TEST_RUNNER_TEST_GAMES` env var (prefixed so xcodebuild forwards it) limits which games run:

```bash
# Via run-tests.sh (handles the prefix automatically)
./run-tests.sh integration secrets-can-kill

# Directly via xcodebuild
TEST_RUNNER_TEST_GAMES=secrets-can-kill,blackmoor-manor \
  xcodebuild test-without-building -scheme SecondChance \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -only-testing:SecondChanceTests/DiskInstallIntegrationTests
```

## GamePuppeteer

The `GamePuppeteer` Xcode target (CLI tool wrapped as an `.app` bundle) handles the launch-and-quit phase. Build it once before running integration tests:

```bash
xcodebuild -project SecondChance.xcodeproj -target GamePuppeteer \
  -configuration Debug \
  CONFIGURATION_BUILD_DIR=DerivedData/Build/Products/Debug
```

Then add `DerivedData/Build/Products/Debug/GamePuppeteer.app` to **System Settings → Privacy & Security → Accessibility** and **Screen Recording**.

If the binary is absent the launch phase is skipped; install assertions still run.


**Features:**
- 🎮 Tests complete installation flow
- ⏱️ Timeout handling (10 min install, 30 sec launch)
- 📸 Screenshot capture
- 📊 JSON + HTML reports
- 🎯 Can test specific games or all games
- 🚀 Skip rebuild option for faster iteration

**Output:**
- `test-output-YYYYMMDD-HHMMSS/` - All test results
  - `test-results.json` - Machine-readable results
  - `report.html` - Human-readable HTML report
  - `{game-slug}/` - Per-game logs, wrappers, and screenshots

## Test Fixtures (`TestFixtures/`)

Mock data for testing without real installers:

- **scarlet-hand-disk/** - Mock disk structure with autorun.inf, setup.ini
- **mock-installer/** - Mock PE executables for exiftool testing (create as needed)

Tests automatically skip if fixtures don't exist.

## Running Tests

### Swift Unit Tests

**In Xcode:**
1. Open `SecondChance.xcodeproj`
2. Press `Cmd+U` to run all tests
3. View results in Test Navigator (Cmd+6)

**Command Line:**
```bash
cd SecondChance
swift test                          # Run all tests
swift test --filter GameDetector    # Run specific suite
```

### Integration Tests

**Test all games:**
```bash
./test-games.sh
```

**Test specific game:**
```bash
./test-games.sh secrets-can-kill
```

**Options:**
- `--quick` - Skip rebuild, use existing app
- `--no-launch` - Test installation only, don't launch
- `--timeout N` - Set launch timeout in seconds (default: 30)

### Example Workflow

```bash
# 1. Run fast unit tests during development
cd SecondChance
swift test

# 2. Test one game integration after changes
cd ..
./test-games.sh scarlet-hand

# 3. Full regression test before release
./test-games.sh
```

## Test Reports

### Swift Testing Output
```
✔ Game Detection/Detect game from fingerprint (34 tests)
✔ Game Detection/Detect game from alternate codes (7 tests)
✔ Game Detection/Unknown fingerprints return nil (4 tests)
✔ Game Installer/MSI installer arguments - silent install
...
Test run passed after 2.3 seconds
```

### Integration Test Report

**Console:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎯 Testing: scarlet-hand
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📦 Installing game...
✅ Installation succeeded
✅ Wrapper created: Nancy Drew - Secret of the Scarlet Hand.app
🚀 Testing game launch...
✅ Game launched successfully

📊 TEST SUMMARY
✅ Passed:  15 / 20
❌ Failed:  3 / 20
⚠️ Skipped: 2 / 20
```

**HTML Report:**
Opens automatically with detailed results table showing:
- Game name
- Status (Passed/Failed/Skipped)
- Error messages
- Duration
- Timestamp

## Adding New Tests

### Swift Unit Test

```swift
import Testing
@testable import SecondChance

@Suite("My New Feature")
struct MyFeatureTests {
    
    @Test("Test something", arguments: ["input1", "input2"])
    func testSomething(input: String) {
        // Test code
        #expect(result == expected)
    }
}
```

### Integration Test

Just add a new game directory to `installers/` and it will be automatically picked up by `test-games.sh`.

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Test
on: [push, pull_request]
jobs:
  unit-tests:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Swift tests
        run: cd SecondChance && swift test
  
  integration-tests:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run integration tests
        run: ./test-games.sh --no-launch
```

## Troubleshooting

### "Test fixture not found" warnings
These are expected if you haven't created mock PE files in `TestFixtures/`. Tests will be skipped automatically.

### Integration tests timeout
Increase timeout: `./test-games.sh --timeout 60`

### Build failures
Check `test-output-*/build-log.txt` for details

### Game won't launch
Check game-specific logs in `test-output-*/{game-slug}/launch-log.txt`

## Performance

- **Unit tests**: ~2-5 seconds (all tests)
- **Integration test (one game)**: ~3-5 minutes (includes Wine prefix init)
- **Integration test (all games)**: ~2-3 hours (20+ games)

## Best Practices

1. **Run unit tests frequently** - They're fast and catch most issues
2. **Test one game integration** - Before committing changes
3. **Full test suite** - Before releases or major changes
4. **Use --quick flag** - When iterating on test script itself
5. **Check HTML reports** - Easier to review than console output

## Future Enhancements

- [ ] Create proper mock PE executables with metadata
- [ ] Add ScummVM game testing
- [ ] Add Steam game detection testing
- [ ] Performance benchmarking
- [ ] Memory leak detection
- [ ] Automated screenshot comparison
- [ ] Test parallelization
