# Launching a game

What a wrapp does between being opened and the game's window appearing,
what its loading window says meanwhile, and when it says the launch may
have failed. The code is `WrappTemplate/main.swift` and `GameLauncher`
(the steps), `Shared/LoadingStage.swift` and `Shared/LoadingClock.swift`
(what the window says, and when), and `Shared/LaunchActivityMonitor.swift`
(the signs it watches for).

## The steps

1. **The last session.** If the game's Wine is still running from the last
   time it was played, the window says so and waits for it
   (`.lastSessionClosing`), offering after a few seconds to stop it.
2. **Wine, and Steam, get going.** A Wine game's wrapp starts Wine's
   desktop and waits until it has registered the display devices
   (`WineDesktop`; AGENTS.md has why). A game that needs Steam starts Steam
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

None of these waits has a time limit. A launch that may still work is
waited for until it does, or until the player gives up — and if they give up
while the window says the launch may have failed, that is reported
(`giveUpIfStuck`). A wait ends early only when what it waits on can no
longer arrive: Wine's launcher exits before the game appears, the game
exits before its window does, Steam exits, or Wine's desktop launcher exits
with no `explorer.exe` left to finish the job.

## The loading window

Each step shows as a `LoadingStage`, with its own message, and its own
clock (`LoadingClock`), which starts when the stage does — or, behind the
save warning, when the warning is confirmed:

- **"Taking longer than usual"** comes after the stage's `slowNoteAfter`.
- **"Possible launch failure"** needs two things: the stage has run for its
  `possibleFailureAfter`, longer than it takes on a busy Mac, and the launch
  has shown no sign of getting anywhere for the stage's `stallAfter`. A
  launch that is merely slow keeps showing signs, so it is left be; one that
  is stuck stops, and the window says so as soon as the stage's time is up,
  so that a player who quits then sends a report. It stays up until the
  next stage.
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

It leaves out what the wrapp runs itself to check on the launch: Wine's
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
three times that on a heavily loaded Mac, against 50 s, 10 minutes and 5
minutes before, when a busy Mac never said so at all.
