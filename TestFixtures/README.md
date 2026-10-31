# Test Fixtures

This directory contains mock data for testing the SecondChance application without requiring actual game installer files.

## Structure

### scarlet-hand-disk/
Mock disk structure for "Secret of the Scarlet Hand" game:
- `autorun.inf` - Contains the game label
- `setup.ini` - Contains app name and product info
- `setup.exe` - Would normally contain Product Name metadata (not a real executable in tests)

### mock-installer/
Mock installer files for testing installer type detection:
- `setup.exe` - Mock InstallShield installer
- `setup.msi` - Mock MSI installer
- `inno-setup.exe` - Mock Inno Setup installer

## Windows programs and MSIs

The tests that read a Windows program's version info or an MSI's subject
(`WindowsExecutableTests`, `MSISummaryTests`) build their files byte by byte
in the test, so they need nothing here.

## Usage in Tests

Tests check if these fixtures exist before running. If they don't exist, the test is skipped:

```swift
@Test("Detect game from mock disk")
func detectFromMockDisk() async throws {
    let fixturesPath = URL(fileURLWithPath: "/path/to/TestFixtures")
    guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
        throw XCTSkip("Test fixture not found")
    }
    // ... test code
}
```

## Real Game Testing

For integration tests with real games, run `./sc test integration <game-slug>` — it uses actual installer files from the `installers/` directory.
