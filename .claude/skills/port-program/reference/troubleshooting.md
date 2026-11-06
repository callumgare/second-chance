# Symptom → cause → fix

Read the logs first: the build's (`sc wrapp build` prints where; every step
under `DerivedData/sc-logs/`), and the wrapp's own (`docs/logging.md`
says where). Wine's `err:` lines usually name the cause. For more,
`SECOND_CHANCE_WINEDEBUG=+seh,+loaddll open -n <app>` (keep runs short).

## Wine

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Quits within seconds, exit 0, nothing drawn | The display mode switch failed | The prefix has `EmulateModeset` already; check the log for `ChangeDisplaySettings … returned -2`. `GameQuitCheck` reports it (`docs/wine-in-process-helpers.md#quit-watch`) |
| `nodrv_CreateWindow … no driver could be loaded` | Run outside the GUI session (SSH) | `sc in-gui-session`, or `sc --on` (it re-runs in the GUI session) |
| Wrong colours, slow 8/16-bit game | DirectDraw palette on Mac | `DO wine.cnc-ddraw` and `--wine.graphics=direct-draw` |
| First click does nothing | cnc-ddraw swallows it | The launch's `--wine.graphics=direct-draw` arms the cursor lock; check the log for it (`docs/wine-in-process-helpers.md#cursor-lock`) |
| Black screen, D3D game | wined3d lacking a feature, or an unscaled emulated mode | `SECOND_CHANCE_MODE_SCALING=0` to compare; `+d3d` trace briefly |
| D3D10/11/12 program fails | wined3d on OpenGL 4.1 can't | Out of reach for the wine module: say so |
| "Please insert the disc" | Disc check | Keep the disc as a CD-ROM drive with its label (`WINE.KEEP-DISCS`, `WINE.MOUNT --cdrom`) |
| Disc check fails, SafeDisc/SecuROM files present | Protection driver can't load | Another edition (GOG/Steam) or the publisher's no-CD patch |
| A 16-bit program or `SETUP.EXE` fails at once (`LDT`, `winevdm`) | Win16 under Rosetta 2 | Use the program's 32-bit build, or unpack the installer (`deark`, `unshield`) and do its steps; see engines.md |
| Installer hangs at the end | It waits on a dialog, or spawned a process that never exits | Its log/screenshot; `--automation` with AutoIt, or `--creates` so the build knows when it's done |
| No video, black where a cutscene goes | Codec or QuickTime missing | Imports/requirements: `winetricks icodecs` (Indeo), `cinepak`, `quartz`; QuickTime for Windows (`quicktime72`). Smacker/Bink need nothing |
| No music | DirectMusic, MIDI | `winetricks directmusic`; MIDI goes to macOS's synth |
| Stuck on a loading screen for minutes; `err:dmsynth:synth_sink_render_thread WaitForMultipleObjects returned 0` every ~1.5 s | Wine's DirectMusic synthesiser takes ~1.5 s per sound loaded (Game Maker 7 games load every sound through DirectMusic: Iji, 2026-11) | `WINE.WINETRICKS directmusic` (Microsoft's DLLs): Iji then loaded in ~10 s. Needs `cabextract` (below) |
| A winetricks verb fails: `Cannot find cabextract` | Second Chance doesn't bundle cabextract (2026-11), so no verb that unpacks a Microsoft redistributable works in a build: `directmusic`, `d3dx9*`, `quartz`, `vcrun*`, `corefonts`… | Planned: the wine module keeps Sikarugir's cabextract as a build-only tool on winetricks' `PATH`. Until then, for an experiment, a scratch copy on `PATH`; a bundle needing such a verb waits |
| `WINEDLLOVERRIDES=… open <app>` changes nothing | The wrapp builds Wine's environment itself and doesn't pass it on | Experiment in the prefix directly (`WINEPREFIX=<app>/Contents/SharedSupport/prefix WINE=<app>/Contents/SharedSupport/wine/bin/wine`), or a `WINE.REGISTRY` DllOverrides step |
| Text missing or wrong font | Its fonts weren't installed | The installer installs them; or copy the `.fon`/`.ttf` into `C:/windows/Fonts` and register them |
| `Unhandled page fault` on start, Armadillo/protected exe | Rosetta faults on its tricks | `docs/big-fish.md` (the Rosetta fault fix) |
| Runs, but saves vanish on relaunch | It writes outside any volume | Find where it writes; make a volume |
| Saves beside its exe, or in `C:/windows` | A Wine volume can only be under `C:/users/` (2026-11) | Look for a setting that moves them (LaserTank's `NETWORK_INI` only moves them to `C:/windows`); otherwise note in the manifest that they stay in the app, and report it |
| The app's Quit does nothing; the wrapp ends the game by force and its scores/settings (written on exit) are lost | The game ignores Wine's quit (`WM_QUERYENDSESSION`): Allegro 4 games do (Icy Tower, 2026-11), Game Maker 7 ones too (Iji) | `LAUNCH --wine.quit-key=<keys>`, in the key notation (`docs/wrappfile.md#key-sequences`): `f12:hold` holds F12 for 5 s, repeating as a held key does (a game that takes repeats as presses walks its menus), `:hold=2s` that long; `up return*2` presses keys in turn, 2.5 s apart. When the quit key first asks the player, `--wine.quit-confirm-key=<keys>` is what a second Quit presses (Icy Tower: `--wine.quit-key=escape --wine.quit-confirm-key=escape:hold`). Write `:hold` rather than a bare key, which `sc bundle check` warns of. Try the keys first with `sc puppet do <name> key escape:hold=4s`. Find the game's own quit path by hand first, from a game, its menu and paused |
| Keys reach the game from `sc puppet do`, but not ones a helper posts | An `NSEvent` key with empty `characters` is unseen by a game reading typed keys; a down and up let out together (Cocoa's main thread held up) are a press a polling game misses | Give posted keys their characters (`\x1b` for Escape); time each up from its down. `SECOND_CHANCE_WINEDEBUG=+key` shows each press and release as Wine got it |
| Hangs on exit: its own log stops at its last shutdown step, 0% CPU, window still up; intermittent, more on one Mac than another | Allegro 4.x's `remove_timer` waits INFINITE on a `_beginthread` handle the CRT already closed; wineserver reuses the value (Icy Tower, 2026-11: ~3/11 exits on macOS 26, 0/41 on macOS 15) | `DO wine.keep-thread-handles` in the stage, after it has Wine: its msvcrt then keeps `_beginthread` handles open (`docs/modules.md#the-wine-modules-patches`). A Wine-side backtrace of a hung game: `winedbg` attached through `sc wrapp wine` (one capture per hang: attaching ends it under wow64) |
| A DirectDraw game's windowed mode fails under cnc-ddraw (its log: setting a windowed mode failed, then fullscreen), or switching to it from its options crashes it (`Unhandled page fault` on a NULL `screen`) | Asked for a window (`DDSCL_NORMAL`), cnc-ddraw makes up a display mode the size the window has then, often a sliver, and its `GetClientRect` hook reports that size; Allegro 4's windowed driver checks the client area is the size it asked for and gives up (Icy Tower, 2026-11) | Give the game's exe its own `ddraw.ini` section with a made-up mode of the size it asks for: `EDIT C:/windows/syswow64/ddraw.ini --ini=<exe name>.fake_mode=640x480x16` after `DO wine.cnc-ddraw`. cnc-ddraw doesn't lock the cursor in that mode, so the cursor lock helper gives up after its 15 clicks |

## Building from a disc image

| Symptom | Cause | Fix |
| --- | --- | --- |
| `hdiutil: attach failed - no mountable file systems` | A hybrid Mac/PC disc: hdiutil follows its Apple partition map to the HFS side | Fixed 2026-11-04 (`ISOMounter.mountISOSide` mounts the ISO 9660 side). By hand: `hdiutil attach -nomount -readonly <iso>`, `mount -t cd9660 -o rdonly <dev> <dir>`; `umount` before `hdiutil detach` |
| `couldn't be copied … Attribute not found` / EINVAL on a folder | A hybrid disc's ISO side lists Mac forks as AppleDouble `._` files | Fixed 2026-11-04 (`copyContents` copies contents alone, without `._` files) |

## Testing (WrappPuppeteer)

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Game window did not go into a fullscreen Space within 120s` | The program asks for a window, and native fullscreen leaves it in one (`Native fullscreen: the game asks for a window`): it goes fullscreen only when the program asks (a Direct3D borderless window covering the screen, a DirectDraw game setting a display mode through cnc-ddraw). A test with no `tests.window` expects fullscreen | If the program's window is what it should be, say so: `tests: { window: windowed }` (LaserTank, SkiFree, Icy Tower). If it should be fullscreen and the helper misjudges it, `LAUNCH --wine.window=fullscreen` forces it (docs/wine-in-process-helpers.md, "When the launch says") |
| `--wine.graphics=direct-3d` but the log says `Cursor lock armed` | The in-process helpers read the exe's imports (`ddraw.dll` → DirectDraw), not the launch (seen with Iji, 2026-11) | The lock is the launch's choice now: `--wine.mouse=grab-early` (with `DO wine.cnc-ddraw`), or `--wine.mouse=free` for a game played with the keyboard; a launch recorded before the option still infers it |

## ScummVM

**Look inside with ScummVM's debugger first**, for any ScummVM game and any
engine: an error, a hang, a scene that never comes, a puzzle that won't
take a click. Run the wrapp under `sc puppet start <name> --wrapp <app>`.
An engine error opens the console by itself, and Ctrl+Alt+D opens it at
any time (after `sc puppet do <name> focus`). Type commands with `sc puppet
do <name> type "<command>" --then "key return"`, and read what they print
with `sc puppet log <name> --grep '  ScummVM  '`, which has all of it,
however many screens long (`docs/dev-cli.md#scummvms-debugger`). `help`
lists the engine's own commands (each engine has its own: Director's
`bt`, `v`, `disasm`, `xl` and breakpoints; others show rooms, scripts,
inventory or flags), and every engine has `debugflag_list`,
`debugflag_enable <channel>` and `debuglevel <n>` (a channel prints
nothing until the level is high enough: 5 is a lot), which turn its debug
channels on into the same log from that moment, so what happens next is
traced.

| Symptom | Cause | Fix |
| --- | --- | --- |
| `--detect` finds nothing | Wrong folder, Mac files without resource forks, or an unknown release | `--recursive`; for Mac data use MacBinary or `dumper-companion`; ScummVM's "unknown variant" message gives md5s to compare with its detection table |
| A Director game's Lingo error ("Builtin 'count' did not return value!", "… should be of type ARRAY …, not VOID") | A builtin was given VOID: usually what an Xtra or file call returned for something ScummVM doesn't do | At the error, in ScummVM's debugger (above): `bt` for the handler, `v` for the VOID, `disasm <script>:<handler>` for the call that gave it; then that Xtra's or builtin's source in ScummVM (`engines/director/lingo/xtras/`, `lingo-builtins.cpp`). Ingenious: FileXtra's `DirectoryToList` gives VOID for a folder that isn't there |
| "Unable to locate the '….dat' engine data file" | The Wrappfile's `SCUMMVM.KEEP-DATA` took that file out | Name it in `SCUMMVM.KEEP-DATA` too |
| A warning that the game is unstable/unsupported | ScummVM's support level for it (every Director game is `ADGF_UNSTABLE`) | Keep it: the player should know a game isn't fully supported, and save often. Test how far it plays; say in the manifest's `notes` what works. The integration test must click past it (a needle for the dialog's button in the bundle's `tests/needles/`) |
| Detected, starts, then exits 1 after seconds: `ERROR: Builtin '…' did not return value!` (Lingo) | The director engine can't yet run something the game's scripts do (Ingenious under 2026.3.0, 2026-11) | `--detect` isn't "it runs": always launch to the title. Try a newer ScummVM (its releases, or a daily build) by hand, under the ground rule on engines from their makers, and, if fixed, propose the scummvm module's update. Otherwise the next route (Wine) |
| Director: `LINGO: syntax error, unexpected tEQ` in `MovieScript id: 0` at a line like `_name = "…"` | ScummVM can't parse a bare `x = y` assignment in the projector's startup script, `Lingo.ini` beside the exe (2026.3.0 and 2026.4.0); the globals it sets stay empty, and the game fails later for what looks like another reason (Bioscopia: the disc-2 check built `e:\` with no file name) | Rewrite each assignment as `set x to y` in a copy of `Lingo.ini` (a `COPY` in the Wrappfile replacing the game's); report it to ScummVM |
| Director: the game says its disc isn't in the drive | Its Lingo finds the CD by drive type, often through the Buddy API Xtra's `baDiskInfo(letter, "type")`; ScummVM's emulation says `E:` is the CD-ROM and `C:` the hard disk, and maps `E:\…` to the game folder | Trace it (`--debuglevel=5 --debugflags=lingoexec,paths,xobj`) and see which path it builds: put the disc's files (and its marker file, e.g. `CDNr2.rup`) at the game folder's root, and check every global in the path is set |
| A ScummVM wrapp logs `critical … Error setting up cached prefix … "prefix" doesn't exist` | The wrapp sets up a Wine prefix it doesn't have | Harmless; ignore |
| Running ScummVM windowless (`SDL_VIDEODRIVER=dummy`) to test without a screen: `Could not load any graphics mode!!`, exits at once | The OpenGL graphics manager needs a real display, and `--gfx-mode=normal` on the command line doesn't avoid it | **Windowless works** (2026.3.0 and 2026.4.0, 2026-11-05) with `gfx_mode=surfacesdl` in the config's `[scummvm]` section plus `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy` and `mute=true`. Add `--debugflags=screenshot` (Director) to get a PNG of every frame in `./dumps/`: pictures with no screen, so it can run on any Mac without asking for a screen (but no input: it stops where the game waits for a click). Set `enable_unsupported_game_warning=false` in that scratch config only, as nobody can click the warning |
| Clicking into an engine run by hand on the test Mac: macOS asks "would like to control this computer using accessibility features", or the click is dropped | Posting input to another app needs Accessibility, which nothing run over SSH or by `gui-run` has | **Use Peekaboo through its bridge host** (2026-11-05): Peekaboo.app runs on the test Mac (which account: `.local/AGENTS.md`) as the login agent `boo.peekaboo.bridge-host`, with Screen Recording, Accessibility and Event Synthesizing granted. Over SSH, pin every call with `PEEKABOO_BRIDGE_SOCKET="$HOME/Library/Application Support/Peekaboo/bridge.sock"` (this also stops the CLI auto-starting daemons from the SSH session, which have no grants and grab the capture lock), and never pass `--no-remote` from SSH. For a game, click as a hand would: `move --smooth --foreground` to the point (global coordinates: the window's origin from `window list` plus the point), then `click --foreground --input-strategy synthOnly`, since a background click only presses accessibility elements and games have none. Better still, run the engine under `sc puppet start <name> -- <engine> …`, which inserts the helper and clicks from inside it with no grants (`docs/dev-cli.md#puppet-sessions`). Take the screen lease by hand first (`sc lease take`). A built wrapp needs none of this: WrappPuppeteer clicks from inside it |
| A windowless or hand-run ScummVM still running after `kill <pid>` | It doesn't always end on SIGTERM while busy | Check with `kill -0`/`pgrep` after a second or two, then `kill -9 <pid>`; never assume a kill worked |
| A bare ScummVM stops at "check for updates?" | First run with no settings | `--config=<ini>` with `[scummvm]` `updates_check=0`, as the wrapp's template has. Leave `enable_unsupported_game_warning` alone in the wrapp: the warning is wanted (a scratch config for a windowless experiment may turn it off) |

## DOSBox

| Symptom | Cause | Fix |
| --- | --- | --- |
| Too fast or too slow | `cycles` | A GOG or eXo `.conf` for the game says what works |
| No sound | Sound card settings in the game's own setup | Run its `SETUP.EXE`/`INSTALL.EXE` in DOSBox once and keep the config file it writes |

## Director games under ScummVM: getting at a failing scene

At a running game's error, ScummVM's debugger (above) is quicker than a
trace: `bt`, `v` and `disasm` at the moment it fails. What follows is for
getting to that moment without playing there.

- **Skip the menus:** `--start-movie=<movie>` (e.g. `Game/01_entry.dcr`) with a windowless
  run goes straight to the movie under test, no clicks needed.
- **Find where a handler lives:** `--dump-scripts` decompiles every script to `.lingo`;
  `grep -l '^on <handler>'` over them names the movie or cast that defines it.
- **"Call to undefined handler" with `tell sprite(n)`:** Director 8 "code library" pattern:
  game logic in a linked movie (a `MovieCastMember` on a sprite), reached by
  `tell sprite(n)`. ScummVM 2026.4.0 (and master as of 2026-11) only `tell`s windows
  (`wrong argument type`, type 19 = sprite ref), so the linked movie's handlers are never
  found. An engine gap, not a data problem (Bioscopia).

## A hang: cleaning up after it

When a bounded wait runs out (SKILL.md, "Bound every wait"), look first, then stop it, then check it's gone.
Killing the process you started is rarely enough:

| What hung | Look at first | Stop it with | Left behind if you don't |
| --- | --- | --- | --- |
| A Wine program (game, installer) | A puppet `shot`, the wrapp's log (Wine's `err:` lines), `sample <pid> 3`; a diagnostics bundle (`kill -USR1` the wrapp, `docs/wrapp-launch.md#diagnostics-bundles`) | `sc puppet stop`, which ends the prefix's whole Wine session; by hand, `wineserver -k` in that prefix, then check (`pgrep -u <user> -fl wine`). Never `wineserver -k9` alone | A wineserver and its devices holding the prefix, which hang the next run in it |
| A wrapp that won't quit (its window says the game quit unexpectedly) | Its log's last lines: was the quit a failure? | Quit it as a person would (`sc puppet stop`); `kill` by pid only after | A wrapp holding its lock, so the next launch attaches to it instead of starting |
| `hdiutil attach` | `hdiutil info` (does the image have a device, but no mount point?) | Kill `hdiutil` with SIGKILL (it ignores SIGTERM), then the `diskimages-helper` whose pid `hdiutil info -plist` gives for that image (`hdid-pid`), as this user. Second Chance's own attaches do this themselves (`DiskImage.attach`) | A wedged disk service for every user on that Mac: `diskutil list` hangs, other mounts take minutes or fail, until a restart |
| A program run by hand (`gui-run`, an engine) | Its `gui-run … log` | `gui-run … stop` (the whole tree), then `pgrep` by pid | A window on a test session's screen, and its load |

Kill by pid, never by a pattern you built (`pkill -f`): a pattern that comes out empty matches everything.
