# Launching a game

What a wrapp does between being opened and the game's window appearing,
what its loading window says meanwhile, and when it says the launch may
have failed. The code is `WrappTemplate/main.swift` and `GameLauncher`
(the steps), `LastSession.swift` (the first of them), `AppDelegate.swift`
(quitting, and opening the game again with the arguments in
`WrappLaunchOptions`), `Packages/SecondChanceKit/Sources/SecondChanceKit/LoadingStage.swift` and `Packages/SecondChanceKit/Sources/SecondChanceKit/LoadingClock.swift`
(what the window says, and when), and `Packages/SecondChanceKit/Sources/SecondChanceKit/LaunchActivityMonitor.swift`
(the signs it watches for).

## The steps

1. **The last session.** If the game's Wine is still running from the last
   time it was played, the window says so and waits for it
   (`.lastSessionClosing`), offering after a few seconds to stop it.
2. **Wine, and Steam, get going.** A Wine game's wrapp starts Wine's
   desktop and waits until it has registered the display devices
   (`WineDesktop`, [below](#wines-desktop)). A game that needs Steam starts Steam
   instead, which starts the desktop itself, and waits for it to sign in
   ([steam.md](steam.md#running)). ScummVM has nothing to start.
3. **The save warning.** A Wine game shows a warning to save often until
   the player clicks **I Understand** (or has ticked "Don't show this
   again"). Steps 1 and 2 run behind it, so by the time the player has read
   it Wine is usually ready; only the game itself waits for the click
   (`launchGame`'s `beforeTheGame`). It matters most for a Steam game: on an
   idle Mac its window came 7 s after the click instead of 25–29 s. A Wine
   game gains little on an idle Mac, where the desktop takes a second and a
   half, and more on a busy one, where it has taken 20–30 s.
4. **The game.** Wine starts the game's `.exe` (or Steam does, for a game
   with DRM that insists, `wine-steam`), or the wrapp starts ScummVM.
5. **Its window.** Once the game's first window is on screen the loading
   window closes and the game is brought to the front. For ScummVM too: it
   used to close after a fixed two seconds.

Before any of them, a launch kills Wine programs left in the prefix by a
session that was killed (`WineServer.clearLeftovers`): with no server they
never finish, and the game among them would pass for this launch's, whose
window never comes. The game is also taken only among the programs working
in this prefix's folder.

None of these waits has a time limit. A launch that may still work is
waited for until it does, or until the player gives up — and if they give up
while the window says the launch may have failed, that is reported
(`giveUpIfStuck`). A wait ends early only when what it waits on can no
longer arrive: Wine's launcher exits before the game appears, the game
exits before its window does, Steam exits, or Wine's desktop launcher exits
with no `explorer.exe` left to finish the job.

## Wine's desktop

Left to Wine, a game's first
desktop access starts `explorer.exe /desktop` and waits only 10 s for it; on a
loaded machine under Rosetta that runs out, and the game carries on with no
display adapters — Secrets Can Kill Remastered then crashes on a null Direct3D
object exactly 10 s in. `WineDesktop`
(`Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/`) starts the desktop
itself and waits until it has registered the display devices, which it detects
through the volatile `HKLM\HARDWARE\DEVICEMAP\VIDEO` key. A build waits up to
600 s, since with every core busy a fresh session has taken two and a half
minutes to bring it up, and what runs without it is sure to fail; a wrapp waits
for as long as the desktop's `explorer.exe` is still running, as its loading
window says meanwhile whether that looks stuck
([docs/wrapp-launch.md](docs/wrapp-launch.md)). Each check is itself a Wine
program and gets 120 s, because one cut short at 20 s never saw the desktop
ready, and the checks back off to one every 10 s as the wait grows, so they
don't take the CPU the desktop needs. `GameLauncher` does this before the game,
and `GameInstallerRunner` before every installer and patcher, which fail the
same way: with an exit code rather than a crash, or for AutoIt with no window
and an exit 0 before its script runs. A program that still prints
`nodrv_CreateWindow` fails with `WineError.noDisplay`, and a build then
restarts the Wine session and retries that step once
([docs/wrapp-build.md](docs/wrapp-build.md)). Wine runs that desktop through
`start.exe /exec`, which is itself a Windows program waiting on explorer, so
the two would keep the whole Wine session alive after the game quits;
`WineDesktop.release()` ends the `start.exe` once the programs are done and
explorer then closes normally. A build releases it before `wineserver -w`,
which would otherwise wait for ever, and so does a wrapp, which then waits for
the session to end before it quits — whether the game ended or the player quit
— and kills Wine only if it won't end (`wine.server.shutDown`), with three
times as long at each step while the Mac is heavily loaded; even its 15 s quit
fallback (later on a busy Mac) kills Wine before exiting. **Killing Wine means
killing its programs too:** `wineserver -k9` kills the server alone, and Wine's
programs, waiting on it, are left running for good — so `wine.server.kill()`
then kills every Wine program working in the prefix's folder
(`WineServer.programs`), and a launch first clears any a killed session left
behind (`clearLeftovers`), as the game monitor would otherwise take that
session's game for its own and wait for ever for its window. Never run
`wineserver -k9` by hand without doing the same. A launch that still finds Wine
running in the prefix waits for it in the loading window
(`LoadingStage.lastSessionClosing`), which after 3 s also offers to stop it,
and drops that offer and carries on if Wine finishes first; opening a wrapp
while it is closing down (macOS reactivates the running copy) starts it again
once Wine has finished. `SECOND_CHANCE_PRESTART_DESKTOP=0` restores Wine's
on-demand start, for comparison. Anything that runs `wine` and reads its output
must not wait for EOF on a pipe: Wine's background services inherit the child's
stdout and hold the pipe open.

## The loading window

Each step shows as a `LoadingStage`, with its own message, and its own
clock (`LoadingClock`), which starts when the stage does — or, behind the
save warning, when the warning is confirmed:

- **"Taking longer than usual"** comes after the stage's `slowNoteAfter`.
- **"The game may not be starting"** needs two things: the stage has run for its
  `possibleFailureAfter`, longer than it takes on a busy Mac, and the launch
  has shown no sign of getting anywhere for the stage's `stallAfter`. A
  launch that is merely slow keeps showing signs, so it is left be; one that
  is stuck stops, and the window says so as soon as the stage's time is up,
  so that a player who quits then sends a report. It stays up until the
  next stage. Its buttons are Quit, Try Again — the quit a give-up is,
  then the game opened afresh once Wine has finished — and Launch
  Directly, for a Steam game that can go without. A launch still saying
  so 5 minutes after the loading window first showed is reported by
  itself ([failure-reports.md](failure-reports.md)). A Wine game's wrapp captures a diagnostics bundle (`stalled`)
  as the note appears, while whatever is stuck still is, so the report
  carries its stacks.
- **A busy Mac** (`SystemLoadReading.isHeavy`) gets a note saying so, and a
  stage whose speed depends on the CPU (`slowsUnderLoad`) gets
  `heavyLoadFactor` times as long before it may count as failed. Past that
  the possible-failure note shows below the busy-Mac one.
- **Stages that wait on the player** — signing in to Steam, Steam's
  question about the other computer, or any other question in Steam's
  window — have no clock, and drop the window from the floating level, so it
  doesn't cover Steam's window in the middle of the screen.
- **A newer Second Chance** is looked for once the launch has failed, or
  may have, and if one is out the window suggests updating and setting the
  game up again ([updates.md](updates.md#a-wrapp-that-fails)).

### Signs of progress

`LaunchActivityMonitor` samples once a second, from when the window shows
until the game's window appears, and hands each sign to the clock:

| Sign | What it is |
| --- | --- |
| `cpu` | Wine's programs (or ScummVM) used at least `busyCores` of CPU since the last sample |
| `newProcess` | A Wine program started |
| `output` | Wine, Steam or the game printed a line |
| `steamLog` | Steam wrote to its logs |

It counts only the game's own Wine — programs working in another prefix
are another game's, which would keep a stuck launch looking busy — and
leaves out what the wrapp runs itself to check on the launch: Wine's
desktop is checked for with `reg.exe`, a Wine program of its own each time,
and `wineserver`'s CPU is mostly its work for those checks. Counted, they
made a stuck desktop look busy. Each stage says which signs count
(`countsAsProgress`): Steam's update counts only its own progress lines,
and connecting to Steam only the time, since offline Steam keeps retrying —
and logging — for ever.

Each sample is logged at `.debug` while the window waits, as
`[Launch] 12s: Wine CPU 0.41 cores; cpu +game.exe`, so a launch log shows
afterwards what a slow or stuck launch was doing.

### Steam's own steps

While Steam starts, the window follows its bootstrapper and its client
through their logs (`SteamLogs`; [steam.md](steam.md#driving-steam)):
"Starting Steam…", then "Updating Steam…" with a progress bar while it
updates itself (`.updatingSteam`), "Connecting to Steam…" once the client
is trying to sign in (`.connectingToSteam`), the sign-in prompt if it needs
one, and "Steam is starting *Title*…". An update's download is reported
about four times a second, so 30 s without a new line is a stalled update,
whatever the load.

## The Dock

A Wine game runs in a process of its own, which Wine's Mac driver makes a
regular app with its own Dock icon and menu bar. The wrapp stays in the Dock
beside it, and clicked there, or chosen in Cmd-Tab, brings the game forward
(`GameLauncher.bringGameForward`, from `applicationDidBecomeActive`): it hands
activation to the game's process and activates it, which only an active app
may do, so a Dock click's reopen, which arrives before the wrapp is active,
leaves it to the activation that follows. It doesn't while one of its own
windows is up, such as the log window in debug mode. A ScummVM game's wrapp
still hides itself from the Dock once the game's window appears, leaving
`scummvm`'s icon.

The wrapp keeps App Nap off for as long as it runs
(`ProcessInfo.beginActivity`, in `main`). Behind the game, macOS napped it
within a minute, every thread down to priority 4, and with every core busy
a napped wrapp never got the CPU: it couldn't see the game end, quit when
asked (a SIGTERM went unhandled for minutes), end Wine or write its log
until the load went.

Taking the game's own icon away, by making its process an accessory app,
was tried and undone: Wine's Quit (⌘⌥Q, its menu) then hung White Wolf for
good, where with the icon and menu bar it quits cleanly.

## Closing

The same window says when a wrapp is taking a moment to quit, whether
someone quit it or the game ended by itself: the wrapp waits for Wine to
finish before it exits. Wine's server, and with it Wine's services and
desktop (`WineServer.systemPrograms`), lingers 3 s after its last program
ends, so once only those are left they are stopped (`wineserver -k`) rather
than waited out — routine, so not shown as a step below. Once a quit has run for 6 s
(`QuitStep.showAfter`), so that a usual one shows nothing, the window comes
up with a spinner, "Closing *Title*…" and that it's taking a little longer
than usual, without taking the focus. Its
line beneath follows how firmly the game is being ended, from
`WineServer.shutDown`'s steps: waiting for it to finish, Steam closing (and
saving its sign-in), asking it to stop (`wineserver -k`), and making it stop
(`-k9`, and then each of its programs, which outlive the server). While
the Mac is heavily loaded each step waits three times as long
(`GameLauncher.quitPeriods`), since there Wine takes 4–5 s to end by itself
against 5 s before it is asked to stop. It never replaces the error window: someone reading why the game
failed keeps that. Quitting from the error window still waits for Wine, but
says nothing more.

A quit lets the pre-started desktop go first (`releaseDesktop`, as the
game's own end does): its `start.exe` keeps the Wine session alive, so
without that a quit could never end by itself in its grace period.

## How a launch ends

`GameLauncher.launchGame` returns a `LaunchOutcome`, and `main` decides from
it what to show: `.notStarted` (the player left another game holding Steam,
or quit first) and `.failedAndTold` (Steam's alert already said why) show
nothing more; `.ended` carries the exit code, whether the run ended badly
(`handleGameTermination`'s judgement, which also reports it) and whether the
game's window ever appeared. The loading window closes only once the game's
window appears, so a game that dies before then (ScummVM included, which has
no quit check) gets the error window in its place, rather than the wrapp
vanishing. A game that fails after its window appeared is reported but shows
nothing, as before. Steam and the desktop are finished (`finishSession`)
after the error is up, so it isn't held back while Steam closes, and the
wrapp counts as closing (opening it again starts it again once Wine has
finished) from the moment the game has gone.

## Under load

With other programs on every core
(at the priority a Terminal's or a browser's run), Wine 10 takes 20–30 s to
bring its desktop up and a game 25–50 s to start, and Steam minutes to sign in;
with a performance core or two free it starts in seconds, so it is a cliff, not
a slope. Wine 9 was worse: its desktop waited minutes, or never came up, with
Wine almost idle — a wrapp still on it should be rebuilt. Load at a lower
priority (20, a LaunchAgent with no `ProcessType`) doesn't slow Wine at all,
which matters when making load to test with
([docs/wrapp-launch.md](docs/wrapp-launch.md#measurements)), as does making it
with loops that compute rather than call the kernel. Work that must happen
under load can't run at `.utility`, which waits a minute at a time there (the
log's drain queue did), and the wrapp keeps App Nap off: napped behind the
game, at priority 4, it didn't run at all
([docs/wrapp-launch.md](docs/wrapp-launch.md#the-dock)). `SystemLoad`
(`SecondChanceKit`) measures it — other programs' CPU in cores, against the
performance-core count, heavy at all but one; the load average is useless here,
since starved Wine threads push it past 100. Every log header carries a `load:`
line, `SystemLoadMonitor` logs `[Load]` lines while the Mac is heavily loaded
during a build or wrapp run, and a failure summary gives the load now and over
the last ten minutes; a wrapp's loading window says so while the Mac is heavily
loaded (`SystemLoadMonitor`), and gives the launch three times as long before
it says it may have failed ([docs/wrapp-launch.md](docs/wrapp-launch.md)); and
the integration test reports such a game as `overloaded` rather than testing
it, unless run with `--ignore-load`.

## Diagnostics bundles

A badly starting Wine game leaves a diagnostics bundle in
`~/Library/Logs/SecondChance/diagnostics/<slug>-<time>-<reason>/`
(`StartupDiagnostics`): no window 8 s after the game process appears (each
threshold stretched by `LoadingStage.heavyLoadFactor` on a heavily loaded Mac)
(`slow-start`), Wine's unhandled-exception line (`crash`), still no window at
25 s (`hang`), an exit before any window (`exited-before-window`), Wine's
launcher exiting before the game's exe appears (`exited-before-game`), or the
game quitting within 15 s of its window (`quit-early`) — and, at any stage,
Wine's desktop included, when the loading window says the launch may have
failed (`stalled`), or whenever the wrapp gets SIGUSR1 (`manual`; sent twice a
minute apart, the same stacks tell stuck from slow). Each holds a `sample` of
the game process's thread stacks and of every other Wine process
(`explorer.exe`, `wineserver`, …) taken at the same moment, `top`, the process
list (taken first, before a crashing game can exit),
display/lock/screen-sharing state, the game's system log, the last 300 Wine
output lines and the wrapp's whole log so far; the newest 10 are kept (none
under 15 minutes old, which may be another game's still being written) and the
wrapp log names the folder. **No `winedbg` in a capture:** it attaches to every
program in the session, and one stopped while attached (it took minutes on a
loaded Mac) ended the game it was looking at, or left it suspended. Every
launch also keeps its log in
`~/Library/Logs/SecondChance/<slug>/launch-<time>.log` (newest 10).
`SECOND_CHANCE_DIAGNOSTICS=0` turns it off and
`SECOND_CHANCE_DIAG_SLOW_SECONDS` moves the threshold — set it to `1` to force
a bundle and check the capture works.

## The save warning when scripting a launch

Launched by hand
(`open`, its `Contents/MacOS/WrappTemplate`, `sc wrapp run`), a wrapp whose
engine is Wine (Steam's included) shows a save-progress warning and doesn't
start the game until someone clicks **I Understand** — Wine's desktop, and
Steam for a game that needs it, start behind it — so a script that launches a
wrapp and waits for the game waits for ever on an unattended Mac. The wrapp
skips the dialog when `~/Library/Application Support/<bundle
id>/dont-show-save-warning` exists (`InfoWindowController`). Create it for the
experiment and remove it afterwards, as it is the player's own setting.
`SECOND_CHANCE_DATA_DIR` moves that folder, with the game's saves and the
settings some games keep beside them, somewhere else (`Configuration.swift`);
WrappPuppeteer sets it to an empty folder for each launch, so a test always
meets the dialog and never reads or changes the player's saves and settings.

## Measurements

The numbers come from launches timed on an M1 Max (8 performance and 2
efficiency cores) under 0–14 busy loops at normal priority, and from 529
launch logs kept by two Macs before that
([the plan](historical-plans/2026-10-22-launch-timing.md) has how, and what
went wrong first). Seconds from the start, or from the save warning's
confirmation, to the game's window:

| Game | Busy loops: 0 | 4 | 7 | 8 | 10 | 14 |
| --- | --- | --- | --- | --- | --- | --- |
| Old Clock (Wine, DirectDraw) | 3 | 3 | 4 | 5 | 46 | 26 |
| Haunted Carousel (Wine, DirectDraw) | 3 | 3 | 4 | 5 | 48 | 23 |
| Secrets Can Kill Remastered (Wine, Direct3D) | 6 | 4 | 8 | 14 | 48 | 31 |
| Sea of Darkness (Wine, Direct3D) | 4 | 4 | 6 | 10 | 37 | 29 |
| Stay Tuned for Danger (ScummVM) | 3 | 3 | 3 | 3 | 3 | 3 |
| Curse of Blackmoor Manor (through Steam) | 25–29 | 29 | 40 | 59 | 343 | 286 |
| Warnings at Waverly Academy (through Steam) | 32 | 30 | 46 | 62 | 425 | 277 |

- **Load only matters once every core is busy.** Up to the performance-core
  count a launch barely slows; past it, Wine's desktop alone takes 20–30 s
  and Steam's sign-in minutes. The busy loops have to run at the priority
  real programs do (31): run at 20, as a LaunchAgent with no `ProcessType`
  gives, they never slowed Wine at all.
- **A slow launch keeps showing signs; a stuck one doesn't.** On a Mac with
  every core busy, Wine's programs used the CPU almost every second, and the
  longest a working launch went without any sign was 7 s for a Wine game,
  83 s for Steam's start and 33 s for Steam starting the game. With the
  game, or Wine's desktop, paused, Wine idled at 0.00–0.03 cores and showed
  nothing.
- **Steam's own programs are no sign either way.** They used 0.2–0.3 cores,
  and wrote to Steam's logs, whether Steam was launching the game or idle
  with the game running.
- **Steam's `ShowInterstitials` step can wait 30 s by itself**, with nothing
  else stirring (68 launches: mostly 1–3 s; then 10–16 s five times, and
  30 s once).
- **Wine 9 was different.** A wrapp still on Wine 9 waited 30–110 s for its
  desktop with Wine almost idle, even under low-priority load that slowed
  Wine 10 not at all, and with every core busy never brought it up in ten
  minutes. A wrapp built before the Wine 10 upgrade should be rebuilt.

With the numbers above, a stuck launch now says it may have failed after
30 s (Wine game), 120 s (Steam's start) or 60 s (Steam starting the game),
or 180 s for a game Big Fish's launcher starts (`bigFishStartingGame`, slow
to say so after 120 s: its copy protection runs first, and White Wolf's
window took 77–90 s on an idle Mac; [big-fish.md](big-fish.md)),
three times that on a heavily loaded Mac, against 50 s, 10 minutes and 5
minutes before, when a busy Mac never said so at all.
