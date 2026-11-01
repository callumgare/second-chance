# Test Fixtures

This directory contains mock data for testing the SecondChance application without requiring actual game installer files.

## Structure

### scarlet-hand-disk/
Mock disc for "Secret of the Scarlet Hand", which `GameDetectorFixtureTests`
recognises from its text files alone:
- `autorun.inf` - Contains the game label
- `setup.ini` - Contains app name and product info

## Windows programs and MSIs

The tests that read a Windows program's version info or an MSI's subject
(`WindowsExecutableTests`, `MSISummaryTests`) build their files byte by byte
in the test, so they need nothing here; nor do the installer-type tests in
`GameInstallerTests`, which write their few bytes to a temporary file.

## Usage in Tests

Find the folder from `TestPaths.repoRoot`, never from an absolute path, and
`#require` that a committed fixture exists, so a missing one fails rather than
passing without testing anything:

```swift
let disc = TestPaths.repoRoot.appendingPathComponent("TestFixtures/scarlet-hand-disk")
try #require(FileManager.default.fileExists(atPath: disc.path))
```

## Real Game Testing

For integration tests with real games, run `./sc test integration <game-slug>` — it uses actual installer files from the `installers/` directory.
