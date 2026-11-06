# Driving programs while porting: one toolkit, Peekaboo where it's better

Proposed 2026-11-05 and revised five times that day, as the [record of
revisions](#how-the-plan-changed) below says. Built 2026-11-05 to 2026-11-06.
Finished 2026-11-06, with what was left either measured or moved to the
candidates.

## Outcome

**Built:**

| Piece | Commits |
| --- | --- |
| The screen lease, and taking it by hand | `6f14f069`, `8673c436`, `d90e32db` |
| Lookups of processes and logs that see only this user's | `00035bc0`, `d061ae00` |
| Test sessions: the pool, `session add`, claim and release, the keep-alive | `e9b2cfda`, `6f41d950`, `f1222fac`, `605d8593` |
| Protocol v2 in the in-process helper, serving concurrently, armed in every process | `1b992084` |
| `sc puppet`: start, stop, `do`, `text`, `shot`, `saves`, `log --count`, `wait` | `c43aaf4c`, `952159f0` |
| Sharded integration runs across Macs (`--shard-on`) | `373dd4a6` |
| Peekaboo in test sessions, and whole-screen screenshots through it | `8d5d2bfe` … `02865b05`, `1095043a` |
| Named screens, needles cut into a bundle's format, `expect`, `--text` and `--needle` locators | `bde7b49d`, `cad529ce` |
| Wine dialogs by their controls (`c` refs), drafting the AutoIt that repeats them | `1a3c958b` |
| `record`, `sheet`, `audio` (a Core Audio process tap) | `f46136d7` |
| Clicks in a test session, where the Mac's pointer can't be moved (the virtual pointer) | `ab08115a` |
| One package for the control sockets' requests and replies (`Packages/PuppetProtocol`) | `8475c3e8` |
| Scrolling (protocol version 3), `--then` chains, `--json` replies, a finer change measure | `20f6e266`, `d84fb8c4` |

Instead of the separate `prepare` verb, `puppet start` copies an engine with
hardened runtime and signs the copy ad hoc. `PuppeteerVision` became
`Packages/PictureMatching`.

**Measured (2026-11-06):**

- **Input.**
  - Clicks land in a test session: a full disc-game integration run in one
    passed 32 of 33, every click-driven game included.
  - Posted keys reach a Wine game, ScummVM and DOSBox. Tyrian's set-up menu
    followed arrows, Return and Escape in a test session.
- **Capacity**, on the test Mac (M1 Max, 8 performance and 2 efficiency
  cores), with nothing else running. Old Clock (DirectDraw) and Secrets Can
  Kill Remastered (Direct3D) were launched and quit, as the integration test
  does, from 1 to 4 accounts at once (the console and three test sessions).
  The 3 and 4 runs were each done twice:

  | Accounts at once | Launches passed | Launch time (each game) | CPU peak |
  | --- | --- | --- | --- |
  | 1 | 3 of 4 (the failure: the session's screen locked) | 27–31 s | 3–4 cores |
  | 2 | 4 of 4 | 25–27 s | 5.8 cores |
  | 3 | 12 of 12 | 26–34 s | 7–7.5 cores |
  | 4 | 16 of 16 | 28–34 s, one 41 s | 8–8.3 cores |

  Four launches at once barely slowed each one, and kept the CPU at about the
  number of performance cores, which is where [Wine's
  cliff](2026-11-02-wine-hangs-under-load.md) begins. So the cliff is beyond
  four launches. A Mac holds three test sessions besides its console, so it
  can never run more than that, and a per-Mac launch-slot budget would limit
  nothing. More test users would need the slot count measured again.
- **Test sessions lock every 20 minutes.** The keep-alive is connected as a
  viewer but sends no input, so macOS counts the session as idle. Its default
  screen saver then starts and locks it. The keep-alive unlocks it within
  seconds, but a launch at that moment fails with "the screen is locked".
  Turning the test users' screen saver off would fix it; not done here.

**Not built, as candidates** ([section 8](#8-candidates-built-when-a-port-needs-them)):

- the per-Mac launch-slot budget;
- the benchmark (section 7);
- the helper's frame ring, with `stats`;
- `cursor`, with hover probing;
- one `look` verb with `w` and `t` refs;
- the background mode in the helper;
- why Escape seemed to do nothing in Secrets Can Kill Remastered.

**Ruled out:** a `CGVirtualDisplay` made in a test session, which lands on
the console user's desktop.

The rest of this document is the plan as it stood when it was finished, with
only the progress record and the candidates brought up to date.

## How the plan changed

Proposed 2026-11-05, then revised that day:

1. after a review of similar tools;
2. after a trial of Peekaboo on the test Mac;
3. after a full review of Peekaboo's docs and source, and of local models;
4. after a critical review of the plan against the code;
5. once several GUI logins turned out to run at once on one Mac. That changed
   the foundation ([section 0](#0-sessions-several-gui-logins-per-mac)), and
   the phases were reordered around it.

## Why

Porting a program means watching it and using it: getting past its start screen,
clicking through its menus, checking that video plays and sound comes out, saving and
loading. On 2026-11-05 an agent playing Bioscopia did that by hand:

- a one-off Peekaboo LaunchAgent per command;
- window coordinates added up by hand;
- a smooth move before every click;
- a full screenshot read after almost every action;
- every stop checked by hand.

It worked, slowly. What's missing:

- **A session** that starts any program with our in-process helper inside, holds the
  screen, and stops it cleanly. That includes Wine's server and desktop.
- **Input that games see:** moved to, held long enough, and real keycodes.
- **Replies that tell the agent what happened** without a picture each time, while
  leaving it free to look whenever looking is the quicker way.

## Principles

1. **Rich replies, and the agent chooses how to look.** The aim is the cheapest
   *route* to the right answer, and **turns cost more than pictures**:
   - every tool call re-reads the whole context;
   - deep into a session that is tens of thousands of tokens a turn;
   - a 640x480 frame is 414 tokens.

   So:
   - **Each action's reply carries everything cheap at once,** in about five lines:
     what's new (a window, a dialog, the program exiting), the outcome, how much
     changed, which screen it is if known, the text on screen, and new log lines
     counted. One call, no climbing.
   - **The agent looks** (`shot`, at the game's resolution or a crop) whenever it
     judges that's quicker: a new or puzzling screen, a choice of where to go, a
     question of quality. Nothing in the toolkit stands in its way, and the skill's
     `reference/token-budget.md` gives the costs.
   - **Text isn't free:** listings are capped (`--max`, then "+22 more").
   - **Picture-heavy stretches go to a `porting-player` subagent,** whose pictures
     never reach the lead's context.

2. **Every action reports its outcome.** The effect (`changed` / `no-change` /
   `unverifiable` / `refused`), from a before-and-after comparison. A `no-change`
   after a click means it missed or was ignored.

3. **Peekaboo for Mac-native windows; our helper for programs.** Peekaboo reads and
   drives Mac windows through Accessibility, better than we would. Games have no
   accessibility tree, poll their input, and run in fullscreen Spaces. Our
   in-process helper handles all of that and needs no permissions.

4. **A small core, built well; everything else a candidate with a trigger.** The
   skill's rule: don't build what no port has needed. The core replaces today's
   `gui-run`, `pbrun` and `pbclick`, and does what every port does. Everything else
   ([section 8](#8-candidates-built-when-a-port-needs-them)) waits for a port to
   need it.

## What it should feel like

Run from this Mac against the test Mac:

```sh
P="./sc --on <user>@<test Mac> puppet"
$P start lure --engine scummvm --purpose "Lure save/load check" -- --path=game lure
#   lure: scummvm pid 4121, helper armed; w1 "Lure of the Temptress" 640x400; lease taken; idle stop 10m
$P click lure --at 320,300
#   new: —   clicked 320,300 (moved, held 60 ms) → changed 64% → screen: ?
#   text: "Revolution", "presents"   log: —
$P shot lure                       # judged worth a look: a screen not seen before
#   shots/lure-002.png  640x400 (345 tokens at 2x)
$P name lure title                 # the title screen is now a named screen (a needle)
$P key lure f5
#   new: w2 dialog   key F5 → changed 31% → screen: ?   text: "Save game", "Load game", "Quit"
$P click lure --text "Save game"
#   clicked t1 "Save game" → changed 12% → text: "Enter a description:"
$P type lure "check1" && $P key lure return
#   typed 6 keys → changed 3%     |    key Return → changed 40% → screen: title?
$P saves lure
#   new since start: home/Library/Application Support/ScummVM/Savegames/lure.001 (12 KB)
$P stop lure
#   quit asked; gone in 1.1s; nothing left; screen held 15:02:11–15:06:40; lease released
```

One picture was read, where seeing helped. Every other answer came back in the
action's own reply.

## 0. Sessions: several GUI logins per Mac

**What we found (2026-11-05, the test Mac).** A second, standard user (a test user), logged
in through Screen Sharing's "Log in as yourself", gets a GUI session of its own:
`gui/502`, on a virtual display. The console user's session stays on the physical
screen meanwhile.

- **Games run there with full fidelity,** in front in their own session: native
  fullscreen, their own cursor and focus. That held for SkiFree (Wine), Lure
  (ScummVM) and Secrets Can Kill Remastered (Direct3D).
- **The real screen was untouched,** while another session's integration run went
  on.
- **Open problem: drawing with no viewer.** When the Screen Sharing viewer
  disconnects, games keep running, but whatever draws with OpenGL stops reaching
  the window: Direct3D was black, ScummVM froze. cnc-ddraw still animated.
  Details in [section 9a](#9a-running-without-taking-the-screen).

a test user now also exists on the development Mac, with the same authorized key.

### Assumptions this overturns

1. **"One screen per Mac, so screen work takes turns."** The unit is the GUI
   session, and a Mac can have several. Most of the coordination built so far
   rationed one screen: messaging peers before taking it, the screen lease, and
   "one screen-taking subagent at a time". Give each agent or test run a session
   of its own, and they don't contend.
2. **"Don't disturb the person, so screen work goes to the test Mac."** A session
   on the development Mac runs beside the person working on it, which suits fast
   porting loops (no sync). That Mac's disk is short (about 6 GB free), so the
   user frees space before a task that needs it.
3. **"Running beside a person needs a background mode in the helper"** (never
   activate, a virtual cursor, focus loss swallowed). In its own session a game
   really is in front, so nothing in Wine needs patching. That mode drops to a
   fallback for a Mac without spare sessions.
4. **"Integration tests launch one game at a time."** With N sessions, N games
   launch at once; builds already run side by side. The limit becomes CPU (Wine's
   cliff once every core is busy), measured per Mac as launch slots.
5. **The virtual display's job changes.** It was for hiding a window from the
   person. Now it's a candidate for keeping a session drawing without a viewer.

### What sessions need

- **A pool of test users per Mac.** Three each to start (a test user, `a second test user`,
  `a third`), more if the capacity measurements show they'd be used. A provisioning
  script creates them as standard users. It needs the admin password, so the
  person runs it. It:
  - adds them to `com.apple.access_ssh` and `com.apple.access_screensharing`
    (both admin-only by default);
  - installs the authorized key;
  - creates the shared folders.
- **Keeping each session alive and drawing, from the console user.**
  - A process in the console user's own session (which has the real display, and
    stays awake) holds a remote-desktop connection into each test session, as the
    Screen Sharing viewer did. It is a LaunchAgent in that session, started at
    login and restarted if it drops.
  - It also logs the test session in at the start, so nobody needs to use Screen
    Sharing by hand.
  - Wanted: the simplest, automatable, least resource-hungry way. Candidates, in
    order:
    1. a minimal VNC client (`vncdotool`, a small Swift/RFB client) that connects,
       asks for the occasional frame update, and draws nothing;
    2. macOS's own Screen Sharing app, minimised, scripted;
    3. ~~a `CGVirtualDisplay` created inside the test session~~ **ruled out
       (2026-11-05):** made from a test user's background session, the display was
       added to the *console* user's desktop (the person watching saw a second
       desktop appear), and the game in a test user never reached its fullscreen
       Space (no frames). Displays belong to the console session. (That run was
       also on a locked session, see below.)
  - **Spike result (2026-11-05): the minimal RFB client works.**
    a spike script (≈130 lines of Python, no
    dependencies: Apple's type-30 Diffie-Hellman + AES-128-ECB login through
    CommonCrypto, then an 8x8 update request every 2 s):
    - Run as a LaunchAgent in the console user's session. Over SSH the login
      keychain is locked (`security` exit 36), so the password can't be read there.
    - Server says `RFB 003.889` and offers types 30, 33, 36, 35; answering 3.8 with
      type 30 as a test user reaches **the test user's own existing session** (its
      ScreensharingAgent does the work), with no prompt on the console.
    - **The test session locks whenever its viewer leaves** (Screen Sharing locks it
      on disconnect), and a locked session never moves a game into its fullscreen
      Space (`capture`: "isn't in its fullscreen Space yet"). So the keep-alive must
      stay connected, and it unlocks: a click on the user's picture (bottom centre),
      2 s, then the password typed as key events and Return.
    - With it connected: Secrets Can Kill Remastered (wined3d) gave 4 distinct desk
      frames out of 6 (2 black fades), against 12 identical black frames before; Lure
      (ScummVM) gave 4 different frames out of 4.
    - Cost: the client 23 MB, ~0% CPU; screensharingd ~1.6% CPU while connected.
    - **It logs a session in from cold.** With a test user logged out (its own
      LaunchAgent sent loginwindow `aevtrlgo`), the same 3.8 + type-30 connection
      created its session: Finder and Dock up in ~3 s, nothing shown on the console.
      No session-select step is needed when the user isn't logged in.
    - Still to do: reconnecting after a drop; several sessions at once (needs a
      second test user); `log show`'s `processImagePath` is unreliable for wrapps
      (every WrappTemplate build shares one executable UUID), so log reads filter on
      `userID`, never the wrapp's path (3a's finding).
  - The spike measures, for each: whether OpenGL keeps drawing, the CPU and memory
    it costs, and whether it can log the session in by itself.
- **`sc` targets a session.** `sc --on the test user@the test Mac:<path> …` already reaches it
  (ssh takes `user@host`), and the GUI-session check asks launchd now
  (`9476b6f8`).
  - **Claiming:** `sc session claim [--mac <host>] [--purpose]` picks a free session
    from the pool and leases it, and `release` gives it back. Agents get a session
    without asking peers.
- **Session-aware leases.** One lease per session, kept where every user can read
  it (`/Users/Shared/second-chance/leases/<user>.json`, not in each home):
  - messages name the session ("the test Mac/a second test user");
  - `sc lease --all` lists every session on a Mac;
  - `take`, `release` and `expiring` work per session.
- **A load budget per Mac.** Today's load check would count another session's game
  as "other programs" and report `overloaded`. Launches take a slot instead. The
  number of slots per Mac is measured: how many games launch at once before
  Wine's cliff. Builds keep their disk reservations.
- **Per-user state.**
  - **Per user:** a checkout and build (`--skip-app-build` syncs a build into each);
    copies of game apps, since Wine insists on owning its prefix
    (`docs/plans-for-consideration/wrapps-for-every-user.md`); grants (Peekaboo,
    `screencapture`, the audio tap); the Steam sign-in; `.env`.
  - **Shareable:** the engine store, read-only in `/Users/Shared`, as engines are
    prepared once and read.
- **Logins are on demand,** by the keep-alive process. A logged-in test session
  takes `/dev/console`, which old `sc` builds and scripts misread (fixed in `sc` and
  remote-screenshot).

### Sessions interfere unless every lookup is per user

**What happened (2026-11-05).** Games run in a test user's session failed three games
in another agent's console integration run: SkiFree, Secrets Can Kill Remastered,
and Shadow Ranch. Two causes:

1. **Process lookups saw every user's processes.** WrappPuppeteer's
   `ProcessFinder.waitForProcess` took the first process of that name started since
   the launch, so the test could watch the other session's SkiFree. The wrapp's
   game monitor and its launch-progress check had the same blind spot. **Fixed:**
   `00035bc0`. ProcessList records each uid, and its lookups are this user's only.
   The load check counts another user's Wine as load.
2. **The integration test's system-log reader read every WrappTemplate line,**
   whoever's process it was. That failed a passing Shadow Ranch with the other
   session's "quit before its window appeared". **Fixed on
   refactor/builders-into-modules** (`8662f6f4`: filter on the launched wrapp's
   path). `VMPuppetRunner`'s `log show` has the same predicate, harmless in a
   single-user VM.

**Also: load.** Big Fish trial windows took 45–90 s to appear (normally about 3 s)
while games ran in the other session. That's the launch-slot budget's job.

**Rule until the session pool exists:** keep test sessions idle while a console
integration run is going on that Mac. When building the pool, audit for any other
per-system lookup: logs, `pgrep`/`pkill` patterns, `NSRunningApplication` by
bundle id (per session already), temp paths, sockets in `/tmp`.

### Sharded integration runs, across Macs

Integration tests run as shards: each game build-and-launch is a unit, run in any
free session on any Mac in the pool.

- **The coordinator** is the `sc test integration` the person runs. It:
  - lists the games and sources;
  - asks each Mac (`--on`) for its free sessions and launch slots;
  - hands out games, the biggest builds first, onto the Macs with the disk for
    them;
  - collects each shard's results, logs and recordings back into one report
    (results stay per Mac today; shards copy theirs back).
- **A shard is today's per-game flow** (`IntegrationGameRun`), run by `sc` as that
  session's user, with `--skip-app-build` and a synced build.
- **Installers are where they are.** A game whose disc images exist on only one Mac
  runs there. The coordinator matches games to Macs by which installers each has,
  read from `installers/`.
- **Failures stay attributable:** each row names the Mac and session it ran on.
  A game is retried on another Mac only on an infrastructure failure (the session
  dropped), never on a test failure.
- **The release gate stays meaningful.** Every session plays exactly as a player's
  Mac, so a shard's pass counts like today's.

## 1. What others do, and what we take

The reviews (2026-11-05) covered Peekaboo's docs and source in full, local GUI
models, and the wider landscape. Nothing does the whole job: every tool needs a DOM,
an accessibility tree, permissions, or an instrumented build, and none is built for
games.

| Tool / pattern | What we take |
| --- | --- |
| **Peekaboo** | Its CLI, for Mac-native windows and system alerts ([section 2](#2-peekaboo)). Its outcome vocabulary. Its visualizer, by sending it events (a candidate) |
| **Playwright** (CLI + skills for coding agents) | A long-running session with thin clients; locators resolved at action time; actionability checks; strict matching; `expect`; isolated sessions; text replies with paths, not inline pictures |
| **Midscene.js, Cua, Agent S3, UFO2** | The split: the agent plans and judges; cheap local signals (OCR, frame statistics, the Wine control tree) do the routine checking; a small model only where it measurably helps (a candidate). Waits poll cheap signals, never a model |
| **openQA, SikuliX** | Needles with similarity, regions and click offsets (ours already). A failed `expect` keeps the closest match and a diff; needles are cut from a session's frames into the bundle's format |
| **Anthropic's computer use tool** | Zoom as a crop at native pixels; held keys; mouse down and up; image costs (the token budget) |
| **AltTester; Peekaboo's GameBridge** | Ask the program when it can say more than its pixels: the Wine control tree for dialogs and installers; ScummVM's debugger as a candidate |
| **VideoGameBench** (2025) | Painted point-and-click hotspots defeat small models: keep them for the agent's eyes, a needle, or the hover probe (a candidate) |
| **Cua Driver, CGVirtualDisplay** | Background input and a display per session: spikes in phase 1, since a session that leaves the screen alone would end the one-screen bottleneck |

## 2. Peekaboo

**Set up on the test Mac (2026-11-05):**

- Peekaboo.app 4.9.7 runs as the login agent `boo.peekaboo.bridge-host`
  (`--background-bridge-host`, `bridge.sock`), granted Screen Recording,
  Accessibility and Event Synthesizing.
- The CLI is `openclaw/tap` 4.9.7 (notarized).
- Over SSH every call sets `PEEKABOO_BRIDGE_SOCKET` to that socket. That pins the
  route and stops the CLI auto-starting daemons from the SSH session: those have no
  grants, and take the per-user capture lock.
- Never pass `--no-remote` from SSH.

**Use it for:**

- **The game app's own windows,** beyond what `wrapp.sock` already offers (`info`,
  `confirm` for the save warning).
- **Second Chance itself,** and installers that are Mac apps.
- **macOS's alerts and prompts:** `dialog list` / `dialog click --button "…"`, in the
  background, never taking focus. This is also how the screen is kept clean (the
  skill's `reference/test-mac-screen.md`).
- **`window list` and `space list`,** for finding where things are.

**Not for games:**

- Their accessibility map is empty.
- Background clicks: a single left click only presses accessibility elements. Its
  docs say right, double, middle and triple clicks go through routed `CGEvent`s;
  worth one test on a Wine window in the background spike.
- Its background typing sends virtual keycode 0 plus a Unicode string
  (`BackgroundInputDriver.swift:492`). The foreground path is unverified.
- Capture needs the window on the current Space.

**Don't depend on its libraries.**

- They are large, MainActor-heavy and fast-moving (4.0 to 4.9.7 in 2.5 months).
- They bring a per-user capture lock and private API into our process.
- Copying pieces turned out unnecessary too. Our `ImageFingerprint` covers the
  differ and the dHash, and the helper's move, hover and hold click already works
  where the human path would have helped.

**Learn from it:**

- move before a click, and hold for frames;
- report the real reason something was refused, not a stock message;
- set `collectionBehavior` on any overlay meant for fullscreen Spaces;
- check a window's id, pid and bounds before a coordinate action.

## 3. The helper: protocol v2 (`puppet_control.m`)

**Unchanged:**

- one line each way, replies starting `ok` or `error`, window points from the top
  left;
- the socket name `game-<pid>.sock`, which the test scenario
  (`NancyDrewQuitScenario.swift:147`) and every built wrapp use.

**Changed:**

- **Serve concurrently,** a thread per connection. Today one slow capture (8–16 s on
  a worn-down Mac) blocks every click behind it.
- **A frame ring.** An in-process `SCStream` on the game window keeps a few seconds
  of small (about 160 px), downscaled greyscale frames. Requests ask it for numbers,
  not pictures. This is what makes change detection, "still", "black" and "video
  playing" cheap. Today each look is a PNG written to disk. Phase 1 measures its CPU
  cost on the test Mac first.
- **Arm in every process: `PUPPET_CONTROL_EXE=*`.** `processRunsExeNamedBy`
  (`helper_common.h`) matches exactly today. Add the `*` that `hidden_windows.m:116`
  already has, so installers, launchers and the game each get a socket.

**New requests:**

| Request | Reply / effect |
| --- | --- |
| `hello` | `ok version=2 pid=… exe=… commands=…` (old helpers in built wrapps answer `error`, and the client copes) |
| `windows` | One line per window: `id`, title, frame, level, visible, key, kind (`main`, `dialog`, `panel`). Needed: the "biggest visible window" rule picks the game over a Wine message box |
| `stats since=<t> [window=] [region=]` | From the frame ring: change % and motion box since `t`, black %, frames a second, how long it's been still |
| `capture <path> [window=] [region=] [scale=]` | As now, plus a window, a region (the zoom, at native pixels) and a scale |
| `click <x> <y> [window=] [button=] [count=1..3] [hold=<ms>]` | As now: a move, a 150 ms hover, then a press held (default 60 ms, two frames) |
| `down` / `up` / `drag` / `scroll` | Presses and releases alone; a drag as press, a few moves, release; scroll-wheel events |
| `key <name>[+mods] [hold=<ms>]` | Key down, hold (default 60 ms), key up, **with the real virtual keycode**. Names: `return`, `escape`, `f1`, `left`, `a`, `cmd+q` |
| `type <percent-encoded text>` | A real keycode for each character (US layout), held and spaced |
| `focus [window=]`, `cursor` | That window to the front; the cursor's image hash and hot spot (for the hover-probe candidate) |

All input goes through `NSApp postEvent:`, as clicks do now. Phase 1 proves posted
keys in Wine (a DirectInput game and a `GetAsyncKeyState` one), ScummVM and DOSBox
(Tyrian, where scancodes will break first).

## 4. Getting the helper into what's run

This is already done for:

- **Wine:** prepared Wine's `winemac.so` has a weak dependency on the helper
  (`MachOPatch`).
- **ScummVM:** `DYLD_INSERT_LIBRARIES` (`ScummVMRuntime.swift:41`).
- **DOSBox:** the same (`DOSBoxRuntime.swift:41`).

The dylib is universal. The one new piece is `puppet prepare <app>`: an ad-hoc
re-signed copy of an engine downloaded for an experiment. The downloaded ScummVM
2026.4.0 has hardened runtime, which ignores inserted libraries. Mac-native windows
go through Peekaboo.

## 5. Puppet sessions (driving a program)

### Where they run

A session is a **`sc` job in the GUI session**, using the machinery `sc` already
has:

- `LaunchAgentJob`, `attach`, `attach --stop`;
- **the screen lease, held by that `sc` process** for the session's life.

`sc puppet start` launches it, and every other `sc puppet …` verb is a thin client:

- **No sync.** The verbs skip the repo sync, as `attach` and `lease` do, so a
  session left running never blocks `--on`.
- **One SSH connection.** Clients reuse a persistent connection (ControlMaster), so
  a click doesn't pay ssh setup.
- **Pictures come back.** Shots are copied to this Mac (the porting workspace's
  `shots/`) when made.
- **It builds where it runs.** The server is Swift in `Tools/sc` (SwiftPM, which
  builds on the test Mac), not WrappPuppeteer (Xcode, built here and synced). Changing it
  doesn't mean a `--skip-app-build` round trip.

**Ending:**

- **Idle stop:** 10 minutes since the last client call, plus `--max-minutes`. A
  watch on the agent's process can't see across ssh.
- **One driver at a time.** The lead and a subagent can share a session's name
  through the brief, but only one drives it at once.
- **Stop the session before handing the test Mac over,** for example to a bundler's
  integration test, or the lease stops that test.

### Starting and stopping

- **`start <name> [--wrapp <app> | --engine <id> | --wine <prefix> | -- <command>]`**
  - **Isolation:** an empty HOME and `SECOND_CHANCE_APP_SUPPORT_DIR` by default.
    `--home <dir>` reuses one, for a relaunch that keeps its saves (rung 5).
  - **Engine debug switches:** `--winedebug <channels>` and `--debugflags <flags>`
    (ScummVM), so the log says something.
  - **Wine starts through WineKit,** as the repo requires: `Wine.start` with a
    `WineCommand`, `runWithoutCrashHandler`, and Wine's desktop (`WineDesktop`) up
    before the program, or a loaded Mac starts the game with no display. `sc wrapp
    wine` already does this.
  - **The first reply:** the windows, the helper's state, the lease, and when it
    will stop if idle. If native fullscreen is still settling, it says "waiting",
    not "failed".
- **`stop <name>`:**
  1. ask the program to quit (the helper's `quit`);
  2. a grace period;
  3. for Wine, `wine.server.kill()` (which ends `wineserver`, `explorer.exe` and the
     services);
  4. a pid-tree check that reports anything left.

  It never uses a pattern kill. It prints the times the screen was held, for the
  message to peers.
- **`status`, `log [--since] [--grep] [--count]`.** `--count` gives `uniq -c`-style
  counts, as a log of 481 identical Lingo errors deserves.

### Replies

Every action's reply is about five lines:

```text
new: <windows or dialogs that appeared, exit, crash or quit-watch report — or —>
<action and where> → <effect> <change %> [box] → screen: <name|?>
text: <up to N OCR lines, quoted>          log: <new lines, counted>
```

- `--max <n>` caps listings.
- `--json` gives everything, for scripts.
- `--verbose` adds detail.
- Exit codes: 0 done, 1 error, 3 timed out, 4 program gone, 5 ambiguous.

### Looking

- **`shot [--region x,y,w,h] [--scale native|2x]`.** A picture at the game's own
  resolution, or a crop, or 2x for a small DOS frame. Copied back; the path is
  printed.
- **`text [--region]`.** OCR lines with boxes and refs (`t1` …), upscaled
  nearest-neighbour first for pixel fonts.
- **`screen`, and `name <screen>`.** Which named screen this is and how sure. Names
  come from the bundle's needles, and `name` cuts one from the current frame in the
  bundle's `tests/needles/` format, so a port's session grows its integration test's
  needles. Matching starts with our `ImageFingerprint`, with Apple Vision's feature
  prints (`VNGenerateImageFeaturePrintRequest`) if that proves better.
- **`look`.** Refs for windows (`w`), text (`t`) and Wine controls (`c`, from
  phase 4), capped, with the shot's path, refs drawn on it.

### Acting

- **Locators**, resolved at the moment of action:
  - `--text "<s>"`;
  - `--needle <yaml>` / `--image <png>`;
  - a ref (`t3`, `w1`, `c4`);
  - `--at <x> <y>`.

  They take `--within`. They are **strict:** two matches is an error listing both
  (`--nth` picks one).
- **Before acting,** it waits (short, capped) until:
  - the target resolves;
  - the target's own region is still, because a whole screen never is in a game
    with idle animation;
  - the window is in front;
  - the cursor lock is done.
- **After acting,** it replies as above. A coordinate action is refused if the
  window moved or was replaced since its ref was made.
- **Actions:** `click`, `move`, `down`, `up`, `drag`, `scroll`, `key`, `type`.
  Chaining (`--then …`) saves a turn when the next step needs no judgement.

### Waiting and checking

- **`wait --change | --still <s> [--region] | --screen <name> | --text <s> | --window | --exit [--timeout]`**:
  polls the frame ring and OCR, never a model.
- **`expect <locator | --screen <name>>`**: retries until true. A failure keeps the
  shot, the closest match and a diff.

### Senses beyond the picture

- **`saves`**: files created or changed under the session's HOME, prefix or game
  folder since a mark. This finds the bundle's volumes (step 8) without hunting.
- **`audio`** (phase 5): sound levels over time from a Core Audio process tap
  (`AudioHardwareCreateProcessTap`, macOS 14.2+). "Output running" isn't enough,
  because SDL and Wine keep their streams open playing silence, so Bioscopia's
  missing sound effects would read as fine. The tap needs the system-audio
  recording permission, which the user will grant on the test Mac. That is the one part
  that wants a signed app: a small helper target, not the whole server.
- **`record`** (phase 5): the frames into a `.mov` with chapters (`VideoAnnotator`),
  for people. **`sheet`**: a contact sheet of the frames that changed, as an add-on
  to `record`.

## 6. Wine dialogs and installers

Installers come early in nearly every Windows port, and step 5's `INSTALLER.RUN
--automation` needs an AutoIt script. A helper run in the same prefix lists the
dialog's controls: class, ClassNameNN, text, rectangle and handle. AutoIt's
`WinList`, `ControlGetText` and `ControlClick` do that, and we already ship AutoIt.
It brings two things:

- **`c` refs:** `click setup c2` presses "Next >" by handle, whatever the screen
  shows.
- **AutoIt lines:** for each action the session prints the line that repeats it, so
  the installer's script is drafted by doing the install once.

## 7. Measuring it

Without a measurement, "token-efficient" is a guess. So:

- **A fixed benchmark** of programs that already work, each with set goals:
  - SkiFree (Wine, DirectDraw);
  - Lure of the Temptress (ScummVM; save and load);
  - Tyrian 2000 (DOSBox, keyboard);
  - one Nancy Drew game (Direct3D, a cursor it draws itself);
  - one Wine installer.
- **Counted from Claude Code's transcript files** (`*.jsonl`, per turn: `input`,
  `cache_read`, `cache_creation`, `output`): tokens, summed for the lead and its
  subagents; turns; wall time; pictures read.
- **A/B on the same tools:** "pictures only" (`shot` and Read after every action)
  against "rich replies". Comparing with the improvised Peekaboo session would mix
  up tool friction with the replies' value. The Bioscopia log has no counts, so it
  isn't a baseline.
- **Every phase's "done" says what the benchmark should show.** A change that
  doesn't lower turns or tokens, or doesn't keep the agent as right, doesn't stay.

## 8. Candidates, built when a port needs them

Each has the trigger that would justify building it. Until then it's an idea, not
work.

| Candidate | Trigger |
| --- | --- |
| **Local vision model `ask`** (Qwen3-VL-4B or Holo2-4B on the test Mac, loaded on demand, never while another holder has the lease; yes/no questions) | It beats OCR plus frame statistics plus the agent's look on the benchmark, in turns and correctness. Apple's on-device Vision (feature prints, OCR) is tried first, as it needs no download |
| **Grounding by description** (`--describe`) | Probably never: OCR covers text, the control tree covers Wine controls, and small models fail on painted hotspots. Only if a port shows otherwise |
| **Hover probing** (find clickable regions by cursor change) | A point-and-click port where finding hotspots costs many turns. First as a one-game experiment, since games that draw their own cursor (ScummVM, Nancy Drew) need a capture per cell |
| **The visualizer** (Peekaboo's, for people watching the test Mac) | When people watch sessions. As a sender only: write Peekaboo's event JSON and post its notification, and the Peekaboo.app already on the test Mac draws it. Offer upstream the `collectionBehavior` fix for fullscreen Spaces |
| **Codegen** (a person plays, the session writes the commands) and **export** to a scenario | A long play-through needed more than once. Scenarios are sets of handlers, so export drafts handlers from named screens, not a list of steps |
| **ScummVM's debugger as a source of refs** | A Director port whose sprites matter (also a debugging aid, as for Bioscopia's handlers) |
| **A session as a Midscene device** | If a planner-in-the-loop proves useful |
| **The helper's frame ring** (an in-process `SCStream` keeping small greyscale frames; `stats` from it; dropped from phase 5 by the user's decision) | Before-and-after captures prove too slow, or miss changes shorter than an action's wait |
| **Running without taking the screen** | Done another way: test sessions ([section 0](#0-sessions-several-gui-logins-per-mac)). A virtual display was ruled out |
| **A per-Mac launch-slot budget** | A Mac with more test sessions than launches it can take at once: four at once didn't reach the cliff on an M1 Max (measured 2026-11-06), and a Mac has three test sessions besides its console |
| **The benchmark** (section 7: turns, tokens and pictures, "pictures only" against rich replies) | Someone proposes a candidate whose trigger is the benchmark, such as the local model; or a cheap version first, one `porting-player` run per goal with its counts |
| **`cursor`** (the cursor's image hash and hot spot) | Built with hover probing |
| **A `look` verb with `w` and `t` refs** | Agents keep asking for one: `controls` gives `c` refs, and `text`, `screen` and the `--text` locator cover the rest |
| **Escape in Secrets Can Kill Remastered** (no visible effect on the desk or case file: unbound, or unseen) | A port needs Escape in a Direct3D Nancy Drew game |
| **The helper's background mode** (section 9a's approach 1) | A Mac with no spare test session |

## 9. The test Mac's screen

- **The lease** (`docs/dev-cli.md#the-screen-lease`):
  - every `sc` command that opens windows takes it;
  - work outside `sc` takes it by hand (`sc lease take --for 30m --purpose …`,
    `sc lease release`);
  - **looking needs no lease**, but must leave the screen alone during someone
    else's;
  - sessions hold it through their `sc` job.
- **Keeping it clean:** while holding the screen, an agent may dismiss notifications
  and alerts, hide windows, and change settings (Do Not Disturb, an app's
  notifications), restoring them afterwards. The how-to is the skill's
  `reference/test-mac-screen.md`.

## 9a. Running without taking the screen

Research (2026-11-05: Wine 10 source, SDL2, ScummVM, DOSBox Staging,
CGVirtualDisplay users; nothing run yet). This could let ports and test runs go on
while the Mac is in use, or side by side on the test Mac. [V] means checked in source;
[I] means still to be proved by experiment.

**What stands in the way today.** A virtual display alone doesn't fix it: a login
session has one cursor and one active app. And Wine's Mac driver ties a game to both:

- **Losing focus is reported to the game [V].** When the app deactivates, the game
  gets `WM_ACTIVATEAPP(FALSE)` (`applicationDidResignActive:`,
  `macdrv_app_deactivated`). Direct3D games then restore the display mode and
  minimise (wined3d). cnc-ddraw lets go of the mouse, and many old games pause.
- **`GetCursorPos` reads the person's real mouse [V].** Our posted events are
  trusted for only 100 ms, then `[NSEvent mouseLocation]` is read (win32u
  `get_cursor_pos`). This may even be why clicks need a 150 ms hover.
  `GetAsyncKeyState` is clean: it reflects only Wine-delivered input.
- **A game can grab the person's cursor [V].** `SetCursorPos` warps it, and
  `ClipCursor` confines it.
- **Posted moves are dropped where another window covers the game [V]**
  (`windowNumberAtPoint`). Clicks still reach an inactive window
  (`acceptsFirstMouse` YES).
- **Posted keys go nowhere while inactive [I]** (no key window). Calling the
  window's `postKeyEvent:` directly avoids that.
- **Drawing goes on when the window is hidden or covered [V];** App Nap is off.
- **There is no offscreen Wine display driver [V]:** our Wine ships only
  `winemac.so`.

For the SDL engines: SDL handles posted events whatever window is key [V]. A click
on an inactive SDL window needs `SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH=1` [V]. Nancy and
Director in ScummVM ignore focus loss [V], and DOSBox Staging pauses only if it's
configured to [V].

**The approaches, ranked:**

1. **A background mode in the in-process helper** (dev-only, under the puppet
   directory). It:
   - never activates;
   - swallows the focus-loss events, so the game believes it's in front;
   - gives the game a virtual cursor (`mouseLocation` answered for winemac;
     `setCursorPosition:` and clipping recorded, never applied to the real
     cursor);
   - routes moves to the game window even when covered;
   - delivers keys through `postKeyEvent:`;
   - sets SDL's click-through hint.

   Native fullscreen is off, so games run windowed: in a corner, behind other
   windows, or on a virtual display (approach 3). ScreenCaptureKit captures a
   covered window [V for streams, per WWDC22 10155; I for our screenshots].
   - **Covers:** DirectDraw (cnc-ddraw), ScummVM, DOSBox, and windowed Direct3D.
   - **Doesn't cover:** fullscreen Direct3D still sizes to the person's display.
   - **Gives up:** the activation, native fullscreen and cursor lock that players
     hit. So the foreground run stays the release gate.
2. **A second macOS user, logged in through Screen Sharing in the background.**
   That session has its own WindowServer state: its own cursor, active app, Spaces
   and virtual display.
   - **For:** wrapps would run there unmodified, every engine and graphics path, at
     full player fidelity.
   - **Unknowns [I]:** whether OpenGL is accelerated there, especially once the
     viewer disconnects, and whether capture and posted input work.
   - **Practicalities:**
     - `sc`'s GUI-session re-run targets that user's `gui/<uid>`;
     - file access to builds and the engine store;
     - Steam and Big Fish sign-ins are per user;
     - a lease per session.
   - The least code, if it renders.
3. **A virtual display (`CGVirtualDisplay`) as the window's home.** Private API,
   working on macOS 14–26 per go-macos (tested on 26.6.2) and Chromium's test
   utility. Its quirks:
   - removal is asynchronous;
   - a display whose mode changed can't be removed until its process exits;
   - each display leaves an ICC profile in `/Library/ColorSync/Profiles/Displays`.

   It gives an unoccluded, unseen spot, but not a second cursor or focus. Making
   Wine treat it as the primary display (extending `display_below_notch.m`'s
   answers) would let fullscreen Direct3D games run there at their own mode, with
   no scaling.
4. **Each engine's headless mode.**
   - **ScummVM:** works already (no input).
   - **DOSBox Staging 0.83:** documents `SDL_VIDEODRIVER=dummy` [V]; input through
     `AUTOTYPE`.
   - **Wine:** none.
5. **VMs:** Direct3D through wined3d's Vulkan renderer and MoltenVK (Wine 10's
   fixed-function Vulkan path) might render in tart [I]. That's useful for "does it
   reach the menu" checks, not for gating releases.
6. **Input from outside** (`CGEventPostToPid`, SkyLight) gains nothing over the
   in-process route for Wine, and needs Accessibility. Skip.

**Results so far (2026-11-05, the test Mac, macOS 26).** The second-user session works,
with the viewer connected:

- **Setup:** a standard user, a test user, logged in through Screen Sharing's "Log in as
  yourself". It got its own GUI session (`gui/502`) on a virtual 2560x1440 display,
  while `the console user`'s session stayed on the physical screen
  (`kCGSSessionOnConsoleKey`: the console user true, the test user false).
- **The games**, run from wrapps that a test user copied (so it owns them), one at a
  time, with the in-process puppet helper and an isolated
  `SECOND_CHANCE_APP_SUPPORT_DIR`:

  | Game | Result |
  | --- | --- |
  | SkiFree (Wine, DirectDraw) | Native fullscreen on the test user's display; captures animate; a posted click restarted the skier. The cursor lock gave up after 15 middle clicks |
  | Lure of the Temptress (ScummVM) | Native fullscreen; the intro captured and moving (the Virgin logo) |
  | Secrets Can Kill Remastered (Direct3D) | **Rendered**: the Nancy Drew splash captured, and quit watch saw the "first frame on screen". Hardware OpenGL works in a background session |

  Each quit cleanly on request, and nothing was left.
- **The console:** checked by screenshot, it showed only the other session's
  integration run, which went on throughout.
- **Gotchas found along the way:**
  1. **Wine refuses a prefix owned by another user.** Copies must be made by the
     user who runs them. See `docs/plans-for-consideration/wrapps-for-every-user.md`.
  2. **A second Screen Sharing login takes `/dev/console`.** That broke `sc`'s
     GUI-session check (fixed: 9476b6f8, now asks launchd) and the
     remote-screenshot skill's (fixed the same way).
  3. **Builds older than the current helper** name the socket `game.sock`, not
     `game-<pid>.sock`.

- **With the viewer disconnected** (2026-11-05, same session still logged in), what
  we capture stops changing for every game that draws with OpenGL:

  | Game | How it draws | Viewer disconnected |
  | --- | --- | --- |
  | SkiFree | cnc-ddraw | **Still animates** (four different frames) |
  | Lure | ScummVM, OpenGL | First frame (the Virgin logo), then identical frames |
  | Secrets Can Kill Remastered | wined3d → OpenGL | **Black** for a whole minute (12 identical frames) |

  The game itself keeps running. Secrets.exe was at 132% CPU, its main thread in
  AppKit's ordinary event loop, so nothing blocks. It's the picture that stops
  reaching the window.

  - **Likely cause:** with no viewer, the session's virtual display has no one
    consuming it, and WindowServer stops compositing OpenGL surfaces onto it (no
    refresh). Not proved.
  - **Next experiments, cheapest first:**
    1. A viewer left connected but minimised or hidden on another Mac: if that
       works, it's a workaround today.
    2. A `CGVirtualDisplay` created inside a test user's session, a display that
       stays "live" with no viewer (section 3 above).
    3. An `SCStream` running on the window (the planned frame ring), in case a live
       stream keeps it composited where one-shot screenshots don't.
    4. Software presentation: ScummVM's `surfacesdl`; Wine's GDI path.

  Also still to do: the cursor lock's give-up in a background session, and driving
  input in more depth.

**Spikes, in phase 1, in this order:**

1. **The current helper with the game inactive, covered and the real mouse moving**
   (1 h, no code): `yield` to the Finder, cover the window, then `capture`,
   `click`, and watch whether the game follows the real mouse.
2. **A second user session with a Direct3D game** (1 h; needs a test user on
   the test Mac): frames, `capture` and `click` with the viewer connected, then
   disconnected.
3. **A virtual display:** a 40-line tool making an 800x600 display, and a windowed
   DirectDraw wrapp moved onto it.
4. **Side checks:** DOSBox's dummy driver (15 min); the Vulkan renderer in a VM
   (30 min).

Spike 1 sizes the background mode; spike 2 decides whether it's needed for full
fidelity.

## 10. Where the code goes

| Piece | Home | Why |
| --- | --- | --- |
| The wire protocol (helper and session sockets, the reply format) | A new dependency-free package, `Packages/PuppetProtocol` | `sc` can't depend on PuppeteerCore, which brings SecondChanceKit and Sentry (`Packages/PuppeteerCore/Package.swift`) |
| OCR, fingerprints, template matching | Split from PuppeteerCore into a dependency-free `PuppeteerVision`, used by WrappPuppeteer and `sc` | Same reason; they need nothing but Apple's frameworks |
| The session server and the `puppet` verbs | `Tools/sc` (`sc puppet …`, run as a GUI-session job) | It holds the lease, builds on the test Mac, and iterates fast |
| Wine start and stop | WineKit (`Packages/WrappKit`) | The repo's rule |
| Protocol v2 | `WrappTemplate/InProcessHelpers/puppet_control.m`, `helper_common.h` | Serves the tests too. WrappPuppeteer's scenario gains keys, window-targeted capture and region-scoped settling |
| The control-tree helper | Beside the AutoIt scripts the wine module uses | Already the installers' tool |
| The audio tap | A small signed helper target | The only part needing a permission |
| Docs | `docs/testing.md`, `docs/wine-in-process-helpers.md`, `docs/dev-cli.md` | With the code |
| Using it | The skill: steps 5–8, `reference/driving-programs.md` | Updated in the phase that changes it. `gui-run`, `pbrun` and `pbclick` retire when the session replaces them |

## Phases

Each phase is committed and usable on its own, and its skill changes ship with it.

**Progress (2026-11-05, completed 2026-11-06):**

| Phase | State | Evidence |
| --- | --- | --- |
| 1 keep-alive | **done: yes** | RFB client keeps a test session logged in, unlocked and drawing; logs one in from cold (§0) |
| 1 virtual display | **no** | lands on the console user's desktop |
| 1 input | **yes** (2026-11-06) | posted keys: SkiFree arrows + F2 (Wine), Ctrl-F5 opens ScummVM's menu, Tyrian's set-up menu follows arrows, Return and Escape (DOSBox, in a test session); clicks open SCK Remastered's case file in a test session, and with the virtual pointer (ab08115a) a full disc-game run in a test session passed 32 of 33. Escape had no visible effect in SCK (desk, case file): left as a candidate |
| 1 capacity | **measured** (2026-11-06) | three test sessions and the console per Mac; four launches at once on the M1 Max test Mac all passed, about 10% slower, CPU at the performance-core count: the cliff is beyond four ([Outcome](#outcome)) |
| 2 session pool | **built** (e9b2cfda; the fork: numbered users, shared installers store, add installs the keep-alive) | claim/release from the dev Mac; keep-alive LaunchAgent on the test Mac |
| 3 helper v2 | **built** (1b992084) | SkiFree integration run passed with it; `hello` answers in 14 ms during a capture |
| 3 puppet session | **built** (c43aaf4c) | Lure in the test user: start, do click/key (47%/28% changed), text (OCR), shot (1196 tokens), log --count, saves, stop (held 18:34–18:37) |
| 3 wait, engines by hand | **built** (952159f0) | Bioscopia under ScummVM 2026.4.0 (hardened runtime: copied and re-signed) in the test user: start screen → intro → menu → New game, blocker reproduced, mostly from `text` and `log --count` |
| 4 sharded runs | **built** (373dd4a6) | `sc test integration … --shard-on <host>[,…]`: one claimed test session per Mac, games matched to the installers each Mac has, one merged table naming Mac and session. One shard per Mac until capacity is measured |
| 2 keep-alive hang | **fixed** (605d8593) | the keep-alive's keychain/ioreg lookups through swift-subprocess sometimes never resumed (a task waited for ever, nothing logged); now Foundation `Process` |
| 2 keep-alive's own copy | **done** (f1222fac) | runs a copy of sc in Application Support, not the checkout every sync rebuilds |
| Peekaboo in test sessions | **built** (8d5d2bfe … 02865b05) | `sc session setup-peekaboo [<user>] [--on <host>]`: installs Peekaboo if missing (pinned, checksummed), starts its bridge in each test session, opens the pane there and Screen Sharing here (password via a named pipe, never saved), waits for the grants. On this Mac: adds this Mac's keys to the test user (sudo) and tunnels Screen Sharing over SSH (untested) |
| 5 named screens, needles, `expect`, locators | **built** (bde7b49d, cad529ce) | the frame ring and `stats` left as a candidate, by the user's decision |
| 6 Wine dialogs and installers | **built** (1a3c958b) | `controls` lists `c` refs; each action prints the AutoIt line that repeats it; `autoit` prints the script so far |
| 7 senses | **built** (f46136d7) | `record` (a movie with a chapter per action), `sheet` (the frames that changed, in one picture), `audio` (a process tap, through a small signed app) |
| Clicks in test sessions | **fixed** (ab08115a) | a test session's pointer can't be moved; the virtual pointer shows the game one that follows posted moves |
| PuppetProtocol | **built** (8475c3e8) | one Foundation-only package for the helper's and the wrapp's socket requests and replies, used by sc and PuppeteerCore |
| §5's remaining verbs | **built** (20f6e266, d84fb8c4) | `do … scroll` (helper protocol version 3), `--then` chains, `--json`; `do` measures change on a finer thumbnail and says where it changed, as Tyrian's menu highlight read as no change |
| `prepare` | **not needed** | `puppet start` copies a hardened engine and signs the copy ad hoc |

**From the fork's set-up work (2026-11-05):**

- Test users are `second-chance-testing-<n>` (the user's choice); the test Mac's a test user is
  adopted as it is. `sc session add [--count n]` makes them, shares the installers and
  installs the keep-alive: phase 2's provisioning script is done.
- Installers: `/Users/Shared/second-chance/installers` per Mac (inheriting ACL); each
  checkout's `installers` links there, and `--on` sends them by their own rsync.
- Still per account: the engine store (the main per-account cost left: share it
  read-only next), `.env`, the Steam sign-in, Screen Recording/Peekaboo grants.
- The keep-alive runs from the runtime copy's `sc`, which every `--on` sync rebuilds; a
  broken build there stops it restarting. Give it its own copy.
- AGENTS.md "Where to run what takes the screen" puts test sessions first; the skill
  and its agents point there.

**Decisions since (2026-11-05, evening):**

- **Whole-screen looking is Peekaboo's, per account.** macOS won't let a script grant
  Screen Recording or Accessibility (TCC behind SIP; MDM can't pre-approve Screen
  Recording), so `setup-peekaboo` makes the person's part a minute an account. Then
  `peekaboo see --mode screen --no-elements --path <png>` (Peekaboo 4: `image` is gone)
  over SSH with `PEEKABOO_BRIDGE_SOCKET` replaces the remote-screenshot skill, which is
  retired once the test accounts have their grants. The Screen Sharing server's frames
  (no grant at all) stay the fallback if per-account grants prove a burden.
- **Decided by the user (2026-11-05, late):** the helper's frame ring is dropped from
  phase 5 and becomes a candidate (trigger: before-and-after captures prove too slow or
  miss short changes). The rest of phases 5–7 is built now: named screens, needles
  into bundles, `expect`, locators (5); the Wine control tree and AutoIt lines (6);
  audio, record and sheet (7). The earlier proposal, kept for the record: Small captures before and after an action already answer
  changed/still/black; named screens wait for a bundle's test to need needles; the
  Wine control tree for the first installer port; audio when a port's sound can't be
  judged from its log.
- **Lessons from the first ports through the toolkit:** Bioscopia's blocker was found
  windowless (`--start-movie`, `--dump-scripts`), not with `puppet`; `text` and
  `log --count` carried most of the replay; a capture above the window's own scale
  leaves an OpenGL surface in a corner (fixed: never above it).

1. **Spikes (days).**
   - **Session keep-alive,** from the console user's session: a minimal VNC client,
     the Screen Sharing app scripted, and a `CGVirtualDisplay` in the session.
     Measure whether OpenGL keeps drawing, the CPU and memory, and whether it can
     log a session in unattended.
   - **Capacity:** how many background sessions macOS allows at once (Screen
     Sharing's high-performance mode may allow one); and launch slots per Mac (game
     launches at once before Wine's cliff), on the test Mac and on the development Mac.
   - **Input:** posted keys, holds and drags into Wine (DirectInput and
     `GetAsyncKeyState` games), ScummVM and DOSBox.
   - Done when: the plan holds a yes/no table with evidence for each, and the
     benchmark's "pictures only" baseline is measured.
2. **The session pool.**
   - Work:
     - the provisioning script (three test users per Mac);
     - the keep-alive LaunchAgent;
     - shared folders and the shared engine store;
     - session-aware leases (`/Users/Shared`, `lease --all`);
     - `sc session claim` and `release`;
     - a per-Mac launch-slot budget in place of the load check's view of other
       sessions.
   - Done when: an agent claims a session on either Mac, runs a game there with
     no viewer and with full fidelity, and releases it, while the person and
     another session work undisturbed.
3. **The minimal puppet session, in a claimed session.** Phase 2 of the earlier
   order:
   - `start`, `stop` and `log --count`;
   - protocol v2's concurrent serving, `hello`, `windows`, input and `*`;
   - outcome replies; `text`, `shot`, `saves`;
   - the skill updated.

   The background mode is not built. Done when a `porting-player` reaches the
   benchmark's goals in SkiFree, Lure and Tyrian in a claimed session, with turns
   and tokens recorded.
4. **Sharded integration runs, across Macs.**
   - Work: the coordinator, shards per game in claimed sessions, matching games to
     installers, results gathered into one report.
   - Done when: a full run is split between the test Mac and the development Mac and
     finishes in a fraction of today's time, with every row naming its Mac and
     session.
5. **Frames and checks:** the frame ring and `stats`, `wait`/`expect`, named
   screens, needles into bundles, the "new:" header, locators.
6. **Installers and dialogs:** the Wine control tree and AutoIt lines.
7. **Senses:** `audio` (a process tap), `record`, `sheet`.
8. **Candidates**, each when its trigger fires ([section 8](#8-candidates-built-when-a-port-needs-them)).
   They now include the helper's background mode, for a Mac with no spare
   session.

## Questions for the user

1. ~~Outside mode~~ **Answered (2026-11-05): the user will grant any permission a
   testing tool needs on the test Mac.** Peekaboo has its grants on the test Mac; the audio
   tap will need system-audio recording.
2. ~~Enforcing the lease~~ **Answered (2026-11-05): enforced, by failing rather than
   waiting**, with flags to go ahead or break it. Built (`6f14f069`).
3. ~~Private APIs in a dev tool~~ **Answered (2026-11-05): fine in our dev tools**
   (`CGVirtualDisplay` included), as long as they are never part of a released
   Second Chance or a wrapp it builds.
4. ~~Models on the test Mac~~ **Answered (2026-11-05): yes.** Ollama or `mlx-vlm` and a few
   3–6 GB models, now a candidate (section 8), installed when its benchmark runs.
5. ~~Peekaboo.app on the test Mac~~ **Answered and done (2026-11-05):**
   - 4.9.7 from the GitHub release, checked against `checksums.txt`, notarized
     (team FWJYW4S8P8);
   - the login agent `boo.peekaboo.bridge-host`;
   - the CLI from `openclaw/tap`;
   - granted Screen Recording, Accessibility and Event Synthesizing.
6. ~~A lease for work outside `sc`~~ **Answered (2026-11-05): yes.** Built
   (`8673c436`): `sc lease take` / `release`.

7. **Test users per Mac:** answered (2026-11-05): three per Mac to start, more if
   they'd be used. a test user exists on the test Mac and the development Mac.
8. **Disk on the development Mac:** the user frees space before a task that needs
   it.
9. **Keep-alive:** answered (2026-11-05): a process in the console user's session
   remotes into each test session, to keep it logged in and drawing. Find the
   simplest, automatable, least resource-hungry way (phase 1).

## Risks

- **Sessions without a viewer** may not draw OpenGL with any keep-alive. Then
  sessions still work with a viewer, and the virtual display is the next try.
- **Load across sessions.** Several games at once can push a Mac over Wine's cliff.
  The slot budget is measured, not guessed.

- **Posted keys and Wine.** Phase 1 proves them first. The fallback for dialogs is
  the control tree. For games it is `SendInput` through Wine's PE side, which is
  much harder.
- **The frame ring's cost.** A stream inside the game process adds CPU to a game
  under test, and Wine slows sharply once every core is busy. Phase 1 measures it;
  small, greyscale frames at a few a second keep it light.
- **Animated screens** never go fully still: settling and `wait --still` are scoped
  to a region and capped.
- **Thin answers that mislead** (OCR of pixel fonts, a wrong screen match) cost a
  turn and a recovery. Replies say how sure they are, and the agent looks when
  unsure.
- **Peekaboo's churn.** Pin its version on the test Mac and upgrade on purpose.
- **Captures on a worn-down test Mac** are slow (`systemstatusd`). The frame ring
  avoids repeated captures; a reboot is still the cure.

## Sources

- Peekaboo:
  - [the repository](https://github.com/openclaw/peekaboo), read at commit `14a4418`
    (4.9.7+);
  - docs: `bridge-host.md`, `daemon.md`, `engine.md`, `visualizer.md`, `dialog.md`,
    `click.md`, `type.md`;
  - source: `RuntimeHostResolver*.swift`, `BridgeCapabilityPolicy*.swift`,
    `ScreenCaptureKitOwnerLease.swift`, `BackgroundInputDriver.swift`,
    `PeekabooVisualizer`.
- Image costs: [Claude vision docs](https://platform.claude.com/docs/en/build-with-claude/vision)
- Local models:
  - [Holo2-4B](https://huggingface.co/Hcompany/Holo2-4B)
  - [Qwen3-VL report](https://arxiv.org/pdf/2511.21631)
  - [VideoGameBench](https://arxiv.org/html/2505.18134v2)
- Agent patterns:
  - [Midscene model strategy](https://midscenejs.com/model-strategy.html)
  - [Cua composed agents](https://cua.ai/agent-sdk/supported-agents/composed-agents)
  - [UFO2](https://arxiv.org/html/2504.14603v2)
  - [Playwright CLI vs MCP](https://www.testdino.com/blog/playwright-cli-vs-mcp)
- Others:
  - [Cua Driver](https://cua.ai/docs/explanation/the-no-foreground-contract)
  - [DeskPad](https://github.com/lukepighetti/deskpad)
  - [AltTester](https://alttester.com/docs/desktop/pages/overview.html)
  - openQA developer mode:
    [Fedora devel post](https://lists.pagure.io/archives/list/devel@lists.fedoraproject.org/message/ZNCT2UG52GTI73LWQVQQB3NHBX47YNYD/)
- The critical review of this plan (2026-11-05): its findings are folded in above.
  Main points:
  - turns cost more than pictures;
  - the helper's PNG-per-look can't give change detection;
  - sessions as `sc` jobs;
  - WineKit for Wine;
  - the audio tap;
  - the PuppeteerCore/Sentry dependency;
  - the socket name and `*`;
  - the phase order.
