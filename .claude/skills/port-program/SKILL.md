---
name: port-program
description: Make a program that doesn't run on a modern Mac (a Windows, DOS or classic Mac OS program; an installer, a disc or disc image, a download or just a name) run as a Second Chance wrapp, by writing a Wrappfile that builds it and then a program bundle around it. Use when asked to port, wrap, package or "get X running" for an old program or game, to write a Wrappfile or bundle for a new program, to work out what an unknown installer or disc is and what would run it, or to judge which engine (Wine, DOSBox, ScummVM, an emulator) a program needs.
---

# Porting a program to a wrapp

You're turning a program that won't run on this Mac into a Second Chance
**wrapp**: an `.app` holding the program and the engine that runs it. You do
it in two halves:

1. **A Wrappfile that runs it.** Built and iterated with `wrapp-builder`,
   the builder's own command-line tool. It knows nothing of Second Chance:
   just a Wrappfile, a target stage and inputs. Most of the work, and all
   the guesswork, is here.
2. **A program bundle around it.** Once the Wrappfile works, wrap it in
   `Bundles/<namespace>/<name>/`: a `manifest.yaml` with the editions it
   came as and where each comes from, the volumes its saves live in, its
   test, then `sc bundle check`, `sc generate`, a real build and an
   integration test.

This skill is the procedure. The facts live elsewhere, and this file points
at them rather than repeating them:

| For | Read |
| --- | --- |
| Wrappfile syntax and instructions (**the authority**; if this skill's examples differ, the doc wins) | `docs/wrappfile.md` |
| Manifests, editions, download editions, detection | `docs/program-bundles.md` |
| Modules, engines and how they're prepared | `docs/modules.md` |
| What a Wine game needs at launch (graphics, cursor lock, display modes, quit watch) | `docs/wine-in-process-helpers.md`, `docs/wrapp-launch.md` |
| Needles and scenarios for the integration test | `docs/testing.md` (#needles, #scenarios) |
| Identifying files: tools and tells | [reference/identifying-files.md](reference/identifying-files.md) |
| Where others have already worked out how to run it | [reference/knowledge-sources.md](reference/knowledge-sources.md) |
| Which engine for which platform; emulators | [reference/engines.md](reference/engines.md) |
| Wrappfile shapes for common cases | [reference/cookbook.md](reference/cookbook.md) |
| Symptom → cause → fix | [reference/troubleshooting.md](reference/troubleshooting.md) |
| Porting logs from earlier ports (what was tried) | `.local/porting/*/log.md` |

## The builder stands on its own

The Wrappfile builder (`Packages/WrappBuilder`, the modules in `Modules/`,
`wrapp-builder`) is being built to work without Second Chance, as it's
likely to be split off into a project of its own one day. Keep that line
where you put things, in bundles and in any change a port leads you to:

- **The builder's** (the Wrappfile, the core's instructions, a module's
  instructions, functions, stages, launch options, executors and runtime
  helpers): anything about authoring, building or running *a* wrapp that
  any program could need. How a program is installed, what a Wine prefix
  needs, whether a program starts fullscreen or in a window, which
  in-process helper a game needs, a build tool like `cabextract`. A
  program's needs are said in its Wrappfile, through what the modules
  offer.
- **Second Chance's** (its manifest fields, `sc`, the app, the catalogue,
  WrappPuppeteer's game scenarios): its library of program bundles and
  its interface. Editions and where they come from, detection, licences
  shown to people, `display-name`s, failure reports.

So when a port needs something new, ask where it belongs before writing
it: a fact about the program goes in its Wrappfile; a capability any
program might need goes in the builder or a module (and its docs); only
what's about Second Chance's library or interface goes in Second Chance.
A manifest `notes` entry or a test parameter is never the place for
something the build or launch must act on.

## Keep going until it's done

A port asked for is a port to finish. **It's finished when it reaches rung 5**
(step 7), **or when every route (step 4) has been tried and each is stuck**
for a reason the log records (step 6 says what "stuck" takes). Reaching a
rung, finishing an attempt, committing a bundle or having a plan for what's
next isn't a stopping point: do the next thing.

**Ending your turn is asking the user.** A reply that ends with options, a
recommendation or "next I'd…" stops the port until they answer, just as a
question would, only less clearly. So:

- **If you can decide, decide.** Take what you'd recommend, write it in the
  log's "Decisions" (what, why, what else was possible) and carry on. The
  user can overrule it from the log.
- **If only the user can decide** (the list below), ask with
  `AskUserQuestion`, never a question in prose, so it's plain you're
  waiting.

**Is the user around?** Only if their latest message asked you something,
asked you to check back, or was sent moments ago with the port. "Port X"
and nothing more means they've left you to it.

**Yours to do without asking**, as part of a port:

- **Committing** a change that passes its tests (`sc test unit`, `sc lint`,
  and the integration test of anything it affects) and has no other known
  problem, as `.local/AGENTS.md` allows. **Never push, tag or release.**
- **Granting a permission in a test account, or on the test Mac's
  console account**: Accessibility, Screen Recording, Automation, to a tool
  the port needs (grants are per user). Record what was granted to what in
  the log and in `.local/AGENTS.md`. Permissions in the user's own account on
  their Mac are the user's.
- **Third-party software that's reasonably part of porting**: a tool,
  unpacker, codec, runtime, fan patch or another engine build that the
  program or the research calls for (beyond the standing permission on
  engines, below). Get it from its makers or the project's own release page,
  record the URL and sha256, check a signature where there is one, and run
  it as an untrusted input: in its own folder in the workspace, in a test
  account, with a scratch `HOME`, never installed system-wide. Remove it
  when it's done.
- **Changing what other programs get** (a module's settings or stages, the
  wrapp's template, a runtime helper) when the change is minor, or when
  tests show it harms nothing: the unit tests, plus the integration tests of
  the shipped programs it reaches (in a test account). Anything bigger, prototype in
  the workspace, test the port with it, and propose it in the report.

**Ask the user** (with `AskUserQuestion`) only for:

- **Spending money**, buying, or signing up for an account or service.
- **Anything outward-facing**: pushing, tagging, releasing, or posting
  anywhere public (a bug report, a forum). Draft it in the workspace instead
  and say so in the report.
- **A blocker that would badly hamstring the port**: something you can't get
  past yourself that makes the work far slower or impossible, such as a
  permission in the user's own account that a key step needs, no test
  account or test Mac to run on, an
  input that's missing or damaged. Ask as soon as you hit it if the user's
  around. If not, carry on with whatever doesn't need it, then ask once
  nothing worthwhile is left that doesn't.

Anything else you'd like the user's view on goes in the log's "Waiting on
the user", with what you did meanwhile, and you keep going.

**Waiting isn't stopping.** When a Mac's screen is busy, or a long build or
test is running, do the screen-free work, then wait with `Monitor` (an
until-loop on the `ps` check below) or `ScheduleWakeup` for longer waits,
and go on when it's free. Ask the peer holding the screen for a gap if
yours is short.

**A long session isn't a reason to stop.** Context is summarised as it
fills, and the porting log is your memory: keep it current and carry on.

## Ground rules

- **Inputs are untrusted.** Put each download or extracted archive in its
  own empty folder under the porting workspace, never run a script from
  inside one, run Python with `-I`, and only run Windows programs inside
  Wine, never on the Mac directly. Record every input's sha256.
- **Where screen-taking and heavy work runs** is AGENTS.md's "Where to run
  what takes the screen" (the order, the lease, agreeing a screen with other
  agents, keeping it clean, leaving nothing running), with this setup's Macs
  in that order in `.local/AGENTS.md`. Most of a port runs in a **test
  account**: claim one and keep it for the port (`sc session claim --for
  4h`, renewed by claiming again). Only the user's own screen needs asking
  about; when nobody's there to ask, never use it.
  [reference/test-mac-screen.md](reference/test-mac-screen.md) has how to
  clear prompts and notifications from a screen you hold.
- **ScummVM can run with no window** (`gfx_mode=surfacesdl`,
  `SDL_VIDEODRIVER=dummy`, and for Director `--debugflags=screenshot` for a
  PNG per frame: reference/troubleshooting.md, ScummVM): no screen needed at
  all, so do that first and run with a window only for what needs input.
- **Starting an engine by hand** (ScummVM, an emulator, a bare Wine)
  needs a GUI session: `sc puppet` runs it under a puppet session
  (`docs/dev-cli.md`), or `scripts/gui-run <user>@<host> start <name>
  '<command>'`, then `gui-run … log <name>` and `gui-run … stop <name>`.
  Copy inputs there with `rsync` to `~/tmp/porting/<name>/` in that
  account. `stop` ends the job's whole process tree and says if anything
  survived; never trust a stop you haven't checked.
- **Bound every wait on a program you don't know yet.** A program being
  ported hangs in ways nobody has seen: on exit (Icy Tower's did), on a
  dialog nobody can see, in `hdiutil` (which once wedged a test Mac's disk
  service until its helper was killed). A command that blocks on one costs
  the whole of its tool call, or the program's own limit (WrappPuppeteer
  waits 300 s for an exit, an install up to 30 min), and teaches nothing
  meanwhile. So:
  - **Wait on the signal, with a deadline.** Wait for what the step stands
    in for (the window, the exit, a log line), never a fixed sleep, but give
    the wait a bound of a few times what the step should take. Make it
    generous, and longer on a loaded Mac: Wine slows sharply once every core
    is busy, and a tight bound there reports a hang that's only slowness.
  - **Use the tools' own bounds first:** `sc puppet wait … --timeout`, `do …
    --wait`, a background run (`run_in_background`) with a Monitor that
    reports the outcome or the deadline. Where only a shell will do, macOS
    has no `timeout`: `perl -e 'alarm 60; exec @ARGV' <command>`.
  - **Start and wait separately.** Launch, quit or install in one step and
    wait for its outcome in another, so a hang says which part hung.
  - **A hang is a finding.** When the deadline passes, look before you kill:
    a shot of the window, the log, `sample <pid>` or a diagnostics bundle
    for a Wine game. Then stop it and clean up as
    [reference/troubleshooting.md](reference/troubleshooting.md#a-hang-cleaning-up-after-it)
    says, and note it in the log.
  - **When sc's own limit is longer than you need**, say so in "Lessons for
    the skill" with the step and the bound you'd have wanted: a port wants to
    know at 30 s what an integration run waits 300 s for (the exit wait).
    The fix is an explicit, shorter option on that sc command for porting
    runs, made as any change to sc ([Keep going until it's
    done](#keep-going-until-its-done)), not a lower default, which the
    integration tests' allowance for load relies on.
- **Engines from their makers may be downloaded and run for experiments**
  (the user's standing permission, given 2026-11-05). An official release
  or nightly build of an engine or emulator (ScummVM, DOSBox and its forks,
  Basilisk II/SheepShaver, QEMU, Wine builds), from its makers' own site or
  GitHub releases, run by hand to see whether it runs the program. Record
  the URL and sha256 in the porting log, and check a published checksum or
  signature where there is one (`codesign -dv`, `spctl -a -vv`). Run it in
  its own folder in the porting workspace in a test account, with a scratch
  `HOME` or config, never installed or put on `PATH`, and remove it
  afterwards. A result worth keeping becomes an update to the engine's
  module, which pins it by hash: made and tested as any change to what
  other programs get ([Keep going until it's done](#keep-going-until-its-done)).
  Other third-party software that's part of porting is covered there too.
- **Licences.** Before writing a `download` edition, find out what the
  makers allow (`licence:` in `docs/program-bundles.md#download-editions`).
  Use only the makers' URLs, a distributor they name, and Wayback/archive.org
  copies of those. A commercial program is a `disc` (or other owned-source)
  edition, never a download. Never offer disc images in text people see.
- **Other projects' data is reference, not source.** CrossOver's CrossTies
  and Porting Kit's recipes say what worked for them. Read them, and write
  our own steps. Never paste their files or text into a bundle.
- **One fact, one place.** A lesson that applies beyond this program goes
  into the reference file it belongs in (or `docs/` if it's about Second
  Chance itself), not just the porting log.
- **Spend tokens where they buy the most progress.** The aim is the
  cheapest *route* to the right answer, not the cheapest single look. A
  picture that shows at once what's really going on can save several wrong
  turns, which cost far more than the picture. So prefer the light tools for
  routine questions, and use your own eyes whenever you judge they're the
  quicker way to understand. Read [reference/token-budget.md](reference/token-budget.md)
  for the costs and when each kind of look pays.
  - **Light by default:** a log line, OCR, whether the picture changed, a
    named screen, a local model's one-line answer. These answer "is it
    loading?", "did the click do anything?", "what does the dialog say?" for
    tens of tokens.
  - **Look yourself:** when something's new, puzzling or looks wrong; when a
    light answer is unsure or doesn't add up; when you're about to decide
    where to go next; or when the quality of the port is the question. Even
    then, a crop or the game's own resolution often does as well as the
    whole screen.
  - **Long or picture-heavy jobs go to a subagent** (below), so their
    pictures and logs stay out of your context.
  - **This is about how to look, never a reason to do less** or to stop
    early: an unfinished port wastes everything spent on it.
  - **Logs:** filter and count them (`grep … | sort | uniq -c`) rather than
    pasting them.
  - **The porting log is the shared memory,** so neither a later session nor
    a subagent rediscovers anything.
- **Fix the skill as you use it, not at the end.** This skill and its
  files (`reference/`, `scripts/`, the log template) are yours to improve.
  The moment something in them is wrong, missing, misleading or slower than
  it needs to be — a script that misdetects a file or leaves a process
  running, a reference that's out of date, a step in this procedure that
  sent you the wrong way — fix it then, test the fix, and note it in the
  porting log's "Lessons for the skill". A lesson left for "later" is lost
  when the session ends.

## The porting log

Keep `.local/porting/<namespace>-<name>/log.md` from the start, as you go
rather than at the end. Copy the outline from [log-template.md](log-template.md).
It records what the program is, the inputs and their hashes, what each
source of knowledge said, every attempt (Wrappfile change → result), and the
rung reached. It's what makes a second attempt cheaper than the first, and
it's what you report from: at the end it's distilled into `report.md` beside
it ([step 9](#9-finish-report-and-improve-the-skill)). Note findings in the
log as they happen (a "Found:" line is enough), and anything that cost time
and could be avoided next time under "Could be better", so the report needn't
be reconstructed from memory.

## Subagents

Self-contained work goes to a subagent, briefed with the porting log:

- **`porting-researcher`:** lookups, walkthroughs and manuals.
- **`porting-player`:** picture-heavy play, in a test account.
- **`porting-debugger`:** one failure's cause.
- **`porting-bundler`:** step 8, once the Wrappfile reaches rung 3.

Three points in the procedure hand work over by default: the research at
intake ([step 1](#1-intake)), a failure that needs more than a few
experiments ([step 6](#6-when-it-doesnt-work)), and the bundle at rung 3
([step 8](#8-the-program-bundle)).

You stay the lead: you own the log, the decisions, the user, and the screen
schedule (a test account of its own for each screen-taking subagent). Subagents report and you write.
[reference/subagents.md](reference/subagents.md) has when to delegate, the brief and
the patterns.

## 1. Intake

Find out what you've been given: a file, a folder, a disc image, a URL, or
just a name. If it's only a name, find where the program legitimately comes
from (the makers' site, a store, an archive the makers point to) before
anything else.

Make the workspace, `.local/porting/<namespace>-<name>/`, with `inputs/`
(each input in its own folder), `extracted/` and `log.md`. Pick the
namespace as `Bundles/` does: who the program comes from, or `freeware/`
for programs given away.

**Start the research now, in a subagent.** As soon as you know what the
program is, brief a `porting-researcher` with step 3's lookups (CrossOver,
Porting Kit, Lutris, PCGamingWiki, the WineHQ AppDB, ScummVM, a manual or
walkthrough) and let it run while you identify the files: nothing it does
needs your results, and its verdicts are waiting when you choose the engine.

## 2. Identify

```sh
python3 -I .claude/skills/port-program/scripts/identify.py <file or folder>
```

It reports the platform and executable type (DOS, DOS extender, Win16 NE,
Win32/64 PE with its imports), installer family, packer and copy protection
markers, disc layout (ISO 9660, Joliet, HFS, Apple partition map, hybrid),
classic Mac formats (MacBinary, StuffIt, resource forks, 68k/PPC), and what
to unpack it with. It reads files and never runs them.

Then unpack until you reach the program itself, not its installer. What to
use for each format, and the tells that something is what it seems, are in
[reference/identifying-files.md](reference/identifying-files.md). Answer
these in the log before going on:

- **Which platforms are on it?** A hybrid disc can hold a Windows build
  *and* a Mac build, and an old download can have DOS, Win16 and Win32
  builds. List each one: it's a separate route to running it.
- **What is the program made with?** Director projectors (`.dxr`, `.cxt`,
  `PJ95`/`PJ97` creators), SCUMM/AGI/SCI data, Smacker or Bink video, Flash
  projectors, Visual Basic and MFC: the engine often matters more than the
  platform.
- **What does it need?** Its imports (DirectDraw/Direct3D, DirectPlay,
  QuickTime, Indeo), its README's requirements, its installer's extra
  components (QuickTime, DirectX, fonts, codecs), and whether it checks for
  its disc.
- **Is it protected?** SafeDisc and SecuROM's drivers don't run under Wine.
  A protected disc usually needs the publisher's own no-disc patch or a
  later (GOG/Steam) release, which is a different edition.

## 3. Look up what others know

Others have usually solved it already. Search before experimenting. This is
the researcher's job, started at intake ([step 1](#1-intake)); run these
yourself only for a quick check of one source:

```sh
S=.claude/skills/port-program/scripts
python3 -I $S/refs.py sync                 # once a month: CrossOver's and Porting Kit's indexes
python3 -I $S/refs.py search <name>        # CrossTies, Porting Kit ports, local .wsi3 recipes
python3 -I $S/refs.py show crossover:<id>  # what CrossOver installs and sets for it
python3 -I $S/refs.py show pk:<id>         # a Porting Kit port's notes (and recipe, if one is here)
python3 -I $S/refs.py draft crossover:<id> # candidate Wrappfile lines from a CrossTie, and what didn't map
python3 -I $S/refs.py draft pk:<id>        # the same from a Porting Kit recipe (or pk:<file.wsi3>)
python3 -I $S/refs.py lutris <name>        # Lutris's install scripts (runner, winetricks, files)
python3 -I $S/refs.py pcgw <name>          # PCGamingWiki: fixes, settings, where it's sold
```

Also check ScummVM (`scummvm --detect --path=<folder>` with the module's
ScummVM, below), the engine reimplementation lists, the WineHQ AppDB, and
for a classic Mac program Macintosh Garden or Macintosh Repository's notes:
[reference/knowledge-sources.md](reference/knowledge-sources.md) says
what each is good for and how to query it. Write each source's verdict in
the log, including "nothing".

## 4. Choose the engine

Go down this list and take the first that runs the program well. The
reasons for the order, and the emulators beyond these, are in
[reference/engines.md](reference/engines.md).

1. **An engine reimplementation Second Chance has: ScummVM.** If
   `scummvm --detect` names the game, that's the route, on any platform's
   data, since it skips Wine, codecs and display modes entirely. Check its
   support level and that it really plays: the compatibility page lists
   only tested games, so also read the engine's `detection_tables.h` on
   GitHub (the game's entries, and the support flag: every Director game is
   `ADGF_UNSTABLE`, so ScummVM warns before starting it). ScummVM from the
   module: the prepared engine in
   `~/Library/Caches/SecondChance/engines/<prepared hash>/MacOS/scummvm`
   (`sc engine fetch scummvm` if missing), run with `HOME=<scratch>` so it
   doesn't touch the user's settings, and with `--config=<ini>` holding
   `[scummvm]` `updates_check=0`, or a first run stops at a dialog. An
   unstable game's "not fully supported" warning stays: the player should
   know, and save often.
2. **DOS → DOSBox** (the dosbox module).
3. **Windows → Wine** (the wine module): Win32 first. Win16 only if our
   Wine runs 16-bit programs (check the reference file; if a program has
   both, use the 32-bit one).
4. **Nothing above runs it** (a classic Mac-only program, a Win16 program
   our Wine won't run, an OS/2 or Amiga program): it needs **an engine
   Second Chance has no module for.** Once every route above has failed,
   see [Needs a new engine](#needs-a-new-engine).

When there's more than one route (a hybrid disc, a game ScummVM *and*
Wine could run), list them all in the log with what you know of each, and
try the best one first. **Detection isn't support**: a route is only
chosen once the program reaches its title screen by it. Ingenious was
detected by ScummVM, started, and died 15 s later on a Lingo error.

**Routes are a loop, not a menu.** When a route is stuck (step 6), log why
and start the next one yourself; never stop to ask which to try. And you
needn't wait until it's stuck: when a route turns out to have far more
trouble ahead than it looked (failure after failure, each needing an engine
fix), weigh it against the others and switch if another now looks the
better bet. Write the reasoning in "Decisions". A route left isn't closed:
come back to it if the others do worse and it's the best again.

**Trying another engine version** (a newer ScummVM, a daily build, an
emulator) is covered by the ground rule on engines from their makers, and
other software a port needs by [Keep going until it's
done](#keep-going-until-its-done). Tools from Homebrew formulae for
inspecting files are fine.

## 5. Write the Wrappfile and iterate

Start from the closest shipped bundle and the shapes in
[reference/cookbook.md](reference/cookbook.md):

| Program comes as | Start from |
| --- | --- |
| A bare Windows exe, or a zip of one | `Bundles/freeware/skifree` |
| A zip of DOS files | `Bundles/freeware/tyrian-2000` |
| Data ScummVM runs | `Bundles/freeware/lure-of-the-temptress` |
| A Windows installer on a disc | any `Bundles/nancy-drew/*` disc edition |
| An installer that must be clicked through | the installer module's AutoIt use (`docs/wrappfile.md`, `INSTALLER.RUN --automation`) |

`sc bundle list --where <path>=<value>` finds bundles by any manifest field
(`notes.installer=installshield`, `editions.source=download`).

Write the Wrappfile in the workspace, next to the inputs, and iterate with
`wrapp-builder` (its help, and `docs/wrappfile.md`):

```sh
wrapp-builder check Wrappfile
wrapp-builder plan  Wrappfile --target=<stage> --input game=<path>
wrapp-builder build Wrappfile --target=<stage> --input game=<path> \
    --allow-path='*' --out=<scratch>/<name>.app --events=json
```

- `--allow-path='*'` is for experiments only, so assets can be added
  without changing the build's arguments. The bundle later names its
  folders in `allow-paths`.
- Launch the built app in a test account and **look**: `sc puppet`'s
  captures (or the wrapp's puppet helper), and the
  app's log (`docs/logging.md` says where). Never judge a launch from the
  exit code alone: an old game that can't set its display mode quits
  cleanly.
- For anything you don't understand yet, get a shell on the problem rather
  than rebuilding: run the program with the prefix's Wine by hand
  (`sc wrapp wine <slug> -- <program>` on a built wrapp, or the engine's own
  binary with a scratch `HOME`), try the fix, then write it into the
  Wrappfile.
- One change per attempt, each with its result in the log.

**If `wrapp-builder` doesn't exist yet** (`ls Packages/WrappBuilder/Sources`,
`.local/plans/builders-into-modules.md` decision 26): check with
`./sc bundle check <bundle folder>` and `./sc bundle plan <bundle id>
<edition>`, and build with `./sc wrapp build <slug> --from download` (or
`disk`) once the bundle exists and `sc generate` has run. Until that plan's
phase 2a, a `download` edition can only `COPY` its input (no `RUN` of an
installer), so prefer a portable or zip edition, and do an installer's
steps by hand with `sc wrapp wine` to prove them. Record in the log what
you'd have written with the planned syntax.

## 6. When it doesn't work

[reference/troubleshooting.md](reference/troubleshooting.md) maps symptoms
to causes and fixes: no window, quits at once, black screen, wrong colours,
no video, no sound, first click ignored, "please insert the disc", an
installer that hangs. Read the log the build and the app leave before
guessing.

What CrossOver and Porting Kit did (step 3) is your best list of things to
try: their winetricks verbs, DLL overrides, Windows version and registry
keys, which `refs.py draft` writes as Wrappfile lines. Try them one at a
time, and keep only what's needed.

When the program's source is published, read it before guessing: where it
writes its settings and saves, what it checks at start, which switches it
takes are often a `grep` away.

**A failure that needs more than a few experiments goes to a
`porting-debugger`**, briefed with the log's attempts and how to reproduce
it, in a test account of its own, while you carry on with what doesn't
depend on it (the volumes, the research, another route).

**Stuck, or out of ideas? Research before the next experiment.** Two
failed attempts with no new lead mean it's time to look rather than try
another variation:

- **Make the engine say more.** Wine's `WINEDEBUG` channels
  (`docs/logging.md`); ScummVM's `--list-debugflags=<engine>` then
  `--debuglevel=5 --debugflags=…` (for Director, `lingoexec`, `paths`,
  `xobj`, `screenshot`). A trace usually shows the exact call the program
  is stuck on.
- **Read the engine's source for that call.** ScummVM, DOSBox and Wine are
  open: when a trace stops at a function (an Xtra's method, a Win32 API),
  read how the engine implements it, on GitHub, on master (it may already
  be fixed there, which says a newer build is worth trying). Bioscopia's
  disc check was solved by reading ScummVM's `budapi.cpp`.
- **Search for others hitting it.** The engine's bug tracker and forums
  (ScummVM's Trac/GitHub issues, WineHQ Bugzilla and AppDB comments,
  VOGONS for DOS), the exact error text in quotes, the game's own name
  with the engine's, and the other sources in
  [reference/knowledge-sources.md](reference/knowledge-sources.md) again
  with what you know now (the authoring tool, the Xtra or DLL involved).
  Search tools are fine to use freely; record what each turned up in the
  log, including nothing.
- **Look at the same thing done for a similar program**: another game on
  the same engine, authoring tool or installer, in `Bundles/`, in
  `.local/porting/*/log.md`, or in CrossOver's and Porting Kit's data.

- **Hand a deep failure to a `porting-debugger`**, and work on another route
  or another part of this one while it digs.

Then write down the hypothesis the research gave you before testing it.

**A route is stuck** only when all of these have been done and the log
says what each found: the engine made to say more, the engine's source
read for the failing call, the bug trackers and other sources searched,
a newer engine build tried where the standing permission or the software
rule covers one, and the fixes the research suggested tried. Then go to
the next route (step 4). Bioscopia's black first scene was reported as a
stopping point with three untried leads, all of them allowed: that's not
stuck.

**When the fault is Second Chance's**, not the program's (a disc image that
won't mount, a copy that fails on an odd file), fix it: the change, a unit
test beside the existing ones, the doc that describes that code (AGENTS.md's
table says which), `sc test unit` and `sc lint`, and its own `fix(…)`
commit. A change to what other programs get (a module's settings, the
wrapp's templates, a new volume kind) also needs the integration tests of
the shipped programs it reaches; when it's more than minor and tests can't
show it's harmless, prototype it, keep porting with it, and propose it in
the report.

## 7. How far it got: the ladder

Report the highest rung reached, with evidence for each:

1. **Builds**: the Wrappfile checks, plans and builds an app.
2. **Launches**: the program's process starts, and the log shows no fatal
   error.
3. **Reaches its title or main screen**: a screenshot shows it.
4. **Plays**: it takes input (a click or key does what it should), and its
   sound and video work.
5. **Lasts**: saves survive quitting and relaunching (the volume is where the
   program writes), and it quits cleanly from its own menu and from the
   app's Quit.

**The target is rung 5.** Rung 3 is the least a bundle is committed with:
a checkpoint, so commit it (step 8) and keep climbing. Stopping below rung
5 means every route is stuck; say plainly what's below it.

## 8. The program bundle

With a Wrappfile that reaches rung 3 or better, **hand this step to a
`porting-bundler`**, briefed with the workspace: it follows the steps below
through to a committed, tested bundle while you finish the port's open
questions (sound, saves, a later scene). Do it yourself only when the bundle
is a few lines on an existing one. The steps:

1. Create `Bundles/<namespace>/<name>/` with the Wrappfile, and a
   `manifest.yaml` following `docs/program-bundles.md`: `id`, `title`,
   editions (each with its `source`, `build.target` and inputs), the
   volumes the program writes to, `tests`, and `notes` (`about`, and
   `checked`: what you checked and when). Copy the field shapes from the
   closest shipped bundle.
2. **Volumes**: find out where the program writes saves and settings (watch
   what changes in the prefix or its folder after playing and saving), and
   make each a volume (`docs/wrappfile.md#the-launch-volumes-and-icon`).
   Check what the modules can do first: as of 2026-11 a Wine volume can only
   be under `C:/users/` (`RecordedLaunch.savesVolume`), so a game that saves
   beside its exe or in `C:/windows` has no volume, and its saves stay in
   the app (lost on a rebuild or update). Say so in the manifest's `notes`
   and the report rather than forcing it.
3. **A download edition**: URLs in the order the docs give, the sha256 and
   size, `unpack`, `licence` and `licence-from`, and a Wayback `id_` copy,
   checked by its CDX digest rather than downloaded twice.
4. **A disc edition**: `detect` so the build recognises the disc (its
   volume name, a file only it has) and doesn't mistake another for it.
5. **Its test**: the engine module's `starts-and-quits` scenario and a
   `running` needle (`tests/needles/*.yaml`) on text or a picture its
   title screen shows (`docs/testing.md#needles`).
6. `./sc bundle check Bundles/<namespace>/<name>`, `./sc generate`,
   `./sc test unit` (the bundle tests), then a real build and
   `./sc --on <user>@<host>:<path> test integration <slug> --source
   <source>` in a claimed test account.
7. Commit, as `.local/AGENTS.md` allows: `feat(bundles): <program> runs`,
   with the bundle, the generated table and any reference changes in
   separate commits where they're separate changes.

## Needs a new engine

When no module Second Chance has can run the program, don't write a module.
Do the work that makes the decision easy:

1. **Pick the engine** from [reference/engines.md](reference/engines.md):
   what it emulates, its licence, whether it runs natively on Apple Silicon,
   whether it needs a ROM or an operating system image and where those
   legally come from (often the hard part), how it's configured without a
   GUI, and how a program is started in it automatically.
2. **Prove it with a proof of concept, in the workspace**, not in
   `Modules/`: get the engine's Mac build, boot it with a config file you
   wrote, start the program without clicking, and screenshot it running (on
   a test account). Time how long it takes to start, and see where the
   program's saves end up. Each experiment and its result goes in the log.
3. **Write the proposal** in `.local/porting/<…>/new-engine-proposal.md`:
   the engine, why it beats the others, what the PoC showed (with
   screenshots), the module it needs (its package's downloads, how it's
   prepared, its path type, `LAUNCH` and volume forms, its test scenario,
   the instructions its build needs), what a person must provide (a ROM, an
   OS install) and how they'd be asked for it, and what's still unknown. Use
   `docs/plans-for-consideration/` plans as the shape.
4. **Report.** The user decides whether the module is built: a new engine
   is never minor. This ends the port only if no other route is left to
   try; otherwise carry on with those.

## 9. Finish: report and improve the skill

Only when the port is finished ([Keep going until it's
done](#keep-going-until-its-done)):

- **Write the report** to `.local/porting/<namespace>-<name>/report.md`
  (outline in [report-template.md](report-template.md)), before you tell the
  user anything. Where the log is the running record, the report is what was
  *found out* along the way, written to be read cold weeks later by someone
  porting a similar program: what the program turned out to be, what each
  source of knowledge was worth, each route and why it worked or stuck (with
  the evidence: log lines, traces, screenshots in the workspace), the
  surprises and dead ends and what they cost, what changed in Second Chance
  or its modules and why, and what's still unknown. Its **"Suggested
  improvements"** section is required: for every problem the port ran into
  that something could have avoided (in Second Chance, `sc`, a module, the
  bundle format, this skill or its tools), the problem, what it cost, and
  the change you'd suggest, and whether you made it. Small ones count: a
  confusing message, a missing option, a limit that was too long. Write it even when the
  port stops short of a bundle: a failed port's findings are the most useful
  to the next attempt. Every claim points at its evidence or says it's a
  guess.
- **Report** to the user from it: the rung reached and its evidence, the
  route chosen and the routes not taken (and why each stuck), what's
  committed, what's left, the decisions you made that the user may want to
  overrule, and the log's "Waiting on the user", each with what you did
  meanwhile, and the path to `report.md`.
- **Clean up**: engines and tools you started, on both Macs, are stopped
  (checked, not assumed); any `caffeinate` you started is gone; the screens
  are handed back to the peers.
- **Improve this skill** before you finish: a new tell for identifying a
  format goes in `identifying-files.md`; a new source of knowledge in
  `knowledge-sources.md`; a symptom and fix in `troubleshooting.md`; a new
  Wrappfile shape in `cookbook.md`; a step of this procedure that wasted
  time or misled you, here. Keep each file's facts dated where they'll go
  stale.
- **Improving the tooling** (scripts here, and the toolkit that drives programs,
  `.local/plans/puppet-toolkit.md`) follows the same rule as the ground rule on
  tokens:
  - **What a tool prints by default is what an agent needs to decide its next
    step, in as few tokens as that takes:** a one-line summary, numbered refs,
    paths to the images rather than the images.
  - **More is on request:** `--json`, `--verbose`, a picture.
  - **Prefer a local, deterministic or on-device answer** (OCR, fingerprints,
    a local model) when it's as good as a paid model's, and say how sure it
    is, so the agent knows when to look for itself.
  - **The test for a change:** fewer tokens or fewer steps on a real port,
    shown in its porting log.
  - **Don't build what no port has needed.** Note an idea as a candidate,
    and build it when a port wants it.
