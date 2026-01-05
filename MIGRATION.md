# Migration Guide: Bash to Swift

This guide explains how the bash implementation has been rewritten in Swift and how to migrate.

## Architecture Comparison

### Bash Implementation
```
second-chance-app/
├── build.sh                           # Build Platypus app
├── wrapper-creator.sh                 # Main installation logic
├── game-titles-info.sh               # Game database
├── lib/
│   ├── support.sh                    # Helper functions
│   └── wrapper-caching.sh            # Caching system
└── shared/
    ├── applescript.sh                # UI dialogs
    ├── wine-lib.sh                   # Wine management
    └── utils.sh                      # Utilities
```

### Swift Implementation
```
SecondChance/
└── SecondChance/
    ├── SecondChanceApp.swift         # App entry point
    ├── Models/                        # Data structures
    ├── Views/                         # SwiftUI UI
    ├── ViewModels/                    # UI logic
    ├── Services/                      # Business logic
    └── Utilities/                     # Helpers
```

## Key Mappings

### Main Logic Flow

| Bash File | Swift Equivalent | Notes |
|-----------|------------------|-------|
| `wrapper-creator.sh::main()` | `GameInstaller.installFrom*()` | Split into separate methods per source |
| `wrapper-creator.sh::setup_base_wrapper_app()` | `WrapperBuilder.createBaseWrapper()` | Async/await instead of sequential |
| `wrapper-creator.sh::detect_game_slug()` | `GameDetector.detectGame()` | Type-safe with enums |

### Game Database

| Bash | Swift | Improvements |
|------|-------|-------------|
| Shell variables (`game_slug__prop_name`) | `GameInfo` struct | Type-safe, auto-complete |
| String interpolation for lookup | `GameInfoProvider.gameInfo(for:)` | Compile-time safety |
| Manual parsing | Codable protocols | JSON serialization |

### Wine Management

| Bash Function | Swift Method | Changes |
|--------------|--------------|---------|
| `run_with_wine()` | `WineManager.runWine()` | Async, better error handling |
| `create_wine_prefix()` | `WineManager.createWinePrefix()` | Promise-based |
| `mount_dir_into_wine_env()` | `WineManager.mountDirectory()` | Simplified parameters |

### Caching System

The caching system has been completely redesigned:

#### Bash Implementation
```bash
# Simple directory copying
cache_dir="$tmp_dir/wrapper-cache"
cp -r "$wrapper_path" "$cache_dir/stage-name"
```

Issues:
- No metadata
- Manual restoration
- Hard to track what's cached
- No validation

#### Swift Implementation
```swift
// Rich metadata and validation
try cacheManager.saveCache(
    wrapperPath: wrapperPath,
    stage: .diskGameInstallerCopied,
    gameSlug: gameSlug,
    installationType: .disk
)

// Automatic validation
if let metadata = try cacheManager.restoreCache(
    stage: .diskGameInstallerCopied, 
    to: destinationPath
) {
    if metadata.gameSlug != currentGame {
        throw WrapperError.cachedGameMismatch
    }
}
```

Benefits:
- JSON metadata with timestamps
- Automatic validation
- Size tracking
- Cache management UI (future)
- Type-safe stages

### UI/Dialogs

| Bash (AppleScript) | Swift (SwiftUI) | Advantages |
|-------------------|-----------------|------------|
| `show_button_select_dialog()` | Native SwiftUI views | Better UX, animations |
| `show_folder_selection_dialog()` | `NSOpenPanel` in Swift | Async/await, type-safe |
| Progress via stdout | `@Published` properties | Real-time reactive UI |

## Code Examples

### Game Detection

**Bash:**
```bash
detect_game_slug() {
    local install_action="$1"
    local source_path="$2"
    
    if [ "$install_action" == "disk" ]; then
        volume_name=$(basename "$source_path")
        # String matching...
        if [[ "$volume_name" =~ "Blackmoor" ]]; then
            echo "blackmoor-manor"
        fi
    fi
}
```

**Swift:**
```swift
func detectGame(fromDisk diskPath: URL) async throws -> String {
    let volumeName = diskPath.lastPathComponent.lowercased()
    return detectFromVolumeName(volumeName)
}

private func detectFromVolumeName(_ name: String) -> String {
    if name.contains("blackmoor") {
        return "blackmoor-manor"
    }
    // ... pattern matching with early returns
    return "unknown"
}
```

### Progress Tracking

**Bash:**
```bash
echo "PROGRESS:50" >&4
echo "DETAILS:Installing game..." >&4
```

**Swift:**
```swift
@Published var currentState: InstallationState = .installingGame
// Automatically updates UI via Combine
```

### Error Handling

**Bash:**
```bash
if ! [ -f "$game_exe_path" ]; then
    show_alert "Error: Game executable not found"
    exit 1
fi
```

**Swift:**
```swift
guard fileManager.fileExists(atPath: gameExePath.path) else {
    throw InstallationError.gameExecutableNotFound
}
// Automatic error propagation and user-friendly presentation
```

## Testing Strategy

### Bash
- Manual testing required
- Hard to automate
- No unit tests

### Swift
- Unit tests for all services
- UI tests with XCTest
- SwiftUI previews for rapid iteration
- Mock objects for testing

Example test:
```swift
func testGameDetection() async throws {
    let detector = GameDetector.shared
    let mockDiskURL = URL(fileURLWithPath: "/Volumes/Blackmoor Manor")
    
    let gameSlug = try await detector.detectGame(fromDisk: mockDiskURL)
    XCTAssertEqual(gameSlug, "blackmoor-manor")
}
```

## Performance Improvements

1. **Parallel Operations**: Swift's async/await allows concurrent operations
2. **Memory Efficiency**: No subprocess overhead
3. **Startup Time**: Native app vs. bash script execution
4. **Caching**: Smarter caching reduces repeated work

## Development Workflow

### Bash
1. Edit shell script
2. Rebuild Platypus app
3. Run app
4. Debug with echo statements

### Swift
1. Edit in Xcode
2. Instant compilation feedback
3. Run with debugger
4. Breakpoints, variable inspection
5. SwiftUI previews for UI

## Migration Checklist

- [x] Core models and data structures
- [x] Game database (GameInfoProvider)
- [x] Game detection logic
- [x] Wine management
- [x] Wrapper creation
- [x] Installation orchestration
- [x] Improved caching system
- [x] SwiftUI interface
- [x] Progress tracking
- [x] Error handling
- [ ] Steam integration (partial)
- [ ] ScummVM engine support
- [ ] Game wrapper launcher
- [ ] Installer answer file handling
- [ ] AutoIt script integration

## Next Steps

1. **Bundle Wine**: Add Wine framework to Xcode project resources
2. **Test Installation**: Verify disk-based installation works end-to-end
3. **Implement Steam**: Complete Steam installation flow
4. **Add ScummVM**: Implement ScummVM engine support
5. **Create Launcher**: Build the game wrapper launch mechanism in Swift
6. **Polish UI**: Add preferences, settings, about screen
7. **Add Tests**: Write unit and integration tests
8. **Documentation**: API documentation with DocC

## Maintaining Both Versions

During transition, you may want to keep both:

1. Keep bash scripts in `second-chance-app/` (legacy)
2. Swift version in `SecondChance/` (new)
3. Test Swift version thoroughly before deprecating bash
4. Create migration path for users

## Common Issues and Solutions

### Issue: Wine Framework Not Found
**Solution**: Bundle Wine framework in `SecondChance/Resources/wine/`

### Issue: Game Detection Fails
**Solution**: Check `GameDetector.swift` patterns and add game-specific logic

### Issue: Cache Not Working
**Solution**: Enable caching in `InstallationViewModel`:
```swift
viewModel.enableCaching = true
viewModel.stagesToRestore = [.base]
```

## Getting Help

- Read the main README.md
- Check Swift documentation comments
- Review SwiftUI preview code for examples
- Use Xcode's Quick Help (Option+Click)

## Contributing

When adding new features:
1. Follow Swift naming conventions
2. Add documentation comments
3. Write unit tests
4. Use SwiftUI previews
5. Update this migration guide
