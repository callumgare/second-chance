# Visual Setup Guide

## Creating the Xcode Project - Step by Step

### Step 1: Open Xcode and Create New Project

![Step 1](https://via.placeholder.com/800x400/4A90E2/FFFFFF/?text=File+%3E+New+%3E+Project)

In Xcode:
- Click **File > New > Project** (or press `Cmd+Shift+N`)

---

### Step 2: Choose App Template

![Step 2](https://via.placeholder.com/800x400/4A90E2/FFFFFF/?text=macOS+%3E+App)

1. Click the **macOS** tab at the top
2. Select **App**
3. Click **Next**

---

### Step 3: Configure Project

![Step 3](https://via.placeholder.com/800x400/4A90E2/FFFFFF/?text=Configure+Project)

Fill in these fields:

```
Product Name:           SecondChance
Team:                   (Your team or None)
Organization Identifier: com.secondchance
Bundle Identifier:      com.secondchance.SecondChance
Interface:              SwiftUI  ← IMPORTANT
Language:               Swift    ← IMPORTANT
```

**Uncheck all boxes** (Core Data, CloudKit, Tests, etc.)

Click **Next**

---

### Step 4: Save Location

![Step 4](https://via.placeholder.com/800x400/4A90E2/FFFFFF/?text=Save+to+Directory)

**CRITICAL:** Navigate to:
```
/Users/callumgare/repos/second-chance/
```

The project will create a `SecondChance` folder here.

Click **Create**

---

### Step 5: Project Created!

You should see:

```
SecondChance
├── SecondChance (folder)
│   ├── SecondChanceApp.swift (default file)
│   ├── ContentView.swift (default file)
│   └── Assets.xcassets
└── SecondChance.xcodeproj
```

---

### Step 6: Remove Default Files

![Step 6](https://via.placeholder.com/800x400/E24A4A/FFFFFF/?text=Delete+Default+Files)

In the Project Navigator (left sidebar):

Right-click and **Delete** (Move to Trash):
- ❌ `SecondChanceApp.swift` (the default one Xcode created)
- ❌ `ContentView.swift` (the default one Xcode created)
- ❌ `Assets.xcassets` (we have our own)

---

### Step 7: Add Your Swift Files

![Step 7](https://via.placeholder.com/800x400/4AE251/FFFFFF/?text=Add+Files)

1. Right-click on **SecondChance** folder in Project Navigator
2. Choose **Add Files to "SecondChance"...**
3. Navigate to:
   ```
   /Users/callumgare/repos/second-chance/SecondChance/SecondChance/
   ```
4. Select **ALL** the files and folders:
   - SecondChanceApp.swift
   - SecondChance.entitlements
   - Models/
   - Views/
   - ViewModels/
   - Services/
   - Utilities/
   - Resources/

5. **IMPORTANT OPTIONS:**
   - ❌ **UNCHECK** "Copy items if needed"
   - ✅ **CHECK** "Create groups"
   - ✅ **CHECK** "Add to targets: SecondChance"

6. Click **Add**

---

### Step 8: Verify File Structure

Your Project Navigator should now show:

```
SecondChance
├── SecondChance
│   ├── SecondChanceApp.swift ✓
│   ├── SecondChance.entitlements ✓
│   ├── Models ✓
│   │   ├── GameInfo.swift
│   │   ├── InstallationType.swift
│   │   ├── InstallationState.swift
│   │   └── CacheStage.swift
│   ├── Views ✓
│   │   ├── ContentView.swift
│   │   ├── WelcomeView.swift
│   │   └── InstallationProgressView.swift
│   ├── ViewModels ✓
│   │   └── InstallationViewModel.swift
│   ├── Services ✓
│   │   ├── GameInfoProvider.swift
│   │   ├── GameDetector.swift
│   │   ├── GameInstaller.swift
│   │   ├── WineManager.swift
│   │   ├── WrapperBuilder.swift
│   │   └── CacheManager.swift
│   ├── Utilities ✓
│   │   ├── FileUtilities.swift
│   │   ├── ProcessUtilities.swift
│   │   └── ViewExtensions.swift
│   └── Resources ✓
│       └── Assets.xcassets
└── SecondChance.xcodeproj
```

**All files should be black** (not red/missing)

---

### Step 9: Configure Entitlements

![Step 9](https://via.placeholder.com/800x400/4A90E2/FFFFFF/?text=Signing+%26+Capabilities)

1. Click **SecondChance** project (top of navigator)
2. Select **SecondChance** target
3. Go to **Signing & Capabilities** tab
4. Find **Code Signing Entitlements** and set to:
   ```
   SecondChance/SecondChance.entitlements
   ```

Or add App Sandbox capability:
- Click **+ Capability**
- Add **App Sandbox**
- Enable:
  - ✅ User Selected Files (Read/Write)
  - ✅ Downloads Folder (Read/Write)
  - ✅ Audio Input
  - ✅ Outgoing Connections (Client)

---

### Step 10: Build!

![Step 10](https://via.placeholder.com/800x400/4AE251/FFFFFF/?text=Press+Cmd%2BB)

Press **Cmd+B** to build

You should see:
```
Build Succeeded ✓
```

If you get errors, check:
- All files are added to target
- No duplicate files
- Deployment target is macOS 13.0+

---

### Step 11: Run!

![Step 11](https://via.placeholder.com/800x400/4AE251/FFFFFF/?text=Press+Cmd%2BR)

Press **Cmd+R** to run

The app should launch with the welcome screen! 🎉

---

## Troubleshooting

### Files appear red in navigator
→ Remove and re-add them, making sure to uncheck "Copy items"

### "Cannot find X in scope" errors
→ Make sure all files are checked under "Target Membership"

### Build takes forever
→ Close and reopen Xcode, then clean (Cmd+Shift+K)

### App crashes immediately
→ Check entitlements file is properly set

---

## Next Steps

Once built successfully:

1. ✅ Read [CHECKLIST.md](CHECKLIST.md)
2. ✅ Add Wine framework to Resources/
3. ✅ Test with a game disk
4. ✅ Celebrate! 🎉

---

## Still Stuck?

Check the detailed instructions in [SETUP.md](SETUP.md)
