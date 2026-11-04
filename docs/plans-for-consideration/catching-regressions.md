# Catching regressions

Proposed 2026-11-05. **Not planned yet: build each part when something needs
it.** Each part below says what would prompt it. The first three are small,
and the next engine update (a new ScummVM, Wine or DOSBox version in a module)
is reason enough to build them. The tiny test programs are the largest
part and pay off over the longest time. Build them when the builder's own
features (how a Wine program's window is handled, stores, cursor lock) need
testing without a real game.

It builds on what exists today: the integration test, which builds each game
and launches it with WrappPuppeteer
([testing.md](../testing.md)); the wine module's
`routine-errors.yaml`, read by the wrapp's quit check
([wine-in-process-helpers.md](../wine-in-process-helpers.md)); module
versions and their constraints (`USE scummvm@2026.3.0`,
[modules.md](../modules.md#releases)); and `sc bundle list --where`
([program-bundles.md](../program-bundles.md)). It follows the line the
builder keeps from Second Chance (the builder may one day be a project of
its own): what an engine's log means, and test programs for the builder's
features, are the builder's and its modules'. Which games to test and how
results are shown are Second Chance's.

## Why

An engine update changes every game that uses the engine, and nothing but a
full integration run says whether one broke. That run takes hours, needs
real installers and a Mac whose screen it can take, and tells us a game
started and quit, not that it ran as before. Two things seen in November
2026 show the gap:

- ScummVM 2026.4.0 replaced 2026.3.0 in the scummvm module because it runs
  Director games 2026.3.0 couldn't. Every Director game is marked unstable
  by ScummVM, since its own testing doesn't play them: a new release can fix
  one game and break another, and only our tests would notice.
- Two Director games failed for reasons a log line named exactly
  (`ERROR: Builtin 'getAt' did not return value!`, `LINGO: syntax error,
  unexpected tEQ`), while the window showed only black or white. A launch
  test that passes on a window appearing can't tell those apart from a
  working game.

### What ScummVM does

ScummVM's own CI builds every platform and runs unit tests of its shared
code; games are tested by people playing them through before a release.
Its Director engine is the exception, with a buildbot of its own
(`director-buildbot` in `scummvm/scummvm-sites`, tests in
`scummvm/director-tests`), which these ideas borrow from:

- **Many real games, every movie, a few frames each.** A list of targets
  (real games, with every movie file in them) is run movie by movie with
  `--start-movie=<movie> --debugflags=fewframesonly,fast`: ten frames, no
  delays, no window and no input, so hundreds of movies in minutes.
- **Log lines decide the result.** A run fails on a Lingo syntax error or a
  line the engine's developers marked `BUILDBOT:` for it, whatever the exit
  code.
- **Screenshots are compared with the previous build's,** never with hand-made
  reference images. A difference is a warning (a failure in strict mode),
  linked to a viewer that shows the two side by side, frame by frame.
- **Small test movies each pin one behaviour.** Some log lines on a good
  run and check them on replay.
- **It runs only when the Director engine's code changes.**

ScummVM's macOS release has no event recorder (`--record-mode` isn't in its
`--help`), so replaying a person's input through a real game isn't on offer.
WrappPuppeteer's scenarios stay the way to script a game.

## The parts

### 1. Log lines that mean trouble

**What:** each engine module lists the lines in its engine's output that mean
something went wrong, beside the lines it already says are routine:
`Modules/scummvm/trouble.yaml` with `ERROR:`, `LINGO: syntax error`, `did not
return value`, `Unimplemented xlib` (with which Xtras matter); Wine's could
name `err:module:import_dll … not found` and the like. WrappPuppeteer
reports each one it sees in a launch, with the line, as a warning; a
bundle's `tests` can make one a failure for that game.

**Why first:** it costs a file per module and a check in the judge, and it
turns "black screen" into the line that says why. It would have named both
Director failures above at once.

**Prompt:** the next engine update, or the next port that fails with a clean
log on screen and a reason in the engine's output.

### 2. Comparing engine versions

**What:** a module keeps an older version so a bundle can pin it, and the
same lets a test run a game on both: `sc test integration <game> --module
scummvm@2026.3.0`, then on the newest, and a report of what differs: the
trouble lines (part 1), the time to the first needle, the captures (part 4).
A difference is a warning, as ScummVM treats screenshot changes.

**Prompt:** any change to a module's `versions`.

### 3. Testing only what a change affects

**What:** `sc test integration --affected [<base>]` works out the games a
change could break from the diff since `<base>` (by default the last commit
that passed): a changed module → the bundles that `USE` it or are built
`FROM` its stages (`sc bundle list --where`); a changed bundle → that game;
the template, the helpers or the builder's core → everything. It prints the
list and why each is in it, so a wider run is a choice, not a surprise.

**Prompt:** the first module change whose whole-suite run would take hours
for a handful of games, as the scummvm module's 2026.4.0 did (eight games).

### 4. Captures compared with the last passing run

**What:** WrappPuppeteer already captures the game's window for its needles.
Keep a few captures from each passing run (after each needle it waited for,
and at its end) per game, engine version and macOS, and compare a new run's
with the last passing one's. A difference beyond a threshold is a warning in
the report, with both pictures and their difference side by side. No
reference images to curate: the baseline moves with each passing run, and a
person decides whether a difference is a regression.

**Prompt:** a change that alters how games look without stopping them
(scaling, Wine's graphics, an engine's renderer), or part 2 wanting more than
logs to compare.

### 5. A windowless smoke test for ScummVM games

**What:** ScummVM runs with no window (`gfx_mode=surfacesdl` in its
settings, `SDL_VIDEODRIVER=dummy`), and the Director engine can save a
picture of every frame (`--debugflags=screenshot`) and start any movie
(`--start-movie`). A scummvm module test runs each movie of a Director game
for a few frames (`fewframesonly,fast`) with no screen, judged by part 1's
lines, as ScummVM's buildbot does. Other ScummVM engines get a shorter
version: start, run for a while, look for trouble lines. It needs the game's
files, as the integration test does, but no screen, so it can run on any Mac
beside other work.

**Prompt:** the first Director game committed as a bundle, or a scummvm
update that part 1 alone can't vouch for.

### 6. Tiny test programs as fixtures

**What:** small Windows programs of our own, each doing one thing the
builder or the helpers handle, committed with their source in
`TestFixtures/programs/` and built once (with mingw-w64), as ScummVM's test
movies pin one Director behaviour each:

- asking for fullscreen each way the native fullscreen helper looks for
  (`ChangeDisplaySettings`, DirectDraw exclusive mode, Direct3D
  `Windowed = FALSE`, a borderless window covering the screen), and one
  that stays a small window;
- saving a file beside its exe and in the Windows folder, for stores;
- a DirectDraw window that reports where its clicks land, for cursor lock;
- an installer-like program that writes files and registry keys and exits
  with a chosen code, for `RUN` and the installer module.

Each writes what it saw to a file the test reads (a window's style, the
display mode it was given, the clicks it got), so the result is a fact, not
a picture. With bundles of their own (`Bundles/test/…`), they go through the
whole build and launch with no installers, so the integration test of the
builder's features can run anywhere, CI included, in minutes.

**Prompt:** the first builder feature that can't be tested without a real
game; the builders-into-modules work has several (how a window is handled,
the `files=` store, cursor lock as a choice).

### 7. A behaviour trace for Director games

**What:** the order of the movies a Director game loads (`Loading movie
'…'`) in a scripted run is recorded on a passing run and compared on later
ones. Cheaper and steadier than pictures: a font change doesn't move it, a
broken script does.

**Prompt:** part 5, once it exists, wanting more than "no trouble lines".

## Not proposed

- **Reference images made by hand** for every game: ScummVM's buildbot
  avoids them, and so should we. The previous passing run is the baseline.
- **Replaying recorded input through games:** ScummVM's macOS build has no
  event recorder, and WrappPuppeteer's scenarios already script what a test
  needs.
