# Her Interactive store downloads: Windows installers and Mac (Cider) DMGs

*Implemented 2026-10-22. A frozen record of the plan as carried out, with
what each phase found and the decisions that changed on the way. For how Her
downloads work now, read [docs/her-download.md](../her-download.md).*

## Goal

Make Her Interactive's store a first-class source. It is the only place
some games can still be bought, and it sells them as Windows downloads, Mac
downloads, or both. Big Fish Games was to follow as a builder of its own,
reusing what this produced.

`HerDownloadWrappBuilder` already existed but was hidden behind a debug toggle
and half worked:

- It named the game from the filename alone.
- It never routed a ScummVM game, so Scarlet Hand (a ScummVM game) would have
  been installed under Wine and then had Wine stripped out.
- It never gave InstallShield an answer file, so every install was interactive.
- It accepted only `.exe`.

The Mac downloads no longer run on modern macOS.

## What the samples contained

Two downloads were examined, one of each kind.

- **Windows (Scarlet Hand):** an InstallShield 16 "Setup Launcher". Its
  version info says only "InstallShield", but it embeds a disc's `Disk1`,
  whose `setup.ini` (`Product=Nancy Drew: Secret of the Scarlet Hand`) and
  registry key are stored as plain text.
- **Mac (Trail of the Twister):** a UDIF DMG holding TransGaming's Cider
  installer. `installer/INSTALLDATA.tgz` is an unencrypted tar.gz of a
  finished Cider app, and the app's `c_drive/Program Files/Nancy Drew/Trail
  of the Twister` is the complete installed Windows game. Its `Info.plist`
  names the folder and the exe (`CedegaGameDir`, `CedegaGameName`). Cider's
  `system32` carries its own `ddraw.dll` and `d3d9.dll`, and its registry
  holds nothing for the game.

## Decisions made with the user

- Her Download ships visible on the welcome screen, and the debug toggle is
  removed.
- A download whose filename doesn't name the game is identified the way a
  disc is, by what is inside it, rather than with a picker.
- Mac downloads that aren't Cider builds are investigated, not just refused.

## Phase 0: the spike

Each check was made by hand under the bundled Wine before the code was
written.

1. **`setup.exe /extract_all:<dir>` unpacks the launcher in seconds.** It
   writes the files into a `Disk1` folder inside `<dir>`, which the first
   version of the code missed (see Testing).
2. **The disc's answer file can't be reused.** The download's wizard asks 5
   questions where the disc's asks 8, and the file is keyed on the product
   GUID, which differs. An answer file was recorded with `/r` by driving the
   wizard with a throwaway AutoIt script. It replays silently (`ResultCode=0`
   in 25 s) through the runner's existing InstallShield arguments.
3. **ScummVM detects the installed folder** (`nancy:nancy6`), even though it
   holds `Ciftree/CIFTREE.DAT` rather than the disc's `ciftree.dat`.
4. **No patches for a Cider build.** Twister's one patch is a 2010 updater
   for a GeForce 2/4 MX problem. It looks for an install its own installer
   registered, and the Cider build, from 2015, never ran one.

## As built

- **Detection:** `GameDetector.detectGame(fromHerInstaller:)` adds the
  `Product=` values and `SOFTWARE\Her Interactive\` names found in the binary,
  read in 4 MB chunks, to the filename. `detectGame(fromCiderPackage:)` uses
  the volume name and `tgInstall.plist`.
- **Windows:** `GameInstallerRunner.unpackInstallShieldLauncher` unpacks into
  `nancy-drew-installer/disk-1`, and `WrappBuildHelper.installAnswerFile` (now
  shared with the disc builder) copies `installer-answer-files/her-download/<slug>.iss`.
  The disc machinery then installs the game. Both engines install under Wine,
  and ScummVM is pointed at the installed folder. The unpacked installer is
  deleted afterwards.
- **Mac:** `ISOMounter` mounts the DMG with `-noverify`, since hdiutil's
  checksum took 37 s and gzip checks the payload anyway. `CiderPackage`
  extracts in one `tar` pass and moves the game to `Program Files (x86)`, the
  path the disc gives it. Any other DMG fails with
  `WrappBuildError.unsupportedMacDownload`.
- **Input:** `HER_INSTALLER_PATH` and the open panel take `.exe` or `.dmg`.
  `HER_INSTALLER_PATH` now counts as headless, and `CLIBuilder` requires it
  for a headless Her build, since without it the build would open a panel and
  hang.
- **`sc`:** `--from her-download`, `--source her-download`, and
  `HerDownloadInstallIntegrationTests`, which runs once per
  `installers/<slug>/her-download*.exe|.dmg`.

## What testing found

- **The unpack looked for `setup.exe` in the wrong place.** The first
  integration run "didn't unpack", fell back to the launcher's own wizard and
  waited on screen. `/extract_all` had put the files in `disk-1/Disk1`. The
  launcher now unpacks into `unpacked/` and the folder holding `setup.exe` is
  moved to `disk-1`.
- **The Cider game needed some of Cider's `system32` after all.**
  `Twister.exe` imports `MFC80.DLL`, which Wine doesn't provide and which a
  disc's installer installs. The game failed with `status c0000135`. The plan
  had left all of `system32` behind. Now the DLLs there with no Wine builtin
  are copied into the game's folder: the MFC runtimes, `atl71`, NVIDIA's Cg
  and `squish`. Every graphics and input DLL Cider has, Wine has too, so none
  of them comes over.
- **bsdtar fails on an `--include` that matches nothing**, so the DLL pattern
  is one case-insensitive glob rather than one per case.
- With both fixes, both downloads build, launch and quit cleanly under
  WrappPuppeteer.

## Left open

- **Answer files.** Only Scarlet Hand's download has one. Other Windows
  downloads install through their own wizard until one is recorded (the steps
  are in [her-download.md](../her-download.md#answer-files)), and a headless
  build of them fails.
- **Non-Cider Mac downloads (phase 4).** Which games' Mac downloads are Cider
  builds, and what the rest are, needs a sample of a later game's Mac
  download. They are refused with a message pointing to the Windows download.
- **Big Fish Games** is still to come, as its own builder. The binary
  fingerprinting, the answer-file primitive and `CiderPackage` are what it
  can reuse.
