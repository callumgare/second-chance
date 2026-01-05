# Running Tests Without Xcode Project Setup

The test files are created but need to be integrated into Xcode. Here are your options:

## Option 1: Add Tests to Xcode (Recommended)

1. **Open Xcode project:**
   ```bash
   open SecondChance.xcodeproj
   ```

2. **Create test target:**
   - File → New → Target
   - Choose "Unit Testing Bundle"
   - Name: `SecondChanceTests`
   - Click Finish

3. **Add test files to target:**
   - Select all `.swift` files in `SecondChanceTests/` directory
   - In File Inspector (right sidebar), check the `SecondChanceTests` target

4. **Add Swift Testing package:**
   - File → Add Package Dependencies
   - Enter: `https://github.com/apple/swift-testing`
   - Add to `SecondChanceTests` target

5. **Run tests:**
   - Press `Cmd+U` to run all tests
   - Or: Product → Test

## Option 2: Run via xcodebuild (No Manual Setup)

You can run tests via command line without opening Xcode:

```bash
cd SecondChance

# Build and run tests
xcodebuild test \
  -scheme SecondChance \
  -destination 'platform=macOS'
```

This will automatically discover and run the test files.

## Option 3: Use Integration Tests Only

The integration test framework is ready to use immediately without any Xcode setup:

```bash
# Test one game
./test-all-games.sh secrets-can-kill-remastered

# Test all games
./test-all-games.sh
```

## Quick Test Run

To verify the integration test framework works:

```bash
# Quick test (if you have a game installer)
./run-tests.sh quick secrets-can-kill-remastered
```

## Next Steps

1. **Add test target to Xcode** (5 minutes) - Enables `Cmd+U` testing
2. **Run integration tests** (ready now) - Tests complete installation flow

See [SecondChanceTests/README.md](SecondChanceTests/README.md) for full documentation.
