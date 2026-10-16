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

## Environment variables

| Variable | Effect |
| -------- | ------ |
| `SECOND_CHANCE_LOG_STDERR` | `1` copies log lines to stderr even when it isn't a terminal, `0` never does. Unset, stderr gets them only when it is a terminal. |
| `SECOND_CHANCE_LOG_LEVEL`  | The quietest level copied to stderr (`trace` … `critical`). Default `notice`. |
| `SECOND_CHANCE_LOG_FILE`   | Mirror every entry, at every level, to this file in the full format. `--mirror-logs` does the same with a file in `~/Downloads`. |
| `SECOND_CHANCE_WINEDEBUG`  | Wine's `WINEDEBUG` for every Wine process Second Chance or a wrapp starts. Unset, it is `-all,err+all`: every channel off except the `err` class. |
