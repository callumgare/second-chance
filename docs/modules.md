# Modules

A module is what a program needs beyond its own files: an engine to run it
(Wine, ScummVM), a service beside it (Steam), or knowledge shared by a series
(Nancy Drew's installers and patches). Each is a folder in `Modules/`, of data,
and may name Swift compiled into Second Chance (`native:`). The Swift is
described in [wrapp-launch.md](wrapp-launch.md#modules) (what each module does
in the wrapp), [testing.md](testing.md) (in WrappPuppeteer),
`Packages/WrappBuilder/Sources/WrappBuilder/Modules/` (preparing its engine)
and [below](#executors) (its executor, which carries out its instructions in a
build, in a package of its own under `Packages/Modules/<name>/`); this doc
covers the data.

```text
Modules/
  module.schema.json        the schema every module.yaml is checked against
  releases.json             each module's releases, as recorded (generated)
  wine/
    module.yaml
    stages/prefix           the Wrappfile a new prefix is set up by (FROM --module=wine@10 prefix)
    stages/update           the wine-prefix update, over an old app's prefix (FROM ${input.previous})
    functions/cnc-ddraw     cnc-ddraw, for a DirectDraw game (DO wine.cnc-ddraw)
    functions/prefix-settings  the prefix's settings, which both stages give it (DO wine.prefix-settings)
    functions/keep-thread-handles  msvcrt keeping _beginthread's handles, for an Allegro 4 game's exit (DO wine.keep-thread-handles)
    routine-errors.yaml     Wine's err: lines that say nothing is wrong
  scummvm/  dosbox/  basilisk/  steam/  big-fish/  nancy-drew/  installer/  disc/  her-download/
```

`installer`, `disc`, `her-download` and `big-fish` are, so far, a `module.yaml`
naming their Swift and declaring the instructions a Wrappfile gives them
([wrappfile.md](wrappfile.md)), which today's builders carry out. The wine and
nancy-drew modules' instructions are carried out by their executors
([below](#executors)).

What a module adds to a build (its instructions, and the options and mount
fields it adds to the core's) is data, its `module.yaml`'s `build:`
([below](#what-a-module-declares)), its path types (`wine:`, `scummvm:`)
included. Where a path of its type is in the app is its kit's Swift
(`ModulePaths`, [wrappfile.md](wrappfile.md#path-types)). A module's `BuildModule`
only prepares its engine, for a module with one; its instructions are
carried out by its executor ([below](#executors)) or, until it has one, by
today's builders. An addition needs something to carry it out, so for now
only a module with an executor, or whose Swift today's builders know, can
declare any. `sc module check` and the unit
tests refuse two modules registering one path type, a type named with one
letter, and two module ids that differ only in case.

Second Chance ships the folder in its resources (`Contents/Resources/Modules`),
where a build reads it, and so does WrappPuppeteer, for its needles.

## module.yaml

```yaml
# yaml-language-server: $schema=../module.schema.json
format: 1
id: "wine"                     # a shipped module's is one name; one someone adds is namespaced
release: 1                     # our fixes beneath its versions; counts up
native: "wine"                 # its Swift: Packages/Modules/wine, compiled into Second Chance
versions:                      # what this release provides, as a bundle names it with @
  - version: "10.0_8"
    package: { … }             # an engine's: what it is made from (below)
data: ["routine-errors.yaml"]
retired: ["prefix.yaml"]       # data only Second Chance's Swift read, dropped (below)
stages: ["stages/prefix", "stages/update"]  # Wrappfiles a bundle builds FROM (FROM --module=wine@10 prefix)
functions: ["functions/cnc-ddraw", "functions/prefix-settings", "functions/keep-thread-handles"]
allow-paths: ["assets/"]       # folders of its own its stages and functions may read files from
updates:                       # its default updates, after a bundle's
  - { id: "wine-prefix", when-changed: ["stages/prefix"] }
build:                         # what it adds to a build (below)
  instructions: { … }
  core-options: { … }
```

A module's data tables are YAML, read as YAML 1.2 as bundles are
([program-bundles.md](program-bundles.md#how-a-manifest-is-read)), and a table
with a schema beside it (`patches.json` and `patches.schema.json`) is checked
against it whenever the module is loaded. A Wrappfile reads a table as
`${<module>.data.<table>…}` (in the module's own functions,
`${self.data.<table>…}`), and the module's release as `${<module>.version}`
([wrappfile.md](wrappfile.md#values)). The schema is what the checker
checks such a path against, and a field it gives a `default` reads as that
when a table leaves it out, so a function needs no fallback
(`patches.schema.json` gives `destinationSubdirectory` `""` and `automation`
`none`). A module's `updates` are run after a
bundle's for a wrapp whose copy of the module is behind, as
[wrapp-build.md](wrapp-build.md#updating-a-wrapp) describes; one with no
`build` is done by the module's own Swift. Its `when-changed` names data
files and stages: a data file is compared by a hash of its bytes, and a
stage by a hash of its steps as planned (`PlannedStage.plannedTextHash`), so
a comment or a reformat changes nothing, and only a change to what the stage
does runs the update. `allow-paths` names the folders of
the module's own that its stages and functions may read files from, as a
bundle's manifest does ([wrappfile.md](wrappfile.md#what-a-build-may-read)):
the nancy-drew module's `assets/`, for its AutoIt scripts and icon. A file is
never readable for being in the module's folder alone.

## What a module declares

`build:` says what the module adds to a build. The checker
(`WrappfileChecker`) and the planner (`BuildPlanner`) read this and nothing
else, so they know a module from its folder alone, and a module someone adds
could declare instructions the way a shipped one does. It is parsed by
`ModuleDeclarations`
(`Packages/WrappBuilder/Sources/WrappBuilder/Modules/ModuleDeclarations.swift`)
and checked against `module.schema.json`.

```yaml
build:
  path-types:                  # the paths it handles, written wine:C:/…
    wine: { roles: [location, program], short-form: "^[A-Za-z]:([/\\\\].*)?$" }
  instructions:                # its own, by name in upper case: WINE.KEEP-DISCS is KEEP-DISCS
    KEEP-DISCS:
      options:                 # each a kind, or { kind, role }
        into: { kind: value, role: location }
        combined: { kind: value, role: location }
      required: [into]         # options it can't do without
      arguments: { count: "1...", roles: [input] }
      layer: suggested         # expensive: a layer after it is worth keeping
      may-ask: true            # it may ask the person something as it runs
    REGISTRY: { options: { set: flag, remove: flag }, arguments: { count: "1...2" } }
  core-options:                # options it adds to core instructions, written --wine.<option>
    LAUNCH: { graphics: value, clean-exit-log: value, clean-exit-line: value, cursor-lock: flag, window: value }
```

- **`path-types`** are the kinds of path it handles, by name (never one
  letter, so a drive is never a type): their `roles`, `location` (a place in
  the app or the engine) and `program` (what `RUN` and `LAUNCH` start), and
  an optional `short-form`, a regular expression on the whole path that it
  claims in those roles in a stage that uses it (wine's and dosbox's `C:/…`).
  Where two modules' short forms match, the one the stage used last takes it
  ([wrappfile.md](wrappfile.md#path-types)). Where a path of the type is in
  the app, how a message describes it, and the path from its drive's root
  that older settings name a program by are the module's kit's Swift, a
  `ModulePaths` (`WinePaths` in `WineKit`); `PathPlaces.shipped`
  (SecondChanceKit) and `ModuleKits.places` (`wrapp-builder`, `sc`) are the
  shipped modules' table. A module whose folder changes needs a new release.
- **An instruction's `options`** are each a kind: `value` (`--into=…`),
  `flag` (`--patch`) or `repeated` (`--mount=…`, as many as needed). Written
  as `{ kind, role }`, the role says what the value is, where it isn't text:
  a `location` (a place in the app or the engine), a `program`, an `input`,
  a `copy-source`, a `file` the build reads, `text`, or a `store`, named by
  its short name in the module's own files
  ([wrappfile.md](wrappfile.md#stores)). The checker and planner read the
  roles to know which words are paths, and which stores.
- **`required`** names the options it can't do without; each must be one it
  declares.
- **`arguments`** says how many it takes (`count`: `1`, `1...2`, or `1...` for
  any number from 1; none when left out), and what each is (`roles`, in
  order, the last going for every argument after it).
- **`layer: suggested`** says a layer after it is worth keeping, and
  **`reads-data`** names the module's data tables its Swift reads, which go
  into its steps' keys (`NANCY-DREW.CONFIGURE-INI`'s `reads-data: [ini]`)
  ([wrapp-build.md](wrapp-build.md#the-layer-cache)). **`may-ask`** is kept
  with the instruction; nothing acts on it yet.
- **`core-options`** are the options it adds to core instructions, by
  instruction, in a stage that has the module: the wine module's `LAUNCH
  --wine.graphics`, the steam
  and big-fish modules' `LAUNCH --steam.exe` and `--big-fish.exe`. Each is a
  kind or `{ kind, role }`, as an instruction's options are.
- **`mount-fields`** are the fields it adds to core mount types, by type,
  written `<module>.<field>=…` in a `--mount=`: the dosbox module's
  `store: ["overlay"]`, a launch's store laid over a DOSBox drive.
- **`watches`** are the watches it adds to `WATCH`, written
  `--<module>.<watch>`, which its executor makes (`ModuleExecutor.watch`): the
  wine module's `busy`. An instruction's **`signals`** are its defaults, by
  option (`INSTALLER.RUN`'s `{ alive: alive }`)
  ([wrappfile.md](wrappfile.md#signals)).
- **`signals`** (beside `build:`, at the top of `module.yaml`) names files of
  `SIGNAL` blocks, named `<module>.<signal>`: the installer module's `alive`.
- **`stores`** (beside `build:`, at the top of `module.yaml`) names files of
  `STORE` and `LOCK` lines, the module's stores, which every stage and
  function of the module sees ([wrappfile.md](wrappfile.md#stores)): the
  steam module's sign-in and client, Big Fish's sign-in.
- **`provided-files`** are files its Swift provides rather than its folder,
  which a Wrappfile names as `module:<id>:/<path>`: the installer module's
  `autoit`, AutoIt, which Second Chance carries.
- **`setup`** lists the instructions `USE` would plan in a tree that doesn't
  have the module yet, in order, each one of its own instructions: the wine
  module's `[HELPERS, PREFIX]`, the in-process helpers laid in and
  wineboot's prefix. `USE` plans them, after the core's `ENGINE` step, once
  per tree ([wrapp-build.md](wrapp-build.md#the-runner)). **`update-setup`**
  is what it plans instead in an old app's tree (`FROM ${input.previous}`,
  [wrappfile.md](wrappfile.md#updates)), `setup` unless given: the wine
  module's `[HELPERS]`, as its prefix is made already and `wineboot -u` over
  an old one can wait for ever on Wine's Mono installer. An update that
  moves Wine runs `WINE.PREFIX` itself.

Today's builders and the executors carry the declared instructions out, so
a declaration could promise what nothing does. `BuilderDeclarations`
(`SecondChance/Builders/BuilderDeclarations.swift`) lists, by module, the
instructions the builders and executors carry out and the options each
reads, and
`ModuleDeclarationTests` holds every shipped module's `build:` to it: every
instruction declared is carried out, none is carried out that isn't
declared, and every option declared is read, so none is accepted and
ignored. A change to what a builder carries out changes both. An option the
builder accepts only in certain forms checks them and refuses the rest:
`STEAM.INSTALL`'s mounts must be the shared sign-in and the kept client
(`SteamWrappBuilder.checkMounts`).

## Executors

A module's part in a build is its **executor**: a `ModuleExecutor`, which
carries out the instructions its module declares, and only those
(`handles`). Executors are written against `WrappModuleKit`, a library of
`Packages/WrappKit` that `WrappBuilder` re-exports, and need nothing of
Second Chance's, so one compiled into Second Chance and one a module
someone wrote would be written the same way. The runner hands each step to
its module's executor ([wrapp-build.md](wrapp-build.md#the-runner)).

- **`run(_:in:)`** carries out a `PlannedStep` (every value substituted,
  every path in full form) in the step's `StepContext`.
- **`runProgram(_:in:)`** runs a program of the module's path type for
  `RUN` (`wine:C:/setup.exe`), given as a `ProgramRun` (the program, its
  arguments, `--env` and a timeout), returning its exit code.
- **`keyInputs(for:in:)`** names what a step's key needs beyond its text
  (`KeyInputs`: a disc's listing, an installer's fingerprint, the revision
  of `WINE.KEEP-THREAD-HANDLES`' patch), and **`checkpoint`** makes the
  tree safe to keep as a layer, nothing running in it.
- **`revision`** is part of every one of its steps' keys: raise it when a
  change to its Swift changes what its steps make. A change that touches
  one instruction's output can key that instruction alone through
  `keyInputs` instead, so every other layer stays (`KeepThreadHandles.revision`).
- **`finish`** ends whatever the executor started, and is called at the end
  of every build, on failure and cancel too.
- A failure is a `StepFailure`: `.recipe` for what the Wrappfile or module
  says can't be done, `.failed` for a step that was tried and failed.

An executor is made once per build. It may keep what lasts between steps (a
running Steam), but a step's only results are its tree and its events, so a
later step never reads anything it kept. The `StepContext` is all it uses:
the step's `tree` (laid out as a wrapp, so `WrappLayout(app:)` works on it)
and another stage's by name, a file the plan reads by its full form, an
input by name (resolved only when asked for, so disc 2 is asked for when a
step needs it, through an `InputProvider`), a file of its own module's
folder (`moduleFile`, for what its `reads-data` says), the emitter (`emit`
for an `EMIT`-like string, `substep` for what the step is doing), `ask` for
a `StepQuestion` (`confirmStepFailure`, `choose`, `confirm`) and its
`StepAnswer`, `runProgram` for running a program as `RUN` would, `fetch`
for a download by URL and hash, and the build's `log`.

**The Swift is a package under `Packages/Modules/<name>/`**, apart from the
module's data in `Modules/<name>/`, so editing Swift doesn't change the
module's release. Its `module.yaml`'s `native:` names it. A package has the
module's executor and, where other processes need some of the module's
Swift, its **kit**:

| Package | Products | Has |
| --- | --- | --- |
| `Packages/Modules/wine` (`WineModule`) | `WineKit`, `WineExecutor` | The kit is the Wine library every process that runs a Windows program uses — `Wine`, `WineCommand`, the registry, server, desktop and drives ([wrapp-build.md](wrapp-build.md#running-wine)) — which `SecondChanceKit` links. The executor carries out `WINE.DRIVES`, `REGISTRY`, `WINETRICKS`, `MOUNT`, `KEEP-THREAD-HANDLES` and `SKIP-SYNTH-PLAYOUT` ([below](#the-wine-modules-patches)), runs `wine:` programs for `RUN`, and has `Winetricks` and the winetricks script as a package resource. It also carries out the `setup` steps `USE wine` plans, `HELPERS` (the in-process helpers laid in the tree's `Frameworks/`) and `PREFIX` (wineboot's). Beside them, `InProcessHelpers/` and `build-in-process-helpers.sh` ([wine-in-process-helpers.md](wine-in-process-helpers.md)). |
| `Packages/Modules/scummvm` (`ScummVMModule`) | `ScummVMExecutor` | Carries out `SCUMMVM.KEEP-DATA <file>…` ([below](#the-scummvm-modules-data)). ScummVM's engine is prepared by `ScummVMBuild` in `Packages/WrappBuilder` and started in the wrapp by `ScummVMRuntime`, which haven't moved into the package. |
| `Packages/Modules/nancy-drew` (`NancyDrewModule`) | `NancyDrewExecutor` | Carries out `NANCY-DREW.CONFIGURE-INI <folder>`: every `.ini` in the folder given what the module's `ini.yaml` says, read through `moduleFile`, each file written back in the encoding it came in (`TextFile`, in `WindowsFormats`). |
| `Packages/Modules/basilisk` (`BasiliskModule`) | `BasiliskExecutor`, `BasiliskKit` | Carries out `BASILISK.SETUP`, `CDROM`, `RUN` and `STARTUP` ([below](#the-basilisk-modules-mac)); given the in-process helpers and the engine's build tools (hfsutils) by whoever runs it. The kit places `basilisk:` paths (`BasiliskPaths`). Basilisk II is prepared by `BasiliskBuild` in `Packages/WrappBuilder` and started in the wrapp by `BasiliskRuntime`. |

### The scummvm module's data

ScummVM's engine data comes with it: a `.dat` per engine that needs one
(`nancy.dat`, `lure.dat`, `ultima.dat` at 16 MB) and what several engines
share (`classicmacfonts.dat` and `macgui.dat`, the Mac fonts and windows
Director and other Mac games draw with; `fonts.dat`; `encoding.dat`;
`fonts-cjk.dat` at 38 MB), about 80 MB in all. The engine package keeps all
of it, so a game's engine finds what it needs without the module knowing
which games will be built.

A Wrappfile keeps only what its game needs:

```dockerfile
FROM scratch AS scummvm
USE scummvm
SCUMMVM.KEEP-DATA nancy.dat
```

`SCUMMVM.KEEP-DATA <file>…` takes out every other file the engine's list
(`Resources/engines/scummvm.files`) names directly in `Resources/`, keeping
what ScummVM's own windows (its warnings, its error console) need and its
licences (`ScummVMExecutor.alwaysKept`), and writes the list again without
them. Files of the bundle's own there (its icon) aren't the engine's and
stay. A name the engine doesn't have fails the step, as the game wouldn't
start. A Wrappfile that doesn't say keeps everything, which is the place to
start a port from: slim it once the game runs. Which file an engine needs
is in ScummVM's source (`engines/<engine>/detection.cpp` or its
`<engine>.dat` loading) or in the error a game stops at.

### The wine module's patches

Most Wine problems are worked around outside Wine: a registry setting, a
winetricks verb, an in-process helper. A few are only fixable in Wine's own
code. Those are byte edits made by Swift compiled into Second Chance, so no
Mac that builds needs a compiler, and each finds the code it changes by an
export and a pattern, checks what it finds, and fails the step (naming what
it found) on a Wine it doesn't know rather than patching blind.

- **Every Wine gets** `RosettaFaultFix`, in 32-bit `ntdll.dll`, made as the
  engine is prepared, so it is in the engine store
  ([big-fish.md](big-fish.md#armadillo-under-rosetta)).
- **A game that asks gets `WINE.KEEP-THREAD-HANDLES`**, through
  `DO wine.keep-thread-handles`, in a stage after it has Wine. It patches the
  stage tree's own copy of the engine (cloned from the store, and replaced
  file by file, so the store is never touched) and the prefix's copy of the
  same DLL (`syswow64`, when it's Wine's). A Wrappfile that doesn't name it
  gets Wine unchanged.
- **A game that asks gets `WINE.SKIP-SYNTH-PLAYOUT`**, through
  `DO wine.skip-synth-playout`, the same way: the stage tree's own engine and
  the prefix's copy of the DLL, when it's Wine's (Microsoft's, which
  winetricks' `directmusic` lays in, is left alone).

`KEEP-THREAD-HANDLES` (`KeepThreadHandles`, in `WineExecutor`) is for Allegro
4.x Windows games that sometimes hang as they exit: the game's own log stops
at `Exiting Allegro`, the window stays up and it uses no CPU. Allegro's
`remove_timer` sets its stop event and then waits, with no limit, on the
timer thread's handle from msvcrt's `_beginthread`. The C runtime closes that
handle itself when the thread returns (Wine's `_beginthread_trampoline` →
`_endthread` → `CloseHandle`, as on Windows), so when the high-priority timer
thread ends before the main thread starts waiting, and wineserver has handed
the freed value to a new object in between, the main thread waits for ever
on something nobody signals. Icy Tower hung on about 3 exits in 11 on macOS
26, and on none of 41 on macOS 15: it's a race.

The patch changes `_endthread`'s one `call [CloseHandle]` in Wine's 32-bit
`msvcrt.dll` (`lib/wine/i386-windows/`) into `pop ecx; test eax, <the same
address>`: the handle is taken off the stack as the stdcall would have, and
the call's address stays as an operand, so the base relocation over it still
lands harmlessly if the DLL loads elsewhere. The call is found from the
`_endthread` export to the next export, by kernel32's `CloseHandle` import
slot, and must be the only one there and be followed by `push eax` (its
result unused). The handle then stays the thread's, signalled once it ends,
at the cost of one handle per `_beginthread` thread for the life of the
process. Changing what the patch makes means raising
`KeepThreadHandles.revision`, which only that step's key holds.

`SKIP-SYNTH-PLAYOUT` (`SkipSynthPlayout`, in `WineExecutor`) is for games
whose sounds go through DirectMusic and that stop a synthesiser's sink for
each one: Game Maker 7's, which give every sound a performance of its own as
they load. Wine 10's sink (`dlls/dmsynth/synthsink.c`), when it's
deactivated, writes half a buffer of silence and then waits, in
`synth_sink_wait_play_end`, until everything written has played; its buffer
holds two seconds of sound, so each stop takes about 1.5 s, and Iji, with
about 240 sounds, sat on its loading screen for six minutes, logging
`err:dmsynth:synth_sink_render_thread WaitForMultipleObjects returned 0` at
each stop. Wine 11.2 rewrote the sink to wait only for its write latency. The
way round it before was winetricks' `directmusic`, Microsoft's DLLs, which
load at once but bring Microsoft's `dsound.dll`, under which Wine's
DirectShow audio renderer plays nothing: MCI's MP3 music was silent.

The patch changes the play-out loop's `jae <done>` (everything written has
played) in Wine's 32-bit `dmsynth.dll` into `nop; jmp <done>`, the same
displacement ending in the same place, so the loop ends the first time
round, having written its silence and read the play position once. The loop
is found by its trace message (`Waiting for EOS, start_pos …`), which only it
passes: the `jae` is the one just before the check of whether that trace is
on (`test byte [<channel flags>], 8`), within 0x60 bytes, and must jump past
the message. Sound still in the buffer as the sink stops is cut off; the
buffer is released, and so stopped, straight afterwards anyway. Changing
what the patch makes means raising `SkipSynthPlayout.revision`.

An update of a wrapp that moves Wine (the wine module's `stages/update`)
lays the new Wine in without either patch, as that stage doesn't run the
bundle's own stages.

Second Chance's builders have the shipped executors through `ModuleSteps`
(`ModuleSteps.executors()`), which gives the wine executor the wine engine's
`build-tools` ([below](#engine-packages)) and each executor its module's
folder in the app's resources. `wrapp-builder build` has none yet, so it
refuses a plan with any module's instruction. Each package's
`Package.swift` mirrors the app targets' Swift settings, as every package
does, and its tests run with `swift test --package-path
Packages/Modules/<name>`, and in `sc test unit`.

## Engine packages

An engine module's version says what the engine is made from: its makers'
downloads, each checked by its SHA-256 as a download edition's input is
([program-bundles.md](program-bundles.md#download-editions)), and the hash of
the tree preparing them gives.

```yaml
versions:
  - version: "10.0_8"
    package:
      prepared: "9fab…"                  # EngineTree's hash of the prepared tree
      sources:
        - id: "wine"                     # what the module's Swift knows it as
          sha256: "2a6b…"
          size: 166321980
          urls: ["https://github.com/Sikarugir-App/Engines/…/WS12WineSikarugir10.0_8.tar.xz"]
        - id: "wineskin"
          …
```

**Preparing** (`EnginePreparer`, with the module's `BuildModule.prepare`)
lays the sources out as a wrapp's `Contents/` and lists the files it made
in `Resources/engines/<module>.files`. It uses only what every macOS has
(`tar`, `ditto`, `hdiutil`, `codesign`), so it can run on the Mac that
builds. Wine's:

- Sikarugir's Wine goes in `SharedSupport/wine`, and its wrapper
  template's frameworks in `Frameworks`.
- The Mac driver (`winemac.so`) gets a weak dependency on the in-process
  helpers, and `wineserver`, which asks for `@rpath/libinotify`, a run path
  to `Frameworks`. Both are load commands written into the file's header
  padding (`MachOPatch`), as `install_name_tool` would, which only comes
  with Xcode's tools. Every other Wine program finds the frameworks through
  `DYLD_FALLBACK_LIBRARY_PATH` (`Wine`).
- The wrapper template's `cabextract` is kept in `build-tools/`
  (`EngineTree.buildTools`), for winetricks, which needs it for any verb
  that unpacks a Microsoft redistributable (directmusic, d3dx9, vcrun). It
  is left out of the engine's file list and never installed into a wrapp
  (`EngineInstall`); a build puts it first on winetricks' `PATH`
  ([wrapp-build.md](wrapp-build.md#running-wine)). It is in the prepared
  hash, as the rest of the tree is.
- Wine's 32-bit `ntdll.dll` gets the Rosetta fault fix (`RosettaFaultFix`),
  which lets programs wrapped in Armadillo, as Big Fish's games are, run
  under Rosetta ([big-fish.md](big-fish.md#armadillo-under-rosetta)).
- The wrapper's Swift modules are dropped, and the framework they were in
  is sealed again.
- Every unsigned program and DLL is signed, deepest first: signing a
  framework's binary seals the hashes of every file in it, so they must be
  signed before it.

ScummVM's copies the program, its frameworks and every data file in its
app's Resources (not its docs or icon) out of its disk image: 80 MB of
them, which a Wrappfile slims to its game's
([below](#the-scummvm-modules-data)). DOSBox
Staging's copies its program and the libraries beside it into `MacOS`, and
what it needs of its Resources (not its 40 MB manual) into the wrapp's,
where it looks for them, and signs the program and libraries again, ad hoc:
they come with hardened runtime, which would refuse puppet control's
inserted library.

**The prepared hash** (`EngineTree.hash`) covers each path, a file's
contents, whether it is executable, a link's target, and the code signature
a file that isn't Mach-O keeps in its `com.apple.cs.*` extended attributes;
not times, owners or other attributes, which a download or a copy changes.
Preparing must give the package's hash, so every Mac runs the engine that
was tested. It is taken **before signing**: `codesign` writes a different
ad hoc signature for the same file on another macOS (15.6 and 26.2 do), so
a module's Swift returns what to sign, and the preparer hashes the tree,
then signs it.

```bash
./sc engine prepare wine                   # prepare it here; check, or print, its hash (or wrapp-builder engine prepare)
./sc engine prepare scummvm --into /tmp/s  # and keep the tree
```

A new version is added without `prepared`, prepared, and given the hash
`sc engine prepare` prints. Give each source a second URL where one exists
(the Wayback Machine's copy, its `id_` form, checked against the hash), and
`sc release` refuses to release while a source's first URL doesn't answer
with its size (`sc engine check`). Changing a package changes the module's folder,
so it needs a new release, as any change does.

### The basilisk module's Mac

The basilisk module runs a classic 68k Mac program in Basilisk II. Its package is
E-Maculation's universal Basilisk II and System 7.5.3, which Apple gave away, on a
disk image (`BasiliskBuild.prepare`: the program and SDL2 re-signed ad hoc, so the
in-process helpers load into it, and the system disk as `SharedSupport/basilisk/system.hfv`).

- **The ROM**, which Apple never gave out, is no source of the package: it's the
  person's own, kept in the engine store as `roms/<sha256>.rom` (`MacROMs`, known
  by the checksum it starts with) and given to a build as the provided file
  `module:basilisk:/rom`. When none is kept, the build takes the file `MAC_ROM_PATH`
  names, or asks the person once (`WrappBuildInput.getMacROM`): a page saying what
  it is, with a button to the Internet Archive's copy of a Quadra 800's and one
  to choose the file, checked by its checksum (a file that isn't one is asked about
  again). A Debug build of Second Chance downloads that copy instead of asking, once
  per Mac, as it would an engine (`WrappBuildHelper.ensureMacROM`); a Release build
  never downloads one, and a headless build with no `MAC_ROM_PATH` fails with a
  plain message.
- **`USE basilisk`** plans `BASILISK.SETUP`: the system disk copied to the app's
  `SharedSupport/basilisk/boot.hfv` and the ROM to `mac.rom` beside it.
  `BASILISK.CDROM ${input.disc-1}` keeps a disc's image in the app as the Mac's CD
  (`cdrom-<n>.iso`): a disc input built from an image gives it as `disc-1.image`.
- **`BASILISK.RUN --automation=<script>`** does at build time what only the Mac
  itself can, such as running Apple's Installer: it boots the tree's Mac with the
  in-process helpers inserted, and `basilisk_mac.m` drives it by the script
  (`BASILISK_MAC_AUTOMATION`), a line at a time, then shuts it down. A line is one
  of puppet control's requests (`click 440 418`, `key cmd+option+w`,
  [docs/wine-in-process-helpers.md](wine-in-process-helpers.md#puppet-control)),
  `type <text>`, `wait <seconds>`, `wait-for <seconds> <text>`, which waits for the
  text to be on the Mac's screen (Vision reading a picture of the window), or
  `wait-gone <seconds> <text>`, for it to go, or `wait-restart <seconds>`, for the
  Mac to restart. Basilisk II keeps its window at a restart, and the screens
  between are gone too soon to be caught reliably, so a restart is told by the
  startup disk (the first `disk` of Basilisk II's prefs): Mac OS marks it
  unmounted cleanly as it restarts and clears the mark as it mounts it again. A
  request the window can't take yet (no window, or none to take it) is tried
  again for 90 s. The
  helper reports `automation finished` or `automation failed at line <n>` (with a
  picture of the screen left in the temporary folder's `basilisk-automation/`),
  and the step fails on the second, or when the Mac hasn't shut down in
  `--limit` seconds (15 minutes). Its prefs are the wrapp's, silent. Its layer
  is suggested: what it installs is kept, once per Mac.
- **`BASILISK.STARTUP <basilisk:disk:…:item>`** moves an item on the startup disk
  (an alias the script made) into `System Folder:Startup Items`, so the Mac opens
  it at every boot. It changes the disk with the engine's hfsutils
  (`build-tools/hfsutils`, `hmount`, `hrename`, `humount`, with a `HOME` of its
  own, where they keep the mounted volume), never with code of ours.
- **Its path type**, `basilisk:`, is a path on the emulated Mac in Mac OS's own form
  (`basilisk:Ingenious CD:Ingenious`); it has no place in the app (`BasiliskPaths`).
- **In the wrapp** (`BasiliskRuntime`): the startup disk is the person's, a store
  the launch mounts at `basilisk:disk/` (`STORE basilisk-disk`), copied from the app's
  on the first launch, so what the Mac writes there (a program's Preferences, its
  saves) stays theirs. A launch that ended without the Mac shutting down leaves the
  disk marked as not shut down cleanly, and the next boot would stop to say so: the
  runtime marks it clean first (the HFS Master Directory Block's `drAtrb` bit 8).
  Basilisk II starts with prefs written then: the ROM, that disk, the
  CDs, `--basilisk.screen` (640x480x8 unless said), no JIT (it crashes under
  Rosetta), and `delay 500`, without which QuickTime's movies stop on their first
  frame. The in-process helpers are inserted on every launch, for
  `basilisk_mac.m` (`BASILISK_MAC_EXE`), which:
  - gets the window drawing: Basilisk II presents only when the Mac's screen
    changes, and macOS drops what an occluded window presents (a background
    login's always is), so it pictures the window until it counts as visible,
    and sends SDL an "exposed" event for a full redraw. Never continually: each
    picture stalls Basilisk II for most of a second (a picture twice a second
    made the sound and video stutter), as does each of an automation's
    `wait-for`s;
  - gives the Mac a first pointer position, without which the Finder never
    draws its desktop;
  - gives the window its green button: Basilisk II's fixed-size window is made
    fullscreen-capable and resizable (keeping the screen's shape), and in
    fullscreen its pointer grab and hidden menu bar are undone, so the title bar
    can be reached to leave it;
  - shuts the Mac down when the wrapp quits (SIGUSR2), or Basilisk II's own
    Quit is chosen (⌘Q, which SDL alone would turn into the power key, leaving
    the Mac asking "shut down now?"): the power key, then Return on Shut Down,
    so the disk is left clean.

### The engine store

Prepared engines are kept in `~/Library/Caches/SecondChance/engines/<prepared
hash>/` (`EngineStore`), so each is fetched and prepared the first time a
build needs it and found after that; nothing is fetched ahead of a build.
Only a version whose package names its `prepared` hash can be stored.

- An engine is prepared under `.incoming-<hash>-<uuid>` and renamed into
  place whole, so nothing finds half of one.
- Two builds wanting the same engine, in one process or two, take a lock on
  its hash (`.locks/<hash>.lock`): one prepares it, and the other then finds
  it.
- A tree missing a file its list names, as macOS emptying the cache can
  leave one, is prepared again.
- `prune(keeping:)` removes engines no listed version names, and what a
  preparation that stopped partway left; one whose lock is taken is being
  prepared, and is left.

**On a Mac with test users** (it has a pool file, `/Users/Shared/second-chance/pool`,
from `sc session add`), the store is `/Users/Shared/second-chance/engines`, shared by
every user, so a test account doesn't fetch and prepare every engine again
(`EngineStore.standardRoot`). It's made with an inheriting ACL that lets every user
use and add to it, and the lock and the rename work across users as across builds.
A user who can't write it uses their own store. Since any user could change a shared
engine, and a wrapp signs and runs what it copies, an engine another user prepared is
used only when its tree hashes to the hash recorded for it when it was signed,
`.signed/<prepared hash>` (`isTrusted`, a second or two for Wine); one that doesn't, or
has no record, is prepared again. The package's `prepared` hash can't be checked there:
it's taken before signing, as `codesign` signs ad hoc differently each time, and the
store keeps the signed tree. Checked against it, no user ever trusted another's engine,
and each deleted the shared one and prepared it again, sometimes under another
account's build that was copying it. The record is written by whoever prepared the
engine, so it catches a tree damaged or changed since rather than proving who made it.

It is a cache: a wrapp holds its own copy of its engine, so clearing it costs
only the next build's download. `sc engine fetch [<id>…]` fills it here, as
a build would.

A build installs the engines it needs from the store
([wrapp-build.md](wrapp-build.md#the-template)); Second Chance itself carries
none.

## What lives where

| Module | Data | Read by |
| --- | --- | --- |
| `wine` | `stages/prefix`: the Wrappfile stage a new prefix is made by — its drives (`WINE.DRIVES`), then `functions/prefix-settings`: `EmulateModeset` (`WINE.REGISTRY`) and `isolate_home` (`WINE.WINETRICKS`), in order; `stages/update`, the `wine-prefix` update, which gives an old app's prefix this Wine and those settings again ([wrappfile.md](wrappfile.md#updates)); `functions/cnc-ddraw`, cnc-ddraw and its `ddraw.ini` settings, which a DirectDraw game's stage runs (`DO wine.cnc-ddraw`); `functions/keep-thread-handles`, `WINE.KEEP-THREAD-HANDLES` for an Allegro 4 game that hangs as it exits, and `functions/skip-synth-playout`, `WINE.SKIP-SYNTH-PLAYOUT` for a game that loads its sounds through DirectMusic for minutes ([above](#the-wine-modules-patches)) | `WineManager`, as it makes a prefix, and the wine module's executor, which carries the steps out (through `ModuleSteps`); Steam's and Big Fish's builders run `cnc-ddraw` themselves for a DirectDraw game until their editions have stages |
| `wine` | `routine-errors.yaml`: Wine's routine `err:` lines | the wrapp's quit check (`GameQuitCheck`), compiled in by `sc generate` |
| `steam` | `stages/client`: Steam's client in the wine module's prefix, ⌘ acting as Ctrl in its windows (`FROM --module=steam@1 client`); `functions/install`, the game installed by Steam with the shared sign-in, then signed out (`DO steam.install`) | `SteamWrappBuilder`, which carries the client stage out before the game is known and the edition's steps after ([steam.md](steam.md#building)) |
| `big-fish` | `stages/manager`: the Game Manager in the wine module's prefix, from its installer pinned by its hash, ⌘ acting as Ctrl in its window (`FROM --module=big-fish@1 manager`); `functions/install`, the game installed and activated, then the account taken out (`DO big-fish.install`); `functions/cnc-ddraw`, cnc-ddraw hooking the functions themselves, as Armadillo rebuilds a game's imports (`DO big-fish.cnc-ddraw`) | `BigFishWrappBuilder`, which carries the manager stage out before the game is known and the edition's steps after ([big-fish.md](big-fish.md#the-build)) |
| `wine`, `scummvm`, `dosbox` | `module.yaml`'s `runtime: { save-warning }`: whether their programs get the save warning before they start (Wine's do) | the wrapp (`ModuleID.showsSaveWarning`), compiled in by `sc generate` |
| `steam` | `routine-errors.yaml`: what Steam logs as it starts | the same, for a game launched through Steam |
| `nancy-drew` | `patches.json`: Her Interactive's patches ([game-patches.md](game-patches.md)) | `GamePatchCatalog`, and `setup-game-patches.sh`, which stages their archives in the app's download cache |
| `nancy-drew` | `ini.yaml`: what every `.ini` in a game's folder has changed once it's installed (LCD mode, saves in Documents) | the nancy-drew module's executor, for `NANCY-DREW.CONFIGURE-INI` (`DO nancy-drew.configure-ini`) |
| `nancy-drew` | `clean-exit-log.yaml`: the log Her's later engine writes, and its clean-exit line | the wrapp (`HerEngineLog`), compiled in by `sc generate` |
| `nancy-drew` | `assets/*.au3`: the AutoIt scripts that click through an installer that won't run silently, and patchers with no silent mode | `GameInstallerRunner` |
| `nancy-drew` | `needles/`: the splash screens many games share and the main menu's Exit, and `scenarios/quit-from-menu.yaml`, the test every game's bundle names ([testing.md](testing.md#scenarios)) | WrappPuppeteer (`TestData`), from the source tree or its bundle's copy |
| `nancy-drew` | `functions/patch`, `functions/configure-ini`, `functions/set-icon`: Wrappfile functions (`DO nancy-drew.patch --id=… --into=…`), the first two written by each stage that installs a Wine game, the last (the games' icon, `COPY` and `APP --icon`) by every game's; `assets/installshield-custom-dialog-automate.au3`, the script `INSTALLER.RUN --automation` names for an InstallShield installer that won't exit by itself; `assets/nancy-drew.icon`, the games' icon, and `assets/nancy-drew.icns` compiled from it by `sc generate` for their `APP --icon` | the Wrappfile checker and planner, and the builders carrying the plan out |

Second Chance's app finds the nancy-drew module through `NancyDrewModule`.
The quit scenario itself is still Swift (`NancyDrewQuitScenario`), until
scenarios are data.

The wrapp reads no YAML, as only the builder does, so what it needs of a
module's data is generated as Swift by `sc generate` and checked in; a test
fails when it isn't what the data makes. A change to the `prefix` stage's
steps changes the prefix layer's key, so the next build makes a fresh prefix
by itself
([wrapp-build.md](wrapp-build.md#the-layer-cache)).

## Releases

A module has **versions**, which bundles constrain (`USE wine@10`), and
**releases**, our fixes beneath them: one number per module, counting up,
never written in a bundle. `Modules/releases.json` records every release: the
versions it provided, its functions and data, and a hash of every file in its
folder. A release, once recorded, never changes.

```bash
./sc module check            # every module valid, each at its recorded release
./sc module release wine     # record wine's files as its current release
```

`sc module` and `sc engine` run the same code as `wrapp-builder module` and
`wrapp-builder engine` (`WrappBuilderTool`,
[dev-cli.md](dev-cli.md#wrapp-builder)), which take the modules folder as
`--modules <dir>`.

So **changing anything in a module's folder means raising its `release:`**
and recording it with `sc module release`. `sc module check` (and the unit
tests) fail on a module whose files differ from what its release recorded,
naming the files. A new release is compared with the one before: for a
version both provide, it may not drop a function or a data table, since a
bundle can't choose a release and must keep working; that needs a new
version. It may stop providing a version altogether. The one exception is a
table only Second Chance's own Swift ever read, which no bundle could: the
module names it under `retired`, and it goes (the wine module's
`prefix.yaml`, which the `prefix` stage replaced).
