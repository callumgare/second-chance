# The developer CLI (`sc`)

`./sc` at the repo root builds, runs, tests and releases Second Chance. It is a
Swift package in `Tools/sc/`; the `./sc` script only builds that package (when
its sources have changed) and runs it. `./sc --help` and `./sc <command> --help`
are the full reference; this page explains how the pieces fit.

```bash
./sc app build                         # Build Second Chance.app (Debug)
./sc app run                           # …and run it, logs in this terminal
./sc wrapp build stay-tuned            # Build a wrapp headlessly from installers/stay-tuned/
./sc wrapp run stay-tuned              # Launch it (building it first if there's none)
./sc wrapp update stay-tuned           # Put the latest WrappTemplate into it
./sc wrapp wine stay-tuned -- regedit  # Run Wine inside its prefix
./sc test unit                         # Unit tests (seconds) + sc's own tests
./sc test integration stay-tuned       # Install, launch and quit one game for real
./sc test                              # Everything — hours
./sc release --dry-run                 # What the next release would contain
./sc setup                             # Once per clone: tools, commit hook, completions
./sc clean wine-prefixes               # Start the next build from a fresh Wine prefix
./sc in-gui-session -- <command>       # Run anything in the GUI session (over SSH)
```

## Shape of the API

Nouns first, then verbs: the two things you build and run (`app`, `wrapp`), then
single-purpose commands. The same option name means the same thing on every
command that takes it.

**Two kinds of build, never an unqualified "build" option.**

- The *app build* is everything xcodebuild produces: Second Chance.app,
  WrappTemplate.app inside it, WrappPuppeteer and the test bundle. Commands that
  need it run an incremental app build first; `--skip-app-build` uses what is
  already in `DerivedData/` instead and fails if there is nothing there.
- A *wrapp build* installs a game into a wrapp. Commands that use an existing
  wrapp take `--refresh-wrapp skip|template|full`: use it as it is, put the app
  build's WrappTemplate binary and dylib into it and re-sign it, or rebuild it
  from its source. `wrapp run` defaults to `skip` (and builds a wrapp only if
  none exists); `test integration` defaults to `full`, because the wrapp build is
  what it tests.

`test integration --ignore-load` tests every game even on a heavily loaded Mac,
which it otherwise reports as `overloaded` without testing
([testing.md](testing.md)).

`wrapp run` with `--refresh-wrapp skip` and an existing wrapp doesn't build the
app at all — launching a wrapp as it is doesn't need it.

**Every xcodebuild call passes `ONLY_ACTIVE_ARCH=NO`.** `Tools/sc/Sources/SCKit/Support/Xcode.swift`
is the only place xcodebuild is run from; see AGENTS.md for why the flag is
load-bearing.

**Sources.** `wrapp build --from disk` is the only source so far. Each source is
a case of `WrappSourceKind` with its own options type conforming to
`WrappSourceInput` (`Support/Wrapps.swift`), which turns the options into the
app's `INSTALLATION_SOURCE` and inputs. Adding the Her installer or Steam is a
new case and a new type — the same shape as the app's `WrappBuildStrategy`.

**Results on stdout, everything else on stderr.** `wrapp build`, `wrapp update`
and `app build` print a path on stdout, so `open "$(./sc wrapp build stay-tuned)"`
works.

## Debug options

`--debug` is one repeatable, comma-separated option on `app run`, `wrapp build`
and `wrapp run`. Each command accepts the values that make sense for the
program it runs and lists them in its `--help`; `--debug help` prints them.
They map onto the app's and wrapp's own switches:

| `--debug` value        | Becomes                               | `app run` | `wrapp build` | `wrapp run` |
| ---------------------- | ------------------------------------- | :-------: | :-----------: | :---------: |
| `log-window`           | `--debug`                             | ✓         | ✓             | ✓           |
| `skip-installer`       | `--skip-installer`                    | ✓         | ✓             |             |
| `strict-install`       | `STRICT_INSTALL=true`                 |           | ✓             |             |
| `settings-dialog`      | `--debug-options`                     |           |               | ✓           |
| `wine=<channels>`      | `SECOND_CHANCE_WINEDEBUG=<channels>`  | ✓         | ✓             | ✓           |
| `keep-in-dock`         | `SECOND_CHANCE_KEEP_IN_DOCK=1`        |           |               | ✓           |
| `no-native-fullscreen` | `SECOND_CHANCE_NATIVE_FULLSCREEN=0`   |           |               | ✓           |
| `no-cursor-lock`       | `SECOND_CHANCE_CURSOR_LOCK=0`         |           |               | ✓           |
| `no-prestart-desktop`  | `SECOND_CHANCE_PRESTART_DESKTOP=0`    |           |               | ✓           |
| `no-diagnostics`       | `SECOND_CHANCE_DIAGNOSTICS=0`         |           |               | ✓           |
| `slow-start=<seconds>` | `SECOND_CHANCE_DIAG_SLOW_SECONDS`     |           |               | ✓           |

The table lives in one place, `DebugOption.all` in
`Tools/sc/Sources/SCKit/Support/DebugOptions.swift`: a new switch is a new row
there. Commas separate options except inside a value, so
`--debug log-window,wine=+seh,+d3d9` is two options.

## Output

All output goes through `UI` (`Support/UI/`), built on
[Noora](https://github.com/tuist/Noora).

**`--logs collapsed|full|raw`** sets how streamed tool output (xcodebuild, the
tests, the headless app, rsync) is shown. The default is `collapsed` in an
interactive terminal — stdout and stderr both terminals, `TERM` not `dumb` —
and `raw` otherwise, so piped output is the tools' own, unaltered.

- `collapsed`: each step shows its last few lines while it runs, then collapses
  to one ✔ line. A failed step leaves the error lines it saw on screen.
- `full`: every line, formatted by xcbeautify.
- `raw`: every line as the tool printed it.

Whatever the mode, every step's full output is written to
`DerivedData/sc-logs/<time>-<step>.log`, and failures print the path. The app
only sends `notice` and up to stderr ([logging.md](logging.md#levels)), so for a
wrapp build sc also has it write its complete log, every level, to
`<time>-wrapp-build-<slug>.full.log` beside it (`SECOND_CHANCE_LOG_FILE`), and
the same as JSON lines to `<time>-wrapp-build-<slug>.jsonl`
(`SECOND_CHANCE_LOG_JSONL`); a failed build prints the full log's path as well.

`sc wrapp build` passes the slug it was asked for as `EXPECTED_GAME_SLUG`, so a
disc of a different game fails the build rather than building that game, and it
reports the wrapp at the path the app's `completed` record names rather than
the one it expected, so an older wrapp of the same name can't pass for it.

**Live regions.** Noora's renderer assumes one live component at a time. `LiveRegion`
gives each component its own slot (Noora components all take a `renderer:`) and
redraws the slots together, so a progress bar, a status line and a table can
update at once. Lines that should stay, like a failed test, print above the
region. Two Noora quirks the code works around, noted where it does: the
default `Terminal` exits with status 0 on Ctrl-C (sc passes
`signalBehavior: .none` and handles signals itself), and the static
`table(_:renderer:)` ignores its renderer (sc uses the updating table for every
table).

**Interactive only.** Prompts (pick a game when no slug is given, pick what to
`clean`) and the `l` key during a wrapp build only appear when there is a
terminal to answer on; each has a flag equivalent.

## Progress from the app

The headless app reports its build stage through a JSON-lines file:
`sc wrapp build` sets `SECOND_CHANCE_PROGRESS_PATH`, and `CLIBuilder` attaches a
`ProgressFileWriter`, an `EventBus.app` subscriber that writes one line per
`.progress(WrappBuildState)`, `.completed` and `.failed` event. The integration
test writes the same file (`TEST_RUNNER_PROGRESS_PATH`) plus per-game
`started`/`building`/`launching`/`finished` lines, which drive the
`sc test integration` table. [wrapp-build.md](wrapp-build.md#headless-runs) has
the record format.

The app copies its log lines to stderr only when stderr is a terminal. `sc`
runs it with stderr piped to itself, so it sets `SECOND_CHANCE_LOG_STDERR=1`,
which forces that copy on (`0` forces it off).

## Tests

`sc test unit` runs every suite except a short denylist —
`TestRunner.unitExclusions`: the disk-install integration suite and the two
exiftool suites — so **a new suite runs by default**. It then runs `Tools/sc`'s
own Swift tests. `sc test integration [<slug>…]` runs the per-game integration
suite with one worker; `sc test` runs both, as two separate xcodebuild runs.
Each run writes `test-results/<time>-<suite>.xcresult`, and an HTML report goes
in `test-results/<time>/`. `--open-report` opens it on `failures` (the default),
`always` or `never` — the terminal table covers a passing run.

[testing.md](testing.md) covers the suites themselves.

## GUI session and remote Macs

**Over SSH, commands that open windows re-run themselves in the GUI session.**
An SSH shell lives in launchd's Background session, with no WindowServer
connection, so Wine can't create windows: installers exit 1 and the build fails
looking like a broken installer. `app run`, `wrapp build`, `wrapp run`,
`wrapp wine` and `test integration` check `launchctl managername`; outside
`Aqua` they re-run the same command as a one-off LaunchAgent in
`gui/<uid>`, under a pty, stream its output back, forward keystrokes, and exit
with its status. Someone must be logged in at that Mac's console as the same
user. `sc in-gui-session -- <command>` does the same for any command.

A locked screen still has a GUI session — Wine runs — but synthetic clicks land
on the lock screen and screenshots don't show the game. `test integration`,
which drives the game with WrappPuppeteer, refuses to start; the others warn
and carry on.

The re-run gets an explicit `--logs`: it runs under a pty, so it would
otherwise decide it was interactive even when the original command was piped.

**`--on <host>[:<path>]` runs a command on another Mac.** It rsyncs the repo
there (excluding `.git`, `built-apps`, `test-results`, `tmp`, sc's own `.build`
and `DerivedData/sc-logs`) and runs `./sc` with the same arguments over `ssh`
(`-t` when interactive). Output stays there: a test run's results and report
are in the remote Mac's `test-results/`, and the terminal shows the summary
table. `<path>` defaults to this repo's path relative to
your home directory. On the remote Mac, the GUI-session re-run applies as
usual.

## Changing sc

Its code is in `Tools/sc/`:

- `Sources/SCKit/Commands/` — one file per top-level command.
- `Sources/SCKit/Support/` — the pieces they share.
- `Sources/GameCatalog/` — symlinks to the app's `GameInfo.swift` and
  `GameInfoProvider.swift`, so slugs and titles come from the app's own
  database, plus `Catalog.swift`, the public face the rest of the tool uses.
  It builds in Swift 5 mode because those files are the app's.
- `Tests/SCKitTests/` — Swift Testing; `swift test --package-path Tools/sc`,
  also run by `sc test unit` and CI.

Logic lives in the `SCKit` library so tests can parse real command lines with
`SC.parseAsRoot`. Dependencies are swift-argument-parser, swift-subprocess and
Noora, pinned with `.upToNextMinor`.
