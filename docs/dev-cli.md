# The developer CLI (`sc`)

`./sc` at the repo root builds, runs, tests and releases Second Chance. It is a
Swift package in `Tools/sc/`; the `./sc` script only builds that package (when
its sources have changed) and runs it. `./sc --help` and `./sc <command> --help`
are the full reference; this page explains how the pieces fit. Commands are noun
first, then verb (`wrapp build`, not `build wrapp`); a help request naming a
command `sc` doesn't have is an error, with a suggestion when the words are just
in the wrong order, rather than swift-argument-parser's silent fallback to the
nearest command's help.

```bash
./sc app build                         # Build Second Chance.app (Debug)
./sc app run                           # …and run it, logs in this terminal
./sc screenshot                        # Picture the app's and a wrapp's screens for review, light and dark
./sc screenshot app --on-screen --state welcome --out docs/   # Retake the README's pictures
./sc wrapp build stay-tuned            # Build a wrapp headlessly from installers/stay-tuned/
./sc wrapp run stay-tuned              # Launch it (building it first if there's none)
./sc wrapp update stay-tuned           # Put the latest WrappTemplate into it
./sc wrapp wine stay-tuned -- regedit  # Run Wine inside its prefix
./sc test unit                         # Unit tests (seconds) + sc's own tests
./sc test unit DocsTableTests          # Just that suite, wherever it's declared
./sc test integration stay-tuned       # Install, launch and quit one game for real
./sc test integration ghost-dogs --vm sc-sequoia  # …launching it in a tart VM
./sc test                              # Runs nothing: says to name unit, integration or all
./sc test all                          # Unit, then integration: hours
./sc release --dry-run                 # What the next release would contain
./sc release --plain-notes             # Release with the commit-message notes as they are
./sc release --notes-model opus        # Rewrite the notes with a model other than Sonnet
./sc release --build-only              # Build and zip the next version, changing nothing
./sc lint                              # SwiftLint and markdownlint, as CI runs them
./sc setup                             # Once per clone: tools, commit hook, completions, Wrappfile highlighting
./sc clean layers                      # Start the next build from scratch: no cached Wine prefix
./sc clean engines                     # Prepare engines afresh, from their downloads
./sc clean downloads                   # Fetch (and check) AutoIt, the patches, engines' files and Big Fish's installer afresh
./sc in-gui-session -- <command>       # Run anything in the GUI session (over SSH)
./sc --on <host> attach                # Pick up a remote run after the connection dropped
./sc --on <host> lease                 # Who has that Mac's screen (--break to stop their run)
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
([testing.md](testing.md)). `--build-concurrency <n>` builds that many games at
once (they still launch one at a time; by default one per four performance
cores), as far as the disk has room, leaving
`--disk-margin <GB>` (10) free
([testing.md](testing.md#building-games-side-by-side)). `--keep-recordings`
keeps every launch's screen recording, not only a failed or warned one's
([testing.md](testing.md#wrapppuppeteer)).

`wrapp run` with `--refresh-wrapp skip` and an existing wrapp doesn't build the
app at all — launching a wrapp as it is doesn't need it.

**Every xcodebuild call passes `ONLY_ACTIVE_ARCH=NO`.** `Tools/sc/Sources/SCKit/Support/Xcode.swift`
is the only place xcodebuild is run from; see AGENTS.md for why the flag is
load-bearing.

**Sources.** `wrapp build --from disk` (the default), `--from steam`,
`--from her-download`, `--from big-fish` or `--from download` (a free game, downloaded from where
its bundle says: [wrapp-build.md](wrapp-build.md#the-download-source)). Each source is a case of `WrappSourceKind` with its own
options type conforming to `WrappSourceInput` (`Support/Wrapps.swift`), which
turns the options into the app's `INSTALLATION_SOURCE` and inputs. Adding a
source is a new case and a new type — the same shape as the app's
`WrappBuildStrategy`.

`--from her-download` builds from `installers/<slug>/her-download*.exe` or
`her-download*.dmg`, or from the file `--her-download` names. A game with more
than one download needs `--her-download` to pick which
([her-download.md](her-download.md)).

`sc test integration --source disk|steam|her-download|big-fish|big-fish-trial|download|all`
(comma-separated) picks which build sources' suites run; [testing.md](testing.md)
has what each needs. These are `IntegrationSource`'s cases rather than
`WrappSourceKind`'s, as Big Fish has two suites, the owned games and the free
trials, where `wrapp build` has one source and a flag.

`wrapp build` starts the app, and `wrapp run`, `wrapp wine` and `app run`
the program they replace `sc` with, as its own responsible process, so macOS
privacy prompts (which Steam waits on) aren't addressed to `sc`; see
[steam.md](steam.md).

`sc generate` writes the Swift made from `Bundles/` and `Modules/`, and
compiles each module's Icon Composer icons (`assets/<name>.icon`) to the
`.icns` a Wrappfile's `ICON` names (`xcrun actool`, which only Xcode has, so
the `.icns` is checked in).

`--from steam` builds any game on Steam that the signed-in account owns;
`--steam-launch steam|direct` answers the launch question for a DRM-free one,
as `--input launch-mode=steam` does. `--input <name>=<value>` gives any of the
edition's inputs a value (repeat it for more), and `sc bundle plan` takes it
too; the app is handed them as JSON in `SECOND_CHANCE_INPUTS`.
It needs the shared Steam sign-in to exist already — a headless build can't
show Steam's sign-in window — so sign in once by building a Steam game from
the app. [steam.md](steam.md) has the details.

`--from big-fish` builds any game Big Fish Games sells that the test account
in `.env` (`BIG_FISH_EMAIL`, `BIG_FISH_PASSWORD`) owns: a headless build has
nobody to sign in, so `sc` passes the account to the app with
`BIG_FISH_TEST_SIGN_IN=1`, and refuses to start without it. `--big-fish-trial`
builds the game's free trial instead, signed out, with no account needed
([big-fish.md](big-fish.md#testing)).

**Bundles.** `sc bundle check [<folder>…]` checks program bundles against the
manifest schema, `sc bundle list [--where <path>=<value>]` lists them by any
manifest field, and `sc generate` writes the Swift made from bundles and
modules' data: GameCatalog's table of games, and the wrapp's routine Wine
errors ([program-bundles.md](program-bundles.md), [modules.md](modules.md)).
`sc module check [<id>…]` checks modules and their recorded releases, and `sc
module release <id>` records one ([modules.md](modules.md#releases)). `sc engine prepare <id>
[--version <v>] [--into <folder>]` prepares an engine from its package's
downloads as a build would, and checks or prints its hash, `sc engine
fetch [<id>…]` puts engines in this Mac's engine store, and `sc engine check`
asks each engine's downloads are still where their modules say
([modules.md](modules.md#engine-packages)).

**Results on stdout, everything else on stderr.** `wrapp build`, `wrapp update`
and `app build` print a path on stdout, so `open "$(./sc wrapp build stay-tuned)"`
works.

## Screenshots

`sc screenshot [app|wrapp]` pictures the screens worth looking at without
making them happen for real — Second Chance's window part-way through a
Steam build, a wrapp's loading window with a notice up, their error screens
— each light and dark, as `<app|wrapp>-<state>-<light|dark>.png`. Left out,
the target is both. `--list` prints the states' names; `--state` takes some
of them (repeatable or comma-separated, `steam-*` for a prefix). By default
they go into `DerivedData/screenshots/`, with an `index.html` showing each
state's two pictures side by side; `--out` writes them somewhere else,
without the page.

Each app keeps its own catalogue of states, `UIStateCatalog`
(`SecondChance/Utilities/` and `WrappTemplate/`): a name, its window's title,
style and size, and a view set up as it would be then. Run with
`SECOND_CHANCE_UI_STATES=<folder>` (`SECOND_CHANCE_UI_STATES_ONLY` for
`--state`, `SECOND_CHANCE_UI_STATES_LIST=1` for `--list`), an app draws them
(`UIStateShots`, `SecondChanceKit`) and quits before making any window of
its own. A state the view resets as it appears (the loading window's notes
start their clocks afresh) is set again in its `afterAppearing`. To review a
new screen or notice, add a state to the catalogue of the app it's in.

**Off screen**, the default, each is drawn in a window that is never shown,
so nothing comes on screen, nothing takes the focus and no permission is
needed: it's safe on a Mac someone is using. The pictures have only the
window's contents: macOS's window server adds the title bar and shadow, and
only to a window on screen. A default button isn't in the accent colour, as
the window is never key.

**`--on-screen`** shows each in a real window with its title bar and style,
makes the app active, and captures it with its shadow (ScreenCaptureKit; a
process may capture its own windows without Screen Recording). The README's
pictures are the `welcome` state taken this way: `sc screenshot app
--on-screen --state welcome --out docs/` writes `docs/app-welcome-light.png`
and `-dark.png`. They were taken on a Retina display, and each version of
macOS draws a window's frame its own way, so retake them on a Mac like the
one that took them. `sc release` retakes them from the release's build and
commits a picture only when it looks different
([releasing.md](releasing.md)). The app activates itself with
`activate(ignoringOtherApps:)`: the plain `activate()` is only a request
since macOS 14, and it's turned down for an app that hasn't finished
launching through its own run loop, leaving the window drawn inactive.

## Debug options

`--debug` is one repeatable, comma-separated option on `app run`, `wrapp build`
and `wrapp run`. Each command accepts the values that make sense for the
program it runs and lists them in its `--help`; `--debug help` prints them.
They map onto the app's and wrapp's own switches:

| `--debug` value           | Becomes                               | `app run` | `wrapp build` | `wrapp run` |
| ------------------------- | ------------------------------------- | :-------: | :-----------: | :---------: |
| `log-window`              | `--debug`                             | ✓         | ✓             | ✓           |
| `show-ui`                 | `SECOND_CHANCE_SHOW_UI=1`             |           | ✓             |             |
| `skip-installer`          | `--skip-installer`                    | ✓         | ✓             |             |
| `strict-install`          | `STRICT_INSTALL=true`                 |           | ✓             |             |
| `install-stall=<seconds>` | `SECOND_CHANCE_INSTALL_STALL_SECONDS` | ✓         | ✓             |             |
| `layer-cache=<policy>`    | `SECOND_CHANCE_LAYER_CACHE=<policy>`  | ✓         | ✓             |             |
| `settings-dialog`         | `--debug-options`                     |           |               | ✓           |
| `wine=<channels>`         | `SECOND_CHANCE_WINEDEBUG=<channels>`  | ✓         | ✓             | ✓           |
| `wine-sync=<mode>`        | `SECOND_CHANCE_WINE_SYNC=<mode>`      | ✓         | ✓             | ✓           |
| `no-native-fullscreen`    | `SECOND_CHANCE_NATIVE_FULLSCREEN=0`   |           |               | ✓           |
| `no-cursor-lock`          | `SECOND_CHANCE_CURSOR_LOCK=0`         |           |               | ✓           |
| `no-mode-scaling`         | `SECOND_CHANCE_MODE_SCALING=0`        |           |               | ✓           |
| `no-cocoa-start-wait`     | `SECOND_CHANCE_COCOA_START_WAIT=0`    | ✓         | ✓             | ✓           |
| `no-prestart-desktop`     | `SECOND_CHANCE_PRESTART_DESKTOP=0`    |           |               | ✓           |
| `no-diagnostics`          | `SECOND_CHANCE_DIAGNOSTICS=0`         |           |               | ✓           |
| `slow-start=<seconds>`    | `SECOND_CHANCE_DIAG_SLOW_SECONDS`     |           |               | ✓           |
| `reporting`               | `SECOND_CHANCE_REPORTING=1`           | ✓         | ✓             | ✓           |

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
`.progress(WrappBuildState)`, `.stepProgress`, `.completed` and `.failed`
event; a step's figures (a Steam download's, say) follow its stage on the
status line. The integration
test writes the same file (`TEST_RUNNER_PROGRESS_PATH`) plus per-game
`started`/`building`/`launching`/`finished` lines, which drive the
`sc test integration` table; each game's build writes its stage lines with the
game's `source` and `slug`, so games building side by side each keep their
own, and its `finished` line splits its time into build, launch and waiting
([testing.md](testing.md#filtering-games)). [wrapp-build.md](wrapp-build.md#headless-runs) has
the record format.

The app copies its log lines to stderr only when stderr is a terminal. `sc`
runs it with stderr piped to itself, so it sets `SECOND_CHANCE_LOG_STDERR=1`,
which forces that copy on (`0` forces it off).

## Tests

`sc test unit` runs every suite except a short denylist —
`TestRunner.unitExclusions`: the integration suites for discs, Steam, Her
downloads and Big Fish — so **a new suite runs by default**. It then runs `Tools/sc`'s
own Swift tests. Name suites to run only those: `sc test unit DocsTableTests
CompositionTests` runs each where it's declared (`UnitTestSelection`): the
app's through xcodebuild's `-only-testing`, a package's or sc's own through
`swift test --filter`, and the app is built for testing only when one of them
is the app's. `Suite/test()` runs one test. `sc test integration [<slug>…]` runs the per-game integration
suite with one worker; `sc test all` runs both, as two separate xcodebuild
runs. A bare `sc test` runs nothing: it prints its help and exits 64, so a
script that once relied on it meaning the unit tests fails rather than
passing, and the hours-long run is never had by accident.
Each run writes `test-results/<time>-<suite>.xcresult`, and an HTML report goes
in `test-results/<time>/`. `--open-report` opens it on `failures` (the default),
`always` or `never` — the terminal table covers a passing run.

`--vm <name>` launches each game in a tart VM instead of here (`TestVM` gets
the VM ready, starting and stopping it as needed); this Mac's screen then only
needs to allow windows, for the builds, and may be locked.
[testing.md](testing.md#testing-in-a-vm) has the setup and what a VM can't
test.

[testing.md](testing.md) covers the suites themselves.

## Lint

`sc lint` (`Lint` in `Support/`) runs SwiftLint with `--strict` over the
Swift code — rules in `.swiftlint.yml` — and markdownlint-cli2, pinned to
`Lint.markdownlintVersion` and run through `npx`, over `README.md`,
`CONTRIBUTING.md`, `AGENTS.md` and `docs/*.md` — rules in
`.markdownlint.jsonc`, ignores in `.markdownlint-cli2.jsonc`. The files are
listed rather than globbed, since a glob from the root walks the installers
and build output before any ignore applies. Each linter is a step whose output
shows when it fails, and the command exits 1 if either does. CI's Lint job runs
it, and shellcheck over `./sc` and the build phases' scripts (`.shellcheckrc`), and `sc release` runs the same check
([releasing.md](releasing.md#lint-first)). `sc setup` checks `swiftlint` and
`npx` are installed. `swiftlint --fix` fixes much of what SwiftLint finds.

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

**A GUI-session run outlives its connection.** The LaunchAgent's parent is
launchd, not the SSH session, so stopping a run and losing it are kept apart:

- **Ctrl-C** stops the run.
- **A dropped connection** (SIGHUP with a pty; sshd vanishing from sc's
  ancestors without one) only stops sc *following* it. The run carries on,
  including through a restart of the Mac you connected from, but not one of
  the Mac it runs on, which ends its GUI session.
- **`sc attach`** picks it up again. It replays the output from the start,
  forwards keys, and exits with the run's status. With no id, it takes the
  run still going, or the newest if that has already finished. `--list` shows
  the runs and `--stop` stops one.

Each run keeps its job script, output, exit code and input pipe in
`DerivedData/sc-jobs/<id>/`. The id is the start time plus sc's pid. The input
pipe is held open by the job itself, so it survives the sc that started it.
The newest 10 finished runs are kept.

**`--on <host>[:<path>]` runs a command on another Mac.** It rsyncs the repo
there (excluding `.git`, `.env`, `built-apps`, `test-results`, `tmp`, `build`,
the packages' and sc's own `.build` and `.swiftpm`, and all of `DerivedData`,
or all but what was built, `Build/Products`, with `--skip-app-build`) and runs
`./sc` with the same
arguments over `ssh` (`-t` when interactive). Output stays there: a test run's
results and report are in the remote Mac's `test-results/`, and the terminal
shows the summary table. `<path>` defaults to this repo's path relative to
your home directory. The rest of `DerivedData` stays behind because it
records this checkout's absolute path (Swift packages' state, the build's
intermediates), so a build on the other Mac, in a checkout elsewhere, failed
looking for files here; and it holds Xcode's compilation cache, sparse files
tens of gigabytes long that rsync would send in full. rsync neither sends nor
deletes what it leaves out, so the other Mac keeps its own build state, logs
and jobs, and a build there is incremental. Only `--skip-app-build` runs
this Mac's build there, so only then are its products sent: any other
command builds the app there anyway, and products copied while something
here was rebuilding them arrived half-copied. `.env` stays behind because it holds each Mac's own
settings, such as whether tests hide their windows there
([testing.md](testing.md)). `installers/` is sent but protected from
`--delete` (`Remote.protects`), so the other Mac keeps installers this one
doesn't have. On the remote Mac, the GUI-session re-run applies as
usual.

- **The sync is macOS's own rsync at both ends** (`/usr/bin/rsync -aE
  --rsync-path=/usr/bin/rsync`), so a remote Mac needs nothing installed.
  It has to keep extended attributes: the template's non-Mach-O files keep
  their code signatures in them, and without them every wrapp built there
  fails to sign. Apple's rsync spells that `-E` and rejects `-X`; Homebrew's
  rsync 3.x reads `-E` as `--executability` and would drop them silently,
  which is why the remote end is named rather than left to its `PATH`.
- **A sync that stops partway runs nothing there**, and sc says so: most
  often files here changed while being copied (another build, or an agent's
  worktree, which isn't synced). With `--skip-app-build` the other Mac's app
  may be left half-copied, and its own build won't mend it, since its build
  state says the template's Wine and ScummVM are already set up; sc says to
  run `sc --on <host> clean build -y` and build there.
- **If the connection drops,** sc says so: ssh's exit 255. Pick the run up
  with `sc --on <host>[:<path>] attach`, which doesn't sync.
- **While a run is still going there, `--on` refuses to sync.** rsync would
  replace the build and the sc it is using. Attach to it, or stop it with
  `attach --stop`, first.

## The screen lease

**One run at a time has a Mac's screen.** Every command that opens windows
(`app run`, `wrapp build`, `wrapp run`, `wrapp wine`, `screenshot` and
`test integration`) leases the screen before it does, in the process that
opens them: here, or the GUI-session re-run. A second such command on that Mac,
from any checkout, stops at once with exit 75. It doesn't wait, because an
integration run can hold the screen for hours. Instead it says:

- who has the screen, what they're running and for how long;
- their purpose, from `--purpose "<text>"`, which every command takes;
- where they ran it from: the Mac, the checkout and the branch.

Before this, a game launched during another agent's integration run took the
focus and failed that run's tests.

**The holder is named so it can be asked.** A Claude Code session passes its
details to everything it runs, and `sc` records three of them:

- `CLAUDE_CODE_MESSAGING_SOCKET`, the address other sessions message it at
  (`uds:<socket>`, which their agent list maps to its name);
- `CLAUDE_CODE_SESSION_ID`;
- `CLAUDE_PID`.

A person's run records the user and the Mac instead. The session's
messaging token is never recorded. `--on` carries the holder to the other Mac
in `SC_LEASE_HOLDER` (base64 JSON, put on the remote command line with `env`),
since ssh passes no environment; a GUI-session re-run inherits it as it does
the rest.

**A blocked command offers three ways on:**

- `--ignore-screen-lease`: go ahead regardless, leaving the lease in place.
- `--break-screen-lease`: stop the run holding the lease, sending it SIGINT so
  it cleans up as for Ctrl-C, wait up to 2 minutes for it to go, then take the
  screen.
- `sc lease`: show the lease (`--json` for scripts); `sc lease --break` stops
  the holder and leaves the screen free. Like `attach`, `--on … lease`
  doesn't sync.

**A lease lasts as long as the process that took it.** sc releases it on
exit. If the process is killed or the Mac restarts, the next command finds
that process gone and takes the stale lease over. The holder is checked by its
pid and its start time, so a reused pid doesn't count as the holder. A command
that sc itself starts inside a leased run (a descendant of the holder) runs
under the same lease. The lease is
`~/Library/Application Support/au.gare.callum.second-chance.sc/screen-lease.json`,
or the file `SC_SCREEN_LEASE_FILE` names (`ScreenLease`).

## Changing sc

Its code is in `Tools/sc/`:

- `Sources/SCKit/Commands/` — one file per top-level command.
- `Sources/SCKit/Support/` — the pieces they share.
- `Sources/SCKit/Support/Catalog.swift` — what the tool needs of the app's
  own game database, the `GameCatalog` package in `Packages/GameCatalog/`, so
  slugs and titles never drift from the app's. `./sc` rebuilds when that
  package changes too.
- `Tests/SCKitTests/` — Swift Testing; `swift test --package-path Tools/sc`,
  also run by `sc test unit` and CI.

Logic lives in the `SCKit` library so tests can parse real command lines with
`SC.parseAsRoot`. Dependencies are swift-argument-parser, swift-subprocess and
Noora, pinned with `.upToNextMinor`.
