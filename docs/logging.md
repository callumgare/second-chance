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
| `DerivedData/sc-logs/<time>-wrapp-build-<slug>.jsonl` | The same as JSON lines (`SECOND_CHANCE_LOG_JSONL`). |
| `~/Library/Logs/SecondChance/<slug>/launch-<time>.log` | Each wrapp launch's whole log, every level; the newest 10 are kept. The header names it. |
| `~/Library/Logs/SecondChance/app/run-<time>.log` | Each run of Second Chance's whole log, every level; the newest 10 are kept. The header names it, and Debug → Show Run Log in Finder opens it. Not written under test, or when `SECOND_CHANCE_LOG_FILE` or `--mirror-logs` chose a file instead. |
| `~/Library/Logs/SecondChance/diagnostics/<slug>-<time>-<reason>/` | A bundle from a launch that started badly (see AGENTS.md): stacks, process lists, Wine's output and the wrapp's log. |
| Save Log…, `--mirror-logs` | The app's in-memory ring (the last 50,000 entries), or the whole session, to a file you choose or `~/Downloads`. |
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

Every level is kept in the in-memory ring, the log window, Save Log… and the
disk mirror. Only the terminal copy is filtered, so moving chatter to `.debug`
costs nothing when someone needs it later.

## The header

Every process (the app, a wrapp, WrappPuppeteer) starts its log with one
block from `RunContext.logHeader`:

```
━━━ Second Chance 0.4.0 (build 52), pid 4120, run 3f9a2c1e ━━━
  macOS 15.6.0, Mac14,6, process x86_64 under Rosetta
  GUI session; WINEDEBUG=-all,err+all
  load: other programs are keeping 0.6 cores busy, and this Mac has 8 performance cores
```

The `load` line (`SystemLoad`) is the CPU every process but Wine's and the
logging one is using, in cores, against the performance-core count; when it
reaches all but one of them a warning follows, since Wine then takes minutes
to start a program, or never does.

The header is only the start, and a build can begin hours after the app
opened, so load is also watched while Wine work runs: for the whole of each
build, and for a wrapp's whole run (`SystemLoadMonitor`). It samples every 5 s
while a build runs or a game starts, when load decides whether Wine starts at
all, and every 60 s once the game has loaded. It logs nothing while the load
is light: only a `[Load]` warning when the Mac becomes heavily loaded, another
every 5 minutes while it stays so, and a notice when it stops being. A wrapp's
loading window watches the same monitor to say why the wait is long. The
readings of the last ten minutes go into the failure summary.

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
| ScummVM `WARNING:` / `ERROR:`                             | warning / error, except "Game data not found" and "could not find any game" (error) |

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
logs the Wine processes still running (from `ps`), stops the prefix's
wineserver and throws `WineError.timedOut`; an unattended
game install gets `SECOND_CHANCE_INSTALL_TIMEOUT` (default 30 minutes), a
patch installer 15 minutes and a registry write 10 minutes — long, because
with every core busy Wine takes minutes to start a session that takes seconds
on an idle machine.

The exact environment and command, quoted so it can be pasted into a
terminal, are logged at debug as `To re-run by hand:`. Only the variables
Second Chance sets are included, not the whole parent environment.

## Keeping the terminal readable

Repetitive output goes in at debug, with a notice that sums it up:

- msiexec's and Inno Setup's install logs (`InstallerLogStreamer`) log each
  file at debug, the lines that report a failure (`Return value 3`, `Error …`,
  Inno's `Exception message:`) at error, and a
  `MSI log: N lines, N files installed, N error lines` summary when they stop.
  The install is then checked against the same log, and
  `Install is incomplete: …` names its last line when it never says it
  finished;
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

The exception is the games from Ghost of Thornton Hall on, whose exit code
means nothing: their `ExitInstance` ends in MFC's, which returns the `wParam`
of the last message MFC handled, and since the games run their own message
loop that is whatever passed through last — 1 on most clean quits, 0 on
some. Those games write their own `Debug.LOG` to their Documents folder on
every launch, ending in `ExitInstance(), good exit...` once their cleanup is
done, so for a non-zero exit the wrapp reads that (`HerEngineLog`). A log
from this launch that says so makes it a clean quit, logged as a notice
naming the log, with no failure summary; anything else is still the error
above.

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
Load now: other programs are keeping 0.8 cores busy, and this Mac has 8 performance cores
Load recently: 0.8–7.9 cores busy over the last 6 min (busiest at 17:27:41: other programs are keeping 7.9 cores busy, …); heavily loaded at times
Full log: …/sc-logs/20261016-172710-wrapp-build-secrets-can-kill-remastered.full.log
Run: 3f9a2c1e
=== END FAILURE SUMMARY ===
```

The cause of a failure is usually logged well before the failure: the "first
error in this stage" line is there because the last errors are usually
consequences. Stages are what the build's progress shows (`LogContext.enterStage`,
called next to each `━━━ Stage ━━━` divider); a wrapp has "Starting the game"
and "Playing". The error line keeps the error's type and case and its chain of
underlying errors, which `localizedDescription` drops. The load lines are
there for the same reason: by the time a starved Wine program is noticed
failing, the load that starved it may have gone, so the summary gives the
range the monitor saw as well as the load now. A wrapp's summary also
names its diagnostics bundle when it captured one. `grep -A20 'FAILURE SUMMARY'`
finds it. Cancelling a build produces no summary. A detailed failure report
carries the summary, redacted ([failure-reports.md](failure-reports.md)).
`FailureSummary.log` returns it for that.

## Crashes and signals

A Swift trap, an AppKit assertion or a segfault ends a process before anything
in its log says why. `CrashMarker.install` (the app and every wrapp) arms a
handler for the fatal signals that writes one line to stderr and to a
`crash-marker` file in the process's log folder, then lets the crash proceed
so macOS still writes its report. When failure reports are on, Sentry
handles crashes instead and `CrashMarker` installs nothing; the next start
logs the same line from Sentry's report
([failure-reports.md](failure-reports.md#crash-handlers)). At the next start the previous crash is
logged as an error with the path of that report in
`~/Library/Logs/DiagnosticReports`. The handler only makes async-signal-safe
calls, so it never touches the log itself.

A wrapp quits on SIGTERM, SIGINT or SIGHUP the way it does on Cmd-Q, ending the
game's Wine session, and logs the signal; it exits regardless 15 s later.

The app removes temp wrapps (`$TMPDIR/NancyDrew-*.app`) left by a run that
was killed before its cleanup, once they are 6 hours old, and logs each one.

## Structured fields

Entries carry swift-log metadata (`logger.notice("…", metadata: ["pid": "\(pid)"])`)
and the stage they were logged in. The text formats keep the compact line as it
was; the full format appends metadata as ` {pid=1237 program=wine setup.exe}`;
the JSON-lines sink writes everything as fields:

```
{"category":"Wine","label":"au.gare.callum.second-chance.Shared.Wine","level":"error",
 "message":"0124:err:module:import_dll …","metadata":{"pid":"1237","program":"wine setup.exe"},
 "pid":4120,"process":"Second Chance","run":"3f9a2c1e","seq":812,"stage":"Game installing",
 "time":"2026-10-16T06:22:45.627Z"}
```

so `jq 'select(.level == "error" and .stage == "Game installing")'` or
`jq 'select(.metadata.pid == "1237")'` replaces parsing columns and prefixes.
Wine output lines and `SubprocessWatch` lines carry `pid` and `program`.

## Environment variables

| Variable | Effect |
| -------- | ------ |
| `SECOND_CHANCE_LOG_STDERR` | `1` copies log lines to stderr even when it isn't a terminal, `0` never does. Unset, stderr gets them only when it is a terminal. |
| `SECOND_CHANCE_LOG_LEVEL`  | The quietest level copied to stderr (`trace` … `critical`). Default `notice`. |
| `SECOND_CHANCE_LOG_JSONL`  | Also write every entry, at every level, to this file as JSON lines. |
| `SECOND_CHANCE_LOG_FILE`   | Mirror every entry, at every level, to this file in the full format. `--mirror-logs` does the same with a file in `~/Downloads`. |
| `SECOND_CHANCE_RUN_ID`     | The run ID in the header. Inherited by child processes; set it to tie several processes' logs together. |
| `SECOND_CHANCE_INSTALL_TIMEOUT` | Seconds an unattended game install may run before it is stopped. Default 1800. |
| `SECOND_CHANCE_WINEDEBUG`  | Wine's `WINEDEBUG` for every Wine process Second Chance or a wrapp starts. Unset, it is `-all,err+all`: every channel off except the `err` class. |
