# Porting Ingenious! — plan

Status: implemented 2026-11-07 (rung 5: `sc test integration ingenious` passes); "As built" below says where
it went differently. Drafted 2026-11-07, from the porting log, the engine proposal and the basilisk notes, for the user to
agree; revised the same day after the user ruled out hand-written HFS code and asked for existing tools
(hfsutils, from Homebrew's prebuilt binaries) and research into existing automation
(`research-automation.md`). It brings them together; the detail stays where it is:

- `.local/porting/ingenious-consortium-ingenious/log.md`: every experiment, inputs and hashes, decisions.
- `.local/porting/ingenious-consortium-ingenious/new-engine-proposal.md`: the basilisk module's design.
- `.local/porting/ingenious-consortium-ingenious/research-basilisk.md`, `research-mac-settings.md`,
  `research-automation.md` (what exists for automating a classic Mac: nothing that fits unattended).
- `.local/notes/basilisk/implementation-notes.md`: facts from the proof of concept, running notes.
- `.local/plans/module-path-types.md`: the prerequisite refactor.

## Goal

Ingenious! (1998, a Director 5 title on a hybrid Mac/PC disc) as a wrapp built from the person's disc: it boots
an emulated 68k Mac in Basilisk II, starts the game by itself, plays its QuickTime video with sound, keeps the
person's agents across launches, and quitting the game quits the app. Done at **rung 5**: `sc test integration
ingenious` builds it from the disc image and passes its scenario in a test account.

## Where it stands

- **Rung 2 as a wrapp, rung 4 by hand.** The Windows side under ScummVM reaches the sign-in screen but no agent
  can be made (ScummVM never runs the game's key scripts); that stage stays in the Wrappfile, unbuilt, with the
  reasons. The Mac side under Basilisk II, run by hand, does everything the goal asks except start and quit by
  itself from a build.
- **Decided** (log.md, "Decisions"): Basilisk II (E-Maculation's universal build); System 7.5.3, which Apple gave
  away, fetched by each Mac from archive.org's single-item install (one request, cached); the ROM, which Apple
  never gave out, asked of the person once, checked by its checksum and kept in the engine store; nothing from
  abandonware sites. The path type is `basilisk:`; there's no `GameEngine` case for it (the composition carries
  it, as module path types part 3 allows).
- **Found by the proof of concept**: the hybrid ISO works as Basilisk's `cdrom` as it is; QuickTime 2.5 installs
  from the disc through Apple's Installer, clicked through in the emulator; `delay 500` in the prefs is what lets
  the video and sound play (without it QuickTime's clock starves); JIT crashes under Rosetta, so the interpreter
  only; a Startup Items alias starts the game at boot; saves go into the boot disk's
  `System Folder:Preferences:Ingenious Preferences:`; the green button works with an inserted dylib
  (`poc/fsbutton/`).
- **Prerequisite**: module path types. Parts 1 and 2 are committed (96861d92), part 3 (the core launches a bare
  path; `Composition.launcher` optional) is tested and about to be committed, in `.claude/worktrees/path-types`.
- **Drafts** in `.claude/worktrees/basilisk` (uncommitted, written before the path-type refactor): the module's
  `module.yaml` (engine package, `SETUP`, `CDROM`, the `rom` provided file), its executor package,
  `BasiliskPreparing`, a `GameEngine.basilisk` (to remove), and an older draft of path-type work (to drop: the
  refactor replaces it). The bundle draft is in the port's `bundle/`.

## Phases

Each ends with `sc test unit`, `sc lint`, a commit, and the notes file updated. Work in one worktree, made fresh
from main once path types part 3 has landed; the basilisk worktree's drafts are carried over by hand, not merged.

### 1. The engine and a launch (the module's skeleton)

- `Modules/basilisk/module.yaml`: the engine package (Basilisk II zip, System 7.5.3 image), `path-types:
  basilisk: { roles: [location, program] }` (no short form), `runtime: { save-warning: false }`, `SETUP` and
  `CDROM`, `setup: [SETUP]`.
- **Preparing** (`BasiliskPreparing`, `BuildModule`): the app's binary and SDL2.framework into the wrapp's layout,
  re-signed ad hoc (as DOSBox, so the in-process helpers can be inserted); System 7.5.3 as the engine's
  `system.hfv`.
- **The ROM**: a provided file (`module:basilisk:/rom`), looked for in the engine store
  (`engines/roms/<sha256>.rom`), then a dev build's installers store (`installers/apple/`); checked by its
  checksum (its first four bytes: `F1ACAD13` and the others Basilisk II runs); a missing one fails the build with
  a plain message for now (phase 6 asks for it).
- **In a Debug build, the ROM is downloaded** when there's none (the user, 2026-11-07), through Second Chance's own
  engine downloading, as the engines are, so development and test Macs need nothing by hand: archive.org's
  "Macintosh Quadra 800 ROM" (`https://archive.org/download/800_20250604/800.ROM`, 1 MB, md5
  `69489153dde910a69d5ae6de5dd65323`, sha1 `f2a9ce38…42ac5`, sha256 `05ad753f…6b09ca`: byte for byte the user's
  own F1ACAD13 ROM), checked by its hash and kept in the engine store. Compiled out of Release builds
  (`#if DEBUG`, or a build setting of the same effect), so a released Second Chance never downloads a ROM; one
  request per Mac, archive.org's rate limit.
- **Executor** (`Packages/Modules/basilisk/`, `BasiliskExecutor`): `SETUP` copies the system disk into the tree
  as `SharedSupport/basilisk/boot.hfv` and lays in the ROM; `CDROM` keeps the disc image in the app.
- **Kit** (`BasiliskKit`, `BasiliskPaths`): a `basilisk:` path has no place on the host (`location` nil), describes
  itself as "<path>, on the game's Mac"; added to `PathPlaces.shipped` and `ModuleKits.places`.
- **Runtime** (`BasiliskRuntime`, WrappTemplate): writes the prefs at launch (rom, disk, cdrom, `screen
  win/640/480`, `displaycolordepth 8`, `ramsize`, `modelid 14`, `cpu 4`, `fpu`, `nogui`, `ignoresegv`,
  `idlewait`, `delay 500`, no JIT), starts Basilisk II at normal priority, the game its own process
  (`findsGame = .ownProcess`). `LAUNCH basilisk:Ingenious CD:Ingenious` records the program; the screen from
  `--basilisk.screen=640x480x8`.
- **Test module** (`BasiliskTestModule`, WrappPuppeteer) and the `starts-and-quits` scenario.
- **hfsutils as a build tool**, for every change to an HFS disk (never our own HFS code): Homebrew's prebuilt
  hfsutils 3.2.6, fetched without Homebrew from its registry (an anonymous `Authorization: Bearer QQ==` header,
  which the downloader gains), pinned by hash: `arm64_sequoia` (sha256 `2a486e11…b4f45f`, macOS 15+) and
  `sonoma` for Intel (`f0e5cc46…07bb8`, macOS 14+). Tested 2026-11-07 on a copy of the 7.5.3 disk: mount, list,
  mkdir, copy in, set type/creator, rename, read back, delete, all fine, both builds, no patching (they link
  only libSystem, no Homebrew paths). Prepared as the engines are (re-signed ad hoc) and run with a scratch
  `HOME` (it keeps its current volume in `~/.hcwd`). GPL-2.0+: fetched on the Mac, as Basilisk II is, not
  shipped. If Homebrew stops serving a pinned bottle: build it from its source
  (`ftp.mars.org/hfs/hfsutils-3.2.6.tar.gz`, sha256 `bc9d22d6…9840`) with Second Chance's build, as the
  in-process helpers are, and carry it in the app. Still to check: Basilisk II boots a disk hfsutils changed.
- **Done when** a hand-written Wrappfile (`FROM scratch`, `USE basilisk`, `BASILISK.CDROM`, `LAUNCH`) builds with
  `wrapp-builder build` and `sc wrapp build --bundle`, and the wrapp boots to the Finder with the CD mounted, in a
  test account.

### 2. The boot disk in a store (saves)

- The boot disk is the person's: a store (`STORE basilisk-disk`, mounted at `basilisk:disk/`), seeded from the
  app's `boot.hfv` on the first launch and used from there after, so the game's Preferences (its agents) survive
  launches and app updates. The app is never written to.
- An unclean stop leaves "not shut down properly" at the next boot, which holds up Startup Items: set the MDB's
  "unmounted cleanly" bit before each launch (to verify on a copy first).
- **Done when** an agent made in one launch is there in the next, and after `sc wrapp update`.

### Spike result (2026-11-07, `.local/porting/ingenious-consortium-ingenious/spike-keyboard.md`)

All three in-Mac jobs work blind, by keystrokes and bounded waits, no screen reading:
- QuickTime 2.5: the Installer opened by type-to-select + Cmd-Down + Cmd-O; Return takes Continue, Install and
  Restart; **the licence has no default button: Agree is one fixed click (440,418)**. ~20 s to "successful", ~10 s
  back to the Finder after Restart. Confirmed on the disk with hfsutils.
- The alias: Cmd-Option-W (close every window first, so typing goes to the desktop), type "Ingenious CD", Cmd-Down,
  type "Ingenious", Cmd-M, Return on the locked-disk prompt → `:Desktop Folder:Ingenious alias`.
- **Quitting cleanly**: Basilisk II turns SIGTERM (or its window's close button) into the Mac's power key; the Mac
  asks "shut down now?", Shut Down the default, so Return shuts it down and Basilisk II exits 0 with the disk marked
  clean, over the running game too. So quitting the app = SIGTERM + Return (the in-process helper presses it), and
  the runtime's SIGKILL fallback only after that's had its time.
- Bug found: the puppet helper (`puppet_control.m`) let Basilisk II die of SIGPIPE after the Mac restarted (its
  window went away mid-request): it should ignore SIGPIPE (`SO_NOSIGPIPE`) and expect a window to vanish briefly.
  The wrapp's log still says "Wine prefix" and "ScummVM process" for a Basilisk game: cosmetic, to fix.

### 3. Starting the game, and quitting with it

No hand-written HFS or alias code (the user, 2026-11-07). Nothing on our 7.5.3 image can make a startup item
itself (no AppleScript on it: research-automation.md), so:
- `BASILISK.STARTUP <basilisk:program>`: an alias to the program, made by the Finder in the build-time boot of
  phase 4 (select the program on the CD, File ▸ Make Alias, by keystrokes), then moved into
  `System Folder:Startup Items` with hfsutils' `hrename` once the Mac is shut down: the proof of concept's route.
- **Quitting with the game**: the wrapp's in-process helper (in Basilisk II) notices the game has quit (the
  Finder's window frontmost again, or a marker file the Mac writes to Basilisk's shared `extfs` folder) and
  sends Special ▸ Shut Down by keystroke, so Basilisk II exits cleanly and the app with it. Never a kill: the
  saves are on the boot disk.
- **Done when** opening the wrapp goes straight to the game's sign-in screen, and Cmd-Q in the game ends the app.

### 4. QuickTime 2.5 at build time

Nothing existing installs it unattended (research-automation.md): Apple's Installer has no silent mode, and its
archives (`QuickTime™.1.archive`, `idcp`/`kakc`, a `kc` header listing the files, then Apple's own compression)
have no known extractor on the host, so the six files it installs (three extensions, a control panel, an empty
preferences file, MoviePlayer) can't simply be copied in. So the Installer runs in the emulator, once per Mac:
- **First, a spike** in a test account: can the Installer be driven by keystrokes alone (Return on each
  screen's default button, after a first click in the window), and the Finder alias of phase 3 made the same
  way? If so, no screen reading at all.
- `BASILISK.RUN <basilisk:program> --automation=<script>`: boot the tree's Mac, start the program, follow a
  script of keystrokes (and, only if the spike says so, clicks on text found by the in-process helper's capture
  and OCR), each step waiting for the screen to change, with a time limit, then shut down. It runs under the
  build's GUI session, as Wine's installers do.
- The Wrappfile runs the disc's `QuickTime™ Installer` with an automation file in the bundle (Continue → accept
  → Easy Install → Install → Restart), and makes the startup alias in the same boot; its layer kept, so it runs
  once per Mac.
- **Done when** a clean build plays the intro video, and a second build restores the layer.
- Risk: Apple's Installer under automation (timing, a restart mid-way). Its signals: the "Installation was
  successful" text, then the Mac restarting; bounded waits, a capture on failure.

### 5. The Ingenious bundle

- `Bundles/<namespace>/ingenious/` (namespace: who it comes from, `ingenious-consortium/`): the manifest's disc
  edition and detection (the hybrid's ISO and HFS names), the Wrappfile (a `mac` stage from `FROM scratch` with
  `USE basilisk`: `BASILISK.CDROM`, the QuickTime `BASILISK.RUN`, `BASILISK.STARTUP` and `QUIT-WITH`, the boot-disk
  store, `LAUNCH`), the ScummVM stage kept unbuilt with its reasons, an icon.
- Its test: a scenario with needles for the sign-in screen (made from captures), quit by Cmd-Q.
- `sc bundle check`, `sc generate`, a build from the disc image in the installers store, then
  `sc test integration ingenious` in a test account.
- **Done when** that integration test passes (rung 5).

### 6. The person's ROM in Second Chance

- The first build that needs it asks, in plain words: "To run Mac games, Second Chance needs the ROM chip's
  contents from an old Mac (a Quadra 650 or 800 works best). Choose the ROM file.", with a link to archive.org's
  copy (`https://archive.org/details/800_20250604`; the user chose to link it, 2026-11-07, over a page on copying
  one from your own Mac). An open panel takes any file;
  the build checks it, names the Mac it came from or says plainly it can't use it, and keeps it in the engine
  store. Headless: `MAC_ROM_PATH`.
- The text in both string catalogs; a UI test of the question; docs.

### 7. Fullscreen and finish

- **Basilisk II stops redrawing its window after the first frame until it gets a mouse move** (found 2026-11-07,
  `.local/notes/basilisk/debug-boot-stall.md`): the Mac boots to the Finder in 3–5 s, but the window shows
  "Welcome to Macintosh" until the pointer moves. Its SDL2 redraw thread misses the Mac's changes until a full
  refresh: a bug for Basilisk II's makers (a draft report is in the notes). Ours: the in-process helper, inserted
  into Basilisk II on every launch (not only under puppet), forces a full refresh once the window is up and on each
  window change. Until then the scenario and any automation move the pointer before reading the screen.

- The green button: the fullscreen dylib (`poc/fsbutton/`) becomes an in-process helper armed for Basilisk II
  (beside native fullscreen for Wine), windowed at start. The user noticed the window has no green button
  (2026-11-07) and said it can wait for this phase, as long as it isn't forgotten: the helper code is written,
  in `poc/fsbutton/phase7-basilisk_mac-green-button.m.txt`, to put back into `basilisk_mac.m`.
- Sound checked with `sc puppet audio` in a test account (every test account on the test Mac has the audio
  tap's permission, the user said 2026-11-07).
- Docs: `docs/modules.md` (the basilisk module, its engine, the ROM), `docs/wrapp-launch.md` (`BasiliskRuntime`),
  `docs/wrappfile.md` (its instructions), `docs/program-bundles.md` if the manifest gains anything; the porting
  skill's references (Basilisk II, the classic Mac route); the plan to `docs/historical-plans/`.

## As built (2026-11-07)

- **Phases 3 and 4 swapped and merged**: the alias is made in the same build-time boot as QuickTime, then
  `BASILISK.STARTUP` moves it with hfsutils. Basilisk II boots a disk hfsutils changed without complaint.
- **The automation runs inside Basilisk II**, not through the puppet socket: `basilisk_mac.m` reads the script
  (`BASILISK_MAC_AUTOMATION`) and sends each request through puppet control's own handler, so the build needs
  no socket client. Waits are on text Vision reads off the window (`wait-for`, `wait-gone`); no fixed click
  beyond the licence's Agree.
- **A restart is told by the startup disk**, not the screen: Basilisk II keeps its window across a restart, and
  "Welcome to Macintosh" is up too briefly for pictures to catch reliably. Mac OS marks the disk unmounted
  cleanly as it restarts (0.1 s after Restart) and clears the mark as it mounts it again (1.3 s).
- **No continuous picture of the window**: the twice-a-second picture first used to keep a background login's
  window drawn stalled Basilisk II about 0.8 s each time, which made sound and video stutter (the user heard
  it). Instead each `wait-for` asks for a full redraw before its picture.
- **Quitting with the game** wasn't needed as planned: the app's Quit (⌘Q, the test's quit) shuts the Mac down
  by the power key and Return. SDL's NSApplication subclass answers `-terminate:` itself, so that's what's
  replaced. Cmd-Q inside the game quits the game to the Finder; the person then quits the app.
- **The ROM question** is a page in the main window (Cancel, Find One at the Internet Archive, Choose the ROM
  File…), `MAC_ROM_PATH` for headless builds; a Debug build downloads the development copy instead of asking.
- **The test** needs `tests: { window: windowed }`: the window starts windowed, and the green button
  (fullscreen, from the proof of concept's dylib) is in `basilisk_mac.m`.
- **Left over**: `sc`'s integration table shows Ingenious's engine as "wine", from the catalogue's
  `GameInfo.gameEngine`, which has no Basilisk case by design (the wrapp and WrappPuppeteer say basilisk);
  every step failure, the automation's included, reaches the person as "instructions have a problem"
  (`buildRecipeProblem`), as before.

## Decided with the user

Nothing: the user agreed the plan as revised (2026-11-07), with the ROM downloaded in Debug builds, the audio
permission given in every test account, and the ROM question linking to archive.org.

## Open questions

- The smallest `delay` that plays the video reliably (500 does; tune once it's a module's).
- Whether the boot disk, a whole 25 MB+ store, is fine per program, or a second small disk for Preferences is
  worth it (only if another program needs it).
- How many other 68k Director titles behave as well (a check for the porting skill, not for this port).

## After this port

- The user, 2026-11-07: once Ingenious is done, have an agent finish the Bioscopia port, trying the basilisk
  module (Basilisk II) as its route.
- Caveat found 2026-11-07: Bioscopia's Mac version needs Mac OS 8.1+ on PowerPC, which Basilisk II (68k) can't run.
  Its emulator would be SheepShaver (needs Apple's "Mac OS ROM" file and Mac OS 8.5–9.0.4, neither given away
  by Apple) or QEMU mac99 (Mac OS 9.1–9.2.2). Check the user's sources for those first. A module for it would
  share most of the basilisk module's shape.
