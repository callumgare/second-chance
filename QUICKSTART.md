# Quick Start Guide

Get up and running with the Second Chance Swift project quickly.

## Prerequisites

- macOS 13.0 or later
- Xcode 14.0 or later
- Basic familiarity with Swift and SwiftUI
- A Nancy Drew game disk or installer (for testing)

## Setup

### 1. Open the Project

```bash
cd SecondChance
open SecondChance.xcodeproj
```

### 2. Understand the Architecture

The project follows MVVM architecture:

```
Models ← Services ← ViewModels ← Views
```

- **Models**: Data structures (`GameInfo`, `CacheStage`, etc.)
- **Services**: Business logic (`WineManager`, `GameInstaller`, etc.)
- **ViewModels**: UI logic (`InstallationViewModel`)
- **Views**: SwiftUI interfaces (`WelcomeView`, `InstallationProgressView`)

### 3. Key Files to Know

| File | Purpose |
|------|---------|
| `SecondChanceApp.swift` | App entry point |
| `GameInfoProvider.swift` | Game database |
| `InstallationViewModel.swift` | Main UI coordinator |
| `WelcomeView.swift` | Start screen |
| `GameInstaller.swift` | Installation orchestration |

## Running the App

### Debug Mode

Press `Cmd+R` or click the Play button in Xcode.

The app will:
1. Show welcome screen
2. Wait for user to select installation type
3. Guide through installation process

### With Caching (Faster Development)

Enable caching to speed up testing:

```swift
// In InstallationViewModel.swift
init() {
    enableCaching = true
    stagesToRestore = [.base]
}
```

This caches the base wrapper so you don't rebuild it every time.

## Testing Individual Components

### Game Detection

```swift
let detector = GameDetector.shared
let gameSlug = try await detector.detectGame(
    fromDisk: URL(fileURLWithPath: "/Volumes/BlackmoorManor")
)
print("Detected: \(gameSlug)")
```

### Game Info Lookup

```swift
let provider = GameInfoProvider.shared
let game = provider.gameInfo(for: "blackmoor-manor")
print("Title: \(game.title)")
print("Disk Count: \(game.diskCount)")
```

### Cache Management

```swift
let cache = CacheManager.shared
cache.cachingEnabled = true

// List caches
let caches = cache.availableCaches()
for (stage, metadata) in caches {
    print("\(stage.displayName): \(metadata.gameSlug ?? "none")")
}

// Clear all
try cache.clearAllCaches()
```

## SwiftUI Previews

Each view has preview code for rapid iteration:

```swift
#Preview {
    WelcomeView()
        .environmentObject(InstallationViewModel())
        .frame(width: 700, height: 500)
}
```

Click the preview button (Canvas) in Xcode or press `Option+Cmd+Return`.

## Common Development Tasks

### Adding a New Game

1. Open `GameInfoProvider.swift`
2. Add to the `games` dictionary:

```swift
"new-game": GameInfo(
    id: "new-game",
    title: "New Game Title",
    diskCount: 1,
    internalGameExePath: "/Program Files/Game/game.exe"
)
```

3. Add detection patterns to `GameDetector.swift`:

```swift
private func detectFromVolumeName(_ name: String) -> String {
    // ... existing code ...
    if name.contains("new game") {
        return "new-game"
    }
    // ...
}
```

### Testing Installation Flow

1. Create a mock disk directory:
```bash
mkdir -p /tmp/MockGameDisk
touch /tmp/MockGameDisk/setup.exe
touch /tmp/MockGameDisk/autorun.inf
```

2. Run app and select that directory
3. Watch the flow in Xcode debugger

### Debugging Wine Issues

Enable debug output:

```swift
// In WineManager.swift
let process = Process()
process.arguments = arguments
// Add this:
print("Running: \(process.executableURL?.path ?? "") \(arguments.joined(separator: " "))")
```

### UI Tweaks

1. Open the view file (e.g., `WelcomeView.swift`)
2. Use SwiftUI preview to see changes live
3. Adjust spacing, colors, fonts as needed

## Project Structure

```
SecondChance/
├── SecondChance.xcodeproj/
│   └── project.pbxproj          # Xcode project file
└── SecondChance/
    ├── SecondChanceApp.swift    # Entry point
    │
    ├── Models/                  # Data structures
    │   ├── GameInfo.swift
    │   ├── InstallationType.swift
    │   ├── InstallationState.swift
    │   └── CacheStage.swift
    │
    ├── Views/                   # UI
    │   ├── ContentView.swift
    │   ├── WelcomeView.swift
    │   └── InstallationProgressView.swift
    │
    ├── ViewModels/              # UI Logic
    │   └── InstallationViewModel.swift
    │
    ├── Services/                # Business Logic
    │   ├── GameInfoProvider.swift
    │   ├── GameDetector.swift
    │   ├── GameInstaller.swift
    │   ├── WineManager.swift
    │   ├── WrapperBuilder.swift
    │   └── CacheManager.swift
    │
    ├── Utilities/               # Helpers
    │   ├── FileUtilities.swift
    │   ├── ProcessUtilities.swift
    │   └── ViewExtensions.swift
    │
    └── Resources/
        └── Assets.xcassets/
```

## Build Configuration

### Debug
- Full error checking
- Verbose logging
- Caching available
- Fast compilation

### Release
- Optimized
- Minimal logging
- No caching
- Signed

Switch with the scheme dropdown in Xcode toolbar.

## Useful Xcode Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+R` | Build and run |
| `Cmd+B` | Build only |
| `Cmd+.` | Stop running |
| `Cmd+/` | Toggle comment |
| `Cmd+Shift+O` | Open quickly |
| `Cmd+Shift+A` | Show actions |
| `Cmd+Option+[` | Move line up |
| `Cmd+Option+]` | Move line down |
| `Option+Click` | Quick help |
| `Cmd+Click` | Jump to definition |

## Debugging Tips

### Breakpoints

Click the line number gutter to add a breakpoint. App will pause there when running.

### Print Debugging

```swift
print("Debug: \(variable)")
```

Output appears in Xcode console.

### LLDB Console

When paused at breakpoint, use LLDB:

```lldb
(lldb) po variable           # Print object
(lldb) p variable           # Print value
(lldb) bt                   # Backtrace
(lldb) continue             # Resume
```

### View Debugging

While app is running, click the view debugging button (three squares) in Xcode. This shows the 3D view hierarchy.

## Common Issues

### "Wine framework not found"

**Solution**: The Wine framework needs to be bundled. For now, the app won't fully work without it. See TODO.md for status.

### "Game detection returns unknown"

**Solution**: Add detection patterns for your specific game in `GameDetector.swift`.

### Slow compilation

**Solution**: 
- Close previews if open
- Clean build folder: `Cmd+Shift+K`
- Restart Xcode

### Preview not working

**Solution**:
- Try `Option+Cmd+P` to refresh
- Check for syntax errors
- Restart Xcode

## Best Practices

### Code Style

- Use meaningful names
- Add documentation comments
- Keep functions small
- Use guard statements for early returns
- Prefer immutability (let over var)

### Error Handling

```swift
// Good
do {
    try performOperation()
} catch {
    print("Error: \(error.localizedDescription)")
}

// Better
do {
    try performOperation()
} catch let error as InstallationError {
    // Handle specific error
} catch {
    // Handle generic error
}
```

### Async/Await

```swift
// Prefer async/await over completion handlers
func loadData() async throws -> Data {
    // ...
}

// Call with await
Task {
    let data = try await loadData()
}
```

### SwiftUI

```swift
// Extract complex views
struct ComplexView: View {
    var body: some View {
        VStack {
            HeaderView()
            ContentView()
            FooterView()
        }
    }
}
```

## Getting Help

1. **Documentation**: Read the doc comments (Option+Click)
2. **README.md**: Architecture overview
3. **MIGRATION.md**: Comparison with bash version
4. **TODO.md**: What's not done yet
5. **Code**: Read the implementation
6. **Ask**: Open an issue or discussion

## Next Steps

Once you're comfortable:

1. Read [MIGRATION.md](MIGRATION.md) to understand the bash → Swift conversion
2. Check [TODO.md](TODO.md) to see what needs to be done
3. Pick a task and start coding!
4. Write tests for your changes
5. Submit a pull request

## Resources

- [Swift Documentation](https://docs.swift.org)
- [SwiftUI Tutorials](https://developer.apple.com/tutorials/swiftui)
- [Wine on macOS](https://wiki.winehq.org/MacOS)
- [Async/Await Guide](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)

Happy coding! 🎮🔍
