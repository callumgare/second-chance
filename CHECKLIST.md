# Getting Started Checklist

Use this checklist to get the Second Chance Swift app up and running.

## ✅ What's Already Done

- [x] Xcode project created
- [x] All Swift source files implemented (18 files)
- [x] SwiftUI interface complete
- [x] Game database (30+ games)
- [x] Installation orchestration
- [x] Wine management framework
- [x] Caching system
- [x] Comprehensive documentation (6 guides)

## 📋 Critical Steps to Make It Work

### 1. Create the Xcode Project

**IMPORTANT:** The project file needs to be created using Xcode. Follow the detailed instructions in:

👉 **[SETUP.md](SETUP.md)** 👈

Quick summary:
1. Open Xcode
2. File > New > Project
3. Choose macOS > App > SwiftUI
4. Name it "SecondChance"
5. Add all the Swift files from SecondChance/ directory

- [ ] Followed SETUP.md instructions
- [ ] Project opens successfully in Xcode
- [ ] No build errors (should compile cleanly)
- [ ] All files are properly organized

### 2. Bundle Wine Framework

This is the most critical step!

#### Option A: From CrossOver
```bash
# Copy Wine from CrossOver installation
cp -r "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver" \
      "SecondChance/Resources/wine"
```

#### Option B: From Wineskin
```bash
# Extract from a Wineskin wrapper
cp -r "YourGame.app/Contents/SharedSupport/wine" \
      "SecondChance/Resources/wine"
```

#### Option C: Download Pre-built
- Download Wine for macOS
- Extract to `SecondChance/Resources/wine`

- [ ] Wine framework in correct location
- [ ] Directory structure: `Resources/wine/bin/wine`
- [ ] Wine executable exists
- [ ] Frameworks present in `wine/lib/`

### 3. Add Wine to Xcode

1. Drag `Resources/wine` folder into Xcode project
2. Check "Create folder references" (not "Create groups")
3. Add to target: Second Chance

- [ ] Wine folder visible in Xcode project navigator
- [ ] Shows as blue folder (folder reference)
- [ ] Included in build target

### 4. Test Compilation

Press `Cmd+B` to build

- [ ] Build succeeds with no errors
- [ ] Only warnings (if any) are non-critical
- [ ] App bundle created

### 5. First Run Test

Press `Cmd+R` to run

- [ ] App launches
- [ ] Welcome screen appears
- [ ] No crashes
- [ ] UI is responsive

### 6. Test UI Flow (Without Real Game)

- [ ] Click "Game Disk(s)" button
- [ ] File picker appears
- [ ] Cancel works
- [ ] Click "Her Download" button
- [ ] File picker appears
- [ ] Cancel works
- [ ] App doesn't crash

### 7. Prepare Test Environment

Create a mock game disk for testing:

```bash
# Create test disk structure
mkdir -p /tmp/TestNancyDrewDisk
touch /tmp/TestNancyDrewDisk/setup.exe
echo "[autorun]" > /tmp/TestNancyDrewDisk/autorun.inf
echo "open=setup.exe" >> /tmp/TestNancyDrewDisk/autorun.inf
```

- [ ] Test disk created
- [ ] Has setup.exe
- [ ] Has autorun.inf

### 8. Test Game Detection

Run app and select test disk

- [ ] Game detection runs
- [ ] Doesn't crash (may detect as "unknown")
- [ ] Progress indicator shows
- [ ] Can cancel installation

### 9. Test with Real Game (If Available)

If you have a Nancy Drew game disk or installer:

- [ ] Insert/mount game disk
- [ ] Run Second Chance app
- [ ] Select "Game Disk(s)"
- [ ] Select the disk
- [ ] Game is detected correctly
- [ ] Installation proceeds

### 10. Bundle Additional Resources

#### Installer Answer Files
```bash
# Copy from old implementation
cp second-chance-app/installer-answer-files/*.iss \
   SecondChance/Resources/installer-answer-files/
```

- [ ] Answer files copied
- [ ] Added to Xcode project
- [ ] Included in bundle

#### Winetricks
```bash
# Copy winetricks script
cp second-chance-app/build/winetricks \
   SecondChance/Resources/winetricks
chmod +x SecondChance/Resources/winetricks
```

- [ ] Winetricks script copied
- [ ] Made executable
- [ ] Added to project

#### AutoIt (if needed)
```bash
# Copy AutoIt
cp -r second-chance-app/build/autoit \
      SecondChance/Resources/autoit
```

- [ ] AutoIt copied
- [ ] Added to project

## 🧪 Testing Checklist

### Basic Functionality
- [ ] App launches successfully
- [ ] Welcome screen displays correctly
- [ ] Installation type selection works
- [ ] File/folder pickers work
- [ ] Progress display updates
- [ ] Error alerts appear correctly
- [ ] App can be quit normally

### Installation Flow (Disk)
- [ ] Select disk installation
- [ ] Pick game disk
- [ ] Game detected correctly
- [ ] Base wrapper created
- [ ] Disks copied successfully
- [ ] Game installs via Wine
- [ ] Game executable found
- [ ] Wrapper configured
- [ ] App saved successfully
- [ ] Wrapper can be opened
- [ ] Game launches from wrapper

### Installation Flow (Her Download)
- [ ] Select Her download
- [ ] Pick installer file
- [ ] Game detected correctly
- [ ] Wrapper created
- [ ] Installer runs
- [ ] Game installed
- [ ] App saved

### Caching (Development)
- [ ] Enable caching in code
- [ ] Cache saves successfully
- [ ] Cache restores correctly
- [ ] Multiple stages work
- [ ] Cache validation works

## 🐛 Troubleshooting

### Build Fails
- Check Wine framework is present
- Verify all files are added to target
- Clean build folder (`Cmd+Shift+K`)
- Restart Xcode

### Wine Not Found
- Verify path: `SecondChance/Resources/wine/bin/wine`
- Check file exists
- Verify permissions

### Game Detection Fails
- Check volume name/path
- Add patterns to `GameDetector.swift`
- Test with known games first

### Installation Hangs
- Check Wine server status
- Look at console logs
- Enable debug mode
- Check process list

## 📚 Reference Documentation

Before testing, read:
- [ ] [README.md](README.md) - Overview
- [ ] [QUICKSTART.md](QUICKSTART.md) - Developer guide
- [ ] [TODO.md](TODO.md) - What's not done

## 🎯 Success Criteria

Minimum viable product when:
- [x] App compiles without errors
- [ ] Wine framework bundled
- [ ] App launches successfully
- [ ] Game detection works for at least one game
- [ ] Can create a wrapper app
- [ ] Wrapper app can launch the game

## 📝 Notes

### Current Status
- **Code**: 100% complete
- **Wine Framework**: Needs to be added
- **Testing**: Not yet done
- **Distribution**: Not yet ready

### Known Limitations
- Steam integration incomplete
- ScummVM not implemented
- Game launcher needs testing
- Some games may need special handling

### Next Priorities
1. ✅ Get Wine bundled
2. ✅ Test with one game
3. ✅ Fix any critical issues
4. Add missing features
5. Test with more games
6. Polish UI
7. Prepare for distribution

## 🚀 When You're Ready

After completing this checklist:

1. **Test Thoroughly**: Try multiple games
2. **Document Issues**: Note what doesn't work
3. **Iterate**: Fix bugs and add features
4. **Polish**: Refine UI and UX
5. **Distribute**: Prepare for release

## ✨ Tips

- **Use SwiftUI Previews**: Fastest way to test UI
- **Enable Caching**: Speeds up testing dramatically
- **Check Console**: Logs show what's happening
- **Use Debugger**: Set breakpoints to trace issues
- **Test Incrementally**: Don't try everything at once

## 🆘 Getting Help

If stuck:
1. Check the documentation
2. Read code comments
3. Use Xcode's Quick Help (Option+Click)
4. Review [MIGRATION.md](MIGRATION.md) for bash equivalents
5. Check [TODO.md](TODO.md) for known issues

---

**Ready?** Start with step 1 and work through the checklist!

Good luck! 🎮🔍
