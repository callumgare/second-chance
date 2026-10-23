# Her Interactive downloads

Her Interactive's store sells most of the classic games as a Windows download,
and some as a Mac download too. It is the only place some of them can still be
bought (Stay Tuned for Danger isn't on Steam). Second Chance builds a wrapp
from either: `HerDownloadWrappBuilder`, the **Her Download** source.

The two arrive as quite different files, and the builder takes a separate path
for each:

| Download | File | What is in it | How the wrapp gets the game |
| --- | --- | --- | --- |
| Windows | `.exe` | An InstallShield launcher with a disc's `Disk1` inside | Unpack it, then install as from a disc |
| Mac | `.dmg` | TransGaming's Cider installer; its payload is the installed Windows game inside a Cider app | Take the game's folder out of the Cider app |

## Windows downloads

The downloads seen so far are InstallShield "Setup Launcher" executables
(InstallShield 16, built in 2010). The launcher carries a whole `Disk1`
(`setup.exe`, `setup.ini`, `data1.cab`, `data2.cab`, …), and
`setup.exe /extract_all:<dir>` writes it out without installing anything.
Under Wine this takes a few seconds.

`/extract_all` writes the files into a `Disk1` folder inside the directory it
is given. `GameInstallerRunner.unpackInstallShieldLauncher` unpacks into
`drive_c/nancy-drew-installer/unpacked` and moves the folder holding
`setup.exe` to `nancy-drew-installer/disk-1`, which is where a disc's files go. From
there the install is the disc's: `installGameWithWine` finds `setup.exe`, runs it
silently when there is an answer file, and checks for InstallShield's
`setup.ilg` once it finishes ([wrapp-build.md](wrapp-build.md)). Afterwards the
unpacked installer is deleted. Unlike a disc's, nothing reads it again, and
it is about the size of the game.

An installer that isn't an InstallShield launcher, or one that doesn't unpack,
is run as it is, with the installer's own wizard. A headless build then fails,
as for a disc game with no answer file.

### Answer files

A download's installer asks different questions from the disc's. Scarlet Hand's
disc asks 8 (welcome, licence, two info pages, folder, setup type, options,
finish) and the download asks 5 (welcome, licence, folder, ready, finish).
Each answer file is also keyed on the product GUID in `setup.ini`, which
differs between the two. So downloads have answer files of their own, in
`SecondChance/Resources/installer-answer-files/her-download/<slug>.iss`, beside the
discs' in `installer-answer-files/`. `WrappBuildHelper.installAnswerFile` copies the
one for the build's source to `nancy-drew-installer/setup.iss`.

Only Scarlet Hand has one so far. To record one for another game:

1. Unpack the download into a Wine prefix:
   `wine <download>.exe /extract_all:C:\out`.
2. Run the wizard in record mode, `wine C:\out\Disk1\setup.exe /r /f1C:\out\rec.iss`,
   and click through it accepting the defaults.
3. Save `rec.iss` as `installer-answer-files/her-download/<slug>.iss`.

The downloads install to `C:\Program Files (x86)\Her Interactive\<game>`, not to the
disc's `C:\Program Files (x86)\Nancy Drew\<game>` or `C:\Nancy Drew\<game>`. So the
integration test checks only that a Windows download's exe exists, not where it is.

### ScummVM games

The first seven games run under ScummVM, which needs no installer. A disc
build points ScummVM at the disc's files. A download's data is in the
installer's cabinets, though, so the build installs it under Wine like any
other game and then points ScummVM at the installed folder. That folder holds
`Ciftree/CIFTREE.DAT` rather than the disc's `ciftree.dat`, and ScummVM detects
it all the same (`nancy:nancy6` for Scarlet Hand). Wine is stripped from the
wrapp only after the installer and the patches have run.

## Mac downloads

Her Interactive's first Mac release, Trail of the Twister in 2010, was made
with TransGaming's Cider, a commercial Wine fork. The download is a DMG:

```text
<volume>/<Game> Installer.app/Contents/Resources/tgInstall.plist
<volume>/installer/INSTALLDATA.tgz            the Cider app, as output.app
<volume>/installer/INSTALLDATA.tgz.manifest   one line per entry
<volume>/installer/INSTALLDATA.id             TransGaming's integrity check
```

- **`tgInstall.plist`** names the game (`InstallGame`) and the Cider app's
  bundle id (`ForbiddenGameID`, `com.transgaming.nancydrew…`). The game is
  detected from these and the volume's name.
- **`INSTALLDATA.tgz`** is a plain, unencrypted gzipped tar. The Cider app inside it keeps the game exactly as
  the Windows installer left it, under `Contents/Resources/transgaming/c_drive`.
- **The app's `Info.plist`** names the game's folder (`CedegaGameDir`) and exe
  (`CedegaGameName`) as Windows paths.

The person can pick the `.dmg`, or open it and pick `<Game> Installer.app`
inside it: that app sits at the volume's root, so its folder is the mounted
download, and the build reads it from there without mounting anything.
`HER_INSTALLER_PATH` takes either too. An installer app copied out of its
volume has no `installer/` beside it, and fails as not being Cider.

Cider's 32-bit runtime no longer starts on macOS, but the game inside is the
Windows release. So `CiderPackage` extracts only the app's `Info.plist`, its
`c_drive/Program Files` tree and the DLLs in its `system32` (below), in one pass of `/usr/bin/tar` into a staging
directory inside the temporary wrapp. It then moves the folder `CedegaGameDir` names
into the wrapp's `drive_c`. Cider's `C:\Program Files` is a 32-bit Windows's, so the
folder goes to `Program Files (x86)`, where a 32-bit installer puts it in a
wrapp. Twister lands at the path the disc gives it.

**Most of Cider's own `c_drive/windows/system32` is left behind.** Its
graphics and input DLLs (`ddraw`, `d3d8`, `d3d9`, `dinput`, `opengl32`, …) are
empty placeholders: Cider's real ones are Mac libraries in the app's
`Contents/Frameworks` (`libddraw.dylib`, and `libd3d9.dylib` over TransGaming's
OpenGL renderer `libd3dgl.dylib`), loaded first by its `builtin, native` load
order. Its C runtimes (`msvcrt`, `msvcr*`, `msvcp*`) are real, and would
override Wine's builtins. But it also holds the runtimes a disc's installer installs
with the game, and without them the game doesn't start. Trail of the Twister
imports `MFC80.DLL`, for which Wine has no builtin, and Wine fails with
`Importing dlls … failed, status c0000135`. So `CiderPackage` also extracts
`system32`'s DLLs and copies those the wrapp's Wine has no builtin for
(`wine/lib/wine/i386-windows`) into the game's folder, where Windows looks
first. For Twister that is `mfc42`, `mfc71`, `mfc80`, `mfc90`, `atl71`,
NVIDIA's Cg and `squish`. Every graphics and input DLL Cider has, Wine has
too, so none of them comes over.

Cider's registry holds nothing for the game: no Her Interactive keys, only
Wine's own settings and My Documents pointing at the Mac's home.

The progress line shows `Unpacking the game (n%)`, the count of entries `tar -v` has
named against the manifest's count of the ones kept. Extracting Twister's
940 MB payload takes about half a minute.

`ISOMounter` mounts the DMG with `-noverify`. hdiutil's checksum pass takes more than half a
minute on a 1 GB download, and gzip checks the payload as `tar` reads it anyway. A
damaged download fails at extraction with `unsupportedMacDownload`.

**No patches are applied to a Mac download.** Her Interactive's patches are
Windows updaters that look for the game their own installer registered, and a
Cider build never ran one. It is also a later build than they patch: Twister's
is from 2015, and its only patch, from 2010, fixes a GeForce 2/4 MX problem.

### Downloads that aren't Cider

Some later games' Mac downloads may not be Cider builds. Her Interactive
also made native Mac versions, for example. A DMG without the layout above
fails the build with `WrappBuildError.unsupportedMacDownload`, whose message
says to download the Windows version instead. Which games' Mac downloads are
Cider, and whether the others could be used, isn't known yet. Answering that
needs a sample of one.

## Testing

- **Unit tests:** `HerDownloadTests` cover detection from an installer's
  embedded names, recognising and extracting a Cider package (built in the
  test with `tar`), the path mapping, and `HER_INSTALLER_PATH`.
- **Integration tests:** `HerDownloadInstallIntegrationTests` builds and
  launches every download it finds: `installers/<slug>/her-download*.exe` or
  `her-download*.dmg`, once each. A Mac download's row in `sc`'s table is
  `<slug> mac`.

```shell
./sc test integration --source her-download                  # every download in installers/
./sc test integration scarlet-hand --source her-download
./sc wrapp build trail-of-the-twister --from her-download    # or --her-download <file>
```

`sc wrapp build` refuses a game with more than one download until
`--her-download` picks one.
