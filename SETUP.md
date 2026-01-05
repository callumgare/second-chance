# Setup Instructions - Creating the Xcode Project

The Xcode project file needs to be created properly using Xcode itself. Follow these steps:

## Quick Setup (5 minutes)

### Step 1: Create New Project in Xcode

1. Open Xcode
2. Select **File > New > Project** (or Cmd+Shift+N)
3. Choose **macOS** tab
4. Select **App** template
5. Click **Next**

### Step 2: Configure Project

**Product Name:** `SecondChance`  
**Team:** Your team (or leave as None for now)  
**Organization Identifier:** `com.secondchance`  
**Bundle Identifier:** `com.secondchance.SecondChance`  
**Interface:** **SwiftUI**  
**Language:** **Swift**  
**Storage:** None (uncheck Core Data, CloudKit, etc.)  
**Testing:** Can leave enabled or disable

Click **Next**

### Step 3: Save Location

**IMPORTANT:** Save the project to:
```
/Users/callumgare/repos/second-chance/
```

This will create:
```
/Users/callumgare/repos/second-chance/SecondChance/SecondChance.xcodeproj
```

Click **Create**

### Step 4: Remove Default Files

Xcode will create some default files. Delete these:

1. In Project Navigator, select and **delete** (Move to Trash):
   - `SecondChanceApp.swift` (the default one)
   - `ContentView.swift` (the default one)  
   - `Assets.xcassets` (the default one)
   - Any test files if created

### Step 5: Add Your Swift Files

Now add all the files we created:

1. **Right-click** on the `SecondChance` folder in Project Navigator
2. Select **Add Files to "SecondChance"...**
3. Navigate to `/Users/callumgare/repos/second-chance/SecondChance/SecondChance/`
4. Select **all the Swift files and folders** in that directory:
   - SecondChanceApp.swift
   - Models/
   - Views/
   - ViewModels/
   - Services/
   - Utilities/
   - Resources/
   - SecondChance.entitlements

5. **IMPORTANT:** Check these options:
   - ✅ **Copy items if needed** (UNCHECKED - don't copy, use reference)
   - ✅ **Create groups** (selected)
   - ✅ **Add to targets: SecondChance** (checked)

6. Click **Add**

### Step 6: Configure Project Settings

1. Select the **SecondChance** project in navigator (top item)
2. Select the **SecondChance** target
3. Go to **Signing & Capabilities** tab
4. Select your team or choose "Sign to Run Locally"

### Step 7: Configure Build Settings

1. Still in project settings, go to **General** tab
2. Set **Minimum Deployments** to **macOS 13.0**
3. Go to **Info** tab
4. Add this entry:
   - Key: `NSMicrophoneUsageDescription`
   - Value: `Steam requires access to the microphone`

### Step 8: Set Entitlements

1. Select **SecondChance** target
2. Go to **Signing & Capabilities**
3. Click **+ Capability**
4. Add **App Sandbox**
5. Under App Sandbox, enable:
   - ✅ User Selected Files (Read/Write)
   - ✅ Downloads Folder (Read/Write)  
   - ✅ Audio Input
   - ✅ Outgoing Connections (Client)

Or manually set the entitlements file:
- Go to **Build Settings**
- Search for "entitlements"
- Set **Code Signing Entitlements** to: `SecondChance/SecondChance.entitlements`

### Step 9: Build and Run

1. Press **Cmd+B** to build
2. Fix any errors (there shouldn't be any)
3. Press **Cmd+R** to run

The app should launch with the welcome screen!

## Alternative: Import Existing Files

If you already have files in the directory:

1. Create new project as above
2. Close Xcode
3. Open Finder
4. Navigate to the new project location
5. Replace the contents of `SecondChance/` folder with your existing Swift files
6. Reopen project in Xcode
7. Clean build folder (Cmd+Shift+K)
8. Build (Cmd+B)

## Troubleshooting

### "Cannot find 'X' in scope"
- Make sure all files are added to the target
- Check that no files are duplicated
- Clean build folder and rebuild

### Files appear red in navigator
- Files are referenced but not found
- Remove them from project (not trash)
- Re-add using "Add Files"

### "Missing required module"
- Make sure SwiftUI is imported in files that need it
- Check deployment target is macOS 13.0+

### Build errors about InfoPlist
- Xcode should auto-generate Info.plist
- If not, don't manually create one - let Xcode handle it

## Quick Verification

After setup, your project structure should look like:

```
SecondChance/
├── SecondChance.xcodeproj/
└── SecondChance/
    ├── SecondChanceApp.swift
    ├── SecondChance.entitlements
    ├── Models/
    │   ├── GameInfo.swift
    │   ├── InstallationType.swift
    │   ├── InstallationState.swift
    │   └── CacheStage.swift
    ├── Views/
    │   ├── ContentView.swift
    │   ├── WelcomeView.swift
    │   └── InstallationProgressView.swift
    ├── ViewModels/
    │   └── InstallationViewModel.swift
    ├── Services/
    │   ├── GameInfoProvider.swift
    │   ├── GameDetector.swift
    │   ├── GameInstaller.swift
    │   ├── WineManager.swift
    │   ├── WrapperBuilder.swift
    │   └── CacheManager.swift
    ├── Utilities/
    │   ├── FileUtilities.swift
    │   ├── ProcessUtilities.swift
    │   └── ViewExtensions.swift
    └── Resources/
        └── Assets.xcassets/
```

All files should show up in Xcode's project navigator with no red/missing indicators.

## Next Steps

Once the project builds successfully:

1. Read [CHECKLIST.md](CHECKLIST.md) for what to do next
2. Bundle the Wine framework
3. Test with a real game
4. Start implementing missing features

---

**Note:** I apologize for the initial project file being invalid. Xcode project files are complex binary plists that are best created by Xcode itself. This manual setup ensures you get a proper, working project.
