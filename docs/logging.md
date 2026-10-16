# Logging

Second Chance runs a lot of other people's software (Wine, ScummVM, MoltenVK,
twenty-year-old installers) in ways that aren't their happy path, so a build or
a launch that worked yesterday can fail today. The log is usually the only way
to tell why. It has two readers, a person scanning for what went wrong and an
agent grepping for it, and both need the cause to be on a line that says so,
at a level that stands out, near the end.

The plumbing (swift-log → `MultiplexLogHandler` → `LogStore` and OSLog) is
described in the logging bullet of [AGENTS.md](../AGENTS.md). This page covers
what goes into the log and where it ends up.

## Where each log lives

| Log | What's in it |
| --- | ------------ |
| The terminal (stderr) | `notice` and up, compact format, when stderr is a terminal or `SECOND_CHANCE_LOG_STDERR=1`. |
| `DerivedData/sc-logs/<time>-<step>.log` | What sc showed for each step: for a wrapp build, the app's stderr copy. |
| `DerivedData/sc-logs/<time>-wrapp-build-<slug>.full.log` | A wrapp build's whole log, every level, full format (`SECOND_CHANCE_LOG_FILE`). |
| `~/Library/Logs/SecondChance/<slug>/launch-<time>.log` | Each wrapp launch's whole log, every level; the newest 10 are kept. The header names it. |
| `~/Library/Logs/SecondChance/diagnostics/<slug>-<time>-<reason>/` | A bundle from a launch that started badly (see AGENTS.md): stacks, process lists, Wine's output and the wrapp's log. |
| Save Logs, `--mirror-logs` | The app's in-memory ring (the last 50,000 entries), or the whole session, to a file you choose or `~/Downloads`. |
| OSLog (`log show`) | Every entry, crash-durable, under the `au.gare.callum.second-chance` subsystems. |

## Levels

| Level       | Use it for | Shown on the terminal |
| ----------- | ---------- | --------------------- |
| `.debug`    | Detail that only matters when digging: file attribute checks, full process lists, environment dumps, per-file installer progress, Wine's `fixme:` lines. | No (see `SECOND_CHANCE_LOG_LEVEL`) |
| `.notice`   | The normal story of a run: each stage, each subprocess started and how it ended, what was detected and decided. | Yes |
| `.warning`  | Something unusual that the run survives: a retry, a fallback, a missing optional file, a subprocess that wrote to stderr. | Yes |
| `.error`    | Something failed: a subprocess exited non-zero, a patch didn't apply, Wine printed an `err:` line. | Yes |
| `.critical` | A failure that ends the build or the game, or a crash. | Yes |

`.trace` and `.info` aren't used. A warning is not an error: if the run carries
on as intended, it is a `.warning`, however alarming the message.

Every level is kept in the in-memory ring, the log window, Save Logs and the
disk mirror. Only the terminal copy is filtered, so moving chatter to `.debug`
costs nothing when someone needs it later.

## The header

Every process (the app, a wrapp, WrappPuppeteer) starts its log with one
block from `RunContext.logHeader`:

```
━━━ Second Chance 0.4.0 (build 52), pid 4120, run 3f9a2c1e ━━━
  macOS 15.6.0, Mac14,6, process x86_64 under Rosetta
  GUI session; WINEDEBUG=-all,err+all
```

A wrapp's header adds the game, its engine, and the size and file count of
its installed files, which is where an install that was cut short shows up.
Without a GUI session (an SSH shell), the header says so and a warning follows:
Wine can't open windows there, and installers fail with only an exit code.

The run ID is inherited through `SECOND_CHANCE_RUN_ID` when a parent set it,
and exported otherwise, so a build and the Wine processes it starts share one.

## Subprocess output

`ProcessLineLogger.attach` (and `TaggedProcess`, which uses it) logs each line
of a subprocess's output at the level `SubprocessLineClassifier` picks from the
line itself. The pipe only supplies the fallback: `.notice` for stdout and
`.warning` for stderr. Wine, MoltenVK and ScummVM write routine chatter to
stderr and real failures to stdout, so a pipe-based level can't be trusted.

| Line                                                     | Level |
| -------------------------------------------------------- | ----- |
| Wine `err:` (`0124:err:module:import_dll …`)             | error, except the `experimental wow64 mode` notice every launch prints (debug) |
| Wine `warn:`, `fixme:`, `trace:`                         | debug |
| `wine: Unhandled page fault …` and other unhandled exceptions | critical |
| `ShellExecuteEx failed`, `Application could not be started` | error |
| `msync:`/`esync:` start-up lines                          | debug |
| `[mvk-info]` and its tab-indented detail lines            | debug |
| `[mvk-warn]` / `[mvk-error]`                              | warning / error |
| ScummVM `WARNING:` / `ERROR:`                             | warning / error |

Pass `classify: false` to log every line at exactly the given level.

## Subprocess runs

Every Wine run through `WineEnvironment.runWine` (installers, patches,
`reg add`, …) streams its output into the log as it arrives, under the `Wine`
category, framed by lines from `WineEnvironment` written by `SubprocessWatch`:

```
17:22:45.627  notice  WineEnvironment  ▶ wine setup.exe started (pid 1237): start /wait /unix …/setup.exe /verysilent /norestart
17:23:15.630  notice  WineEnvironment  … wine setup.exe (pid 1237) still running after 30.0s; no output for 30.0s (0 lines so far)
17:24:24.211  notice  WineEnvironment  ■ wine setup.exe (pid 1237) exited 0 after 1m 39s, 2 lines of output
```

The `■` line says how it ended: `exited N` (an error when N isn't 0) or
`was killed by SIGKILL (9)`; a signal is never reported as an exit code. The
`…` heartbeat appears after every 30 s without output, so a hung installer
still shows up in the log as hung. A run given a `timeout` that passes it
stops the prefix's wineserver and throws `WineError.timedOut`; an unattended
game install gets `SECOND_CHANCE_INSTALL_TIMEOUT` (default 30 minutes), a
patch installer 180 s and a registry write 120 s.

The exact environment and command, quoted so it can be pasted into a
terminal, are logged at debug as `To re-run by hand:`. Only the variables
Second Chance sets are included, not the whole parent environment.

## Keeping the terminal readable

Repetitive output goes in at debug, with a notice that sums it up:

- msiexec's install log (`MsiLogStreamer`) logs each file at debug, the lines
  that report a failed action (`Return value 3`, `Error …`) at error, and a
  `MSI log: N lines, N files installed, N error lines` summary when it stops;
- the wrapp's process monitor logs the Wine session's process tree as one
  entry when it changes, not every poll;
- environment dumps, file-attribute checks and mounted-image listings are
  debug.

## How a game's end is reported

The wrapp logs one `■` line when the game ends, with the real exit status of
the `wine start /wait` launcher (which passes through the game's own), or the
signal that killed it, how long it ran, and whether its window had appeared:

```
16:23:54.173  error   GameLauncher  ■ Game exited 1 after 6.1s, after its window appeared — a crash or an error on the way out
```

If the launcher exits before the game's exe ever appears (a missing exe, a
DLL that won't load), the wrapp stops waiting at once and says so, rather than
polling for two minutes.

## The failure summary

A failed build, and a game that crashes, quits with an error or never shows
its window, ends its log with one critical entry between fixed markers:

```
=== FAILURE SUMMARY ===
What failed: Building the wrapp, during "Game installing"
Error: Wine execution failed with exit code 1 [SecondChance.WineError.executionFailed(exitCode: 1)]
First error in this stage: 17:28:07.695  error  Wine  00d8:err:winediag:nodrv_CreateWindow Application tried to create a window, but no driver could be loaded.
Last Wine/ScummVM output:
  …the last ten lines…
Full log: …/sc-logs/20261016-172710-wrapp-build-secrets-can-kill-remastered.full.log
Run: 3f9a2c1e
=== END FAILURE SUMMARY ===
```

The cause of a failure is usually logged well before the failure: the "first
error in this stage" line is there because the last errors are usually
consequences. Stages are what the build's progress shows (`LogContext.enterStage`,
called next to each `━━━ Stage ━━━` divider); a wrapp has "Starting the game"
and "Playing". The error line keeps the error's type and case and its chain of
underlying errors, which `localizedDescription` drops. A wrapp's summary also
names its diagnostics bundle when it captured one. `grep -A20 'FAILURE SUMMARY'`
finds it. Cancelling a build produces no summary.

## Environment variables

| Variable | Effect |
| -------- | ------ |
| `SECOND_CHANCE_LOG_STDERR` | `1` copies log lines to stderr even when it isn't a terminal, `0` never does. Unset, stderr gets them only when it is a terminal. |
| `SECOND_CHANCE_LOG_LEVEL`  | The quietest level copied to stderr (`trace` … `critical`). Default `notice`. |
| `SECOND_CHANCE_LOG_FILE`   | Mirror every entry, at every level, to this file in the full format. `--mirror-logs` does the same with a file in `~/Downloads`. |
| `SECOND_CHANCE_RUN_ID`     | The run ID in the header. Inherited by child processes; set it to tie several processes' logs together. |
| `SECOND_CHANCE_INSTALL_TIMEOUT` | Seconds an unattended game install may run before it is stopped. Default 1800. |
| `SECOND_CHANCE_WINEDEBUG`  | Wine's `WINEDEBUG` for every Wine process Second Chance or a wrapp starts. Unset, it is `-all,err+all`: every channel off except the `err` class. |
