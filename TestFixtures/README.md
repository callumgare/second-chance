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

## Creating Mock Executables

Since tests need actual PE (Windows executable) files for exiftool to parse, you can create minimal mock executables:

```bash
# On macOS with Wine installed
cat > test.c <<EOF
int main() { return 0; }
EOF

# Compile with mingw (if available)
x86_64-w64-mingw32-gcc test.c -o setup.exe

# Or download a minimal PE file and edit metadata with exiftool
```

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

For integration tests with real games, the bash script `test-all-games.sh` uses actual installer files from the `installers/` directory.
