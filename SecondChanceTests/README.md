# Testing Framework for Second Chance

This directory contains a comprehensive testing framework for the Second Chance application.

## Quick Start

### Run Swift Unit Tests
```bash
# In Xcode: Cmd+U to run all tests
# Or from command line:
cd SecondChance
swift test
```

### Run Integration Tests (All Games)
```bash
# Test all games (takes a long time!)
./test-all-games.sh

# Test specific game
./test-all-games.sh scarlet-hand

# Quick test (skip rebuild)
./test-all-games.sh --quick

# Install only (don't launch)
./test-all-games.sh --no-launch
```

## Test Structure

### Swift Testing (`SecondChanceTests/`)

**Unit tests** using the modern Swift Testing framework:

- ✅ **GameDetectorTests.swift** - Tests game detection logic
  - Parameterized tests for all game fingerprints
  - Case insensitivity testing
  - Alternate code detection (STFD, CAP, GTH, etc.)
  - Unknown fingerprint handling

- ✅ **GameInstallerTests.swift** - Tests installer automation
  - MSI, InstallShield, and Inno Setup argument generation
  - Silent vs interactive mode testing
  - Installer type detection logic

- ✅ **ExiftoolServiceTests.swift** - Tests exiftool integration
  - Singleton pattern verification
  - Path resolution
  - Property extraction
  - Error handling

**Features:**
- 🚀 **Fast** - Unit tests run in seconds
- 📊 **Parameterized** - Test multiple cases with one test definition
- 🎯 **Focused** - Test individual components in isolation
- ⏭️ **Skip support** - Tests requiring fixtures are skipped if not present

### Bash Integration Tests (`test-all-games.sh`)

**End-to-end testing** with real game installers:

1. Builds SecondChance app
2. Iterates through all games in `installers/` directory
3. Tests game detection from disk
4. Tests automated installation (silent + interactive retry)
5. Verifies wrapper app creation
6. Tests game launch with timeout
7. Captures logs and screenshots
8. Generates JSON and HTML reports

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
./test-all-games.sh
```

**Test specific game:**
```bash
./test-all-games.sh secrets-can-kill
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
./test-all-games.sh scarlet-hand

# 3. Full regression test before release
./test-all-games.sh
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

Just add a new game directory to `installers/` and it will be automatically picked up by `test-all-games.sh`.

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
        run: ./test-all-games.sh --no-launch
```

## Troubleshooting

### "Test fixture not found" warnings
These are expected if you haven't created mock PE files in `TestFixtures/`. Tests will be skipped automatically.

### Integration tests timeout
Increase timeout: `./test-all-games.sh --timeout 60`

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
