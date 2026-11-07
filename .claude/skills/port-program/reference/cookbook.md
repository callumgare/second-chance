# Wrappfile shapes

Each shape is written in the syntax `.local/plans/builders-into-modules.md`
plans (`FROM --module=`, `APP`, `RUN` with `bind` mounts, `allow-paths`).
**`docs/wrappfile.md` is the authority**: when it says otherwise, it's right
and this file is out of date — fix this file. The shipped bundles named
with each shape are the working examples; read them first.

Throughout: `INPUT`s come first, then `CONST`s; a path the program is
launched from is a `CONST`; every edition's target reaches one `LAUNCH`.

## A bare Windows program, or a zip of one (`freeware/skifree`)

```dockerfile
INPUT game
CONST install-dir = "C:/LaserTank"

FROM --module=wine@10 prefix AS download
APP --id=${input.app-id}            # Second Chance gives it; leave out for a plain experiment
COPY --from=${input.game} . ${const.install-dir}/
LAUNCH --wine.graphics=unknown "${const.install-dir}/LaserTank.exe"
```

`--wine.graphics`: `direct-draw` (imports `ddraw.dll`; add `DO
wine.cnc-ddraw`), `direct-3d` (`d3d8`/`d3d9`), `unknown` (GDI, neither).
`identify.py` reads it from the imports; a packed exe needs `upx -d` on a
copy first.

## A Windows installer (any `Bundles/nancy-drew/*` disc edition)

Silent with an answer file or switches, through the installer module:

```dockerfile
FROM --module=wine@10 prefix AS download
USE installer
INSTALLER.RUN --from=${input.installer} --into=${const.install-dir} \
    --creates=${const.install-dir}/Game.exe  <installer>.exe /S
```

Or as a plain `RUN` with the installer bound in, for one that takes a
silent switch and needs nothing of the installer module's (stall watch,
answer files, AutoIt):

```dockerfile
RUN --mount=type=bind,source=${input.installer},target=C:/setup \
    C:/setup/LT4_Setup.exe /S
```

What a shipped bundle does (`freeware/icy-tower`, an Inno Setup download
edition, `unpack: "none"`): copy the installer in, run it into a folder of
your choosing, remove it. `/DIR=` takes a Windows path without spaces
unquoted; the installer module's `INSTALLER.RUN` installs to the
installer's default folder instead and links `--creates` to it.

```dockerfile
COPY --from=${input.game} . C:/setup/
RUN "C:/setup/icytower13_install.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS /DIR=C:\IcyTower
REMOVE C:/setup
```

Silent switches by family: Inno `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART
/SP- /DIR="C:\…"`; NSIS `/S /D=C:\…` (`/D` last, unquoted); InstallShield
5+ `-s` with a recorded `setup.iss` (`-r` records one; `-f1<path>` names it);
MSI `msiexec /i x.msi /qn TARGETDIR=…`; Wise `/s`. An installer with no
silent mode is clicked through with `--automation=<AutoIt script>`
(`docs/wrappfile.md`, the installer module).

## A disc the program reads at run time

```dockerfile
INPUT disc-1
FROM --module=wine@10 prefix AS disc
WINE.KEEP-DISCS ${input.disc-1} --into=C:/discs     # copied in, given D:, kept at launch
```

or `WINE.MOUNT <folder> D: --cdrom` for a folder already in the prefix. A
program that checks the volume label needs the disc kept as a CD-ROM drive
with its label.

## DOS (`freeware/tyrian-2000`)

```dockerfile
FROM scratch AS download
USE dosbox
COPY --from=${input.game} <folder in the zip> C:/GAME/
VOLUME --dosbox.overlay dosbox-saves C:/
LAUNCH C:/GAME/GAME.EXE
```

## ScummVM (`freeware/lure-of-the-temptress`)

```dockerfile
FROM scratch AS download
USE scummvm
COPY --from=${input.game} <data folder> /SharedSupport/game/
VOLUME scummvm-saves scummvm:saves/
VOLUME scummvm-settings scummvm:settings/
LAUNCH /SharedSupport/game/ <scummvm game id, e.g. lure or director:ingenious>
```

The game id is what `scummvm --detect` prints (without the engine prefix
where the shipped bundles leave it out: compare `lure`). A disc edition's
data comes from `${input.disc-1}` the same way: `ingenious-consortium/ingenious`
copies a hybrid disc's whole ISO side and launches `director:ingenious`, and
needs no Wine stage at all (`FROM scratch`), since nothing is installed. Copy only what ScummVM
needs, not installers and other platforms' executables, unless its
detection needs them (it often keys on the projector or main exe).

## A classic 68k Mac program (`ingenious-consortium/ingenious`)

The program runs on an emulated Mac booting System 7.5.3: `FROM scratch`,
`USE basilisk`, the disc as the Mac's CD, and the program named by its path on
the Mac. What only the Mac can do at build time (an Apple Installer, a Finder
alias) is a key script the in-process helper runs inside Basilisk II, which
waits on text read off the screen rather than fixed sleeps; the result is a
layer, done once per Mac. The Mac's startup disk is the person's own, a store,
so what the program saves in its Preferences stays.

```dockerfile
STORE basilisk-disk
FROM scratch AS disc
USE basilisk
BASILISK.CDROM ${input.disc-1}
BASILISK.RUN --automation=bundle:mac/setup.keys     # manifest: allow-paths: ["mac/"]
BASILISK.STARTUP "basilisk:System7_5_3:Desktop Folder:Ingenious alias"
LAUNCH --mount=type=store,source=basilisk-disk,target=basilisk:disk/
LAUNCH --basilisk.screen=640x480x8 --basilisk.shut-down=with-program "basilisk:Ingenious CD:Ingenious"
```

- Write the script from a session by hand first (`sc puppet start`, then `do
  … key`/`type`/`click` and `text`): the Finder takes type-to-select, Cmd-Down
  (open), Cmd-O, Cmd-M (make alias) and Cmd-Option-W (close every window, so
  typing goes to the desktop); a dialog with no default button needs a click
  at a fixed point (the screen is a fixed 640x480).
- Wait with `wait-for <seconds> <text>`, and for a restart with
  `wait-restart`: Basilisk II keeps its window, and the screens between pass
  too quickly to catch.
- `--basilisk.shut-down=with-program` closes the app when the player quits
  the program, rather than leaving them at the Finder: the helper reads which
  application is running from the Mac's memory (no pictures, so it costs the
  game nothing). Leave it off for a program meant to be left for the Finder.
- System 7.5.3's disk has no AppleScript (no extension, no Script Editor) and
  only HyperCard 2.4, which can't shut the Mac down by itself: anything to do
  while the program runs is the helper's, outside the Mac, not a script in it.
- Its test: a text needle on the program's first screen, tagged `running`,
  the `basilisk/starts-and-quits` scenario, and `tests: { window: windowed }`.

## Settings files and the registry

```dockerfile
EDIT C:/GAME/GAME.INI --ini=Video.Windowed=1             # fails if missing; --create to make it
WINE.REGISTRY --set "HKEY_CURRENT_USER\Software\Maker\Game:Path" "C:\GAME"
WINE.WINETRICKS win98                                     # Windows version, then any verbs
```

## Things a program writes: volumes

Find where it writes (play, save, quit, then compare the prefix or its
folder with the built app's), and make each place a volume in the manifest
and a `VOLUME` here. A game that saves beside its exe in `C:/GAME` can't
have a volume on the whole folder (its program would be "the person's
files"): look for a setting that moves saves, or a subfolder it saves into.
