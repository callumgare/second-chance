# Her Interactive downloads

Her Interactive's store sells most of the classic games as a Windows download,
and some as a Mac download too. It is the only place some of them can still be
bought (Stay Tuned for Danger isn't on Steam). Second Chance builds a wrapp
from either: `HerDownloadWrappBuilder`, the **Her Interactive Download** source.

The two arrive as quite different files, and the Mac one in two kinds. The
builder takes a separate path for each:

| Download | File | What is in it | How the wrapp gets the game |
| --- | --- | --- | --- |
| Windows | `.exe` | An InstallShield launcher with a disc's `Disk1` inside | Unpack it, then install as from a disc |
| Mac | `.dmg` | TransGaming's Cider installer; its payload is the installed Windows game inside a Cider app | Take the game's folder out of the Cider app |
| Mac, `-iso-` | `.dmg` | The game's Windows and Mac disc: a Cider installer whose payload is only Cider, beside the Windows release and its installer | Build the disc edition from it, as from the disc ([below](#mac-downloads-that-are-the-games-disc)) |

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
differs between the two. So downloads have answer files of their own: each
game's bundle has the disc's as `assets/disc.iss` and the download's as
`assets/her-download.iss` (`Bundles/nancy-drew/<slug>/`,
[program-bundles.md](program-bundles.md)), and its Wrappfile names it
(`HER-DOWNLOAD.INSTALL ${input.installer} --answer-file=assets/her-download.iss`);
the Her download builder copies it to `nancy-drew-installer/setup.iss` once
the launcher has unpacked. A Mac download builds its bundle's `her-mac` stage,
which has no patches.

Only Scarlet Hand has one so far. To record one for another game:

1. Unpack the download into a Wine prefix:
   `wine <download>.exe /extract_all:C:\out`.
2. Run the wizard in record mode, `wine C:\out\Disk1\setup.exe /r /f1C:\out\rec.iss`,
   and click through it accepting the defaults.
3. Save `rec.iss` as `Bundles/nancy-drew/<slug>/assets/her-download.iss`, and
   name it in the bundle's Wrappfile (`HER-DOWNLOAD.INSTALL ${input.installer}
   --answer-file=assets/her-download.iss`).

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

That is a download whose Cider app holds the game. Some Mac downloads' don't:
they are the game's disc, and build as one
([below](#mac-downloads-that-are-the-games-disc)).

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

### Mac downloads that are the game's disc

From Shadow at the Water's Edge (2010) on, Her's discs are dual-platform: a
hybrid disc whose Mac side holds the same TransGaming installer and whose
Windows side holds the Windows installer and the game. Her's later Mac
downloads are images of such a disc, named `cider-Nancy<code>-iso-<n>.dmg`
(The Silent Spy, Labyrinth of Lies, The Captive Curse and Sea of Darkness
were seen in failure reports). Mounted, one holds the Windows disc's files
beside the installer: a `Setup.exe` (an autorun launcher, "Autorun2
Application") and `Setup.msi` at the top, and the game either loose
(The Silent Spy's `Files/Game/Spy.exe`) or in the installer's cabinets
(Water's Edge's `SAW1.cab`…, spanned across both discs). Its
`INSTALLDATA.tgz` is only Cider, with the game's program rebuilt for Cider
and no data (19 MB for Water's Edge, 22 MB for The Silent Spy). Taking the
game out of it, as from a download, fails: `tar` finds no `Program Files`
(The Silent Spy's payload has none), or the wrapp has the program and none
of its files.

`tgInstall.plist` says which kind an installer is. Its `InstallFiles` is the
installer's list of what it copies where, as `source:`, `target:` and
`flags:` entries. A download's copies only its payload into the app as a whole
(`target:/`) and its manual beside it. A disc's also copies the Windows files
on the image into the app's Windows drive (`target:/output.app/Contents/Resources/transgaming/…`):
The Silent Spy's copies `$INSTALLVOLUME/Files/Game/` to `c_drive/Program
Files/Nancy Drew/The Silent Spy/`, and Water's Edge's unpacks its
cabinets there, each file to the path `CABMapping`'s plist
(`installer/NancyDrew.plist`) gives it. So `CiderPackage.game` is
`.disc` when there is a `CABMapping` or such a copy, and `.payload`
otherwise. Its discs are `DISK_<n>`, each a disc's name and a file on it
(`$INSTALLVOLUME/SAW18.cab` for Water's Edge's disc 2); a disc whose file
isn't on the image is missing from it.

A disc's image builds as the disc does, not by Cider's list: the Windows
installer installs the prerequisites the game needs with it (a Sea of
Darkness wrapp made from the files alone quit for want of `mfc90.dll`;
The Silent Spy's disc carries DirectX's `d3dx9_33` in `Prereqs/`), and some
games check for their disc. The builder recognises the game (from the Cider
installer's names, else as a disc is recognised), finds its Windows
installer (`GameDetector.installerLookup`, refusing an image with none),
and builds the bundle's disc edition, with the image as disc 1
(`DiscInputs`), through `InstallerExecutor`: the disc kept in the wrapp,
the game installed from it, and the disc's patches applied, as the image
is the disc's build. The wrapp records the disc edition (`cd`) and the
Her download source. An image holding every disc's files is the only disc,
kept as D:, but installed from `disk-combined`, links to its files
(`InstallerExecutor.everyDiscOnOne`), as two discs are: run from the CD
drive, Windows Installer checks the drive's label against each later
disc's in its media table ("SAW Disk 2"), and a silent install fails
(`1612`, "Failed to ready media"); from C:, a fixed drive, it checks none.
One missing a disc (the first disc of a two-disc game) asks for the next
disc as a disc build does (`WrappBuildInput.getDisk2Path`, `DISK_2_PATH`
headless), so a dual-platform disc's Mac installer, picked as a Mac
download, builds too.

A hybrid disc's image whose Mac side won't mount (macOS can no longer mount
HFS) shows only its Windows side, with no Cider installer. One with a
Windows installer by name is taken for the game's disc all the same; any
other image that isn't Cider is refused.

Only one sample of this kind has been built: Water's Edge's two discs'
files copied into one Mac disk image (a sparse bundle), Mac installer and
all. How closely Her's own `-iso-` images match it isn't known, as we have
none; The Silent Spy's disc, which a failure report's file list matches, is
laid out as above. A sparse bundle (a folder of bands, named `.dmg` or
`.sparsebundle`) mounts as a `.dmg` does, and `HER_INSTALLER_PATH` and the
installers store take one.

### Downloads that aren't Cider

Some later games' Mac downloads may not be Cider builds. Her Interactive
also made native Mac versions, for example. A DMG without the layout above,
and without a Windows installer, fails the build with
`WrappBuildError.unsupportedMacDownload`, whose message says to download
the Windows version instead. Which games' Mac downloads are Cider, and
whether the others could be used, isn't known yet. Answering that needs a
sample of one.

## Testing

- **Unit tests:** `HerDownloadTests` cover detection from an installer's
  embedded names, recognising and extracting a Cider package (built in the
  test with `tar`), telling a download from a disc by its `tgInstall.plist`
  and the discs on the image, the path mapping, and `HER_INSTALLER_PATH`
  (sparse bundles included).
- **Integration tests:** `HerDownloadInstallIntegrationTests` builds and
  launches every download in the
  [installers store](testing.md#the-installers-store), each Her edition's
  `<bundle id>/her-windows/installer.exe` or `<bundle id>/her-mac/installer.dmg`,
  once each. A Mac download's row in `sc`'s table is `<slug> mac`.

```shell
./sc test integration --source her-download                  # every download in the installers store
./sc test integration scarlet-hand --source her-download
./sc wrapp build trail-of-the-twister --from her-download    # or --her-download <file>
```

`sc wrapp build` refuses a game with more than one download until
`--her-download` picks one.
