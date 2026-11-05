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
./sc wrapp build stay-tuned            # Build a wrapp headlessly from its disc image in the installers store
./sc wrapp run stay-tuned              # Launch it (building it first if there's none)
./sc wrapp update stay-tuned           # Put the latest WrappTemplate into it
./sc wrapp wine stay-tuned -- regedit  # Run Wine inside its prefix
./sc test unit                         # Unit tests (seconds) + sc's own tests
./sc test unit DocsTableTests          # Just that suite, wherever it's declared
./sc test integration stay-tuned       # Install, launch and quit one game for real
./sc test integration ghost-dogs --vm sc-sequoia  # …launching it in a tart VM
./sc installers list                   # The disc images and downloads in this Mac's installers store
./sc test                              # Runs nothing: says to name unit, integration or all
./sc test all                          # Unit, then integration: hours
./sc release --dry-run                 # What the next release would contain
./sc release --plain-notes             # Release with the commit-message notes as they are
./sc release --notes-model opus        # Rewrite the notes with a model other than Sonnet
./sc release --build-only              # Build and zip the next version, changing nothing
./sc lint                              # SwiftLint, markdownlint and the Wrappfiles' format, as CI runs them
./sc setup                             # Once per clone: tools, commit hook, completions, Wrappfile highlighting
./sc clean layers                      # Start the next build from scratch: no cached Wine prefix
./sc clean engines                     # Prepare engines afresh, from their downloads
./sc clean downloads                   # Fetch (and check) AutoIt, the patches, engines' files and Big Fish's installer afresh
./sc store list                        # The stores builds and apps keep: Steam's sign-in and client, each app's saves
./sc store remove steam:client         # Remove one (an app's from every app, unless --app names one)
./sc clean stores                      # Remove the cache stores (--retention keep: the kept ones, saves and sign-ins)
./sc in-gui-session -- <command>       # Run anything in the GUI session (over SSH)
./sc --on <host> attach                # Pick up a remote run after the connection dropped
./sc --on <host> lease                 # Who has that Mac's screen (--break to stop their run)
./sc --on <host> lease take --for 30m --purpose "…"   # Lease it by hand for work sc doesn't run; `release` after
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

`--from disk` builds from the game's disc images in the
[installers store](testing.md#the-installers-store), or from those `--disk`
names; `--from her-download` from its Her edition's `installer.exe` or
`installer.dmg` there, or from the file `--her-download` names. A game with more
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
from Second Chance's `EMIT` strings (`SecondChance/Resources/emit-vocabulary.yaml`,
[wrappfile.md](wrappfile.md#emit)), and compiles each module's Icon Composer icons (`assets/<name>.icon`) to the
`.icns` a Wrappfile's `APP --icon` names (`xcrun actool`, which only Xcode has, so
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
manifest schema, and holds every edition's `EMIT`s to the strings Second
Chance reads ([wrappfile.md](wrappfile.md#emit)), `sc bundle list [--where
<path>=<value>]` lists them by any manifest field, and `sc generate` writes
the Swift made from bundles and modules' data: GameCatalog's table of games,
the wrapp's routine Wine errors, and the `EMIT` strings Second Chance reads ([program-bundles.md](program-bundles.md), [modules.md](modules.md)).
`sc module check [<id>…]` checks modules and their recorded releases, and `sc
module release <id>` records one ([modules.md](modules.md#releases)). `sc engine prepare <id>
[--version <v>] [--into <folder>]` prepares an engine from its package's
downloads as a build would, and checks or prints its hash, `sc engine
fetch [<id>…]` puts engines in this Mac's engine store, and `sc engine check`
asks each engine's downloads are still where their modules say
([modules.md](modules.md#engine-packages)). `sc module` and `sc engine` run
the same code as `wrapp-builder module` and `wrapp-builder engine`
([below](#wrapp-builder)), over the repo's `Modules/`.

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
| `keep-failed-build`       | `SECOND_CHANCE_KEEP_FAILED_BUILD=1`   | ✓         | ✓             |             |
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

`--shard-on <host>[:<path>][,…]` runs the integration suite in a claimed
[test session](#test-sessions) on each Mac instead, one shard each, and
gathers one table naming each row's Mac and session
([testing.md](testing.md#sharding-a-run-across-macs)).

`sc installers list` shows which games' installers are in this Mac's
[installers store](testing.md#the-installers-store).

[testing.md](testing.md) covers the suites themselves.

## Lint

`sc lint` (`Lint` in `Support/`) runs SwiftLint with `--strict` over the
Swift code — rules in `.swiftlint.yml` — and markdownlint-cli2, pinned to
`Lint.markdownlintVersion` and run through `npx`, over `README.md`,
`CONTRIBUTING.md`, `AGENTS.md` and `docs/*.md` — rules in
`.markdownlint.jsonc`, ignores in `.markdownlint-cli2.jsonc`. The files are
listed rather than globbed, since a glob from the root walks the installers
and build output before any ignore applies. Then it checks every Wrappfile
in `Bundles/` and `Modules/` (the bundles' `Wrappfile`s and the modules'
stages and functions) is formatted, as `wrapp-builder fmt --check --migrate`
would, so syntax that has changed fails it too
([wrappfile.md](wrappfile.md#style)); `wrapp-builder fmt --migrate` fixes
what it finds. Each linter is a step whose output shows when it fails, and
the command exits 1 if any does. CI's Lint job runs
it, and shellcheck over `./sc` and the build phases' scripts (`.shellcheckrc`), and `sc release` runs the same check
([releasing.md](releasing.md#lint-first)). `sc setup` checks `swiftlint` and
`npx` are installed. `swiftlint --fix` fixes much of what SwiftLint finds.

## wrapp-builder

`wrapp-builder` is the builder's own command-line tool, in its own package,
`Packages/WrappBuilderCLI/`: it checks, plans, formats and builds
Wrappfiles, and looks after modules and engines, knowing nothing of Second Chance's, so it
can move with the builder. Its commands are in the library
`WrappBuilderTool`, which `sc` links, so `sc module`, `sc engine` and `sc
lint`'s format check are the same code. Run it from the repo root:

```bash
swift run --package-path Packages/WrappBuilderCLI wrapp-builder check Bundles/nancy-drew/old-clock
swift run --package-path Packages/WrappBuilderCLI wrapp-builder plan Bundles/nancy-drew/old-clock --edition cd
swift run --package-path Packages/WrappBuilderCLI wrapp-builder fmt --check Bundles Modules
```

| Command | Does |
| --- | --- |
| `check <bundle folder>` | Parses and checks the bundle's manifest and Wrappfile, planning every edition, without building it ([wrappfile.md](wrappfile.md#checking)). |
| `plan <bundle folder> [--target <stage>] [--edition <id>] [--input <name>=<value>]… [--allow-path <folder>]…` | Prints what building a stage would run, each step with where it was written ([wrappfile.md](wrappfile.md#plans)). `--target` picks a stage other than the edition's; `--edition` whose inputs it's given (by default, the first whose target it is); `--allow-path` a folder of the bundle's it may read beside its manifest's `allow-paths`, or `*` for any path, with a warning ([wrappfile.md](wrappfile.md#what-a-build-may-read)). |
| `build <bundle folder> --out <app> [--target <stage>] [--edition <id>] [--input <name>=<path>]… [--app-id <id>] [--template <app>] [--allow-path <folder>]… [--events plain\|json]` | Builds a stage into an app with the runner ([wrapp-build.md](wrapp-build.md#the-runner)) and the executors the tool has, which are none yet, so it refuses a plan with any module's instruction. Inputs are paths, by name. `--app-id` is the app's id over the Wrappfile's `APP --default-id`; `--template` an app whose files are laid in first (the launcher), without which the result holds what the steps made and isn't an app that runs. `--events` prints the build's events a line each, or one JSON object a line; `EMIT` strings are printed as they are. A step that asks something asks on the terminal, and fails without one. |
| `fmt <file or folder>… [--check] [--migrate]` | Writes Wrappfiles in the one style, in place, a folder searched for bundles' `Wrappfile`s and modules' stages and functions ([wrappfile.md](wrappfile.md#style)). `--check` changes nothing, names each file that isn't formatted, and fails if any isn't; `--migrate` rewrites syntax that has changed first. |
| `module check [<id>…]`, `module release <id>` | Checks modules against the schema and their recorded releases, and records one's files as its release ([modules.md](modules.md#releases)). |
| `engine prepare <id> [--version <v>] [--into <folder>]`, `engine fetch [<id>…] [--version <v>]`, `engine check` | Prepares an engine and prints its tree's hash, puts engines in this Mac's engine store, and checks each engine's downloads are still there ([modules.md](modules.md#engine-packages)). |

Every command but `fmt` takes `--modules <dir>`, the modules folder, by
default `./Modules`. A failure prints `error:` and its reason and exits
non-zero. Its tests (`Tests/WrappBuilderToolTests/`) run with `swift test`,
and in `sc test unit`.

## GUI session and remote Macs

**Over SSH, commands that open windows re-run themselves in the GUI session.**
An SSH shell lives in launchd's Background session, with no WindowServer
connection, so Wine can't create windows: installers exit 1 and the build fails
looking like a broken installer. `app run`, `wrapp build`, `wrapp run`,
`wrapp wine` and `test integration` check `launchctl managername`; outside
`Aqua` they re-run the same command as a one-off LaunchAgent in
`gui/<uid>`, under a pty, stream its output back, forward keystrokes, and exit
with its status. The same user must be logged in to a GUI session there, at the
Mac or through Screen Sharing: sc asks launchd (`launchctl print gui/<uid>` says
`type = login`), not `/dev/console`'s owner. A second user logged in through
Screen Sharing ("Log in as yourself") takes over that file while the first user's
session carries on at the screen, and that second session, in the background,
can run commands too. `sc in-gui-session -- <command>` does the same for any
command.

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
([testing.md](testing.md)). A command that may read installers (one that
builds, runs or tests games from a disc or a Her download) also sends this
Mac's [installers store](testing.md#the-installers-store) to the other Mac's,
below. On the remote Mac, the GUI-session re-run applies as usual.

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
- **Installers go store to store**, by an rsync of their own
  (`Remote.installersSync`), into the other Mac's store at the usual place,
  made first (writable by every user) if it has none. Never `--delete`: the
  other Mac may hold installers this one doesn't. Links go as links, so a
  disc image linked to one of its alternatives is linked the same there.
  Files are compared by size, and no times or extended attributes are set:
  the store's files belong to whoever put them there, and another user may
  write them but not set those. The receiving rsync waits on a lock
  (`lockf` on `/tmp/second-chance-installers-sync.lock`) so two syncs into
  one Mac's store never write the same file at once. Commands that read no
  installers (`session`, `puppet`, `lint`, `installers`, … or a run whose
  every source downloads) send none.

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

**Work that takes the screen without sc takes the lease by hand.**
`sc lease take --for 30m --purpose "<text>"` leases the screen for an engine run by
hand, a Peekaboo session, or someone at the Mac, and `sc lease release` gives it
back. A lease taken by hand has no process: it lasts until it's released or it
expires (`--for`, at most 8 hours; taking it again renews it). Commands from the
same agent session (or, without one, the same user on the same Mac) go ahead under
it, and anyone else's stop as for any lease. Breaking one only clears it, as there's
no run to stop.
`sc lease expiring --before 5m`, left running in the background after `take`, ends
five minutes before the lease runs out and says so: the cue to renew it (`take`
again) or finish up. An agent runs it as a background command, which wakes it when
the command ends. It ends at once with exit 1 if the lease is no longer yours, and
follows renewals.

**Looking needs no lease.** Only what opens windows, takes the focus or sends
input does. A screenshot, a window list, reading logs and `sc lease` itself never
take one, so they can run during another's run. Anything that observes during
someone else's run must leave the screen alone: no window activated, no overlay
drawn.

**A lease lasts as long as the process that took it.** sc releases it on
exit. If the process is killed or the Mac restarts, the next command finds
that process gone and takes the stale lease over. The holder is checked by its
pid and its start time, so a reused pid doesn't count as the holder. A command
that sc itself starts inside a leased run (a descendant of the holder) runs
under the same lease.

**Each user's screen has its own lease,** because each logged-in user has a
screen of their own (see [Test sessions](#test-sessions)). The lease is
`/Users/Shared/second-chance/leases/<user>.json`, where every user can read
and write it, or the file `SC_SCREEN_LEASE_FILE` names, with other users'
beside it (`ScreenLease`). `sc lease --all` lists every lease on the Mac.
A test session's screen is named `<mac>/<user>` in messages. A live lease in
the place older `sc` builds kept it, the user's
`~/Library/Application Support/au.gare.callum.second-chance.sc/screen-lease.json`,
is respected too, until every checkout has the change.

## Test sessions

**A Mac can run games in the background, in test users' own GUI logins**, while
someone uses its screen or another run has it. macOS keeps a separate screen for
each logged-in user. A login made through Screen Sharing ("Log in as yourself")
gets a virtual display of its own. Wine, ScummVM and DOSBox games run there at
full fidelity, and WrappPuppeteer's helper captures them as on the console.

**A test session needs a viewer.** With nobody connected, macOS locks the
session. A locked session never moves a game into its fullscreen Space, so the
game can't be captured or driven. Before the lock, an unwatched session also
stopped OpenGL reaching its windows: Direct3D games went black and ScummVM froze.
So the console user runs a keep-alive, `sc session keep-alive`, a LaunchAgent
(`--install`) that holds a Screen Sharing connection into each test session as a
viewer would:

- **It logs the session in** if it isn't: Apple's login over RFB starts a
  user's GUI session when they have none, in about three seconds, with nothing
  shown on the console.
- **It unlocks it** when it's locked: a click on the user's picture, then the
  password typed (`ScreenSharingConnection.unlock`).
- **It asks for an 8x8 corner every 2 seconds** and draws nothing. It costs
  about 23 MB and no measurable CPU; Screen Sharing's server takes about 2% while
  it's connected.
- **It reconnects** when the connection drops, waiting longer each time (up to
  10 minutes, so a wrong password can't lock the account).

`--install` copies the `sc` it's run with to
`~/Library/Application Support/SecondChance/session-keep-alive/` and runs that copy, so a
sync that breaks the checkout's build doesn't stop the keep-alive coming back; install it
again to update it.

It speaks just enough of RFB for this (`ScreenSharing.swift`): Apple's login,
security type 30, is a Diffie-Hellman exchange whose key (MD5 of the shared
secret) encrypts the user name and password with AES-128. The server announces
version 003.889 and accepts 3.8. Passwords come from the console user's login
keychain (service `second-chance-session`, the user's name as account), which is
locked over SSH, so the keep-alive only works as a LaunchAgent in the GUI session.

**The pool** is the Mac's list of test users,
`/Users/Shared/second-chance/pool`, one name a line (`SessionPool`):

- `sc session add [--count <n>] [<user>…]` sets a Mac up, run by the admin at
  its display, there or with `--on` from a terminal (it uses `sudo`, and over SSH
  asks to unlock the keychain). It creates standard users, named
  `second-chance-testing-<n>` unless named, each with a random password kept in
  the keychain; lets them in over SSH and Screen Sharing; gives new ones the
  console user's authorized SSH keys (existing ones only with `--install-keys`);
  and adds them to the pool. An existing user whose password is in the keychain
  is adopted, and a step already done is skipped, so running it again fixes only
  what's missing. A step needing `sudo` with no terminal fails at once rather
  than wait for a password. A new user's Setup Assistant is marked done
  before its first login: left to run, it holds the session where no sc job
  can start (an Aqua LaunchAgent never runs) while `sc session` still says
  "logged in". A re-run frees a user stuck there, logging it out for the
  keep-alive to log in again. It gives each test user the console user's
  [signing certificate](#signing-in-test-sessions). Then it makes the Mac's
  installers store (below) and installs the keep-alive if it isn't running.
- `sc session logout [--force] [<user>…]` logs the test sessions out (all
  the pool's, unless named), so the Mac shuts down or restarts without asking
  about other users. It stops the keep-alive first, which would log them in
  again within a minute; it comes back at the console user's next login, or
  with `sc session keep-alive --install`. Ending another user's login takes
  `sudo launchctl bootout gui/<uid>`: a user can't end its own from SSH, and
  loginwindow's log-out event, sent from inside the session, needs an
  Automation grant nobody is there to give. What runs in a session is quit
  without saving, so a leased session is left alone unless `--force`.
- `sc session remove [--delete-account] [--force] <user>…` is `add`'s
  counterpart. It takes each user out of the pool, clears its lease and
  restarts the keep-alive so it lets the session go, then asks whether to
  delete the account too, with all its files (default no; no terminal means
  no, unless `--delete-account`). Deleting logs the user out, runs
  `sudo sysadminctl -deleteUser`, which removes the home, and removes the
  password from the keychain. Kept, the account and its password stay, so
  `session add` can take it back. A leased session is left alone unless
  `--force`.
- **Installers are kept once per Mac**, in the
  [installers store](testing.md#the-installers-store),
  `/Users/Shared/second-chance/installers`, writable by every user through an
  inherited ACL, which every user's checkout reads: so a test user's first
  run copies no installer into its home. `session add` makes it if the Mac
  has none.
- `sc session` (or `list`) shows each: logged in or not, locked, and leased or
  free. Logins come from `ioreg`'s console users, which any user can read.
- `sc session claim --purpose "<text>" [--for 2h] [<user>]` leases a free test
  session's screen to you, as `sc lease take` would, and says how to reach it;
  `--json` adds the claim as one line of JSON (`host`, `user`, `expires`), for
  scripts such as a sharded run. Claiming again renews a session you already
  hold, unless `--new` asks for another: a sharded run claims with it, so its
  release at the end never ends a session you're using for something else.
  `sc session release [<user>]` gives it back.

**Running in one** is `--on` with the test user: `sc --on <user>@<mac>:<path>
<command>`. The lease travels with `--on`, so your commands go ahead under the
claim, and anyone else's stop. Each test user has its own checkout and its own
copies of wrapps, since Wine refuses a prefix another user owns
([wrapps for every user](plans-for-consideration/wrapps-for-every-user.md)).

**Sessions share the Mac's processes and system log.** `ps` and `log show` see
every user's. So a lookup by name must be this user's alone (`ProcessList`'s are),
and a log read filters on the line's user id. A game in a test session also loads
the Mac like any other, so a console run's launches are slower while one plays.

### Signing in test sessions

**A test user signs its builds with the console user's certificate.** The
project signs with an Apple Development identity, which lives in the
developer's login keychain. Without one, sc signs ad hoc (as it does on CI),
and says so in the build's output. That builds, but an ad-hoc signature changes
with every build, so macOS forgets each build's permissions at the next.

So `sc session add` copies the console user's valid Apple Development
identities (`SigningIdentity`) into each test user's login keychain, with the
intermediate certificates their chains need: Xcode keeps Apple's WWDR
certificate in the login keychain, not the system's. It exports the
identities as one PKCS #12 file and the intermediates as certificates of
their own (`SecItemExport` won't mix a certificate found by building a chain,
which isn't a keychain item, into the file). Where the key's access list asks,
macOS shows a dialog on the Mac's screen to allow the export, which can't be
answered over SSH alone. Then it imports them over SSH as each test user
(`<user>@localhost`) and lets `codesign` use the keys without asking. It skips
a user that already has every identity, exporting nothing. A login keychain is
unlocked in the user's GUI session, where test runs build (`GUISession.ensure`
comes first), but not over plain SSH: a build there fails with
`errSecInternalComponent`, so build through `in-gui-session` there. A user that has never logged in has no
login keychain yet: run `session add` again once it has. A failure here is a
warning, and the rest of the set-up goes ahead. A renewed certificate reaches
the test users the next time `session add` runs.

### Peekaboo in test sessions

Peekaboo reads and drives Mac windows (system prompts, installers, Finder) where the
puppet helper only sees a game's window. Its Screen Recording and Accessibility grants
are per user, and no script can give them: they live in the system's TCC database
behind SIP, and even an MDM profile can't pre-approve Screen Recording. So
`sc session setup-peekaboo [<user>] [--on <host>]`, run on the Mac you're at, makes the
grants a minute each: with `--on`, for that Mac's test sessions, and without, this
Mac's. Unlike other commands it doesn't run on the other Mac (`Remote.runsHere`): it
reaches the test sessions over SSH itself, since the Screen Sharing window has to open
where you are. Here it needs this Mac's own keys in each test user's authorized keys, which
`session add` gives them (`--install-keys` for older users); and as Screen Sharing
won't connect a Mac to itself, it goes through an SSH tunnel into the test user. For
each test user (default: the pool) it:

1. installs Peekaboo on the test Mac if it's missing: the app into `/Applications`
   and the CLI into `/Users/Shared/second-chance/bin` when Homebrew's isn't there, both
   from the release `sc` pins, checked against the release's checksums;
2. starts Peekaboo's bridge in the user's session (the LaunchAgent
   `boo.peekaboo.bridge-host`), which Peekaboo's commands over SSH reach through
   `PEEKABOO_BRIDGE_SOCKET`;
3. if a grant is missing, opens its pane in System Settings there, and a Screen
   Sharing window here into that session, logged in with the user's password: read
   from the test Mac's keychain in its GUI session (by a one-off LaunchAgent writing to
   a named pipe), brought back over SSH and handed to Screen Sharing by AppleScript, so
   it's never written to a file or a command line;
4. waits for you to turn Peekaboo on (macOS asks for an admin's password, as test
   users are standard users), restarts the bridge so the grant takes, opens the next
   pane, and moves on once `peekaboo permissions` shows both.

**Watching or using a test session by hand:** `sc session view [<user>] [--on <host>]`
opens a Screen Sharing window here into that session, logged in with the password from
that Mac's keychain, handed over as `setup-peekaboo` does (never saved). Like it, it
keeps `--on` for itself. For this Mac's own test sessions it goes through an SSH tunnel,
which it keeps open until you press Return. If Screen Sharing asks, choose "Log in as
yourself".

**Picturing a whole screen:** `sc session screenshot [<user>] [--on <host>] [--out <png>]`
takes a Mac's screen (its logged-in user's, or a test user's session) with that user's
Peekaboo, shrinks it to `--max` pixels across (1600) and saves it here, so prompts,
installers and the Finder, which no game window shows, can be seen. Like
`setup-peekaboo` it keeps `--on` for itself. `screencapture` over SSH can't do this
("could not create image from display"): the process macOS checks for Screen Recording
is the one in the GUI session, Peekaboo's bridge.

## Puppet sessions

**`sc puppet` drives a program by hand,** for porting and debugging, where a
test would script it. `sc puppet start <name> --wrapp <app>` starts a server
(a LaunchAgent in this user's GUI session), which holds the screen lease,
starts the wrapp with WrappPuppeteer's in-process helper armed
([wine-in-process-helpers.md](wine-in-process-helpers.md#puppet-control)),
gets past its save warning, and stops it when asked (`stop`), when it's been
idle (`--idle`, 10 minutes) or after `--max` (2 hours). Stopping asks the game
to quit, then ends the wrapp and anything left in its Wine prefix
(`WineServer.kill`), and says when the screen was held. Each session keeps
its files in `~/Library/Caches/SecondChance/puppet/<name>/`: its logs, its
shots, and an app-support folder of its own, so the player's saves are
never touched.

The other verbs are clients, and `--on` doesn't sync for them:

- `do <name> click|move|down|up|drag|key|type|focus …` acts, then says what
  changed: the share of a 64x36 thumbnail that changed, captured before and
  after (`--wait`), whether it's now black, which windows came or went, and
  whether the program ended. So most actions need no picture.
- `shot` saves a picture, at most 1280 pixels across by default, or a part
  (`--region`, in points) at any `--scale`, and says what it costs to look at
  and how to fetch it.
- `text` reads the window's text with Apple's OCR, each line with where it
  is in points, which a `do … click` can aim at.
- `windows`, `status`, `log [--grep] [--count]` (identical lines counted, for
  a log of hundreds of the same error) and `saves` (files written since the
  start: where its saves go).

Run it in a [test session](#test-sessions), `sc --on <user>@<mac> puppet …`,
to leave the Mac's screen free.

### Wine dialogs and installers

`sc puppet start <name> --wine <wrapp> -- <program> [arguments]` runs a
Windows program, an installer most often, in Wine: the wrapp's Wine (any
Wine wrapp will do), in a clone of its prefix in the session's folder, so
the wrapp is left as it was. `--prefix <dir>` runs in a prefix of your own
(cloned from the wrapp's when it isn't there yet), and `--wine` naming a
wrapp's `Contents/SharedSupport/prefix` runs in that one in place.
`--disc <iso>` mounts a disc image read-only and shows it as D:, a CD-ROM
drive, so the program can be `'D:\Setup.exe'`. A Mac path on the disc is
named by its D: path, and any other Mac path has its folder lent as Y:
(`WineDrives.lend`). The program starts through WineKit (`start /wait` from
its own folder), after Wine's desktop is up (`WineDesktop`), with the helper
armed in every process (`PUPPET_CONTROL_EXE=*`), so whichever of the
installer's processes has the window answers `shot`, `text` and `do`. The
session lasts while any program of its own is left in the prefix, as an
installer's bootstrap often hands over to another program and exits.
Stopping it ends the prefix's Wine (`wineserver -k`, then `WineServer.kill`),
takes the drives back and detaches the disc.

Its dialogs can also be read and driven by their controls, as AutoIt sees
them. AutoIt is copied into the prefix from this checkout's build of the app
(`--autoit <dir>` for another):

- `controls <name> [--all]` lists every visible window in the prefix and
  its controls: class, text, ClassNameNN, rectangle (in the window's client
  area), state and handle, each as a ref, `c1`, `c2` and so on.
- `do <name> click c2` presses that control by its handle (`ControlClick`),
  whatever the screen shows. `do <name> type c3 "<text>"` sets a control's
  text (`ControlSetText`), and `check` or `uncheck` sets a check box. A ref
  whose window has closed, or whose handle is now another control's, is
  refused: list the controls again.
- Each of those actions prints the AutoIt lines that repeat it, which name
  the window by its title and the control by its text (or ClassNameNN), not
  by its handle. Each first waits for the control on the page that shows
  the page's own text (its shortest static text): a wizard keeps one title
  from page to page, and its Next button with it. `autoit <name>` prints the
  script so far (`--out <file>`, `--clear`). It starts the program it's
  given, as `INSTALLER.RUN --automation` gives a script the installer's
  command ([wrappfile.md](wrappfile.md#instructions)). So doing an install
  once by hand drafts its script. Check each page's text is its own, and add
  whatever tells you the install has finished.

Wine programs need the GUI session, which an SSH shell isn't in, so the
session's server runs AutoIt for these commands: they hand it the script
through files in the session's folder.

### Named screens, needles and locators

A session names what's on the screen with the same
[needles](testing.md#needles) an integration test waits for, matched as
WrappPuppeteer matches them (`Packages/PictureMatching`: a `screen` needle by
its fingerprint's distance, at most 0.08; a `region` one by the template
search's correlation; a `text` one by its strings in OCR's lines). Its
needles are the session's own, then its bundle's `tests/needles`, then those
of the module its test scenario is in: the bundle is the wrapp's (its
`WrappLock.json`), or the one `--bundle <id>` names, which the session then
remembers (an engine run by hand has none of its own). `--needles <folder>`
adds a folder looked in first.

- `screen <name>` says which tags (screens) the window matches, each with
  the needle that matched and how surely, and for the rest the nearest
  needle and how near it came.
- `name <name> <tag>` cuts a needle from the window in the bundles' format:
  a `screen` needle of the whole picture, its bars trimmed (as
  WrappPuppeteer's splash references are); with `--region x,y,w,h` (points,
  as `text` gives them) a `region` needle of that part, searched for around
  where it is now and sized to the window; with `--text`, a `text` needle of
  the lines read there. It goes in the session's `needles/` (or `--out
  <folder>`, named the tag or `--as <name>`), which `screen` reads first, and
  is checked against the frame it was cut from. Copied into the bundle's
  `tests/needles/`, with a comment saying what it shows, it becomes the
  integration test's.
- `expect <name> --screen <tag> | --text <text> [--timeout 20]` tries until
  it's true. A failure (exit 3) keeps the last shot and says the closest
  thing there: the tag's nearest needle, or the line of text most like it.
- `do <name> click --text "<text>"` and `--needle <file>` (a needle's
  `.yaml`, or a `.png` found at its own size) find what to act on at the
  moment of acting, for `click`, `move`, `down` and `up`, in place of a
  point, at the needle's click point (a line's middle for text). Text
  prefers a line that is it exactly, ignoring case, to lines holding it.
  They're strict: two matches is an error listing both (exit 5); `--nth <n>`
  picks one, reading top to bottom, and `--within x,y,w,h` narrows the
  search. Nothing found by `--find-timeout` (5 s) is exit 3, with the
  nearest line.
- When the session has needles, every `do` reply ends its line with the
  screen it's on now (`→ screen: title`, or `?`).

## Changing sc

Its code is in `Tools/sc/`:

- `Sources/SCKit/Commands/` — one file per top-level command.
- `Sources/SCKit/Support/` — the pieces they share.
- `Sources/SCKit/Support/Catalog.swift` — what the tool needs of the app's
  own game database, the `GameCatalog` package in `Packages/GameCatalog/`, so
  slugs and titles never drift from the app's.
- `Tests/SCKitTests/` — Swift Testing; `swift test --package-path Tools/sc`,
  also run by `sc test unit` and CI.

`./sc` runs `swift build` every time and lets SwiftPM's incremental build
decide what to rebuild: about 0.6 s when nothing has changed, and nothing is
printed unless it takes over 1.5 s (a spinner in a terminal, one line when
piped). There's no hash or list of its own to keep up: SwiftPM notices a file
synced from another Mac with that Mac's older time (it doesn't go by times
alone) and files added or removed, all checked when this replaced a hash of the
sources. It's a release build optimised file by file
(`-Xswiftc -no-whole-module-optimization`), not as one whole module, so a
change to one file rebuilds little: about 25 s on a loaded Mac, where a
whole-module build took about two minutes for any change.

**Several at once.** Agents and people often run `./sc` in one checkout at
once. Their builds queue on SwiftPM's own lock on `Tools/sc/.build`, and the
spinner says `Waiting for <program> (pid …) to finish with Tools/sc/.build`
while something else holds it. sc runs from a copy, `Tools/sc/.run/sc`,
replaced by a rename only when SwiftPM made a new binary, so a rebuild never
changes the file a running sc started from (or copies, as the keep-alive's
install does). A failed build prints SwiftPM's output; it isn't retried from
clean, which would wipe everyone's build state for what is usually an error in
the code. Anything in `./sc`'s own set-up that fails says so ("getting sc ready
failed") and exits non-zero, so it can't pass for the command having run. To
build or test sc yourself without holding up everyone's `./sc`, give SwiftPM a
folder of your own: `swift test --package-path Tools/sc --scratch-path
<tmp>/sc-build`. Change `./sc` itself by writing a new file and renaming it over
the old one: bash reads a script as it runs, so editing it in place breaks every
run already going.

**Show anything slow.** A step that can take more than about half a second
(an SSH round trip, a build, a wait for something to appear) runs inside
`ui.progressStep` or `ui.logStep`, so it shows a spinner saying what it's doing
and how long it has taken. A command that sits silent looks hung.

Logic lives in the `SCKit` library so tests can parse real command lines with
`SC.parseAsRoot`. Dependencies are swift-argument-parser, swift-subprocess and
Noora, pinned with `.upToNextMinor`.
