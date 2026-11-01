# Plan: why a game hung for good when launched on a maxed-out Mac

## Context

Launched while every core was busy, a game sometimes hung, and stayed hung
after the load stopped. The launch-timing work
([2026-10-22-launch-timing.md](2026-10-22-launch-timing.md)) had covered a
launch that is slow under load; this was one that never recovers.

**The clue:** a hang that outlives the load is a state, not a speed.
Something gives up, or misses a wake-up, while it is starved, and something
else waits for ever on what it never did, as Wine's 10 s wait for its
desktop did before `WineDesktop`.

**What was asked for:** a plan to find out why, and fix it. Along the way:
keep every core busy for the whole of a test, try launching many games at
once, give a busy Mac a longer quit, report a launch still stuck after 5
minutes without waiting for someone to quit it, and offer Try Again
whenever the loading window says a launch may have failed.

## The plan

1. **Reproduce it**, on a test Mac, with a script (kept out of the repo, as
   it is tied to that Mac): busy loops at the priority real programs get, a
   wrapp opened the way a player does, a hang being no window 3 minutes
   after the load stops.
2. **Catch it in the act**: a diagnostics bundle when the loading window says
   the launch may have failed, at any stage, and on SIGUSR1; Windows-side
   backtraces (`winedbg`) in the bundle; a switch to turn Wine's msync and
   esync off.
3. **Find the cause**, against five hypotheses: a Wine timeout whose
   failure path never recovers; a lost wake-up in msync/esync; a deadlock
   in the Mac driver or our in-process helpers; the wrapp stuck, not Wine;
   Rosetta or scheduling.
4. **Fix it**, and add Try Again as a safety net whatever the cause.
5. **Verify** by running the cases that hung again.

## What testing found

Eight rounds of launches on an M1 Max (8 performance cores), with Old Clock
(DirectDraw) and Secrets Can Kill Remastered (Direct3D), then all nine Wine
games built on the test Mac launched at once. Four separate faults, each
hiding the next:

### 1. `wineserver -k9` left the game running, unseen

`wineserver -k9` kills the server alone. Wine's programs, waiting on it,
don't notice it has gone — msync or not, it turned out — and run on for
good with nothing to end them. The test Mac had sessions 6–9 hours old
from integration builds. The next launch of the game took the old
`Game.exe`, found by its name, for its own and waited for ever for its
window, load or none. Reproduced on demand with no load at all: `-k9` left
all ten of Old Clock's programs running. The shutdown's last step is
`-k9`, and a busy Mac reached it sooner; later, even `wineserver -k` left
five behind under heavy load.

**Fixed:** `WineServer.kill()` follows `-k9` by killing every Wine program
working in the prefix's folder (`WineServer.programs`, by each process's
working directory, so without asking the server); every `shutDown` ends
the same way; a launch first kills what a killed session left
(`clearLeftovers`); the game monitor ignores a game working in another
prefix; and on a heavily loaded Mac each step of a quit waits three times
as long before the next (`GameLauncher.quitPeriods`).

### 2. App Nap froze the wrapp

About 50 s after the game's window appeared, macOS napped the wrapp behind
it: every thread down to priority 4. With every core busy that never ran.
The wrapp couldn't see the game end, answer a quit (SIGTERM went unhandled
for 90 s every time), end Wine or write its log. Quitting 10 s after the
window worked; 60 s after, never.

**Fixed:** the wrapp holds a user-initiated activity for as long as it
runs. The log's drain queue moved off `.utility`, which waited a minute at
a time under load, and `LogStore.flush()` now keeps to its timeout.

### 3. Our own `winedbg` capture killed games

The bundle's `winedbg --command "bt all"` attaches to every program in the
session. With nine games and busy loops it ran into its 90 s timeout, and
stopped while attached it ended the game (exit 84 — "The game quit
unexpectedly") or left it suspended. Games also pruned each other's
bundles mid-write.

**Fixed:** no `winedbg` in a capture; a bundle under 15 minutes old isn't
pruned.

### 4. Wine's Mac driver gives Cocoa 5 seconds — the hang

Every Wine program starts its Mac driver in `macdrv_start_cocoa_app`
(Wine's `dlls/winemac.drv/cocoa_main.m`): it puts a struct on its own
stack, asks the main thread to become a Cocoa app with a pointer to it,
and waits 5 s. With nine games starting at once and busy loops on top, the
main thread sometimes took longer. The driver gave up ("Failed to start
Cocoa app main loop"), leaving the program with no display driver for
good, and the main thread, getting there late, crashed on the dead stack
frame (`-[__NSMallocBlock__ lock]: unrecognized selector`). For the game
that meant no window ever, spinning at 133% CPU; for explorer, no desktop
("The explorer process failed to start"). One run in three of nine games
under load hit it, two or three games each time.

**Fixed, both ways:** a new in-process helper (`cocoa_start_wait.m`)
gives that one wait 10 minutes, in every Wine process, and logs a start
past 5 s; and the wrapp watches the game's output for the driver giving
up or `nodrv_CreateWindow` (`NoDisplaySignal`), reports it, and starts the
launch afresh once, showing an error if the fresh start fails the same
way.

### Ruled out

- msync/esync: the leftovers outlived the server with both off.
- Load alone, with Wine's desktop up: every single-game launch under 20 or
  30 busy loops showed its window.
- The extra Wine logging, the log's size.

## Also changed

- A `stalled` diagnostics bundle when the loading window says the launch
  may have failed, from any stage (`StartupDiagnostics`), sent with a
  give-up's report; a `manual` one on SIGUSR1.
- A launch still saying it may have failed 5 minutes in reports itself
  (`stuck_report: automatic`), when the setting sends without asking.
- Try Again, whenever the loading window says a launch may have failed.
- The launch's signs of progress count only the game's own Wine: another
  game's had kept a stuck launch looking busy.
- `SECOND_CHANCE_WINE_SYNC` and `SECOND_CHANCE_COCOA_START_WAIT=0` debug
  switches.

## Lessons for testing under load

- Keep the load on for the whole launch and the quit: a test that stops it
  early measures a quiet Mac half the time.
- Busy loops must compute (`while :; do :; done`), not call the kernel:
  `yes > /dev/null` spent 94% of its time there.
- A test script that cleans up with `wineserver -k9` makes the leftovers
  it is looking for.
- A diagnostic that attaches to the game can end it.

## Verification

Before the last fix, nine games at once under 20 busy loops failed one run
in three, two or three games each time. After all four fixes, six such
runs and one with no busy loops — 63 launches — showed every game's window,
quit cleanly and left nothing running. Twice a Wine program's main thread
took 15–16 s to start Cocoa, which Wine would have given up on at 5 s; the
helper logged both, and both started. Before the second and third fixes,
every launch quit a minute in under load had stuck or left Wine behind; the
16 single-game launches after them, under 20 and 30 busy loops, didn't.
