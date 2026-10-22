# Plan: tuning when the loading window says a launch may have failed

## Context

A wrapp's loading window said "taking longer than usual" and "Possible launch
failure" after fixed times per stage: 20 s and 50 s for a game the wrapp
starts, 2 and 10 minutes for Steam's start, 90 s and 5 minutes for Steam
starting the game. The numbers were guesses. A player who quits while the
possible-failure note is up sends a report (`giveUpIfStuck`), so a note that
comes too late loses the report of a stuck launch, and one that comes too
early tells a player to give up on a launch that would have worked.

**What was asked for:**
- Show Steam updating itself, with its progress, and judge a stalled update
  by the time since its last progress line (30 s), not by one timer for the
  whole stage. Parse any other of Steam's start-up phases worth showing.
- Measure launch times for each kind of game (through Steam or not,
  DirectDraw or Direct3D, Wine or ScummVM) under different loads, and find
  signs that a slow launch is still getting somewhere. Take the load into
  account in when to say a launch may have failed.
- Bring Steam's window forward whenever it waits on the player.
- No time limit on a launch that may still be going.
- Start Wine (and Steam) behind the save warning, so the game starts sooner
  once it's read, if that is neither messy nor pointless.

## Experiments

All on a test Mac (an M1 Max: 8 performance and 2 efficiency cores, macOS
26), with wrapps built for each game, from a script that opens a wrapp the
way a player does (`open`, with a fresh data folder), samples every second
the CPU time of each Wine process, the process list and the logs, and reads
the wrapp's own log for when each step happened. Load was N busy loops.

### What the first runs got wrong

- **Busy loops started from the script ran at priority 20**, as they
  inherited it from `sc in-gui-session`'s LaunchAgent, which sets no
  `ProcessType`. Wine's services run at 31 and a wrapp at 46, so the "load"
  never competed with them: eight loops on eight performance cores slowed
  Old Clock not at all. Real loads (a Terminal's programs, a browser) run at
  31. The loops were moved to a LaunchAgent of their own with `ProcessType`
  `Interactive`, which gives 31.
- **The sampling script was starved the same way**, to a sample every 5–18 s
  under load; it was moved to an `Interactive` LaunchAgent too.
- **So was the wrapp's own monitoring.** `SystemLoadMonitor` and the new
  `LaunchActivityMonitor` ran on `.utility` queues and sampled every ~4 s
  under load. Both are `.userInitiated` now, and judge CPU as a rate over the
  real interval.
- **Three wrapps on the test Mac still had Wine 9** (Kegworks CX 24): Secrets
  Can Kill Remastered among them, which looked like the "cliff" AGENTS.md
  describes, its desktop waiting 30–110 s with Wine using almost no CPU.
  Rebuilt with Wine 10 it started like the others.

### What they found

86 timed launches in all (7 games, 0–14 busy loops, a fault in 12 of them),
the ones other programs' bursts of load spoiled run again on a quiet Mac.
[wrapp-launch.md](../wrapp-launch.md#measurements) has the table of
times. In short:

- **Up to the performance-core count, load barely matters**; past it, a Wine
  game took 25–50 s instead of 3–6 s, and a Steam game 4–7 minutes instead
  of 30 s, most of it Steam signing in. ScummVM took 3 s at every load.
- **A slow launch kept showing signs** — the longest without one was 7 s for
  a Wine game and 83 s for Steam's start, both with every core busy — and a
  stuck one (the game, Wine's desktop, `steam.exe` or Steam's web helper
  paused with `SIGSTOP`) showed none: Wine idled at 0.00–0.03 cores.
- **With the thresholds that followed**, every stuck launch said it may have
  failed — at 30 s for a Wine game unloaded and 90 s with every core busy,
  120 s for Steam's start, 30 s after a stalled update's last line — and no
  launch that worked did.
- **Steam's update was seen for real**: Valve released a client the day of
  the experiments, and the bootstrapper's Windows log matched the Mac one's
  lines, in a slightly different order.
- **Starting Wine behind the save warning** saved about 20 s for a Steam
  game on an idle Mac, and under half a second for a Wine game, whose
  desktop takes a second and a half when the Mac is idle.

## Decisions

- **Possible failure needs a stall, not just time.** A stage must have run
  for its `possibleFailureAfter` and shown no sign of progress for its
  `stallAfter`. Slow launches under load showed signs at least every 7 s
  (Wine games) and 83 s (Steam's start, under every core busy); stuck ones
  showed none at all.
- **What counts as a sign:** Wine's programs using at least 0.05 cores, a
  new Wine program, a line of output, a new step in Steam's launch. Not the
  wrapp's own `reg.exe` checks on the desktop (each a Wine program, and the
  server's CPU for it), and not Steam's own programs' CPU or log writing:
  Steam used 0.2–0.3 cores, and wrote to its logs, whether it was launching
  the game or idle.
- **Load lengthens the stages that need the CPU** threefold while
  `SystemLoadReading.isHeavy`, and the possible-failure note now shows under
  the busy-Mac note once that time is up, instead of never, so a stuck
  launch on a busy Mac gets reported too.
- **Steam's `ShowInterstitials` step can wait 30 s by itself** with nothing
  else stirring (68 launches: mostly 1–3 s, then 10, 13, 13, 14, 16 and 30 s),
  so Steam starting the game gets 45 s without a sign.
- **An update stalls after 30 s without a progress line**, whatever the load,
  as asked; the bootstrapper writes one about four times a second.
- **No time limits** on the game's exe or window appearing, Wine's desktop
  coming up, or Steam signing in; each wait ends only when what it waits on
  is gone.
- **Wine and Steam start behind the save warning**; only the game waits for
  it. This also fixed Steam games, which started the game before the player
  had confirmed the warning at all.
