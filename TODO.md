# TODO: Completing the Swift Implementation

This document tracks what still needs to be done to have a fully functional Second Chance app.

## Critical (Required for Basic Functionality)

- [ ] **Bundle Wine Framework**
  - [ ] Obtain Wine/CrossOver framework for macOS
  - [ ] Add to Xcode project as bundled resource
  - [ ] Update WrapperBuilder to use bundled Wine
  - [ ] Test Wine execution from bundle

- [ ] **Create Game Wrapper Launcher**
  - [ ] Port entrypoint.sh to Swift
  - [ ] Handle game executable launching
  - [ ] Implement Steam launch modes (direct, with steam, silent steam)
  - [ ] Add crash handling and logging
  - [ ] Bundle as separate executable in wrapper

- [ ] **Test End-to-End Installation**
  - [ ] Test with actual game disk
  - [ ] Verify Wine installation works
  - [ ] Confirm game launches from created wrapper
  - [ ] Test multi-disk games
  - [ ] Validate save file paths

## High Priority (Important Features)

- [ ] **Complete Steam Integration**
  - [ ] Implement Steam client launch and wait
  - [ ] Detect when game is installed
  - [ ] Handle Steam login dialog
  - [ ] Detect Steam ID from game
  - [ ] Test DRM modes

- [ ] **Installer Answer Files**
  - [ ] Bundle installer answer files (.iss)
  - [ ] Implement silent installation
  - [ ] Handle custom InstallShield dialogs
  - [ ] Copy answer files to dev location after install

- [ ] **AutoIt Integration**
  - [ ] Bundle AutoIt interpreter
  - [ ] Copy automation scripts to wrapper
  - [ ] Run AutoIt for custom installer dialogs
  - [ ] Clean up AutoIt files after install

- [ ] **ScummVM Support**
  - [ ] Bundle ScummVM
  - [ ] Implement ScummVM game detection
  - [ ] Configure ScummVM for Nancy Drew games
  - [ ] Add ScummVM-specific settings

- [ ] **Error Handling Improvements**
  - [ ] Better error messages
  - [ ] Recovery suggestions
  - [ ] Installation logs
  - [ ] Debug mode with verbose output

## Medium Priority (Quality of Life)

- [ ] **UI Polish**
  - [ ] Add app icon
  - [ ] Improve animations
  - [ ] Add sound effects
  - [ ] Better progress visualization
  - [ ] Game-specific icons in wrapper apps

- [ ] **Preferences Panel**
  - [ ] Debug mode toggle
  - [ ] Cache management UI
  - [ ] Default save location
  - [ ] Wine version selection
  - [ ] Advanced settings

- [ ] **Documentation**
  - [ ] User guide
  - [ ] Troubleshooting guide
  - [ ] Video tutorials
  - [ ] API documentation with DocC
  - [ ] Code comments

- [ ] **Installer Path Detection**
  - [ ] Improve setup.exe finding logic
  - [ ] Handle different installer types
  - [ ] Support InstallShield variants
  - [ ] Add installer signature verification

## Low Priority (Nice to Have)

- [ ] **Game Library Management**
  - [ ] List all installed games
  - [ ] Quick launch from library
  - [ ] Game metadata display
  - [ ] Screenshots gallery
  - [ ] Play time tracking

- [ ] **Update System**
  - [ ] Check for Wine updates
  - [ ] Update existing wrappers
  - [ ] Game patch management
  - [ ] App auto-update

- [ ] **Cloud Features**
  - [ ] iCloud save sync
  - [ ] Settings sync
  - [ ] Achievement tracking
  - [ ] Social features

- [ ] **Advanced Caching**
  - [ ] Cache compression
  - [ ] Differential caching
  - [ ] Cache sharing/export
  - [ ] Cache verification

- [ ] **Localization**
  - [ ] Multi-language support
  - [ ] Localized game titles
  - [ ] Regional settings

## Testing & Quality

- [ ] **Unit Tests**
  - [ ] GameInfoProvider tests
  - [ ] GameDetector tests
  - [ ] CacheManager tests
  - [ ] WineManager tests
  - [ ] WrapperBuilder tests

- [ ] **Integration Tests**
  - [ ] Full installation flow
  - [ ] Cache restoration
  - [ ] Steam integration
  - [ ] Error scenarios

- [ ] **UI Tests**
  - [ ] Welcome flow
  - [ ] Installation progress
  - [ ] Error handling
  - [ ] Settings panel

- [ ] **Performance Tests**
  - [ ] Installation time
  - [ ] Cache efficiency
  - [ ] Memory usage
  - [ ] Wrapper launch time

## Code Quality

- [ ] **Refactoring**
  - [ ] Extract reusable components
  - [ ] Simplify complex methods
  - [ ] Improve naming
  - [ ] Add protocol abstractions

- [ ] **Documentation**
  - [ ] Add doc comments to all public APIs
  - [ ] Create DocC documentation
  - [ ] Add inline code comments
  - [ ] Update README with examples

- [ ] **Error Handling**
  - [ ] Consistent error types
  - [ ] Better error messages
  - [ ] Recovery mechanisms
  - [ ] Logging infrastructure

## Platform Features

- [ ] **macOS Integration**
  - [ ] Handoff support
  - [ ] Quick Actions
  - [ ] Spotlight integration
  - [ ] Touch Bar support
  - [ ] Dark mode refinements

- [ ] **Accessibility**
  - [ ] VoiceOver support
  - [ ] Keyboard navigation
  - [ ] High contrast mode
  - [ ] Accessibility labels

- [ ] **Sandboxing**
  - [ ] Review sandbox entitlements
  - [ ] Test with App Sandbox enabled
  - [ ] Minimize required permissions
  - [ ] Add privacy descriptions

## Distribution

- [ ] **Packaging**
  - [ ] Code signing
  - [ ] Notarization
  - [ ] DMG creation
  - [ ] Installer package

- [ ] **App Store**
  - [ ] Review guidelines compliance
  - [ ] App Store metadata
  - [ ] Screenshots
  - [ ] Promo materials

- [ ] **Open Source**
  - [ ] License files
  - [ ] Contribution guidelines
  - [ ] Issue templates
  - [ ] CI/CD setup

## Known Issues to Fix

1. **Wine Framework Path**: Currently hardcoded, needs to be bundled properly
2. **Steam Detection**: Game detection after Steam install incomplete
3. **Progress Accuracy**: Progress percentages are estimates
4. **Cache Validation**: Need better validation of cached wrappers
5. **Error Recovery**: Some errors leave wrapper in bad state
6. **Memory Usage**: Large game copies could be optimized
7. **Disk Space**: Should check available space before installation

## Performance Optimizations

- [ ] Async file operations
- [ ] Streaming file copies
- [ ] Parallel disk operations
- [ ] Memory-mapped file I/O
- [ ] Background processing
- [ ] Cache preloading

## Security

- [ ] Input validation
- [ ] Path traversal prevention
- [ ] Executable verification
- [ ] Secure Wine configuration
- [ ] Privacy compliance
- [ ] Data encryption (if needed)

## Compatibility

- [ ] Test on macOS 13.0+
- [ ] Test on Intel and Apple Silicon
- [ ] Test with different Wine versions
- [ ] Test with various game versions
- [ ] Test with different disk formats

## Migration from Bash

- [ ] Side-by-side testing with bash version
- [ ] Feature parity verification
- [ ] Performance comparison
- [ ] User migration guide
- [ ] Deprecation timeline

## Project Status

### ✅ Completed
- Core architecture
- Models and data structures
- Game information database
- Basic game detection
- Wine manager framework
- Wrapper builder framework
- Installation orchestration
- SwiftUI interface
- Progress tracking
- Improved caching system
- Documentation structure

### 🚧 In Progress
- Wine framework integration
- Game wrapper launcher
- End-to-end testing

### ⏳ Not Started
- Steam integration
- ScummVM support
- Preferences UI
- Game library
- Distribution

## Timeline Estimate

| Phase | Items | Estimated Time |
|-------|-------|---------------|
| Critical | 5 items | 2-3 weeks |
| High Priority | 20 items | 4-6 weeks |
| Medium Priority | 15 items | 3-4 weeks |
| Low Priority | 20 items | 6-8 weeks |
| Testing & Quality | 15 items | 2-3 weeks |
| Distribution | 10 items | 1-2 weeks |

**Total: ~3-6 months for full completion**

## Next Steps (Immediate)

1. Bundle Wine framework in project
2. Test basic disk installation
3. Create game launcher script in Swift
4. Verify game actually runs
5. Fix any critical issues found
6. Implement installer answer file support
7. Test with multiple games
8. Complete Steam integration
9. Add ScummVM support
10. Polish UI and add preferences

## Notes

- Some features from bash may not be needed in Swift version
- Can ship MVP with just disk installation working
- Steam and ScummVM can be added in updates
- Focus on core functionality first, polish later
- Get user feedback early and iterate

---

**Last Updated**: December 31, 2025
**Status**: Initial Swift implementation complete, testing phase next
