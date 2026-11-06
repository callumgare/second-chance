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
./sc setup                             # Once per clone: tools, git hooks, completions, Wrappfile highlighting
./sc worktree add <name>               # A worktree in .claude/worktrees, sharing .local and cloning caches
./sc worktree remove <name>            # Remove one (and its build output) once it's merged
./sc clean build                       # Delete every checkout's DerivedData, worktrees' and Xcode's too, leaving any in use
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
  already in `DerivedData/` instead and fails if there is nothing there. The
  app carries its own copies of `Bundles/` and `Modules/`, which a build
  reads, so it warns when the checkout's differ from them (`StaleAppData`,
  about 20 ms): an edited Wrappfile isn't used until the app is built again.
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

**Sources.** `wrapp build --from disk`, `--from steam`,
`--from her-download`, `--from big-fish` or `--from download` (a free game, downloaded from where
its bundle says: [wrapp-build.md](wrapp-build.md#the-download-source)). Without
`--from`, the game builds from the first of disk, her-download, download, steam and
big-fish its bundle has an edition for, except that a disc or Her download already
in the installers store comes first; `--disk`, `--her-download` and
`--big-fish-trial` each imply their source (`WrappSourceOptions.kind(for:repo:)`). Each source is a case of `WrappSourceKind` with its own
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

**Naming a program.** The wrapp commands take a program bundle's id,
`nancy-drew/blue-moon`, or what follows its slash, `blue-moon`, which is taken
as the one bundle whose id ends `/blue-moon` (`Games.resolve`). When several
do, a terminal is asked which; without one, the command fails naming each.

**Interactive only.** Prompts (pick a game when none is named or several match, pick what to
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

`--shard-on <host>[:<path>][,…]` runs the integration suite in claimed
[test sessions](#test-sessions) on those Macs instead, a shard per four of each
Mac's performance cores (`--shards-per-mac` to choose); `--shard <user>[@<host>],…`
names the test sessions instead. Either gathers one table naming each row's
session
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

## Worktrees

`sc worktree add <name>` makes a worktree in `.claude/worktrees/<name>`, where
Claude Code makes its own, and prepares it. Every other way of making one is
prepared too: `sc setup` installs a `post-checkout` hook, which git runs for a
new worktree with a null old HEAD, and it runs the main checkout's
`sc worktree prepare`. The hook never fails, as a failing hook would fail the
`git worktree add`; it says to run `./sc worktree prepare` in the worktree
instead. `prepare` does only what a worktree lacks, so it's safe to run again,
on a worktree made before the hook or after a clean.

- **Ignored files it needs are links to the main checkout's**: `.local` and
  `.env` (`Worktrees.linked`). (`.claude`'s porting skill and agents are in
  the repo, so a worktree has them from git.) One copy,
  so nothing drifts, and a note written in a worktree is in every other. An
  empty folder left where one goes is replaced; one with files is left as the
  worktree's own.
- **Caches start as APFS clones of the main checkout's**, which take no space
  until one side changes a file, and then only that file. Only what doesn't
  depend on where the checkout is: `DerivedData/SourcePackages` (the packages
  Xcode fetched, Sentry's frameworks among them), `DerivedData/ModuleCache.noindex`
  (most of its modules are keyed by a hash that doesn't name the checkout,
  and clang checks each against its inputs before using it), and each
  SwiftPM package's fetched dependencies in its `.build` (`checkouts`,
  `repositories`, `artifacts`, `workspace-state.json`). The package state
  records the checkout's absolute path, as do the checkouts' git remotes, so
  those are rewritten to the worktree's; left as they were, the worktree
  would fetch through the main checkout's and break once that was cleaned.
  What a build compiles (`DerivedData/Build`, a package's `.build/<arch>`) isn't
  cloned: it records the path throughout, so it's rebuilt anyway, and a clone
  would only keep old blocks alive. `du` counts clones in full; `df` shows
  what they cost, and so does `sc clean` (next paragraph). A worktree on another volume gets no clones, and its first
  build fetches as usual.
- **SourceKit-LSP's background indexing is off in each of its packages**,
  through `.sourcekit-lsp/config.json` (ignored), which otherwise fills each
  package's `.build/index-build` with gigabytes. It has to be the package's own
  file: SourceKit-LSP indexes unless the workspace says not to, a workspace's
  file outranks what the editor asks for (the Swift extension's `auto` asks for
  indexing), and one at the checkout's root doesn't reach the packages below.
  `prepare` also adds `.sourcekit-lsp/` to the repo's `info/exclude`, so a
  worktree of a commit from before `.gitignore` had it isn't counted as
  changed.

`sc worktree list` shows each worktree with whether its HEAD is in `main` and
whether it has changes. `sc worktree remove <name>` refuses while either would
be lost, unless `--force`; it removes the links first, so nothing of the main
checkout's is in reach, then the worktree with all its build output.
`--delete-branch` deletes its branch too.

`sc clean build` deletes the DerivedData of the main checkout and of every
worktree, wherever it was run from, and the folders Xcode's own window built
them into. Those are in `~/Library/Developer/Xcode/DerivedData`, Xcode's
default (a per-user setting, so the repo can't change it), one per checkout
opened, and Xcode never removes one with its checkout. A folder there is this
repo's when its `info.plist` names a workspace in a checkout (a removed
worktree's too, while it was under the main checkout), or, with no
`info.plist`, when it's named after one of the repo's Xcode projects
(`XcodeDerivedData`); Xcode's shared caches and other projects' are left
alone. A folder that a running process names on its command line is left
alone with a warning: an xcodebuild given it as `-derivedDataPath` (and the
compilers it starts), the app `sc app run` launched from it, a GUI-session
job's script in its `sc-jobs`. The
sizes `sc clean` shows, for every target, are what deleting would free, not
what `du` says: it reads each file's APFS private size and clone family
(`DiskUsage`), so a clone counts only once its whole family goes, and not at
all while a file outside what's deleted still holds its blocks.

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

**`--on <host>[:<path>]` runs a command on another Mac** (or as another user,
`<user>@<host>`). Everything is built here; the other side only runs it.
A command that would build the app first builds it here (a test build for
`sc test`) and runs there with `--skip-app-build`. Then sc sends a [runtime
copy](#runtime-copies) to `<path>` and runs `./sc` there with the same
arguments over `ssh` (`-t` when interactive). Output stays there: a test run's
results and report are in that copy's `test-results/`, and the terminal shows
the summary table. `<path>` defaults to this repo's path relative to your home
directory. A `~/` in it is that Mac's home, expanded there, so quote it
(`--on 'user@host:~/tmp/second-chance'`): zsh expands `~` after a `:` in a
variable assignment (`P=user@host:~/…`), handing sc this Mac's home instead.
Commands that work on the sources (`lint`, `generate`, `release`,
`worktree`, `module`, `bundle`, `app build`, `test unit`) aren't sent: run
them here. A command that may read installers (one that builds, runs or tests
games from a disc or a Her download) also sends this Mac's [installers
store](testing.md#the-installers-store) to the other Mac's, below. On the
remote Mac, the GUI-session re-run applies as usual.

### Runtime copies

What `--on` sends is a runtime copy, not the checkout: nothing compiles on
the other side, so the sc and app there are exactly what was built and
tested here, and a test user needs no toolchain set up, no sources, and none
of this checkout's gigabytes. It holds:

- **sc itself:** this sc's binary as `.sc/sc`, and a `./sc` that runs it
  without building (`RuntimeCopy.launcher`), with the marker `.sc-runtime`
  that says what the folder is (`Repo.isRuntimeCopy`).
- **The build:** `DerivedData/Build/Products/Debug` (Second Chance with its
  template, WrappPuppeteer, the in-process helpers, AutoIt, the test bundle)
  and the test build's `.xctestrun` file. The rest of `DerivedData` records
  this checkout's absolute path and holds Xcode's sparse caches, and
  `Release`'s products are gigabytes nothing there runs.
- **The data sc reads there:** `Bundles/` and `Modules/` (manifests, needles),
  as the app carries them inside itself, and `TestFixtures/`, which the
  integration tests read from the repo.
- **For `puppet` commands, the audio tap** (`SC Audio Tap.app`, below), built
  and signed here, as `.sc/SC Audio Tap.app` with its stamp: `puppet audio`
  there installs it into the user's own folder when its stamp differs,
  rather than build it.
- **Only the paths under `.local` the command names**, such as a porting
  workspace's installer in `puppet start --wine <wrapp> --
  .local/porting/<program>/inputs/setup.exe` (`Remote.localPaths`), each to
  the same place there and nothing deleted around it. From a worktree, its
  `.local` link is resolved; links inside are sent as links, never followed
  (a Wine prefix's `z:` is `/`).

**To another user on this Mac** (`<user>@localhost`, or this Mac's own name)
the copy is cloned rather than sent: that user runs a script over ssh that
clones it from this checkout with `ditto --clone` (`RuntimeCopy.cloneScript`),
which takes seconds and next to no disk, as APFS shares the blocks until
either side changes them. Test users can read the checkout, being in
`staff`, and what they clone is theirs. `Bundles`, `Modules` and the Debug
products are cloned beside the old and swapped in, so nothing stale is left;
sc's own files are cloned over the old; the named `.local` paths are merged
in, nothing there deleted. The installers store is the same one, so it isn't
sent.

`.env` stays behind, as it holds each Mac's own settings, such as whether
tests hide their windows there ([testing.md](testing.md)). rsync neither sends
nor deletes what's left out, so the copy keeps its own `built-apps/`,
`test-results/`, logs and jobs, and the files of a full checkout synced there
before runtime copies stay until removed by hand (they're stale, and the
marker makes it a runtime copy all the same). In a runtime copy sc refuses
to build (`Xcode`), uses the build it has whether or not `--skip-app-build`
was given, and runs tests with `xcodebuild test-without-building -xctestrun`,
which needs no project.

- **The sync is macOS's own rsync at both ends** (`/usr/bin/rsync -aE
  --rsync-path=/usr/bin/rsync`), so a remote Mac needs nothing installed.
  It has to keep extended attributes: the template's non-Mach-O files keep
  their code signatures in them, and without them every wrapp built there
  fails to sign. Apple's rsync spells that `-E` and rejects `-X`; Homebrew's
  rsync 3.x reads `-E` as `--executability` and would drop them silently,
  which is why the remote end is named rather than left to its `PATH`.
- **A sync that stops partway runs nothing there**, and sc says so: most
  often files here changed while being copied (a build here). Run it again
  once that's done.
- **If the connection drops,** sc says so: ssh's exit 255. Pick the run up
  with `sc --on <host>[:<path>] attach`, which doesn't sync.
- **While a run is still going there, `--on` doesn't sync over it**: rsync
  would replace the build and the sc it is using. A command that needs the
  build runs in a [snapshot](#snapshots) beside it instead.
- **A command that needs no build (`session`, `lease`, `clean`,
  `installers`, `setup`) runs beside one.** One ssh before any sync reads
  the size and time of the copy's `.sc/sc` (`Remote.probeCommand`); when
  they are this sc's (`RuntimeCopy.stamp`, the time `stage` keeps), nothing
  is sent at all. When they differ and a run is going, this sc alone goes
  to `.sc/versions/<size>-<time>/sc` and runs from there with
  `SC_REPO_ROOT` set to the copy, so it sees the copy's jobs and logs as
  `./sc` would (`Remote.syncPlan`). Those binaries stay until the next full
  sync, which happens only once nothing runs there, as a command one runs
  may re-run it in the GUI session.
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

### Snapshots

A command that needs the build, sent with `--on` while a run is still
going in that copy, runs in a snapshot of the copy rather than waiting
(`RuntimeSnapshot`, `Remote.SyncPlan.snapshot`):

1. The copy's build, data and sc (`RuntimeSnapshot.clonedItems`: the
   marker, `sc`, `.sc/sc`, the audio tap, `Bundles`, `Modules`,
   `DerivedData/Build`) are cloned into `.sc/snapshots/<id>/` with
   `ditto --clone`. Being APFS clones, that takes about a second for a
   full Debug build and next to no disk.
2. What runs keep, or later commands read, is linked back to the copy's own
   (`linkedItems`: `.local`, `built-apps`, `test-results`,
   `DerivedData/sc-jobs`, `DerivedData/sc-logs`, and `.env` when there is
   one). So `sc --on <host>:<path> attach` finds a run started in a
   snapshot, and a wrapp built there is in the copy's `built-apps/` for the
   next `wrapp run`.
3. The snapshot is synced into as the copy would be, so only what changed
   is sent, then each file's time and size is noted
   (`.sc/snapshot-manifest`), and the command runs there.

Every full sync, into the copy or a new snapshot, first removes the
snapshots nothing runs from: a process of that user whose command line
names the snapshot (its sc does, being run by its full path) keeps it, as
does `.sc/snapshot-pending`, which is there until the snapshot's sc starts
(`RuntimeSnapshot.markStarted`), or for an hour if it never does.

**A run that leaves changes in its snapshot says so as it ends.** Once the
command returns, `--on` compares the snapshot with its manifest (one ssh,
under a second: a snapshot holds about ten thousand files) and warns,
listing up to twenty of the files that differ; the command's exit status is
its own. A run followed again with `attach` is checked when it finishes, as
each GUI-session job records the root it runs in (`root` in its job
folder). A connection that drops with nobody attaching again, or a process
the command left running that writes later, is caught by the next sync
instead.

**A snapshot with changes of its own stops the sync.** Nothing a run makes
should land in one, outside the linked folders, so a snapshot whose files
differ from its manifest is kept, and the sync fails naming the files that
differ. Save what is worth keeping, remove the snapshot by hand (the error
says how), then find what wrote there and make it write somewhere linked,
or add that place to `linkedItems`. The first such find: the Debug apps
are built with code coverage on, and one started without
`LLVM_PROFILE_FILE` writes `default.profraw` where it runs, so sc sets it to
`/dev/null` for everything it starts (`xcodebuild test` sets its own).

## The screen lease

**One run at a time has a screen.** Each logged-in user has a screen of
their own, so a Mac with test sessions has several, each with its own lease
(more below). Every command that opens windows
(`app run`, `wrapp build`, `wrapp run`, `wrapp wine`, `screenshot` and
`test integration`) leases the screen before it does, in the process that
opens them: here, or the GUI-session re-run. A second such command for that
screen, from any checkout, stops at once with exit 75. It doesn't wait, because an
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

With those it reads two more from Claude Code's own files (`AgentSessionInfo`),
so a lease names the session as people and agents know it: its name among its
peers (`second-chance-23`, from `~/.claude/sessions/<pid>.json`) and the title
a person sees it under (from the session's transcript, the title they gave it
before the one Claude Code made up). `CLAUDE_CONFIG_DIR` moves both. They're
recorded when the lease is taken, and looked up again whenever it's shown, so a
session renamed during a long run shows its new title. Only the session's own
Mac has its files, so every `--on` command sends that Mac's running sessions'
names and titles along in `SC_AGENT_SESSIONS` (base64 JSON, beside
`SC_LEASE_HOLDER`), for `session list`, `lease` and a blocked command's message
to name the session as it is now. That takes a few milliseconds, as only the end
of each transcript is read, where Claude Code keeps writing the title again.
Where neither source knows the session (shown on a test Mac without `--on`, or
after the session ended), the recorded ones stand.

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
A test session's screen is named `<user>@<mac>` in messages, as `--on` reaches it. A live lease in
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
- **It isn't activity.** It sends no input, and a game's posted events aren't
  the person's, so macOS counts a test session as idle whatever runs there.
  Left at its default, the screen saver starts after 20 minutes and locks the
  session, and a launch that lands before the keep-alive unlocks it fails
  with "the screen is locked". `sc session setup --task screensaver` turns
  each test user's screen saver off (below).
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
  and adds them to the pool. On a Mac that has test users already (the pool's,
  or accounts named as test users outside it), a bare `session add` lists them
  and asks before adding another (no terminal is a failure; `--count` adds
  without asking). Told no, it does nothing, `session setup` included. A new
  user gets the lowest UID that no account has and no process runs as: a
  deleted account's processes can outlive it until a restart, and a new user
  given its UID (as macOS would) shares a UID with them, which then reach
  into the new home, making its login keychain with the old password. Naming an existing user puts it right instead: one whose password
  is in the keychain is adopted, and a step already done is skipped, so only
  what's missing is fixed. A step needing `sudo` with no terminal fails at once rather
  than wait for a password. A new user's Setup Assistant is marked done
  before its first login: left to run, it holds the session where no sc job
  can start (an Aqua LaunchAgent never runs) while `sc session` still says
  "logged in". A re-run frees a user stuck there, logging it out for the
  keep-alive to log in again (name the user to re-run it on one). Then it makes the Mac's installers store (below) and
  installs the keep-alive if it isn't running. It records the users it made or
  checked, and last, unless `--no-setup`, the `sc` you ran reads them back and
  sets them up by name (`session setup <user>…`, with `--on` if `add` ran
  there: below), saying so first, as it's a command of its own after `add`'s
  success. That gives each the console user's
  [signing certificate](#signing-in-test-sessions): over SSH macOS can't ask to
  allow exporting the key, so it exports it in the GUI session instead, where
  macOS asks on that Mac's screen (reach it over Screen Sharing; Always Allow
  stops it asking again).
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
  scripts such as a sharded run. Without a user it takes a free one, never
  one you hold already: renew yours by naming it (`sc session claim <user>`).
  A holder is told apart by its Claude Code session, which an agent's
  subagents share, so a bare claim that renewed would let one agent take
  over another's session and its release end it; a sharded run's release
  likewise never ends a session you're using for something else.
  `sc session release [<user>]` gives it back.

**Running in one** is `--on` with the test user: `sc --on <user>@<mac>:<path>
<command>`. The lease travels with `--on`, so your commands go ahead under the
claim, and anyone else's stop. Each test user has its own [runtime
copy](#runtime-copies), built here, and its own copies of wrapps, since Wine
refuses a prefix another user owns
([wrapps for every user](plans-for-consideration/wrapps-for-every-user.md)).

**Sessions share the Mac's processes and system log.** `ps` and `log show` see
every user's. So a lookup by name must be this user's alone (`ProcessList`'s are),
and a log read filters on the line's user id. A game in a test session also loads
the Mac like any other, so a console run's launches are slower while one plays.

**A program can't move a test session's pointer.** It stays where Screen
Sharing's viewer last put it, (10,10) under the keep-alive, and a warp
(`CGWarpMouseCursorPosition`) puts it back there whatever it asked for. A Wine
game, and ScummVM 2026.4 after a warp, read the real pointer, so
WrappPuppeteer's clicks landed in its corner until the [virtual
pointer](wine-in-process-helpers.md#virtual-pointer) gave the game one that
moves; check a session's pointer with a few lines of Swift
through `sc in-gui-session` (`CGEvent(source: nil)?.location`, a warp, and
again).

### Signing in test sessions

**A test user signs its builds with the console user's certificate.** The
project signs with an Apple Development identity, which lives in the
developer's login keychain. Without one, sc signs ad hoc (as it does on CI),
and says so in the build's output. That builds, but an ad-hoc signature changes
with every build, so macOS forgets each build's permissions at the next.

So `sc session setup` (which `session add` runs last) copies the console
user's valid Apple Development identities (`SigningIdentity`) into each test user's login keychain, with the
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
login keychain yet: run `session setup` again once it has. A failure here is a
warning, and the rest of the set-up goes ahead. A renewed certificate reaches
the test users the next time `session setup` runs.

### Peekaboo in test sessions

Peekaboo reads and drives Mac windows (system prompts, installers, Finder) where the
puppet helper only sees a game's window. Its Screen Recording and Accessibility grants
are per user, and no script can give them: they live in the system's TCC database
behind SIP, and even an MDM profile can't pre-approve Screen Recording. So
`sc session setup [<user>…] [--task screensaver|signing|peekaboo|audio]… [--on <host>]`, run
on the Mac you're at, does every set-up task a test session needs, or those each `--task` names, each
skipping what's done. A user named who isn't logged in yet is waited for first, up
to five minutes, as the keep-alive logs a new one in; one who isn't in that Mac's pool
fails at once, naming the pool (a test user of another Mac wants `--on`). `screensaver` sets each test user's screen saver to never
start (`defaults -currentHost write com.apple.screensaver idleTime -int 0`, as
that user over SSH), which takes effect in the running session; `signing` gives each test user the console user's signing
certificate (above), done on the test Mac, where that certificate is (it asks to unlock the
keychain there, locked over SSH, which holds the test users' passwords too), only when one of
them hasn't got it; neither shows anything in the session, so both go ahead in one someone
else has leased; `peekaboo` makes the
grants a minute each: with `--on`, for that Mac's test sessions, and without, this
Mac's. Unlike other commands it doesn't run on the other Mac (`Remote.runsHere`): it
reaches the test sessions over SSH itself, since the Screen Sharing window has to open
where you are. Here it needs this Mac's own keys in each test user's authorized keys, which
`session add` gives them (`--install-keys` for older users); and as Screen Sharing
won't connect a Mac to itself, it goes through an SSH tunnel into the test user. As
`peekaboo` and `audio` open Screen Sharing into a session and put prompts on its screen,
with either, a session someone else has leased (a run going there) is left alone unless you say
otherwise, asked once, here: at a terminal it asks first, defaulting to no, and from a script it stops
unless given `--ignore-screen-lease`. For each test user (default: the pool) it:

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

`audio` does the same for SC Audio Tap, which `sc puppet audio` listens through
([puppet sessions](#puppet-sessions)), and its one permission, "System Audio
Recording Only" (`AudioTapSetup`). It builds and signs the tap here, as
`puppet start --on` does for a runtime copy, copies it with its stamp into each
test user's `~/Library/Application Support/SecondChance/sc-audio-tap` (unless the
same build is there), so `puppet audio` keeps it and the permission given to it, and
asks the tap whether it has the permission, in the user's GUI session, since TCC
goes by the process responsible for the asker and over SSH that would be SSH's. If
not, it opens Screen Sharing here and has the tap ask, which puts macOS's prompt on
that session's screen: Allow gives it. Otherwise it opens Screen & System Audio
Recording there, where you turn the tap on under "System Audio Recording Only"
(with an admin's password), and waits up to 15 minutes. If macOS records a no
meanwhile (the prompt answered Don't Allow, or closed, which bringing System Settings to
the front does), it won't ask again, and the permission is per account, so a switch
turned on in another session's window doesn't count: setup warns once, with the fix
(that session's switch, or `tccutil reset AudioCapture` as the user and setup again), and
waits on. Signed with your Apple
Development identity, which `signing` gives the test users, the permission
outlasts rebuilds; signed ad hoc, it says so, as a rebuild loses it.

**Watching or using a test session by hand:** `sc session view [<user>] [--on <host>]`
opens a Screen Sharing window here into that session, logged in with the password from
that Mac's keychain, handed over as `session setup` does (never saved). Like it, it
keeps `--on` for itself. For this Mac's own test sessions it goes through an SSH tunnel,
which it keeps open until you press Return. If Screen Sharing asks, choose "Log in as
yourself". A session someone else has leased opens all the same, with a warning naming
who has it and for what: watching disturbs nothing, but what you do there could.

**Picturing a whole screen:** `sc session screenshot [<user>] [--on <host>] [--out <png>]`
takes a Mac's screen (its logged-in user's, or a test user's session) with that user's
Peekaboo, shrinks it to `--max` pixels across (1600) and saves it here, so prompts,
installers and the Finder, which no game window shows, can be seen. Like
`session setup` it keeps `--on` for itself. `screencapture` over SSH can't do this
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
never touched. The `SECOND_CHANCE_*` debug switches `start` is run with
(`SECOND_CHANCE_WINEDEBUG=+cursor,+event`, …) go into the server's LaunchAgent
and so reach the wrapp; launchd would otherwise start the server with none of
them. Over `--on` they don't travel, as ssh passes no environment: set them in
a shell on that Mac.

The other verbs are clients, and `--on` doesn't sync for them:

- `do <name> click|move|down|up|drag|scroll|key|type|focus …` acts, then says what
  changed: the share of a 128x72 thumbnail (from a capture at a quarter of a
  point a pixel) that changed, captured before and after (`--wait`), and the
  box it changed in, in window points, so a menu's highlight moving shows as
  `changed <1% at 312,240 180x24` rather than nothing; whether it's now
  black, which windows came or went, and whether the program ended. So most
  actions need no picture. `scroll <x> <y> up|down|left|right [<lines>]` turns
  the wheel there, 3 lines unless told. `--then "<action>"`, repeated,
  does more actions after it, each replied to in turn, and stops at one that
  fails or ends the program: a turn saved where no judgement is needed between
  steps (`do lure key escape --then "key return"`). `--json` replies with
  every step as JSON (`steps`, and `error` if one failed), for scripts;
  `status`, `windows` and `shot` take `--json` too.
- `shot` saves a picture, at most 1280 pixels across by default, or a part
  (`--region`, in points) at any `--scale`, and says what it costs to look at
  and how to fetch it.
- `text` reads the window's text with Apple's OCR, each line with where it
  is in points, which a `do … click` can aim at.
- `windows`, `status`, `log [--grep] [--count]` (identical lines counted, for
  a log of hundreds of the same error) and `saves` (files written since the
  start: where its saves go).

Beyond a single picture:

- `record [--seconds 10] [--width 960]` films the game window into a
  QuickTime movie in the session's `recordings/`, from the helper's own
  captures (no Screen Recording), two in flight at once: about 60 frames a
  second, each timed as taken. Every `do` is noted in the session's
  `actions.jsonl`, and a `do` sent while a recording runs becomes a chapter
  of it, so run `record` in the background and act meanwhile. It's for a
  person to watch, or for `sheet`.
- `sheet [--since 14:05|90s] [--threshold 5] [--max 16]` sums a stretch of
  recorded play up in one picture: a grid of the frames that changed by more
  than `--threshold` % of the change thumbnail, spread evenly when more than
  `--max` did, each with its time and the actions just before it. Like
  `shot`, it says what the picture costs to look at (16 tiles at the default
  320 pixels: about 1,500 tokens) and how to fetch it.
- `audio [--seconds 5] [--raw]` says how loud the program is: peak and RMS
  every 0.1 s, a row a second (`--raw`: every window), and one line: silent
  (every window under -60 dBFS), sound, or clipping (samples at full scale).
  It measures the samples from a Core Audio process tap on the session's
  processes (macOS 14.2), because SDL and Wine keep their output open
  playing silence, so "output running" says nothing. A tap needs macOS's
  system-audio permission, which goes to apps, not command-line tools, so
  the tap is a small app of its own: `SC Audio Tap`
  (`Tools/sc/AudioTap/main.swift`), which `sc` builds with `swiftc` into
  `~/Library/Application Support/SecondChance/sc-audio-tap/` on first use
  (in a [runtime copy](#runtime-copies), which has no source, it installs
  the one the copy brought)
  and starts as its own responsible process. It's signed with the user's
  Apple Development identity when there is one (test users get it from
  `session setup`), so the permission outlasts a rebuild; signed ad hoc, a
  rebuild (a change to its source) loses it. Denied, a tap hands over
  silence rather than an error, so it checks first (TCC's private
  preflight) and `audio` exits 6 until the permission is given: logged in
  as that user, answer its prompt with Allow, or in System Settings ›
  Privacy & Security › Screen & System Audio Recording, under "System Audio
  Recording Only", turn SC Audio Tap on (+ adds it from that folder). For a
  test session, `sc session setup --task audio <user> --on <host>` does it
  with you ([below](#peekaboo-in-test-sessions)).

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
  where it is now (its own size again on each side, but no more than a tenth
  of the window) and sized to the window, with a warning when it would be
  slow to look for (as `sc bundle check` gives, [testing.md](testing.md#needles))
  and when that part is
  nearly one colour (its brightness's spread under 6 of 255), as a flat patch
  matches any patch like it; with `--text`, a `text` needle of
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
