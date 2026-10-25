# Plan: why a silent install hung, and stopping Wine inheriting our crash handler

## Context

A White Wolf build in the released app (0.7.0, opened from the Finder)
spent 30 minutes in "Installing". The silent InstallShield run
(`setup.exe /s /sms /f1…setup.iss`) printed one line and nothing more. Then
the unattended-install timeout killed Wine, and the retry with the
installer's own wizard installed the game in 78 s, from the same files and
the same prefix. Headless builds of the game had always taken 35–100 s.

**What was asked for:**

- Find out why it hung, by reproducing it rather than guessing.
- When an unattended install stops moving, say so and hand the person the
  installer's wizard, rather than showing 30 minutes of apparent progress.
  That part is still to come.

## What the hang looked like

- `setup.exe` had unpacked its InstallShield engine into `Temp/{…}` and then
  done nothing. No CPU (1.4 s in all), nothing under Program Files, no
  `setup.log`. Its only window was Wine's off-screen 500×500 one, so there was
  no hidden question to show the person: in `/s` mode InstallShield draws
  nothing.
- macOS's `sample` showed its Windows thread waiting in the kernel in
  Rosetta-translated code, which says nothing about why.
- `winedbg` couldn't attach in that session.
- The Mac was heavily loaded at the time. That turned out not to matter.

## Experiments

All on a test Mac (M1 Max, 8 performance and 2 efficiency cores) unless
noted, driven by scripts run as `Interactive` LaunchAgents, so they ran at the
priority real programs do. CPU load was busy loops at that priority
([docs/wrapp-launch.md](../wrapp-launch.md#measurements)).

| # | What | Hung |
| --- | --- | --- |
| E0 | A Wine session alone, started under 12 busy loops and held open 5 minutes, probed every 30 s with `reg query` and `cmd /c echo` | 0/10 (slowest probe 0.6 s) |
| E1 | Headless White Wolf builds, idle: current Debug build and 0.7.0 | 0/6 (setup.exe 31–35 s) |
| E2 | 0.7.0 headless under 12 busy loops, from a fresh prefix | 0/5 (48–111 s) |
| E4 | E2 plus the reporting Mac's state: five other disk images mounted (the prefix registers them as `floppy` drives, as the hung build's had), and disc 2 remounted alone at disc 1's volume path before `setup.exe` | 0/5 (59–101 s) |
| — | On the Mac that hung: the same GUI steps by hand | **1/1** |
| — | On that Mac, headless from a shell, and from a LaunchAgent | 0/2 |
| — | A small app that starts the same Wine steps as a regular foreground app, a prohibited one and from a shell, on both Macs | 0/12 |
| E5 | E1's headless 0.7.0 build with `SECOND_CHANCE_REPORTING=1` and a `SECOND_CHANCE_SENTRY_DSN` that goes nowhere | **1/1** |
| E6 | E5 with the fix | 0/2 (30 s and 36 s, and no crash report) |

So load, a swapped disc, extra mounted volumes, the `floppy` drives, the
hardware, and being a GUI app were all ruled out. The one thing every hung run
had was failure reporting, which is on in a Release build opened normally and
off in every Debug, headless and test run.

Sentry gave it away. Each hang left a "crash" report for **Second Chance**,
which never crashed: an `EXC_BAD_ACCESS` at address 0, from code at
`0x2006…` (Wine's, translated), with no process name, written 4 s after the
hung `setup.exe` started.

## Why it hangs

- With reporting on, Sentry's crash handler (SentryCrash's Mach exception
  monitor) points the process's task exception ports at a port it listens
  on.
- A child process inherits task exception ports, so Wine's processes send
  their hardware exceptions to that port too. Windows programs fault on
  purpose, and Wine turns each fault into a Windows exception through the
  signal that follows a declined Mach exception.
- Sentry's handler (`handleExceptions` in `SentryCrashMonitor_MachException.c`)
  takes one exception on its primary thread: it records a crash, restores the
  process's own ports, and wakes its secondary thread. The secondary thread
  takes one more. Each replies `KERN_FAILURE` and returns.
- The child still holds a send right to the port, but nothing receives on it.
  Its third fault is queued for ever, and the faulting thread waits in the
  kernel.
- Wine processes started after Sentry restored our ports, such as the wizard
  retry, inherit the defaults and work. That's why the retry succeeded.

A wrapp starts Sentry the same way. A White Wolf wrapp ran normally with
reporting on, because its game never faults three times, but any game that
does would freeze.

## Fix

`Process.runWithoutCrashHandler()` (`Shared/ChildProcess.swift`) does four
things, under a lock:

1. Read the task's exception ports.
2. Clear the ones that are set.
3. Start the child.
4. Put them back.

Every launch of Wine, or of something that starts Wine, uses it:
`WineEnvironment`, `WineUtilities`, `SteamClient`, `WineManager`'s
wineserver call, and `TaggedProcess`, which covers winetricks and ScummVM.
A SwiftLint rule rejects a bare `run()` in `Shared/Wine/` and
`Shared/Steam/`. `ChildProcessTests` points the test process's port at one
nobody reads, then checks that a child reading address 0 hangs under `run()`
and dies of `SIGSEGV` under `runWithoutCrashHandler()`.

**Not chosen:**

- **Turning off Sentry's Mach monitor.** Sentry has no option for it; the only
  path is internal (`configuredMonitors`, for managed runtimes).
- **An exec trampoline binary that clears its ports and execs Wine.** It means
  a new executable in both the app and the template.
- **`posix_spawn` with `posix_spawnattr_setexceptionports_np`.** It replaces
  Foundation's `Process`, pipes and termination handling at every site.

Clearing for the length of one spawn costs only Sentry's Mach view of a crash
on another of our threads in that moment; its signal handler still sees it.

## Found along the way

- With reporting forced on, a headless run that found a previous run's crash
  report showed `CrashReportPrompt`'s modal alert and waited on it for ever.
  `FailureReporter.canAsk` now keeps alerts out of runs nobody watches.
- A full `sc --on` sync copies `DerivedData` whole, including an 11 GB
  compilation cache, which took over 20 minutes. Copying the one app with
  `tar` took a minute.
- Wrapps already built with 0.7.0 keep the old template until rebuilt.
