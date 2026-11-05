# Builders into modules: plan

Proposed 2026-11-04. Facts about the code are as of `2b1fb17`. The plan this
follows is
`docs/historical-plans/2026-11-04-program-bundle-improvements.md` ("the
bundle plan" below), and the one before it is
`docs/historical-plans/2026-11-03-generic-programs.md` ("the draft"). The
signals plan is `docs/plans-for-consideration/signals.md`.

What it covers. Every part of it moves a build's work out of
`SecondChance/Builders/` and into the Wrappfile and the modules it uses:

- **One runner carries out every plan** (decisions 1 to 3). A builder no
  longer has a `switch` over steps of its own. What's left of each builder
  is a *source*: it finds out which program and edition is being built and
  gives the runner its inputs.
- **Stages are separate trees**, as they are in a Dockerfile (decision 2).
  `COPY --from=<stage>` reads another stage's tree. A target built
  `FROM scratch` has none of what an earlier stage needed to get the data
  out.
- **Each instruction is carried out by the module that declares it**
  (decisions 4 to 6). Each module's Swift is its *executor*, and its
  instructions are declared in its `module.yaml`, not in Swift. The core
  carries out `COPY`, `ADD`, `EDIT` and `RUN`, mounts included, which the
  bundle plan left out of scope.
- **A module someone adds can bring Swift of its own**, as a program the
  build talks to (decisions 7 to 10). This replaces the draft's rule that
  "an added module is always data alone". It's written against the same
  Swift API as a shipped module's executor, so a module we take over is
  compiled in with its code unchanged (decision 11).
- **A layer at every expensive step** (decisions 12 to 16). Every step has
  a key. A layer is kept where the module says a step is expensive, at the
  end of a stage that another stage is built from, and where the Wrappfile
  asks for one. A build starts from the deepest layer that matches.
- **Progress events owned by the runner** (decisions 17 and 18). The
  runner publishes the events that come from a step's place in the plan
  itself. Modules emit through one typed emitter, and every event is
  recorded with its step so a layer can replay it.
- **Signals, for the build** (decision 19). This builds the signals plan's
  `SIGNAL` and `WATCH`, and uses them in builds: a step's signs of
  progress (`--alive`), its end (`--done`), and the installer's stall watch
  written as a signal.
- **Sources and what's left in the app** (decisions 20 to 22): the person's
  questions, the update source, and where the code ends up, each shipped
  module's Swift in a package of its own.
- **Stores** (decision 23): named folders kept outside the app, which
  steps and launches mount, in place of volumes and cache and secret
  mounts, with retention, scope and locks.
- **What a build may read on the Mac** (decision 24), **`APP`** (decision
  25), and **`wrapp-builder`** (decision 26), the builder's own tool.

## The decisions at a glance

The current answer to each, as settled by 2026-11-05. The decision itself
is the detail; where this and a decision disagree, the decision is right
and this is stale.

| # | Decision | In short |
| --- | --- | --- |
| 1 | One runner | `PlanRunner` carries out every plan; builders become sources that identify the game and give inputs. |
| 2 | Trees | Trees start empty and hold only what steps made; a linear chain shares one tree, branches clone. `USE` plans a module's setup (a core `ENGINE` step, then the module's `setup:` steps, such as `WINE.HELPERS` and `WINE.PREFIX`). The template's files are laid in by the assembler at the end, reserved by its file list. |
| 3 | The core's instructions | `COPY`, `ADD`, `EDIT` (fails on a missing file unless `--create`), `RUN` and mounts (`bind`, `fetch`, `store`); `bind`'s `source=` reads like `COPY`'s; targets are path-typed (`D:` is a drive); a skip goes into every later key. |
| 4 | Executors | A module's Swift is its executor, against `WrappModuleKit`'s `ModuleExecutor` and `StepContext`; `context.runProgram` runs programs by path type, with an exit code. |
| 5 | `module.yaml` declares | Instructions, options, `setup:`, `reads-data:`, mount fields; every declared option is carried out or removed; `when-changed` compares planned text. |
| 6 | Shipped executors | Compiled in, named by `native:`. |
| 7 | Community module programs | A Swift program, out of process, written against the same API. |
| 8 | The protocol | JSON-RPC 2.0 over stdio, matching `StepContext` and `ModuleExecutor` call for call (less `hello` and `$/cancelRequest`); `runProgram` mounts follow the host path rule. |
| 9 | What added modules can't do | Path types, runtime and test facets, sources, engines. |
| 10 | Trust | A warning at import; pinned as imported; a signed copy checked by cdhash; sandbox decided by phase 9. |
| 11 | Graduation | One API, portable executors tested out of process; the steps are in `docs/plans-for-consideration/module-graduation.md`. |
| 12 | Layers | Every step keyed; layers kept where suggested; the deepest hit restored, walking back over stages; locks held for steps that can't ask; policy `all`, `modules` or `off`. |
| 13 | `LAYER-HINT` | Blocks are hints only (outermost wins); functions expand at the call site; no `--always-run` or `--cache-key`. |
| 14 | Keys | Parent key, planned text, files and data tables read, input fingerprints (listings), skips, the executor's revision number, `LayerKey.formatVersion`; not the module's release. Revision numbers are raised by hand, checked against a source hash by `sc release` and `sc test integration`. Steam and Big Fish installs are keyed on the game and may be stale. |
| 15 | Checkpoints | Wine stopped before a layer is kept; costs logged, under load too. |
| 16 | Store runs | Consecutive steps using a store the same way; opened and closed by the runner; no layer inside; `LAYER-HINT` edges end them; identification is a run in a throwaway clone. |
| 17 | Events | The runner publishes the build's shape; executors emit typed and module events, each kind lasting or a moment; `EMIT "<string>"` is passed on unread; Second Chance reads its own strings from `emit-vocabulary.yaml`. |
| 18 | Replay | Only lasting events are kept with a layer and replayed, tagged `replayed`. |
| 19 | Signals | `SIGNAL`/`WATCH` for builds: `--alive`, `--done`, `--asks`, `EMIT --on`, the installer's stall watch. |
| 20 | Sources | `identify` and an `InputProvider`; the edition from detection; questions through `context.ask`. |
| 21 | Updates | Second Chance's: `updates` (a list) and `previous` (a tree) as inputs; module update stages chained; the caller gives the app's id. |
| 22 | Where the code goes | Each module's Swift a package of its own (executor, kit, events) beside its data; WineKit is the wine module's kit; windows and prompts stay in `SecondChanceKit`; `wrapp-builder` its own package. |
| 23 | Stores | `STORE` with `--retention`, `--scope`, `--exclusive`; `LOCK`; `type=store` mounts with `snapshot`; keep stores not used at build, except by their own module's executor; one kept Steam sign-in, 1.1.0's paths moved and linked back. |
| 24 | Host paths | Read only if allowed (`allow-paths`, given by the caller from the manifest), inside an input, pinned by checksum, or `--allow-path` (`*` for any). |
| 25 | `APP` | A step writing `Info.plist`; the caller's id wins, else `APP --default-id`, else an error. |
| 26 | `wrapp-builder` | The builder's own tool: check, plan, build, fmt; knows nothing of Second Chance's; `--template` for now. |
| 27 | Fullscreen | Wine's helper makes a program fullscreen when it asks to be; `--wine.window` overrides; ScummVM and DOSBox stay fullscreen; `tests.window` says what a test expects. |
| 28 | `--wine.cursor-lock` | The cursor lock is the launch's choice, never inferred; launches recorded before the option keep today's inference. |
| 29 | cabextract | The wine module's prepared engine keeps Sikarugir's cabextract in `build-tools/`, on winetricks' PATH at build time, never installed into a wrapp. |

## Why

A Wrappfile is meant to say what a build does, and the bundle plan made
every line of one true (its decision 18). But it's still the builders that
carry the lines out, and they do it by recognising steps' shapes:

- **There are five copies of a step runner.** `DiskWrappBuilder`,
  `HerDownloadWrappBuilder`, `SteamWrappBuilder`, `BigFishWrappBuilder`
  and `UpdateWrappBuilder` each have their own
  `switch (step.module, step.instruction)`. `DownloadWrappBuilder` runs
  only `COPY`. `WineSteps` and the `EDIT --from-data=ini` case are copied
  into all of them. A step one builder doesn't recognise fails there as
  "this flow can't run …", even if another builder could run it. That
  makes a source's builder the thing that decides which Wrappfiles work,
  and the Wrappfile only partly so.
- **A module's Swift is spread around the app.** The installer module's
  code is `GameInstallerRunner`. Nancy-drew's is `WrappBuildHelper.configureGameINI`,
  `GameInstallerRunner+Patches` and `NancyDrewModule`. Steam's is mostly
  `SteamWrappBuilder`, and Big Fish's is `BigFishWrappBuilder`. Wine's is
  split between `WineSteps`, `WineManager` and the disc builder's
  drive-letter code. None of it lives with its module, so a module's
  `native:` is a name and not the place to look.
- **Caching is done per builder.** `InstallLayer` caches "everything the
  disc or Her plan does" as one layer, `WineBuild.prefixLayerKey` caches
  the prefix, and nothing else is cached. A Steam client stage (minutes),
  a patch, or a winetricks verb in a game's own stage is redone every
  build. One wrong code revision number, raised by hand, makes a whole
  install stale.
- **A module someone adds can't do anything new.** The draft made added
  modules data alone, for trust (its "Trust" section). An added module can
  only combine instructions the shipped modules already have. But
  supporting a new store, a new engine helper or a new installer family
  needs Swift, and today that has to ship inside Second Chance.
- **Losing a progress event is easy, and only shows in the integration
  test.** Each builder publishes its own events around its own switch.
  AGENTS.md's warning ("every `bus.publish` moves with it") is the only
  thing protecting them.

## Where things stand

- **`BuildModule`** (`Packages/WrappBuilder/Sources/WrappBuilder/Modules/BuildModule.swift`)
  is metadata. It declares `instructions`, `stages`, `coreOptions`,
  `coreOptionRoles`, `mountFields`, `providedFiles` and an engine's
  `prepare`. It carries out no step. The checker and planner find these
  through `BuildModules.native(_:)` (`BuildPlan.swift:803`,
  `WrappfileChecker.swift:256`), so a module without Swift can declare
  nothing.
- **`native:` is shipped-only.** The schema says so
  (`Modules/module.schema.json`, "only a shipped module may name one"), and
  so does the draft's Trust section. **Modules someone adds aren't loaded
  at all yet.** The draft designed `~/Library/Application Support/Second
  Chance/modules/<id>/<release>/` and importing, but every `ModuleLoader`
  reads `Contents/Resources/Modules` only.
- **Builders recognise steps** (`grep -n 'case ("' SecondChance/Builders/`):
  `KEEP-DISCS` and `INSTALLER.RUN` only in the disc builder,
  `HER-DOWNLOAD.INSTALL` in Her's, `STEAM.*` in Steam's, `BIG-FISH.*` in
  Big Fish's, and patches in the disc, Her and update builders
  (`GameInstallerRunner.isPatchStep`).
- **`RUN` and mounts are carried out for three shapes only**, the patch
  function's (the bundle plan's decision 18: "a small runner for three
  shapes, not the draft's generic one").
- **All of a plan's stages share one temporary wrapp.** A target built
  `FROM scratch` (a ScummVM game's `scummvm` stage) still has the prefix
  that an earlier stage used. `cleanupUnusedEngine` and `STEAM.REMOVE`
  take it away afterwards.
- **Layers.** `LayerStore` and `LayerKey` are generic (in the package;
  `LayerCachePolicy` is app-side, in `InstallLayer.swift`).
  Two kinds of layer use them: the prefix (`WineBuild.prefixLayerKey`,
  `prefixCodeRevision = 2`) and the install (`InstallLayer`, app-side,
  `codeRevision = 1`). The install layer replays a fixed list of events
  (`InstallLayer.Recorded`). Steam and Her's Mac downloads aren't cached.
  The policy is `all`, `prefix` or `off` (`LayerCachePolicy`), and it's
  `prefix` under test.
- **Events.** `WrappBuildEvent` (`SecondChance/Models/AppEvent.swift`) has
  around twenty cases. Some come from the build's shape (`.progress`,
  `.started`, `.completed`, `.failed`). Some are what a person must see or
  do (`.instructions`, `.stepProgress`, `.steamSignInNotice`). The rest are
  facts the build learns (`gameDetected`, `installerResolved`,
  `gameExeDetected`, `patchApplied`, `steamGamesOwned`, …). Steps already
  take `--progress=<key>` (`InstructionSpec.everyStep`), which
  `WineManager.progressText` turns into localised text.
- **The signals plan isn't built.** It covers `SIGNAL`, `WATCH` and
  `SERVICE --ready`, all at launch, with "build steps waiting on a signal"
  as its third phase "when an installer needs one".
- **Interactive steps.** A build asks the person things in the middle of
  a step: disc 2, which new program is the game, carrying on after a
  failed patch, signing in to Steam or Big Fish, which owned game, the
  launch mode. All of it goes through `WrappBuildInput`, which also covers
  headless runs.

## Decisions

### 1. One runner carries out every plan

`PlanRunner` carries out a `BuildPlan`: its stages in order, and each
step through whoever carries out its instruction. Any plan that checks can
be built by any source. A plan's steps are no longer something each source
interprets: a step is either carried out or it's a module's bug.

- **A source doesn't see steps.** It names the program, the edition, the
  choices and how to get each input, then hands over to the runner.
- **"This flow can't run …" goes away.** A step whose instruction no
  executor declares is caught when the plan is checked, not when it's
  built (decision 5).
- **The order is the plan's.** Today's "app steps after the prefix steps,
  outside the install layer" (`runAppSteps`) falls out of decision 2: they
  belong to a different stage.

### 2. Stages are built in trees

Each stage is built in a tree: a folder laid out as a wrapp's `Contents/`,
in the build's working folder.

- **A stage carries on in its parent's tree when nothing else needs the
  parent**, as a Docker layer stack does. It gets a tree of its own, a
  clone of its parent's (`clonefile`, as layers are restored), only when
  the parent is used again: by a second stage built `FROM` it, or by a
  `COPY --from` that runs after the child has started changing it. The
  planner knows which from the plan, so a linear chain of stages is one
  tree, and clones are made only where stages branch. Layers are still
  taken at steps, whichever tree a step is in.
- **Trees aren't layers.** A tree is a working folder for one build, where
  steps run; how many there are is only about saving copies within that
  build. Layers are the cache across builds: one bucket in the layer store,
  each a full snapshot of a tree after some step (a clone, sharing its
  blocks), whose key is made from its parent's key and the step's own
  inputs. So the layers form one DAG, the wine prefix's layer under every
  Wine game's, and any build of any Wrappfile restores whichever node its
  keys match, whichever folder the step that made it ran in. **`FROM scratch` starts from an
  empty folder**, and a module stage (`FROM --module=wine@10 prefix`) from
  that stage's tree, which itself started empty.
- **A tree holds only what steps made.** That's what makes a layer's key
  cover everything in it: there's nothing in a tree that no step put
  there, so nothing a key could miss. Two things a wrapp has today that
  steps don't make come in this way:
  - **an engine, and a module's setup, are steps**, planned when a stage
    first `USE`s the module (below);
  - **the template's files are added by the assembler** after the last
    step (below).
- **`USE` sets a module up in a tree that doesn't have it yet.** The first
  `USE` of a module in a tree plans its setup steps there, shown in
  `sc bundle plan` like any step:
  - **for a module with an engine** (`wine`, `scummvm`, `dosbox`), a core
    `ENGINE <module>@<version>` step, which the runner carries out itself
    (`EngineInstall`, from the engine store), so no executor is needed for
    it, and ScummVM and DOSBox need none at all. It puts the engine where
    the finished app has it (Wine in `SharedSupport/wine` and its
    frameworks in `Frameworks/`; ScummVM and DOSBox in `MacOS/`, beside the
    launcher, as today). Its key has the engine's prepared hash
    (`EngineTree`), so every key after it changes when the engine does;
  - **then the module's own setup steps**, the instructions its
    `module.yaml` lists under `setup:`. The wine module's are
    `WINE.HELPERS`, which lays in the in-process helpers
    (`Frameworks/in_process_helpers.dylib`, keyed on its hash), and
    `WINE.PREFIX`, which makes the prefix (wineboot), as `USE wine` does
    today. The helpers are the wine module's: the Mac driver loads them
    (`EnginePreparer`'s `helpersReference`), and builds need two of them,
    the Cocoa start wait in every Wine program and Big Fish's hidden
    windows (`docs/wine-in-process-helpers.md`). Their source and build
    script move from `WrappTemplate/InProcessHelpers/` to the wine module's
    package. The wine module also provides winetricks, which
    `WINE.WINETRICKS` runs and keys on its hash.

  Every later step runs the real engine, helpers and prefix, at the paths
  the finished app will have. A stage built from one that has the module
  plans no second setup. A target built `FROM scratch` that never `USE`s
  Wine has no Wine, so `installMissingEngines` and `cleanupUnusedEngine`
  go once every builder has moved (phase 6).
- **An `ENGINE` step makes the tree's engine the one it names.** If the
  tree already has that engine at that prepared hash (`engines/<module>.json`),
  it does nothing; if it has another, it replaces it; if it has none, it
  installs it. So a tree that came in with an engine, such as an update's
  `previous` (decision 21), ends with the plan's. The planner treats an
  input tree as having whatever engines its `engines/*.json` record.
  Layers hold engines, but as clones that share their blocks, so a layer
  costs almost nothing for it.
- **The template's files are laid in by the assembler, after the last
  step**: the launcher and what it brings, by the template's own file list
  (what the built `WrappTemplate.app` holds), and its `Info.plist`, merged
  with the tree's (decision 25).
  - **The template's files are reserved, not its folders.** A step that
    writes to a file the template has is an error naming it, so a tree
    can't replace the launcher. An engine's files beside them (ScummVM's in
    `MacOS/`, Wine's frameworks in `Frameworks/`) are fine: no engine file
    shares a name with a template file, which the assembler checks, as
    `EngineInstall` checks today the other way round.
  - **A tree that came in with template files** (an update's `previous`)
    has them replaced, so an updated app has this Second Chance's launcher.
  - **Nothing a build runs needs the rest of the template.** The helpers a
    build needs are the wine module's (above). Because the template comes
    at the end, a Second Chance update brings a new launcher to an app
    restored entirely from layers.
- **`COPY --from=<stage> <path> <dest>` reads the named stage's tree**, as
  in Docker. `COPY --from=${input.x}` reads an input.
- **The target's tree is the wrapp.** The other stages' trees are
  discarded when the build ends, on success or failure.
- **So a ScummVM game built from Her's or Steam's download has no prefix
  to remove.** Its target is `FROM scratch` and never uses Wine, so it has
  no prefix and no Wine. For a target that is built `FROM` a Wine stage,
  what's taken out is still written as a step (`STEAM.REMOVE`).
- **Each build has a working folder**, `builds/<build id>/`, holding a
  `<stage>.app` per tree, so `Wine(wrapp:)` and `WrappLayout(app:)` work on
  a tree unchanged. It's registered with today's temporary-wrapp
  tracking as one unit:
  - an owner file names the build's process, and the stale sweep removes
    a folder whose owner has gone and that's more than 6 hours old;
  - quitting ends Wine in every tree in it;
  - the free-space check looks at its volume;
  - debug mode keeps it;
  - the target's tree is moved out when the app is saved, or copied if
    that's another volume.
- **It doesn't stop layers being shared.** A layer lives in the layer
  store, keyed by what made it, not in any build's folder. A build
  restores one by cloning it from the store into its own tree, and keeps
  one by cloning its tree into the store. So two builds, of the same
  Wrappfile or different ones, share every layer whose key they share:
  the wine module's `prefix` stage under every Wine game, for one.
- **Trees are clones on one volume.** The working folders go in the
  per-user temporary folder (`$TMPDIR`), not in `~/Library/Caches` beside
  the layer store, which macOS may empty when the disk is nearly full,
  mid-build. Both are on the system volume, so clones between them cost
  nothing. If they're on different volumes, the clone falls back to a
  copy, and the log says so, as layers already do.
- **Debug mode's kept folders hold no sign-in.** A working folder kept for
  debugging has every store run's contents taken out as the run closes
  (decision 16). A tree whose run never closed (a build that crashed) is
  deleted whole by the stale sweep, debug mode or not, since only its
  module's executor could take a sign-in out of it, registry value and
  all.

**Why trees, and not one wrapp for every stage:** a stage is then what its
steps made, with nothing left over, so its layer (decision 12) is exactly
its tree. And a Wrappfile means what a reader who knows Dockerfiles would
expect it to.

### 3. The core carries out its own instructions, `RUN` and mounts included

`COPY`, `ADD`, `EDIT`, `MOVE`, `REMOVE` and `RUN` are carried out by the
runner. The bundle plan put "carrying out `RUN`'s programs and mount
fields" out of scope. Here it becomes generic:

- **`RUN <program>` runs through the module its path type belongs to.**
  A `wine:C:/…` program goes to the wine module's executor
  (`runProgram`). That is the same rule `LAUNCH` follows. A program with
  no engine (a Mac path) is refused, as the draft's Trust section requires
  ("runs programs only inside an engine").
- **Mounts are carried out by mount realisers**, one per core type:
  `bind`, `fetch` and `store` (decision 23, which replaces `cache` and
  `secret`). Each puts something where `target` says before the step and
  takes it away after. Each step that needs a mount says so with its own
  `--mount`, even when the step before had the same one. That's more to
  write, but it makes every use of mounted data plain where it happens.
- **`bind` mounts anything the step may read, named as `COPY` names its
  source**:
  - `source=` is read as `COPY`'s first argument is: a file of the
    bundle's (`source=assets/disc.iss`), a module's
    (`source=module:nancy-drew:/assets/x.au3`), or an input's path or
    something inside it (`source=${input.disc-1}`,
    `source=${input.installer}/data`). Which host paths it may read is
    decision 24's rule;
  - a bundle's and a module's own files are always read-only;
  - there is no `from=`. Another stage's files reach a step through
    `COPY --from=<stage>`, as they do today.

  ```dockerfile
  RUN --mount=type=bind,source=${input.disc-1},target=D: D:/setup.exe /S
  RUN --mount=type=bind,source=assets/disc.iss,target=C:/setup.iss …
  ```

- **How `bind` puts it there:**
  - **a file** is cloned into place (`clonefile`, which costs nothing on
    the same volume; a copy across volumes). Not a hard link or a
    symbolic link, since a program writing to either would change the
    original: the person's installer, or a bundle's file;
  - **a folder** is cloned too, on the same volume, where that costs
    nothing. Installers write logs and temporary files beside themselves,
    and a link would let them change the person's own folder, such as a
    Her download's unpacked files. Only a folder on read-only media (a
    disc, a mounted image) is linked rather than copied when it's on
    another volume, since nothing can write to it, and copying a disc for
    every step would cost minutes. Any other folder on another volume is
    copied. A bundle's or a
    module's folder is cloned instead, so the original stays untouched;
  - **a disc image is never seen by `bind`.** The disc module's input
    provider always hands a disc input as a mounted folder, whether the
    person gave a disc or an image (decision 20), so there's one owner of
    mounting images, and a disc and its image key the same listing. The
    Wrappfile syntax says nothing about images, which Second Chance
    doesn't offer people.
- **A mount's `target` is a path like any other, and its path type says
  who mounts it.** Path types are registered by modules
  (`PathTypeRegistry`), as for `COPY`, `LAUNCH` and `RUN`'s program, so a
  Windows-style target is the wine module's:
  - **a bare drive** (`D:`, `D:/`) gives the mount that drive letter for
    the step. Saying `D:` is all an installer that expects its disc on D:
    needs, so there's no `wine.drive=` beside a `target`, which would say
    the same thing twice. A drive the prefix already has is an error
    naming it, rather than a folder quietly made inside it. That can be
    checked when planning, since the prefix's drives come from its
    `WINE.DRIVES` and `WINE.MOUNT` steps;
  - **a path in a drive the prefix has** (`C:/setup.iss`,
    `C:/mountpoint`) puts the mount there. Its parent folder must exist,
    and the last part may be new. Whether a folder exists can only be
    known when the step runs, not when planning, so a missing parent fails
    the step then, naming the path;
  - **a path in the wrapp's own files** (`/SharedSupport/…`) is the
    core's.

  A module's mount fields are only for what a path can't say, such as the
  drive's type: `wine.cdrom`, for a game that checks its disc is in a
  CD-ROM drive, as `WINE.MOUNT --cdrom` does for a drive kept at launch.
- **`RUN`'s program is found the same way.** `RUN D:/setup.exe` is the
  wine module's, by its path type, as the first bullet above says. No
  `--with` is needed.
- **The patch function's three shapes become three ordinary steps.**
  `GameInstallerRunner.runPatchStep` and `isPatchStep` go.
- **`--on-failure=ask`** is carried out by the runner for every step
  (`WrappBuildInput.confirmPatchFailure` becomes
  `confirmStepFailure`). A step that fails and is carried on without is
  recorded by its `--name` (`patchFailed(id:)` becomes the general
  `stepSkipped(name:, message:)`, decision 17).
- **A skip is part of every later key.** A skipped step keeps no layer,
  and every step after it in the stage, and in any stage built from it,
  has `skipped: <name>` among its key's inputs (decision 14). So:
  - a later build where the step succeeds never restores a tree made
    without it;
  - the skipped step is always tried again, since it has no layer;
  - if it fails again and is skipped again, the steps after it find the
    layers the last such build kept.

  That replaces today's rule that an install with a failed patch isn't
  kept at all (`InstallLayer`).
- **`EDIT --ini`** is the core's own (it is `WineSteps.editINI` today, and
  has nothing to do with Wine).
- **`EDIT` fails if its file doesn't exist**, naming the path, unless it
  says `--create`, which makes the file first. So a line that might make a
  file says so. That's for every format `EDIT` writes (`--ini`,
  `--plist`). Today's `--must-exist`, which is about the *settings* (each
  must already be in the file), is renamed `--keys-must-exist` in phase 1,
  so the two can't be mistaken for each other. **`EDIT --from-data=ini` becomes the
  nancy-drew module's own instruction, `NANCY-DREW.CONFIGURE-INI <folder>`**,
  used by its `configure-ini` function. A core instruction is never handed
  to a module because of an option's value, so every instruction has one
  executor, and decision 5's test can say which. The nancy-drew module gets
  a `native:` for it.

### 4. Each module's Swift is its executor

Each module whose instructions do something has an executor, one value per
build. The protocol and `StepContext` are declared in `WrappModuleKit`
(decision 7), not in the runner's package, because the same API serves
executors compiled in and executors in a module's program (decision 7):

```swift
/// A module's part in carrying out a plan: its instructions, and its
/// additions to the core's (mount fields, `RUN`'s programs of its path
/// type). Made once per build; it may hold what lasts between steps (a
/// running Steam) in its session.
public protocol ModuleExecutor: Sendable {
    /// The instructions it carries out, which its module's YAML must
    /// declare (decision 5). Its revision, for its steps' keys, is kept
    /// in the module's `executor-revisions.json`, checked against a hash
    /// of its source (decision 14).
    static var handles: [String] { get }

    /// What a step's key needs beyond its text: a disc's listing, an
    /// installer's fingerprint (decision 14).
    func keyInputs(for step: PlannedStep, in context: StepContext) async throws -> KeyInputs

    /// Carry the step out in `context.tree`.
    func run(_ step: PlannedStep, in context: StepContext) async throws

    /// Run a program of this module's path type (`RUN wine:C:/…`).
    func runProgram(_ program: String, arguments: [String], step: PlannedStep, in context: StepContext) async throws

    /// Make the tree safe to keep as a layer: nothing running in it, and
    /// everything it holds written to disk. Wine ends its session, so
    /// wineserver has written the registry (decision 15).
    func checkpoint(_ context: StepContext) async throws

    /// A run of steps using one of its stores starts (decision 16): take
    /// it up, such as restoring a sign-in and starting Steam.
    func open(_ store: StoreHandle, in context: StepContext) async throws

    /// The run has ended: put it away, such as stopping Steam, saving the
    /// sign-in back and taking it out of the tree. Also on failure and
    /// cancel.
    func close(_ store: StoreHandle, in context: StepContext) async throws

    /// End whatever the build started, on success, failure or cancel.
    func finish(_ context: BuildContext) async
}
```

- **`StepContext`** is a protocol. It gives an executor everything it
  uses and nothing else:
  - the step's tree, and other stages' trees by name;
  - the plan's files;
  - the inputs, resolved only when asked for, so disc 2 is asked for when
    it's used;
  - the emitter (decision 17) and the person (`context.ask`,
    decision 20);
  - `context.runProgram(_:arguments:mounts:env:alive:done:asks:timeout:)`,
    which runs a program the way a `RUN` step would: by its path type,
    through the module that registered it (a `C:/…` program through the
    wine module), with the same watchdog, stall watch and logging, and
    returns its exit code. It's how a `RUN` step and a module program run
    things. A shipped module's executor that needs more of Wine (a desktop
    kept up, a program started and stopped later, waiting for every
    program in the session) uses the wine module's kit directly, as a
    module it depends on (decision 22);
  - its stores, by name, for a store taken as an option
    (`context.store("sign-in")`, decision 23);
  - fetching by hash through the download cache;
  - the log.

  The runner implements it directly (`LocalStepContext`). A module's
  program gets an implementation that forwards each call over the
  protocol (`RemoteStepContext`, decision 8). An executor can't tell the
  two apart.
- **Executors replace the builders' cases one for one.** In wrapp terms:

  | Module | Its executor carries out | Taken from |
  | --- | --- | --- |
  | `wine` | `DRIVES`, `REGISTRY`, `WINETRICKS`, `MOUNT`, `KEEP-DISCS`, and its setup steps `HELPERS` and `PREFIX` (decision 2); `RUN` of `wine:` programs; mount targets that are Windows paths | `WineSteps`, `WineManager.makeWinePrefix`, `DiskWrappBuilder.copyGameDisks` and `mountGameDisksIntoWine` |
  | `autoit` | none of its own: it provides AutoIt (`module:autoit:/AutoIt3.exe`), which the installer module depends on | `WrappTemplate/setup-autoit.sh`, `AutoItService` |
  | `installer` | `INSTALLER.RUN`, `--patch` included | `GameInstallerRunner`, `InstallerPlan`, `InstallStallWatch` |
  | `nancy-drew` | `NANCY-DREW.CONFIGURE-INI` (was `EDIT --from-data=ini`) | `WrappBuildHelper.configureGameINI` |
  | `her-download` | `HER-DOWNLOAD.INSTALL` | `HerDownloadWrappBuilder`, `CiderPackage` |
  | `steam` | `CLIENT`, `INSTALL`, `REMOVE`, and opening and closing its sign-in store | `SteamWrappBuilder`, `WrappBuildHelper.installSteamClient` |
  | `big-fish` | `MANAGER`, `INSTALL`, and opening and closing its sign-in store | `BigFishWrappBuilder` |
  | `disc` | the `disc-N` inputs: mounting an image, the listing for the key | `DiskWrappBuilder.mountIfImage`, `ISOMounter` |

- **A step's only results are its tree and its events.** An executor may
  keep live things in its session between steps, such as a running Steam
  or a mounted image. It may not keep a *result* that a later step reads.
  The bundle plan already made an install's result a path (`--creates`,
  linked if the game went elsewhere), so nothing needs one. This rule is
  what makes every step cacheable (decision 12).
- **Sessions start when first needed.** A build restored from a layer
  past `STEAM.INSTALL` never starts Steam.

### 5. Instructions are declared in `module.yaml`

What `BuildModule` declares in Swift today moves into each module's
`module.yaml`, under `build:`. That covers `instructions` (options and
their kinds and roles, arguments, `required`), `coreOptions`,
`mountFields`, `provided-files`, and the new `layer` field (decision 13):

```yaml
build:
  instructions:
    KEEP-DISCS:
      options: { into: { kind: value, role: location }, combined: { kind: value, role: location } }
      required: [into]
      arguments: { count: "1...", roles: [input] }
      layer: suggested            # expensive: a layer after it is worth keeping (decision 13)
  core-options:
    LAUNCH: { graphics: value, clean-exit-log: value, clean-exit-line: value }
  mount-fields:
    bind: [cdrom]               # wine.cdrom: the drive a bare-drive target makes is a CD-ROM
```

- **The checker and planner read only data.** `BuildModules.native` stops
  being how they learn what a module declares. That's what lets a module
  someone adds declare instructions (decision 7). It also means `sc bundle
  check` needs nothing but the folder.
- **Swift declares nothing the YAML doesn't.** A unit test checks each
  shipped executor against its module's declarations: every instruction
  declared is carried out, and none is carried out that isn't declared.
  The same goes for options: every option an instruction declares is read
  by its executor, or refused if given, so none is accepted and ignored.
  Phase 1 removes or carries out the ones that aren't today
  (`INSTALLER.RUN`'s `--driver`, `--msi-properties` and `--mount`, core
  `RUN`'s `--creates`, and the module schema's `installs-after`,
  `invalidates`, `old-places`, `options-schema` and `volumes`).
- **An instruction says which of its module's data it reads**:
  `reads-data: [ini]` for `NANCY-DREW.CONFIGURE-INI`. A table an executor
  reads in Swift is then in the step's key, as a table a `${…}` value read
  is (decision 14), so editing `ini.yaml` makes those steps fresh.
- **A module lists its setup steps**: `setup: [HELPERS, PREFIX]` for wine,
  the instructions `USE` plans in a tree that doesn't have the module yet
  (decision 2).
  An executor says which instructions it handles as a static list, and the
  test compares that list with the YAML.
- **`BuildModule` keeps what is genuinely code**: an engine's `prepare`,
  `prefixStage`. Everything else moves to `module.yaml`.
- **Path types stay in `PathTypeRegistry`**, in WrappKit, because the wrapp
  reads them at launch (decision 9).
- **The schema gains `build:`**, with the format's `format: 1` unchanged.
  Adding a field is allowed, and no shipped module's release changes
  meaning. Moving the declarations into each folder is a change to the
  folder, so every module gets a new release (`sc module release`).
- **A module update's `when-changed` compares what a stage does, not its
  bytes**, from phase 1 on. The wine module's `wine-prefix` update runs
  when `stages/prefix` changed, and today that's the file's hash, so a
  comment or a reformat would offer every app an update. A wrapp's lock
  records each stage's planned text from phase 1, and `when-changed`
  compares that. A data file is still compared by its contents.
  - There's no transition to handle. No released Second Chance built an
    app with a lock (`docs/wrapp-build.md`), and a released app's
    made-up lock is treated as it is today. So the one-off refresh this
    plan's edits to the file cause reaches only apps built by unreleased
    versions, where running the prefix stage's steps over the old prefix
    again does no harm.

### 6. A shipped module's executor is compiled into Second Chance

`native: "<id>"` keeps meaning "the executor compiled into Second Chance
with this id". That's still shipped modules only. Decision 7 adds a second
way for a module to bring Swift, for everyone.

### 7. A module someone adds can bring a program: its executor

A module may carry a program that carries out its instructions:

```yaml
id: "someone/gog"
release: 1
program: "bin/gog-module"     # a Mach-O in the module's folder: its executor
build:
  instructions:
    INSTALL:
      options: { into: { kind: value, role: location } }
      required: [into]
      arguments: { count: 1, roles: [input] }
      layer: suggested
```

- **It's a separate process**, started by the build when a step first
  needs it, for the length of the build (its session, as in decision 4).
  It talks to the build over its stdin and stdout, a line of JSON per
  message (decision 8). Its stderr goes to the build's log, line by line,
  as a subprocess's output does (`docs/logging.md`).
- **An `ExternalExecutor` in the runner is a `ModuleExecutor`** that
  forwards each call to the program. So the runner sees one kind of
  executor. Everything that applies to a shipped module's executor applies
  to an added one's, including keys, layers, checkpoints and events.
- **It's written in Swift with `WrappModuleKit`**, a new library in
  `Packages/WrappKit`. The library handles the protocol. What the author
  writes *is* a `ModuleExecutor`, the protocol every shipped module's
  executor conforms to, so there's only one API to learn. The program is a
  Swift package of two targets. The library target holds the executor, and
  the executable target is one line, which is all that makes it a program:

  ```swift
  // Sources/GOGModule/GOGModule.swift: the executor, a library target
  import WrappModuleKit

  public struct GOGModule: ModuleExecutor {
      public static let handles = ["INSTALL"]
      public init() {}

      public func run(_ step: PlannedStep, in context: any StepContext) async throws {
          let installer = try await context.input(step.arguments[0])   // a folder, given as D: below
          context.substep("Installing the game")
          try await context.runProgram("D:/setup.exe",
                                       arguments: ["/VERYSILENT", "/DIR=\(step.option("into") ?? "")"],
                                       mounts: [.bind(source: installer, target: "D:")])
      }
  }

  // Sources/gog-module/main.swift: the program, an executable target
  import WrappModuleKit
  import GOGModule
  try await ModuleProgram.serve(GOGModule())
  ```

  The protocol is plain JSON, so a program in another language would work.
  But only Swift is supported and documented, and only a Swift executor
  can graduate (decision 11).
- **It does most things by asking the build.** The protocol offers what a
  build already does carefully: running a program as a `RUN` step would
  (a Windows one through the wine module, with `Wine.run`'s watchdog,
  crash-port clearing and logging), fetching a download by its hash,
  emitting events, asking the person, and logging. A module program that uses only these needs no file access
  outside the step's tree. Decision 10 is about whether it's *made* to.
- **A module with a program is still checked and released as any module
  is.** Its folder is hashed into its release, the program included, so a
  release never changes. The program's hash is also part of every step
  key that uses it, so a new build of the program means fresh layers
  (decision 14).
- **One architecture.** The program must contain arm64 and x86_64
  (`lipo -archs` is checked at import), because the build runs on either.
  A program built for one only can't be imported, and the message says
  which architecture is missing.
- **Shipped modules don't use it.** They're compiled in, for speed.
  Each shipped executor that needs only `WrappModuleKit` (the portable ones,
  decision 11) is also run out of process in a unit test, through
  `ExternalExecutor` and a test program serving it. So the protocol is
  exercised by real executors in `sc test unit`, and the two ways of
  running one can't drift apart.

**Rejected:**

- **Loading a Swift library into Second Chance** (`dlopen` of a
  `.dylib` or `.bundle`). Library validation is off (AGENTS.md), so it
  would load. But Swift has no stable ABI between compiler versions for a
  library that isn't built as a resilient framework. A crash in it would be
  Second Chance's crash and would land in our reports. And its code would
  run inside the app's process, with all of the app's state in reach.
- **Compiling Swift when a module is imported.** That needs Xcode's tools
  on the person's Mac, which nobody playing Nancy Drew has.
- **JavaScript in JavaScriptCore**, which already runs ajv for checking.
  It's cheap to host, but the user wants Swift. A module also needs the
  build's own functions either way, so the protocol in decision 8 is the
  real work, and the language is only a front end to it.

### 8. The module protocol

**JSON-RPC 2.0**, one message per line on the program's stdin and stdout
(newline-delimited: Swift's `JSONEncoder` writes no newlines unless asked
to). Either side may send requests. A request has an `id` and gets a
reply with the same `id`; a notification has none and gets no reply.
JSON-RPC's request and response, notifications, error objects and ids
are a shape readers already know from the Language Server Protocol,
which uses the same, so the protocol doesn't invent any of them.

```text
build → program   {"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocol":1,"module":"someone/gog","release":1}}
program → build   {"jsonrpc":"2.0","id":1,"result":{"protocol":1,"handles":["INSTALL"]}}
build → program   {"jsonrpc":"2.0","id":2,"method":"keyInputs","params":{"step":{…PlannedStep…}}}
program → build   {"jsonrpc":"2.0","id":2,"result":{"inputs":[{"name":"installer","value":"size:…,mtime:…"}]}}
build → program   {"jsonrpc":"2.0","id":3,"method":"run","params":{"step":{…},"stage":"gog-files"}}
program → build   {"jsonrpc":"2.0","id":90,"method":"runProgram","params":{"program":"D:/setup.exe","arguments":["/VERYSILENT"],"mounts":[{"type":"bind","source":"input:installer","target":"D:"}]}}
build → program   {"jsonrpc":"2.0","id":90,"result":{"exit":0}}
program → build   {"jsonrpc":"2.0","method":"emit","params":{"event":{"substep":"Installing the game"}}}
program → build   {"jsonrpc":"2.0","id":3,"result":null}
build → program   {"jsonrpc":"2.0","id":4,"method":"checkpoint"}   …   {"jsonrpc":"2.0","id":9,"method":"finish"}
```

- **`emit` and `log` are notifications**; every other call is a
  request.
- **The protocol is specified as a JSON Schema**, generated from the
  Swift types that `WrappModuleKit` encodes and decodes (`sc generate`),
  and checked in beside `docs/module-programs.md`. A test fails when the
  checked-in schema isn't what the types make, as the generated catalog's
  test does.
- **The protocol is `StepContext` and `ModuleExecutor` on the wire, and
  nothing more**, apart from what the protocol itself needs: `hello`, which
  agrees a version, and `$/cancelRequest`. Every other call is one of their
  methods, and every method of theirs has a call. A method added to either
  protocol gets its call in the same change. A test compares the schema's
  methods with the two protocols', less those two, and fails when they
  differ. That's what keeps graduation (decision 11) a recompile.
- **What the build offers a program** (calls from the program):
  - `input` (an input's path, asking the person if needed);
  - `runProgram`: a program run as a `RUN` step would run it, by its path
    type, with mounts, `--env`, signals and a time limit, replying with its
    exit code (decision 22). Its mounts follow the host path rule
    (decision 24) as a Wrappfile's do: the program's inputs, its own
    module's files, and the stores it took as options. Anything else is
    refused, naming the path, so a sandboxed program can't ask the build
    to bind something it may not read itself. It's the one way
    a module program runs anything: a Windows program goes through the
    wine module like any other, with `Wine.run`'s watchdog, cleared crash
    ports and logging, and the program never builds a Wine command line;
  - `store` (a store the step took as an option, decision 23);
  - `fetch` (a URL and its sha256, through the download cache);
  - `tree` (another stage's tree, read-only);
  - `emit` (decision 17), typed events and plain strings alike;
  - `ask` (decision 20);
  - `log`.
- **What a program is asked** (calls from the build): `hello`,
  `keyInputs`, `run`, `runProgram` (only if the module has a path type,
  which an added one can't, decision 9), `checkpoint`, `open` and `close`
  (a store run's start and end, decision 16), `finish`.
- **Errors** are JSON-RPC error objects. JSON-RPC reserves `-32768` to
  `-32000` and gives `-32000` to `-32099` to servers. Its own codes mean
  what they mean there, and the protocol adds:
  - `-32000`, a recipe problem: becomes `WrappBuildError.buildRecipeProblem`;
  - `-32001`, the step failed: the general failure;
  - `-32800`, cancelled, which is LSP's code for the same, outside
    JSON-RPC's range, used because readers know it.

  The message goes to the log, and the person sees the plain message for
  its kind.
- **Cancelling** is LSP's notification, `$/cancelRequest` with the
  request's `id`, sent either way. The program answers the cancelled
  request with `-32800`. If it hasn't within 10 s, it's ended (SIGTERM,
  then SIGKILL), and the Wine programs it started are ended through
  `wine.server.kill()`, as any cancelled build's are.
- **The protocol has a version.** The `hello` exchange agrees one. A
  program built for a protocol newer than this Second Chance's is refused
  at import, and the message says to update Second Chance.
- **It's documented** in a new `docs/module-programs.md`, with a row in
  AGENTS.md's table.

### 9. What a module someone adds still can't do

- **Path types** (`gog:`). The wrapp resolves them at launch, and a
  wrapp's launch code is ours, signed with Second Chance. A module program
  that ran at launch would be a runtime facet, which this plan doesn't
  build.
- **Run in the wrapp or in WrappPuppeteer.** That would be its runtime and
  test facets (`RuntimeModule`, `TestModule`). It may still add launch
  options that a shipped module reads, as data. Its program runs only
  during a build.
- **Be a source** (decision 20), **or prepare an engine**
  (`BuildModule.prepare`). Both stay compiled in.
- **Shadow a shipped module.** As the draft decided, a shipped module wins
  over an added one with its id, and an added module's id is namespaced
  (`someone/…`).

Each is a later plan if a module needs it. Runtime facets are the obvious
next one.

### 10. Trust, with programs in modules

This changes the draft's Trust section, which said "a bundle's own
instructions stay inside the build" and "an added module is always data
alone". A module program runs on the Mac, not inside an engine. It can do
whatever the person can, just as a Windows program in a wrapp already can
(the draft: "Z: is the whole Mac, and Wine lets programs make Unix
calls"). So the risk is the same kind as an added bundle's, but it's
reached directly rather than through Wine.

- **Importing a module with a program says so, in its own words**, after
  the bundle warning:

  > This adds a part that runs its own program on your Mac while games
  > are being set up. Only add it if you trust the person who made it.

- **It's pinned.** The import records the program's hash with the
  release. A program whose hash doesn't match when it's loaded isn't run,
  and the module is listed with why.
- **It's pinned as imported, and signed as a copy.** `codesign -s -`
  rewrites a Mach-O, so the hash the import pins is the program's as it
  came (and the release records), never the signed file's. The import
  signs a copy beside it, and records that copy's code directory hash
  (cdhash). A load checks the original against the pinned hash and the
  signed copy's cdhash against the record, and runs the copy. That's the
  same reason an engine is hashed before it's signed (`docs/modules.md`).
- **It's runnable.** On import the program is given an ad hoc signature
  (`codesign -s -`, as engines get), and its quarantine attribute is
  removed only after the person agrees. A program the person never agreed
  to is never run.
- **It shows where it came from.** A build that used an added module's
  program says so in its log. A failure report carries the module's id
  and release in `modules`, as a fixed identifier, never its messages
  (`docs/failure-reports.md`).
- **Sandboxed if it can be (decided by a spike, phase 9).** The program
  could run under a sandbox profile that allows writing only to its
  step's tree, its own scratch folder and the download cache, and no
  network, since the build fetches for it. macOS's `sandbox-exec` and
  `sandbox_init` are deprecated but still work on 15 and 26. The spike
  checks that a Swift program using `WrappModuleKit` runs under such a
  profile on both, and how a denial is reported.
  - If it works, every module program runs sandboxed, and the warning
    above loses "on your Mac".
  - If it doesn't, the person's agreement is the protection, as it is for
    bundles. That matches the draft's "kept in proportion".

### 11. A module someone adds can graduate to a shipped one

When a module someone wrote becomes one we look after, it moves into
Second Chance's source with its code unchanged. The design keeps that a
move, not a rewrite:

- **One API.** A module program's executor is a `ModuleExecutor` and
  sees only `any StepContext` (decisions 4 and 7). A shipped executor is
  the same type, with the same context API, given `LocalStepContext`
  rather than `RemoteStepContext`. Nothing in an executor's code says
  which way it's run.
- **Portable executors stay portable.** A shipped executor whose target
  needs nothing of the app's or `SecondChanceKit`'s (only `WrappModuleKit`,
  `WrappKit`'s libraries and other portable executors) is *portable*.
  The `disc`, `wine` and
  `nancy-drew` executors are written that way from the start, and so is
  every graduated one, until a change needs more. A portable executor is
  run out of process in a unit test (decision 7), so a shipped module
  never comes to rely on being in-process without anyone noticing.
  - Every shipped executor is meant to be portable, Steam's and Big
    Fish's included (decision 22). The installer and Her's are portable
    once `GameInstallerRunner` and what it uses move into their module's
    package. Until each has moved, it may depend on the app, and isn't
    portable yet.
- **Executors are packages, one target per module.** Portable shipped
  executors live in `Packages/Modules/<name>/`, a package per module
  (`WineExecutor`, `DiscExecutor`, …), not loose in the app (decision 22).
  A module program is the same shape: a library target holding the executor, and a
  one-line executable target (`ModuleProgram.serve(...)`).
- **Taking a module over is its own plan, for when one is.** Its steps
  (moving the target in, keeping its namespaced id, handing its release
  numbers over, localising its text) and `sc module graduate` are in
  `docs/plans-for-consideration/module-graduation.md`. Nothing needs them
  until there's a module to take over. This plan builds only what keeps
  graduating a move rather than a rewrite: one API, and portable
  executors tested out of process.
- **A module's file is written `module:<id>:/<path>`**: `module:someone/gog:/assets/x.au3`,
  `module:installer:/autoit`. Today's `module:<id>/<path>` can't tell a
  namespaced id's `/` from the path's. Shipped bundles and modules move to
  the new form in phase 1, and the old one is refused with a message
  saying so.
- **A module's stage is named with a flag on `FROM`**:
  `FROM --module=wine@10 prefix`, `FROM --module=someone/gog@1 client`.
  - It's the one place a Wrappfile names a module's version other than
    `USE`, since it must work before any `USE`. Every other mention of a
    module takes the version `USE` gave. A flag sets it apart, as
    Docker's `FROM --platform=` does.
  - The stage's name is then a plain name, like a bundle's own stages,
    so a namespaced id's `/` is never mixed into it, and `<id>@<v>:<stage>`
    would have looked like a Docker image tag.
  - A planned stage records its module as a field, rather than in its
    name, so `PlannedStage.isModuleStage` stops looking for a `/`.
  - Every bundle's `FROM` lines move to it in phase 1, and
    today's `FROM <id>@<version>/<stage>` is refused with a message saying
    so.

### 12. Every step has a key; layers are kept at expensive steps

Docker keys every instruction. This keys every step, but only *keeps* a
layer where one is worth its cost (decision 15 has the cost).

- **A step's key** is its parent's key plus its own inputs (decision 14).
  The parent is the step before it in the stage, or for a stage's first
  step, its `FROM` stage's last step. So keys are a chain, and a change
  anywhere changes every key after it, and none before.
- **A layer is kept after a step when one is suggested there**:
  1. by the module, for an instruction it says is expensive
     (`layer: suggested` in `module.yaml`, decision 13), unless the step
     is inside a `LAYER-HINT` block (decision 13); or
  2. by the plan's shape: the step is a stage's last, and another stage is
     built `FROM` it, or it's a module stage (wine's `prefix`,
     steam's `client`); or
  3. by the Wrappfile: the step is the last of a `LAYER-HINT` block
     (decision 13).

  And never inside a store run, such as the steps that use Steam's
  sign-in (decision 16), or when the policy says not to (below).
  Every suggestion is a hint, and the log says when one wasn't followed,
  and why.
- **A build restores the deepest layer that matches, walking back from
  the target over the stages.** Planning gives every step's text. The
  runner works out keys in order. A step whose key needs a module's
  `keyInputs` (a disc's listing) runs that, which is cheap. For each stage
  still needed, it restores the last kept layer in the store and runs from
  the step after it. A stage is built or restored only if a step still to
  run reads it, through `FROM` or `COPY --from`: if the target's layer
  after a `COPY --from=her-download-files` is in the store, the installer
  stage isn't built at all. A source stage that is needed is restored into
  a tree of its own for the `COPY`. Like Docker, the walk stops at the
  first step whose key can't be known without running earlier steps
  (decision 14).
- **A restored layer replays its steps' events** (decision 18), so the
  screens and tests see what a fresh build would have shown.
- **`InstallLayer` and the prefix layer become ordinary layers.**
  - The prefix is the wine module's `prefix` stage's last step (rule 2).
  - The install is whichever kept layer is deepest in the edition's
    stage. For a disc game that's after its patches, or after the install
    itself, whichever is the deepest hit.
  - `InstallLayer`, `InstallLayer.Recorded`, `InstallLayer.codeRevision`
    and `WineBuild.prefixLayerKey` all go.
- **Locks are taken per layer, and nobody waits on a person.** Today
  `LayerStore.layer(for:make:)` holds the key's lock while the layer is
  made, so a second build of the same game waits and then clones it. That
  stays for the steps between two layers that can't ask anyone anything:
  module stages, and any steps none of which is declared `may-ask` in its
  module's `module.yaml` or opens a store run. So eight cold side-by-side
  builds make the wine prefix once, and the rest wait and clone it, rather
  than all making it under load. Steps that may ask (a disc-2 prompt, a
  Steam sign-in, a wizard) take no lock: a build looks for the layer, and
  if one for that key appears while it's making its own, it throws its own
  away, so one build never waits behind another's question.
- **The policy** (`SECOND_CHANCE_LAYER_CACHE`) becomes `all`, `modules`
  or `off`. `modules` keeps only module stages' layers (the prefix,
  Steam's client, Big Fish's manager) and is the default under test, so an
  integration run still installs every game for real. `prefix` is kept as
  another name for `modules`, so existing `--debug layer-cache=prefix`
  calls still work.

### 13. A Wrappfile's layer hints: `LAYER-HINT` blocks

**A Wrappfile suggests where layers go; it never requires one.** A layer
only saves time. A build that restores nothing makes the same app, which is
what a key means, so "keep a layer here" can't be a promise that a reader
or a later step relies on. Whether one is kept also depends on things a
Wrappfile can't see:

- the policy (`modules` under test, or `off`);
- a store run, such as the steps that use Steam's sign-in (decision 16);
- room on the disk.

So everything a Wrappfile, or a module, says about where layers go is a
hint. The runner follows it when it can, and the log says when it didn't
and why.

**The one hint is a block around the steps it's about.** The parser
already has a `LAYER` … `END` block, from the draft, where it meant "these
steps are one layer". Nothing uses it, and planning flattens it. It
becomes `LAYER-HINT` … `END`, named for what it is. A bare `LAYER` is
refused with a message saying so, as `ARG` is.

```dockerfile
FROM prefix AS disc
USE installer
# One layer for the discs, the install, its patches and its settings,
# rather than one after each: one checkpoint, not five
LAYER-HINT
  WINE.KEEP-DISCS ${input.disc-1} ${input.disc-2} --into=C:/nancy-drew-installer
  INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir} --creates=${const.program}
  DO patch
  DO post-install-setup
END
```

- **`LAYER-HINT` … `END`** says that its steps would be best kept as one
  layer:
  - a layer after its last step is worth keeping;
  - none after the steps before that, whatever their modules suggest.

  It's the draft's grouping, and it's for the draft's reason as well.
  Within a group the Wine session stays up, so an installer and two
  patches pay for one checkpoint, not three (decision 15).
- **There's no hint for "no layer here".** Keeping a step out of a layer
  of its own means putting it in a block with the steps around it, so it
  shares theirs. What can't be said is "no layer at all" for the last
  layer a stage would have. That costs only disk, which pruning looks
  after (`docs/wrapp-build.md#the-layer-cache`). And a stage's last layer is the one that saves a
  rebuild the most work.
- **It only answers suggestions, never the plan's shape.** A layer the
  plan's shape calls for (the end of a stage another builds from, or a
  module stage) is still kept, since later stages and builds start from
  it. A block can't hold a stage's end anyway, because blocks are inside
  a stage.
- **A block is not a scope.** A `VAR` set inside one is the stage's, as
  if the block weren't there. That's unlike an `IF`'s branch, because the
  hint changes nothing the steps do.
- **Blocks hold anything a stage can**: `DO`, `IF`, module instructions.
  A function's steps inside a block are the block's, since they're the
  call site's (below). A block may be inside a function, where it holds
  the function's own steps wherever it's used.
- **A function's steps can be one group wherever it's used**, by putting
  its body in a block:

  ```dockerfile
  # Modules/nancy-drew/functions/patch
  FUNCTION patch
    INPUT id
    INPUT into
    LAYER-HINT
      …   # the patch's ADD, INSTALLER.RUN or RUN
    END
  END
  ```

  Since functions are expanded where they're used, every `DO
  nancy-drew.patch` gets the block too. No function-level setting is
  needed.
- **Blocks nest, and the outermost decides.** A block inside another is
  part of the outer one's single layer, and keeps none of its own. That's
  what lets a bundle group several `DO nancy-drew.patch` calls into one
  layer, although each function groups its own steps:

  ```dockerfile
  # Three patches, one layer after all of them, not one after each
  LAYER-HINT
    DO nancy-drew.patch --id=deception-island-1 --into=${const.install-dir}
    DO nancy-drew.patch --id=deception-island-2 --into=${const.install-dir}
    DO nancy-drew.patch --id=deception-island-3 --into=${const.install-dir}
  END
  ```

- **Hints change no key.** A block isn't a step, and its steps' text is
  the same with or without it. Adding, moving or removing a hint never
  throws a layer away; it only changes which layers the next build
  keeps.
- **A module's suggestion is per instruction**: `layer: suggested` in
  `module.yaml`. The shipped modules suggest a layer after `INSTALLER.RUN`,
  `WINE.KEEP-DISCS`, `WINE.WINETRICKS`, `HER-DOWNLOAD.INSTALL`,
  `STEAM.CLIENT`, `STEAM.INSTALL`, `BIG-FISH.MANAGER` and
  `BIG-FISH.INSTALL`. The core suggests one after `ADD` (a download) and
  `RUN` (a program).
- **A function's steps are the call site's.** Planning already expands
  `DO <function>` into its steps, each with its `origin`
  (`nancy-drew/functions/patch:20 from Wrappfile:16`). For layers, keys and
  everything else, they're treated exactly as if they'd been written where
  the `DO` is: each is keyed as a step of that stage, and each gets a
  layer by the same rules as any other. `DO` itself isn't a step and has
  no key.
  - `DO steam.install` is `STEAM.INSTALL` (a layer suggested), which uses
    the sign-in store. If the next step uses that store too, the run
    carries on and the layer moves to after the run (decision 16). A
    `LAYER-HINT` block's edge ends a run, so a bundle that wants a layer
    between two such steps puts them in separate blocks. The function has
    nothing to do with it.
- **The checker refuses empty blocks**, and has no other rules for hints:
  a hint that changes nothing (a block of one step whose module suggests a
  layer anyway, as the patch function's is) is harmless, so it isn't
  warned about.
- **`sc bundle plan --layers`** shows each step's key (short), the
  function and block it came from if any, and whether a layer would be
  kept after it and why ("module", "stage parent", "`LAYER-HINT`",
  "after a store run", "inside a `LAYER-HINT`"), so a bundle's author can see the cache before building.
- **`sc wrapp build --debug layer-every-step`** keeps a layer after every
  step, hints and suggestions aside, for finding which step of a group
  broke (the draft's `--layer-every-step`).

**No step is marked "always run", and nothing invalidates one step on
request.** A step's result must be fixed by what it's keyed on. That's the
executor's job (`keyInputs`: a disc's listing, an installer's
fingerprint), and an `ADD` can't break it, since it's pinned by its hash.
If a key is ever wrong, the person building can build without layers: the
policy `off` (`--debug layer-cache=off`, `SECOND_CHANCE_LAYER_CACHE=off`),
`sc clean layers`, or the app's `--clear-wine-cache`. A way for a bundle to
make one step fresh on request (a `--cache-key` option fed by an input)
was considered and left out as complexity nothing needs yet. A `RUN` can
already get the same effect with `--env`, since its environment is in its
key.

**Rejected:**

- **`--layer=keep|never` on a step.** An option reads as part of what the
  step does, and a layer isn't: it's the point after the step. A hint
  after a `DO` needed an exception.
- **A `LAYER-HINT` line, and `--no-layer` on a step.** A line marks a
  point, and `--no-layer` reads as an order. A block says which steps a
  hint is about, and gives the grouping that saves checkpoints.
- **`LAYER-HINT --skip` … `END`**, for "no layer after these steps".
  Grouping them with the steps before or after says the same, apart from
  the stage's last layer (above).
- **`--always-run`.** It would let a Wrappfile make a build slower for
  everyone, for something the person building can already ask for, and a
  bundle can already offer through an input.
- **Earthly's `CACHE`.** In Earthly that's a cache mount, which is a
  different thing (a `cache` store, here).
- **A layer the Wrappfile requires.** As above, nothing could rely on it,
  so a requirement would be a hint with a stronger name.

**Why hints and not timing:** keeping a layer after whatever took longest
on this Mac would make which layers exist depend on the Mac and its load.
That makes a cache miss hard to explain and the tests hard to write. The
runner logs each step's time and whether it was kept, so a module's
`layer: suggested` can be set from evidence.

### 14. What a key is made of

A step's key replaces `InstallLayer.key` and `WineBuild.prefixLayerKey`.
It's made of:

- its parent's key (decision 12);
- the step as planned (`PlannedStep.description`, every value
  substituted), with its `--name` and mounts (a
  `LAYER-HINT` block isn't a step, so it's in no key; decision 13);
- the hash of each file it reads (`bundle:…`, `module:<id>:/<path>`, as
  `plan.files`), and of each module data table it reads: those its values
  were read from (`${nancy-drew.data.patches…}`), as the planner records
  them, and those its instruction declares it reads in Swift
  (`reads-data:`, decision 5);
- the key format's version (`LayerKey.formatVersion`), raised whenever
  what goes into a key, or how, changes;
- not its module's release. Any change to a module's folder raises the
  release (`module.schema.json`), a launch-only file such as
  `routine-errors.yaml` included, so the release in a key would throw away
  every Wine game's prefix whenever anything in the wine module changed.
  What a step depends on is already in its key: its planned text, which
  is what its stage or function made of it, the files and data tables it
  read, and its executor's revision. An added module's program is in its
  executor's revision (below);
- its executor's code revision (below). That replaces
  `WineBuild.prefixCodeRevision` and `InstallLayer.codeRevision`, the two
  whole-build revisions raised by hand;
- what the executor's `keyInputs` gives. These are the facts from outside
  the plan, which no file holds:
  - the fingerprint of every input the step reads (below): each disc
    `WINE.KEEP-DISCS` keeps, a Her installer, the input a
    `COPY --from=${input.x}` copies from;
  - for a `COPY --from=<stage>`, the key of that stage's last step. Its
    text is the same whatever made the other stage, so without that, a
    layer after it could be restored for a different installer or
    download;
  - `skipped: <name>` for each step skipped before it (decision 3);
  - the program picked as the installer;
- the Mac's architecture.

**A store's install is keyed like any other step, and may be stale.**
Steam's and Big Fish's installs download whatever version the store has
now, and nothing the build can read beforehand says which: there's no
Steam build id until the install is done. So their key is the game, the
folder it goes in and the store they use, not the game's version. A later
build restores the install it kept, even if the game has been patched
since, until that layer is pruned or the cache is cleared. That's decided
(2026-11-04): it's a speed-up most people want, and someone who needs the
latest version builds without layers or clears the cache (decision 13).
Today neither install is cached, so this is new: phase 6 says so in
`docs/steam.md` and `docs/big-fish.md`.

**What the disc key buys: fresh builds from the cache.** An update never
reads a disc. Its stage takes what it needs from the old app, which
Second Chance passes as the input `previous` (decision 21). A step that
reads a source input makes an update a fresh build, as today. But a
fresh build of a game that has been built before, from the same discs (a
reinstall, a second Mac's account, every integration run), restores the
install instead of copying the discs and running the installer again.
For that to be safe, the key has to know the discs are the same. A
different disc (another language, a reissue) must not restore an install
made from ours.

- **So `WINE.KEEP-DISCS` is keyed on every disc it keeps**, as a step is
  keyed on every input it reads. Today's key uses disc 1's listing alone,
  so that a cached rebuild never asks for disc 2.
- **With disc images**, every disc's path is given up front, so this
  costs nothing.
- **With physical discs**, a cached rebuild of a two-disc game asks for
  disc 2 once, to read its listing, before restoring. That's one more
  disc swap than today, on a rebuild that copies nothing, and only for
  games with two discs. It's worth it (decided 2026-11-04). Someone whose
  app was built from the right disc 1 and the wrong disc 2 must be able
  to rebuild it with the right disc 2 and get the right game, without
  knowing there's a cache underneath. Caching is a speed-up that the
  people using Second Chance shouldn't have to think about.

**An input's fingerprint** is what stands for its contents in a key,
without reading all of it:

- **a file**: its size and modification time;
- **a folder, a macOS bundle, a disc or a disc image's contents**: its
  listing, every file's path, size and modification time
  (`LayerKey.listing`). A bundle is listed like any folder: its own
  modification time changes only when its top-level entries do, not when
  a file inside it is rewritten, so it can't stand for its contents.
  Listing a Wine app's 20 to 30 thousand files takes well under a second
  on an SSD, where hashing its 1 to 3 GB would take several.

A step that needs a true content hash (an `ADD`, pinned by its sha256)
has one already. Because a built app is fingerprinted by its bundle
folder's modification time, the assembler sets it when it saves a wrapp,
even one restored entirely from layers, so a new app never looks like
the one before it.

**Every layer keeps its key's inputs**, as today, so a miss says which
input differed.

#### Code revisions are numbers, checked against the source

Each executor has a revision number, raised by hand when its Swift changes
what it makes, and a check that it's never forgotten. The number, not the
source, is in its steps' keys, so a comment or a refactor that changes
nothing made doesn't throw layers away, which matters most while someone
is working on an executor. The check makes forgetting impossible to ship.

- **Each module's package records its executor's revision and the source
  it was raised for**, in `executor-revisions.json`: the number, and a hash
  of the Swift that carries the executor out (its target's files and the
  paths its `revision-inputs` file lists, each file's path and contents,
  sorted, as `stamp-launcher-revision.sh` hashes the launcher's).
- **`sc release` refuses to release with a stale one.** It works each hash
  out again and refuses if one differs from what's recorded, naming the
  executor. The fix is `sc module revise <module>` (later
  `wrapp-builder module revise`), which records the new hash and raises
  the number, or, for a change that makes nothing different, records the
  hash and keeps the number, with `--same-output`. `sc test integration`
  refuses to run with a stale one too, so an integration run never tests
  new Swift against layers the old Swift made, and `sc lint` warns, so
  it's seen early. Unit tests don't check it, so editing stays quick.
- **The numbers reach the app as Swift.** `sc generate` turns each
  module's `executor-revisions.json` into a table compiled into its
  package, with the usual test that the generated file is current.
- **During development, layers made before an edit are kept until the
  number goes up.** Someone changing what an executor makes raises it, or
  clears layers (`sc clean layers`). That's the trade for not losing every
  layer on every comment or reformat, decided 2026-11-05 over keying
  Debug builds on the source hash.
- **An executor whose layers sit under everything may be split by
  instruction.** The wine executor's prefix steps (`DRIVES`, `REGISTRY`,
  `WINETRICKS`) make the layer every Wine build starts from, so its target
  is laid out by instruction, each folder with its own number:

  ```text
  Packages/Modules/wine/Sources/WineExecutor/
    KEEP-DISCS/            what only WINE.KEEP-DISCS runs
    Prefix/                DRIVES, REGISTRY and WINETRICKS
    Shared/                what more than one of them uses
    revision-inputs        what it uses outside the target, and which folder each instruction is
  ```

  An instruction's hash is then its folder's, `Shared/`'s and its inputs'.
  Only the wine executor splits to begin with. The core's instructions,
  and the mount realisers (`bind`, `fetch`, `store`), each have a number
  too, in `Packages/WrappBuilder/Sources/WrappBuilder/Core/`, since
  they're in nearly every plan.
- **What's outside the target is listed, coarsely.** An executor's
  `revision-inputs` names the sources of what does its work: the wine
  executor lists `WineKit` and `ProcessKit`, and the installer
  `GameInstallerRunner` and `InstallerPlan`, in its kit. A module that
  only carries data or plumbing is left out, with a comment saying why
  (`WrappLogging`, which changes no tree, and the protocol's wire types).
- **What the plan's order is isn't in any key.** `PlanRunner` decides
  which step runs when, not what a step makes, so its own files aren't in
  any revision. A change to how it carries out keys or layers raises
  `LayerKey.formatVersion` (above), which today's `LayerKey` doesn't have
  and this plan adds.
- **Tests keep the layout honest.** In a split executor, every Swift file
  is in an instruction's folder or `Shared/`, and every instruction the
  module declares is assigned a folder. Every path `revision-inputs` names
  exists.
- **A module program's revision is its program's hash**, as imported
  (decision 10). A graduated module gets a number like any shipped
  executor.

### 15. Checkpoints: what keeping a layer costs

A tree can't be kept while something is running in it, or while
something it holds hasn't been written to disk. Before keeping a layer,
the runner calls `checkpoint` on every executor with a session in that
tree:

- **Wine ends its session** (`wine.server` released, as
  `docs/wrapp-launch.md#wines-desktop` says, and killed if it must be).
  wineserver writes the registry to its files as it exits. This is the
  real cost of a layer: a few seconds, more under load (`SystemLoad`), and
  the next step starts the session again. The runner logs it as
  `[Layer] checkpoint took …`. A step that ran no Wine program needs no
  Wine checkpoint, and two kept layers in a row with no Wine between them
  share one. A checkpoint looks for a running wineserver for the tree
  first (`ProcessList`), and if there's none, it doesn't wait for one. With functions expanded, a game with several patches keeps a
  layer after each one. Phase 5 measures what that costs on a disc build.
  If the checkpoints add more than they save on a rebuild, the fix is a
  `LAYER-HINT` block around an install and its patches in the nancy-drew
  games' Wrappfiles, or the defaults (decision 13): `RUN` and `ADD`
  suggesting nothing, say. The rule that a function's steps are the call
  site's doesn't change.
- **No checkpoint falls inside a store run** (decision 16), so a running,
  signed-in Steam is never asked to make way for a layer.
- **An added module's program** gets the `checkpoint` call and must reply
  before the layer is kept.

The layer itself is a clone of the tree, so it costs only the blocks later
steps change. `meta.json`'s size overstates what a layer takes when it
shares blocks with the next one, as it already does for a layer that
shares blocks with a wrapp.

### 16. A store is used in runs, and no layer is kept inside one

A sign-in in the tree (Steam's, Big Fish's) must never be kept in a layer,
and Steam shouldn't be stopped and started between steps that all need
it. One rule does both, worked out from the plan, so no step needs to know
what comes after it.

- **Runs are the planner's choice, not a promise.** A Wrappfile can rely
  on two things only: a store is open for every step that uses it, and no
  layer is kept while one is open. Where runs start and end, beyond the
  edges a Wrappfile draws itself (a `LAYER-HINT` block, below), is up to the
  planner. Today it makes each run as long as it can, as described here.
  A later planner may split a long one on purpose, so that 50 steps using
  one store aren't one layer, the store being closed and opened again in
  between. A bundle that needs a layer at a particular point draws the
  edge with `LAYER-HINT`. One that wants fewer restarts orders its steps
  so they're together, but can't count on one run.
- **A store run is consecutive steps that use the same store the same
  way**: all through the same module's executor (a typed option such as
  `--sign-in-store=…`), or all as a mount with the same target and options
  (`--mount=type=store,source=…`). Only whoever opened a run knows how to
  close it: Steam's `open` puts the sign-in in Steam's folders and the
  registry, and only its `close` can save it back and take it out, while a
  mount is only a link. So a step that uses the store another way ends the
  run, and starts a run of its own:

  ```dockerfile
  # A module someone adds, whose installer keeps its downloads in a cache store
  SHOP.INSTALL ${input.game} --into=… --downloads-store=downloads
  RUN --mount=type=store,source=shop:downloads,target=C:/downloads C:/tools/check.exe
  ```

  is two runs. The shop executor's closes first (its installer stopped,
  what it put in the tree taken out), then the `RUN`'s opens (the store
  linked, the program run, the link removed). Steam's sign-in can't be
  used both ways, since only the steam executor may use a `keep` store at
  build time (decision 23). Two uses of one store are never open at once,
  and each cleans up after itself. An `--exclusive` store's lock is
  released and taken again between them, so another app waiting for it
  may get it in between.
- **The way a store is used isn't declared anywhere new; the planner
  reads it from what the plan already says.** Each step's use of a store
  has a key:
  - **an instruction's option whose role is `store`** in its module's
    `module.yaml` (`--sign-in-store=`) is used through that module, so the
    key is the module's id. Every `STEAM.*` step taking the store as an
    option shares a way of use, since `open` and `close` are the steam
    executor's, not one instruction's;
  - **a `--mount=type=store`** is used as a mount, so the key is the mount
    with its `target` and options (`snapshot`).

  Consecutive steps with the same key make a run. Two modules'
  instructions taking the same store are two ways of use, since one
  module's executor can't close what another's opened. `sc bundle plan
  --layers` shows each run with its key. The planner works the runs out: a step
  that doesn't use the store ends its run, and so does the end of a stage,
  and so do a `LAYER-HINT` block's start and end (below).
- **The runner opens the store at the run's first step and closes it
  after the last**:
  - for a mount, the target is linked at the start and, at the end,
    removed or, with `snapshot`, replaced by a clone;
  - for a store taken as an argument, the runner calls the owning
    module's executor (`open` and `close`, decision 4). Steam's `open`
    takes the lock, restores the sign-in and starts Steam; its `close`
    stops Steam, saves the sign-in back to the store and takes it out of
    the prefix;
  - an `--exclusive` store's lock is held for the run, and released when
    it closes;
  - **closing goes in order**: every executor with a session in the tree
    checkpoints first (Steam and Wine stopped, the registry written), and
    only then does a mount's link come out or its snapshot go in, so
    nothing is swapped from under a running program;
  - **a failed or cancelled build closes every open run, and finishes
    closing.** Cleanup runs in a task that isn't cancelled (a detached one
    the runner awaits), with its own time limit, so Wine calls and
    `Blocking.run` waits that stop for a cancel don't leave a sign-in in
    the tree or Steam running. A close that runs out of time ends Wine's
    session by force (`wine.server.kill()`) and removes what the run
    brought in.
- **No layer is kept inside a run.** A layer suggested inside one, by a
  module, a stage's end or a `LAYER-HINT`, is kept after the run ends
  instead, and the log says so. So no checkpoint ever asks a running,
  signed-in Steam to make way, and nothing a run brings in is ever in a
  layer unless its mount says `snapshot`.
- **So `STEAM.SIGN-OUT` and `BIG-FISH.SIGN-OUT` go.** Their job is the
  end of the run. The steam module's install function is one step:

  ```dockerfile
  FUNCTION install
    INPUT game
    INPUT into
    STEAM.INSTALL ${input.game} --into=${input.into} --sign-in-store=sign-in
  END
  ```

  A bundle that has two Steam steps in a row (say, installing a game and
  then a soundtrack app it owns) gets one Steam start for both, as long as
  nothing else comes between them.
- **The cost is that a step between two uses ends the run.** Steam then
  stops after the first and starts again for the second. A bundle's author
  controls that by the order of its steps, and `sc bundle plan --layers`
  shows where each run starts and ends.
- **Identifying the game is a run of its own, in a throwaway tree.** The
  steam source restores the client stage's layer into a scratch clone,
  opens the sign-in store there (the executor's `open`), lists the games
  the account owns, asks which, and closes the run, Steam stopped and the
  sign-in saved back. Then the clone is thrown away. A run can't carry
  on into the edition's steps, since they run in a different tree, a
  clone of the client stage at another path, and a running Steam belongs
  to the folder it started in. And identifying changes the tree it runs
  in outside any step: Steam writes to its `appcache`, licences and
  config as it signs in. Steam would refresh those itself, so leaving
  them wouldn't break anything (today's apps carry them). Doing it in a
  clone is for decision 2's rule that a tree holds only what steps made:
  the edition's stage starts from exactly the client layer its keys say it
  did, with no exception to the rule that makes keys cover everything. The cost is
  one more Steam start than today in a headless build, where the game is
  named up front; a build in the window already restarts Steam to install
  the game it's asked about.
  - **With no client layer to clone** (the policy `off`, or the first
    build after the cache was cleared), the client stage is built once,
    and its last layer kept for the length of this build only, in the
    build's working folder, whatever the policy. Identification clones
    that, and the edition's stage starts from it too, so the client isn't
    built twice. Big Fish's manager stage is the same.
- **A `LAYER-HINT` block splits a run where a bundle wants a layer.** A
  run never crosses a block's start or end, so steps in the same block can
  share one, and steps in different blocks, or one inside a block and one
  outside it, can't. Each run then closes at the block's edge (Steam
  stopped, the sign-in saved and taken out, the lock released), and the
  block's layer is kept there as written:

  ```dockerfile
  # Two Steam installs, with a layer between them: two runs, two Steam starts
  LAYER-HINT
    STEAM.INSTALL ${input.game} --into=${const.install-dir} --sign-in-store=steam:sign-in
  END
  LAYER-HINT
    STEAM.INSTALL ${input.soundtrack} --into=${const.soundtrack-dir} --sign-in-store=steam:sign-in
  END
  ```

  Without the blocks, the two steps are one run, with one Steam start and
  a layer only after both. The checker needs no warning about a block
  ending inside a run, since one never does.
- **Inside a block, a run may span steps that don't use the store.** A
  block's steps are one layer anyway, so keeping a store open across a
  step that doesn't need it costs nothing in layers and saves closing and
  opening it, such as a Steam restart. So within a `LAYER-HINT` block,
  the planner takes a store's run from the first step in the block that
  uses it to the last that uses it the same way, whatever comes between,
  unless a step between uses it another way, which ends the run as
  anywhere else:

  ```dockerfile
  LAYER-HINT
    STEAM.INSTALL ${input.game} --into=${const.install-dir} --sign-in-store=steam:sign-in
    COPY assets/settings.vdf ${const.install-dir}/settings.vdf
    STEAM.INSTALL ${input.soundtrack} --into=${const.soundtrack-dir} --sign-in-store=steam:sign-in
  END
  ```

  is one run: one Steam start, the lock held throughout, and Steam still
  running, signed in, while the `COPY` runs. Like every run, that's a
  hint the planner follows, not a promise. The steps between see what the
  open store brought into the tree (the sign-in, here), which is no more
  than any other step in the same bundle could have asked for.
  - A step between that runs a program is watched for stalls by its own
    processes only. `--wine.busy` (decision 19) counts the processes the
    step started and their children, not Steam's, so Steam running in the
    background never hides a stalled installer.

### 17. The runner owns the build's shape; executors emit facts

Events today come from three places, and this splits them by who knows
them:

- **What the runner knows, it publishes.** That's `.started`,
  `.completed`, `.failed`, each step's start and end (`stepStarted`,
  `stepRestored` for one restored from a layer, `stepDone(name:)` and
  `stepSkipped(name:, message:)`, since the runner carries out
  `--on-failure`), each `EMIT` it passes (below), each store lock it waits
  for and gets (`waiting`, `acquired`), `.stepProgress(nil)` at each
  step's start, and `.wrappConfigured` and `.signed` at the end. That's
  half of what a builder publishes today.
- **Every event says whether it lasts.** An event is `lasting` (a fact
  about the build: an installer found, a phase reached, a step done) or
  `moment` (true only as it happens: an instruction to the person, how far
  a download got, a disc image mounted, the tree a step runs in). Only
  lasting events are kept with a layer (decision 18). Each kind's is fixed
  where the kind is declared, not chosen per call:

  | Event | Kind |
  | --- | --- |
  | `stepStarted`, `stepDone`, `stepSkipped` | lasting (a restored step's are replayed as `stepRestored`) |
  | `stepRestored` | lasting, emitted when restoring, never stored |
  | `emitted` from a plain `EMIT` | lasting |
  | `emitted` from an `EMIT --on` | moment |
  | `waiting`, `acquired` (a lock) | moment |
  | `instructions`, `stepProgress` (including `nil`), `substep` | moment |
  | `.started`, `.completed`, `.failed`, `.wrappConfigured`, `.signed` | the build's own, never in a layer |
  | a module's event types | as its package declares each (`SteamEvent.gamesOwned`: lasting; `.signInNotice`: moment) |

  A module program's `emit` carries the event's type, whose kind its
  module declares, so the protocol needs no flag either.
- **What an executor learns, it emits** through `EventEmitter`:
  - **generic events the builder defines**: `instructions` (what the
    person must do), `stepProgress`, `substep` text, and
    `emitted(String)` (`EMIT`);
  - **events its module defines**, as `Codable` types in the module's
    package (decision 22): the installer's `resolved` and `gameFound`
    (today's `installerResolved`, `gameExeDetected`), the disc module's
    `disksResolved` (naming the discs by input, never by Mac path) and
    `isoMounted` (a moment), Steam's `gamesOwned` and
    `signInNotice`, Big Fish's `gamesOwned`. The builder carries each as
    `module(id, name, payload)` without reading it, records and replays
    it like any other, and its caller decodes the ones it knows by
    importing the module's package. Second Chance turns them into
    today's `WrappBuildEvent`s, so the screens and tests read the same.

  An added module's program emits the generic kinds (`substep`,
  `instructions`, `stepProgress`) and its own module's events, with its
  own text (decision 20).
- **`wrappStarted` and `engineRouted`** are Second Chance's, made from the
  runner's events: `wrappStarted` from the target tree's start (a moment,
  since it names a folder), `engineRouted` from the plan's launch when the
  build begins.
- **`AutomationBridge` serialises the new events** for the test harness
  (`stepStarted`, `stepRestored`, `emitted`, `waiting`, `acquired`, module
  events, and whether each was replayed), and `RecordingEventSubscriber`
  records them.
- **The emitter is where `bus.publish` lives.** The runner gives the
  emitter its bus, so no executor holds `EventBus.app` or any bus, and
  `BuildBusTests`' rule holds by construction.
- **Every event is recorded with its step** (decision 18), which is what
  the install layer did for its fixed list.
- **`patchApplied(id:)` and `patchFailed(id:message:)` stay as event
  names** until one release after phase 4, published from `stepDone` and
  `stepSkipped` for a step whose origin is the nancy-drew module's `patch`
  function. Recorded event streams and the integration tests read them.
  Then they're renamed (phase 10).

**Why this, rather than signals, protects the events:** the risk AGENTS.md
warns about is a publish left behind when code moves. That's an
orchestration problem, and moving orchestration into one runner that
publishes the shape itself solves it. Signals (decision 19) say what to
look for in a program's behaviour. They're a good way for a Wrappfile to
describe progress, but they don't stop Swift from forgetting a publish.
The contract tests (phase 0 and the testing section) are what catch that.

#### `EMIT`: telling the caller the build has reached a point

What the progress screen shows a step under (`settingUpWrapp`,
`installingGame`, …) is Second Chance's idea, and so is the sidebar it
moves and the substep text under it. The builder may one day be a tool of
its own, so the Wrappfile syntax names none of them. Instead a Wrappfile
can **emit** a string when the build reaches a point, which the builder
passes to its caller without reading:

```dockerfile
FROM prefix AS disc
USE installer
WINE.KEEP-DISCS ${input.disc-1} ${input.disc-2} --into=C:/nancy-drew-installer
EMIT "second-chance.phase.installing-game"
INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir} --creates=${const.program}
DO patch
EMIT "second-chance.phase.configuring"
DO post-install-setup
```

```dockerfile
# Modules/wine/stages/prefix
EMIT "second-chance.substep.display"
WINE.REGISTRY --set x11-driver:EmulateModeset Y
```

**What the builder does with it is generic.**

- **`EMIT <string>`** takes one string, which may hold `${…}` values. The
  builder checks only that it's one non-empty string. How it's written is
  the author's choice: dots, a prefix for whoever reads it, anything.
- **It isn't a step.** It runs no program, changes no tree, has no key
  and keeps no layer. The builder emits `emitted(string)` when the build
  reaches it, in order with the steps around it.
- **It goes where its lines go.** A function's `EMIT`s are expanded with
  its steps, so one inside a function is emitted wherever the function is
  used. One in an `IF` branch that isn't taken is dropped with the branch.
- **Layers record and replay it.** An `EMIT` between steps a layer
  restores is part of that layer's events, so the caller gets the same
  strings whether the steps ran or were restored (decision 18).
- **Executors emit too.** `context.emit("…")` sends the same kind of
  string from Swift, beside the typed events an executor knows (above),
  so a Wrappfile and a module's Swift use one channel.
- **That's all the builder knows.** `--progress=<key>`, the one display
  concept the syntax had (`InstructionSpec.everyStep`), goes, and so does
  any idea of a phase. The wine module's `--progress=display`, `graphics`
  and `disc` become `EMIT`s.

**What Second Chance does: it reads strings starting `second-chance.`**

- **`second-chance.phase.<name>`** says the build has reached one of its
  phases, written in a Wrappfile's form: `setting-up`,
  `copying-installer`, `installing-game` or `configuring`. `detectingGame`
  and `savingApp` aren't offered, since the source and the assembler show
  them. A phase stays until a later one is emitted, and never goes back.
  So an `EMIT` inside a function carrying on past the function's end is
  what's wanted: the build has reached that part, whatever comes next.
- **`second-chance.substep.<key>`** gives the next step's substep, from
  Second Chance's own table of text (`display`: "Setting up the game's
  display"), which is translatable, as `WineManager.progressText` is
  today. An added module's program emits its own English text instead
  (decision 20).
- **`second-chance.progress.<done>/<total>`** sets how far the current
  step has got, as a `.stepProgress` fraction and its figures, for an
  `EMIT --on` whose signal reads a program's progress (decision 19).
- **Any other string means nothing to it.** A module program's own text,
  such as "Installing the game", goes out as the generic `substep` event,
  not as an `EMIT` string, so Second Chance shows it.
- **Defaults are Second Chance's, by instruction.** Without a phase
  emitted, the app's own table gives the phase an instruction reaches:
  `INSTALLER.RUN`, `HER-DOWNLOAD.INSTALL`, `STEAM.INSTALL` and
  `BIG-FISH.INSTALL` reach `installing-game`, and `WINE.KEEP-DISCS`
  reaches `copying-installer`. Any other step stays in the phase the build
  is in. The table is the app's, so module data stays as generic as the
  Wrappfiles: no `phase:` in `module.yaml`. A bundle needs an `EMIT` only
  where the table can't know, such as a plain `RUN` that's really the
  install. The table applies to a step restored from a layer
  (`stepRestored`) as to one that ran, so a cached build's sidebar moves as
  a fresh one's does.
- **The screen, as today.** The phase sets which sidebar step is marked
  (`InstallerFrame`) and the headline shown until a substep has been up
  for 5 s ("Installing the game…"), and the 5 s start again with each
  phase. The substep is the line shown after that.
- **Second Chance's strings are declared in a file of its own**,
  `SecondChance/Resources/emit-vocabulary.yaml`: each string or pattern it
  reads (`second-chance.phase.<name>` with the phase names,
  `second-chance.substep.<key>` with the keys of its table,
  `second-chance.progress.<done>/<total>` with numbers filled in at run
  time). The app's code is generated from it (`sc generate`), so the file
  is the one list.
- **Typos are Second Chance's to catch, from that file.** Its check runs
  with `sc bundle check` and over every shipped bundle in a unit test. It
  refuses a `second-chance.` string the file doesn't declare, matching a
  pattern's run-time parts against any `${signal.…}` in an `EMIT --on`, and
  a phase that would send the sidebar back. The VS Code highlighting
  (`Tools/vscode-wrappfile`) reads the same file to complete and underline
  them. The builder's own checker knows nothing of this.

**Rejected:**

- **Naming Second Chance's phases in the syntax** (a `PHASE` block, a
  `phase:` per instruction). That would make every bundle and module
  depend on one front end's screens.
- **Generic progress keys with a shared vocabulary.** They're generic in
  name only: a vocabulary of "prepare, copy, install, configure" is still
  Second Chance's phases, agreed in advance with tools that don't exist
  yet.
- **Comments as step trivia, read by Second Chance.** That worked, but it
  needed rules for which comments belong to which step, and loose
  comments kept for the check, and a directive looks like prose to a
  reader. An `EMIT` is a line that plainly does something.
- **`EMIT` with a name and a value, or `key=value` pairs.** The builder
  never reads it, so its structure is the caller's business. One string
  is the least the builder has to define.

### 18. A layer replays its steps' lasting events

A layer's `events.json` is every lasting event its steps emitted, and every
`EMIT` between them, in order, with each one's step (decision 17 says what
lasts). Restoring the layer emits them again, each tagged `replayed`.

- **What's kept is decided where an event is made, not by the builder.**
  An executor marks each event it emits lasting or a moment, and the
  builder keeps the lasting ones. It still reads none of them. Moments
  (an instruction to the person, how far a download got, a disc image
  mounted) aren't kept, so `events.json` stays small and has no Mac paths
  from a build long gone.
- **So a lasting event should still be true when it's replayed.** It says
  where things are inside the build's own tree
  (`/SharedSupport/game/Game.exe`) or names an input, never a Mac path.
  Second Chance adds the current build's details (where its tree is,
  which game) when it turns one into a screen event.
- **A skipped step keeps no layer**, and puts `skipped: <name>` in every
  later key, so the next build tries it again (decision 3). That replaces
  today's rule that an install with a failed patch isn't kept at all.

### 19. Signals, for builds

The signals plan has three phases: `SIGNAL`/`WATCH` and `SERVICE --ready`
at launch, `LAUNCH`'s events, and build steps waiting on a signal "when an
installer needs one". Reviewing it against this plan:

- **It helps** wherever a step's progress is *watched* rather than told.
  That's the installer's stall watch, Steam's install phases (read from
  its logs), and an added module whose program runs a Windows installer
  and wants the build to know when it's finished or stuck. A signal lets a
  Wrappfile or a module say that in data, which is what an added module
  needs in place of Swift that knows the installer.
- **It doesn't help** with events whose source is Swift's knowledge
  (`gameDetected`, `installerResolved`) or the build's shape
  (decision 17).

So this plan builds the signals plan's syntax and watcher, and uses them
in builds. Launch-time use (`SERVICE`, `LAUNCH`'s events) stays in that
plan, which then builds on this:

- **`SIGNAL` and `WATCH`** as the signals plan defines them, parsed,
  checked and planned into its recorded `Signal` and `Watch` data. The
  watcher goes in WrappKit (`ProcessKit` has `ProcessList`, and the log
  tails come from `SecondChanceKit`'s `LaunchActivityMonitor`, which moves
  to `ProcessKit`), so the build and, later, the wrapp share it.
- **Two new watches, for builds:**
  - `--grows=<path>` fires when a folder's size changes (the stall watch
    looks at `Program Files (x86)` and `users`);
  - `--wine.busy`, a wine module watch, fires when Wine's programs use the
    CPU or a new one starts (`LaunchActivityMonitor`'s test).
- **A step can name signals**, as core options every step that runs a
  program takes (`RUN`, `INSTALLER.RUN`, `HER-DOWNLOAD.INSTALL`, an added
  module's instructions):
  - `--alive=<signal>`: each time it fires is a sign of progress, for the
    stall watch. With none, the step gets its module's default (below).
  - `--done=<signal>`: the step has finished when it fires, and whatever
    it started is ended. That's for an installer that never exits by
    itself, which an AutoIt script closes today.
  - `--asks=<signal>`: the program is asking the person something, so
    show `.instructions` and stop the stall clock. Today that's "a Wine
    window is on screen", which becomes the default.
- **The installer's stall watch becomes a signal**, the installer
  module's `installer.alive`:

  ```dockerfile
  SIGNAL alive --any
    WATCH --wine.busy
    WATCH --output --matches="."
    WATCH --log="${program.log}" --matches="."
    WATCH --grows="C:/Program Files (x86)"
    WATCH --grows="C:/users"
  END
  ```

  `InstallStallWatch` keeps its window and its load rule
  (`SECOND_CHANCE_INSTALL_STALL_SECONDS`, three times that under load) and
  reads the signal for its signs. What it measured (`[Install] longest
  quiet`) still decides the window.
- **A module program can use a signal** by name in a `runProgram` call
  (`"alive":"self.alive"`), so an added installer module gets a stall
  watch without Swift that watches.
- **`EMIT --on=<signal>` emits each time a signal fires.** It's how a
  Wrappfile turns what a program does into events for its caller, such as
  an installer's progress, with no Swift:

  ```dockerfile
  SIGNAL copying
    WATCH --log="${program.log}" --matches="Copying file (?<done>\d+) of (?<total>\d+)"
  END

  EMIT --on=copying "second-chance.progress.${signal.done}/${signal.total}"
  INSTALLER.RUN --from=${input.disc-1} …
  ```

  - **It listens from its line to the end of the build**, across stages,
    in the order the build runs them, unless it's stopped.
  - **A listener has a name**, `--name=<id>`, which defaults to its
    signal's. `EMIT --off=<name>` stops that one listener and no other, so
    two listeners on one signal (`--name=copy-progress`,
    `--name=copy-log`) can be stopped apart. Two listeners with one name,
    or an `--off` naming none, is an error. A listener in a function keeps listening after the function's
    steps end, as a plain `EMIT` there is emitted wherever the function is
    used.
  - **It fires only while a step runs.** A step restored from a layer runs
    nothing, so nothing fires.
  - **A signal's watches give it data**, which `${signal.<field>}` reads:
    - `--matches` gives its named groups;
    - `--file` gives `path`;
    - `--grows` gives `size`;
    - `--exits` gives `code`;
    - a module's watch gives whatever fields it declares.

    An `--all` or `--any` signal has its watches' fields together, and
    two watches giving one field is an error.
  - **Two values are filled in when a build runs, not when it's
    planned**: `${signal.…}`, and `${program.…}` (the program a signal is
    watched for, its `path`, `dir`, `name` and `log`, which only the step
    running it knows, as `INSTALLER.RUN` knows its installer's log). Both
    are read only in a `SIGNAL`'s watches and an `EMIT --on`'s string. The
    bundle plan left values known only at run time to come back to, and
    these are the first that need them. The builder fills them in and
    still never reads the string. This changes the signals plan, which
    has `${program.path}`, `dir` and `name` known when planning: for
    `INSTALLER.RUN` the program is only chosen as the step runs, so they
    can't be (its dated note says so).
  - **What it emits is a moment** (decision 17): it isn't kept with a
    layer or replayed, since progress is only true as it happens.
  - **A busy signal is coalesced.** A listener emits at most once a second
    (the last value wins), so a signal that fires on every line of output,
    or on `--wine.busy`, doesn't flood the caller.
  - **A function containing `EMIT --on` can be used once per build**,
    since listener names are the build's. That's accepted (decided
    2026-11-04): nothing needs more yet.
- **Not built here:** `SERVICE`, `LAUNCH`'s `--started`/`--failed`/
  `--quit-cleanly`, and signals with inputs (the signals plan's open
  question 2). `${program.log}` is a value the signals plan didn't have:
  an installer's own log, which `INSTALLER.RUN` knows (`InstallerLogStreamer`).

The signals plan gets a dated, post-implementation note saying its first
phase's syntax and watcher are built, for builds, by this plan, and what's
left. Once this is built, its build-side half moves into this plan's
historical record.

### 20. Sources and the person's questions

What's left of a builder is a source:

```swift
/// Where a program comes from: which it is, which edition, and its inputs.
protocol WrappSourceProvider {
    var source: WrappSource { get }
    /// What to build. May build a module stage in a throwaway tree first
    /// (Steam's client, to ask which games the account owns).
    func identify(_ input: WrappBuildInput, runner: PlanRunner) async throws -> BuildRequest
}

struct BuildRequest {
    let program: GameInfo              // detected once, as today
    let edition: String                // from the detection rule that matched
    let choices: [String: String]      // launch-mode
    let inputs: InputProvider          // disc-1 now, disc-2 when a step asks
}
```

- **The edition comes from detection.** The disc and Her sources take it
  from the detection rule that matched (`Rule.edition`), falling back to
  the source's only edition. So a bundle with two disc editions builds,
  where today's builders hard-code `"cd"`, `"her-windows"` and `"her-mac"`.
- **An input is given by an `InputProvider`**, a protocol in
  `WrappModuleKit` that a module implements for its own kind of input. The
  disc module's mounts an image and reads a listing, and asks for disc 2
  when a step first needs it. A source uses it, and so does
  `wrapp-builder build --input disc-1=…`, so the tool needs nothing of a
  source's to build from a disc.
- **An input's value may be a JSON object**, as well as text or a list
  (`--input`, `SECOND_CHANCE_INPUTS`), and its fields read as
  `${input.game.app-id}` does today. A tree input (`previous`) is given as
  its path and an object of fields beside it (`wine`, `bundle`), read as
  `${input.previous.wine}`.

- **Disc**: detect the game from disc 1, and give `disc-N` through the
  `disc` module (mounting an image, asking for disc 2 when
  `WINE.KEEP-DISCS` asks for it). An app chosen in place of a disc goes to
  the update source (decision 21).
- **Her download**: unpack the launcher, tell the game from it
  (`CiderPackage` for a Mac download), give `installer`.
- **Steam**: build the steam module's `client` stage with the runner
  (restored from its layer, decision 12) in a throwaway clone, sign in,
  list owned games, ask which, ask the launch mode, and close that run
  (decision 16). The edition's build then starts from the client layer
  itself, as its stage is `FROM --module=steam@1 client`, and its first
  Steam step opens a run of its own. The one-Steam-at-a-time lock and
  `RunningSteam` are the steam executor's, for each run.
- **Big Fish**: the same, with the big-fish module's `manager` stage.
- **Download**: the bundle id alone. Its URLs are the plan's `ADD`s, which
  the core carries out.
- **The person's questions go through `context.ask`**, which is
  `WrappBuildInput` underneath, so headless answers still come from
  `NON_INTERACTIVE` and the env vars:
  - typed questions for the shipped modules (`chooseGameProgram`,
    `confirmStepFailure`, `steamSignIn`, …);
  - three generic kinds for an added module (`choose(one of:)`,
    `confirm`, `instructions`). Their text comes from the module, in
    English, and isn't translated. The plain-text rule applies to it, and
    `docs/module-programs.md` says so.
- **Only sources compiled in** (decision 9). A store someone adds a
  module for is reached through an existing source for now: the download
  source with a URL input, or a disc. A source in a module is the
  runtime-facet plan's sibling, later.

### 21. Updates are Second Chance's; the builder sees inputs

What an update is (`from:` conditions, a module's default updates, which
apply to an app) is Second Chance's and the manifest's business, not the
builder's. The builder sees only inputs.

- **Second Chance decides which updates apply**, as `UpdatePlanner` does
  today, and passes two inputs:
  - `updates`, a list of the updates' names;
  - `previous`, the old app made into a tree: its prefix carried over,
    `Documents` and A: pointed at stand-ins, Z: mounted for the update's
    Wine programs, a Wine move within a major version done
    (`WineManager.movePrefix`). All of this is Second Chance's
    preparation before the builder runs, as it is today.
- **A Wrappfile branches on them**:

  ```dockerfile
  INPUT updates --default=[]
  INPUT previous

  FROM ${input.previous} AS update
  IF ${input.updates} has "blue-moon-taffy-sort"
    DO patch
  END
  DO post-install-setup
  ```

- **Lists are a value type.** `updates` is a real list, given as JSON in
  `SECOND_CHANCE_INPUTS` and `--input` (`--input 'updates=["a","b"]'`).
  `has` is true when the list on its left holds the text on its right. The
  bundle plan listed lists and `in` as value types to add once a bundle
  needed them, and this is that.
- **A stage can be built from an input.** `FROM ${input.previous}` starts
  a stage from the tree an input names, as `COPY --from=${input.…}` already
  copies from one. So `previous` isn't a special word any more: it's an
  input like any other, declared with `INPUT`, which the checker knows.
  `base`, the other special stage (the manifest's `build.base`, a stage of
  the bundle's chosen by name), goes. No shipped bundle uses it: no
  manifest has `build.base` and no Wrappfile `FROM base`. If a bundle
  ever needs to choose a stage, an `IF` on an input can.
  - Docker's named build contexts (`--build-context name=path`, then
    `FROM name`) are the same idea. An input reuses what Wrappfiles
    already have, a declaration the checker reads, rather than adding a
    second kind of name.
- **A module's own updates are its update stages**, such as
  `Modules/wine/stages/update`. A stage can't be applied to another tree,
  but a function can, so the prefix's settings move into a function,
  `wine.prefix-settings`, which the `prefix` stage and the update stage
  both `DO`. The update stage is `FROM ${input.previous}`, then
  `DO wine.prefix-settings`, with no `WINE.PREFIX`: the prefix is the old
  app's. Second Chance chains them as it chains module stages for a
  build: each applicable module's update stage, with `previous` set to the
  result of the one before, then the bundle's, with the same `updates`.
- **`previous` comes with today's engine.** Second Chance's preparation
  moves the old prefix to this build's Wine within a major version
  (`WineManager.movePrefix`), as today, and the tree's `engines/*.json`
  say which it has. A `USE wine` in an update plans an `ENGINE` step all
  the same, which leaves an engine that matches alone (decision 2).
- **An update keeps the app's id.** The caller gives it (decision 25),
  Second Chance passing the old app's, so an update can never become a
  new app with new stores. The old launcher and the template's other files
  in `previous` are replaced when the assembler lays the template in, as
  for any tree (decision 2).
- **Reading a source input makes it a fresh build.** A plan for an update
  whose steps read a disc or a download input (any input the edition
  takes from its source, by role) needs the source. Second Chance finds
  that out by planning before anything runs, and says so as
  `updateNeedsSource` does today. `INSTALLER.RUN --patch` reads no source
  input, so a patch is fine; `INSTALLER.RUN --from=${input.disc-1}` isn't.
- **Nothing carried over from an old app is cached**, as today.
- **It moves in phase 4 or later.** The update source runs patches, and
  the patch function's silent patchers are `INSTALLER.RUN --patch`, which
  arrives in phase 4.

### 22. Where the code goes

- **`Packages/WrappBuilder`** gains:
  - `PlanRunner` and `LocalStepContext`;
  - the core's instructions and mount realisers;
  - `ExternalExecutor` and the protocol;
  - key-making from the step chain;
  - `WrappAssembler`, which is `WrappBuildHelper`'s template, `Info.plist`
    merge, sign, save and temporary-wrapp tracking (engines are steps now,
    decision 2).

  It doesn't link `WineKit`, and knows nothing of Wine.

- **WineKit becomes the wine module's kit, and modules that need Wine
  depend on the wine module.** `WineKit` moves into
  `Packages/Modules/wine/` as its kit. The installer, steam, big-fish and
  her-download modules already name `wine` in `depends-on`, and their
  packages depend on the wine module's package, so their kits use Wine
  through it directly: `SteamClient` starts Wine's desktop and Steam, and
  imports the sign-in's registry value; `GameInstallerRunner` lends
  drives, waits for every program in the session, and retries when
  there's no display; the wrapp's `SteamRuntime` does the same at launch,
  where there's no runner. A module's Swift dependencies are its
  `depends-on`, which the checker and SwiftPM both see, so a module can
  never use one it hasn't declared.
- **`RUN` and module programs run programs through `runProgram`**, by
  path type, through the module that registered it, with its exit code and
  time limit (decision 4). That's the one way a Wrappfile, or a program
  that can't link Swift packages, runs anything. There are no services
  between modules over the protocol, and no proxies to keep in step.
- **The wine module provides winetricks** (its script, which
  `WINE.WINETRICKS` runs and keys on), and **an `autoit` module provides
  AutoIt**, which the installer module depends on. Neither comes from the
  template or `Bundle.main` any more, the first step in moving the
  template's build-time contents out of Second Chance (decision 26).

  None of these need the app. The events it emits are a package type
  (`BuildEvent`) that the app turns into `WrappBuildEvent`, so the
  package needn't know `AppEvent`.
- **`Packages/WrappKit`** gains `WrappModuleKit`. That's everything an
  executor is written against, shipped or not:
  - `ModuleExecutor`, `StepContext`, `EventEmitter` and the question
    kinds;
  - `PlannedStep`, which moves here from `WrappBuilder` so an executor
    needn't depend on the planner;
  - `KeyInput` and `KeyInputs`, which `LayerKey` (in `WrappBuilder`) is
    made from. `WrappBuilder` depends on `WrappKit`, so the types an
    executor names have to live on this side;
  - `RemoteStepContext` and `ModuleProgram.serve`.

  It also gains the signal watcher, in `ProcessKit`.
- **Isolation.** The app and the packages default to the main actor
  (`.defaultIsolation(MainActor.self)`), with `NonisolatedNonsendingByDefault`,
  under which a plain `nonisolated async` method runs on its *caller's*
  actor. Called from the main-actor view model, a whole build would run on
  the main thread. So:
  - `ModuleExecutor`, `StepContext`, `EventEmitter` and `KeyInputs` are
    `nonisolated` and `Sendable`, and `PlanRunner`'s entry point and every
    call it makes into an executor are `@concurrent`, so a build runs off
    the main actor whoever starts it;
  - an executor's blocking work (listing, hashing, copying, cloning) goes
    through `Blocking.run`, as AGENTS.md requires;
  - `emit` enqueues onto one ordered `AsyncStream` that the runner drains,
    so events reach the caller in the order they were emitted, which the
    event contract depends on. It never hops by spawning a `Task`;
  - `context.ask` awaits the main actor, where `WrappBuildInput` lives;
  - `WrappModuleKit`'s template package for module programs sets
    `nonisolated` default isolation, and `docs/module-programs.md` says
    why, so an author's executor isn't main-actor by accident.
- **Each shipped module's Swift is a package of its own,
  `Packages/Modules/<name>/`**, beside the module's data in `Modules/<name>/`
  (kept apart, so editing Swift doesn't change a module's release). It
  holds:
  - **its executor**, a library target (`SteamExecutor`);
  - **its package dependencies**, the packages of the modules its
    `depends-on` names (the wine module's, for Steam);
  - **its kit**, a library of what the module knows that isn't a build
    step: Steam's client, its logs, sign-in and stall watches and `VDF`
    (today in `SecondChanceKit/Steam/`); Big Fish's Game Manager driver
    (today in `SecondChanceKit/BigFish/`); `GameInstallerRunner`,
    `InstallerPlan` and `InstallStallWatch` for the installer;
    `CiderPackage` for Her's downloads; `ISOMounter` for discs;
  - **its events**, the types it emits (`SteamEvent.gamesOwned`,
    `.signInNotice`; `InstallerEvent.resolved`), which the builder passes
    on as a module's event without knowing them (decision 17).

  The executor and the wrapp's runtime module (`WrappTemplate/Modules/SteamRuntime`)
  both use the kit, and so does Second Chance where it needs to: its
  "Sign Out of Steam" menu calls the steam kit's function, and its window
  decodes the steam module's events. Second Chance may link and use any
  module's package, but a module's package never links Second Chance's.
  So everything Steam- or Big-Fish-specific that isn't a window leaves
  `SecondChanceKit`, which keeps only what's Second Chance's own.
  - **What shows something stays in `SecondChanceKit`**: `SteamLockHolder`'s
    prompts and `SteamSignInWindow` (shared with Big Fish's Game Manager)
    use AppKit and the app's string catalogues. The kits keep the logic
    (the client, its logs, the session rules) and report what needs
    showing as events and questions (`context.ask`), which Second Chance's
    window turns into those prompts.
- **What executors need from the builder moves into `WrappModuleKit`**
  (`ModuleData`, `InstructionSpec`'s option kinds, `PlannedStep`,
  `KeyInputs`), so no module's package imports `WrappBuilder`, which a
  test checks. Otherwise `wrapp-builder`, which links the executors, and
  the executors, which would link the builder, would make a package cycle.
  `wrapp-builder` itself is a package of its own,
  `Packages/WrappBuilderCLI`, depending on `WrappBuilder` and the module
  packages.
- **Portable shipped executors go in their module's package**, a
  library target per module that needs nothing of the app's (decision
  11): `disc`, `wine` and `nancy-drew` from the start, the rest as they
  move (below), and every graduated module.
- **Every executor ends up portable.** Each moves into its package as the
  phase that moves its module's flow does (phase 4 for the installer, disc
  and Her's, phase 6 for Steam and Big Fish), with what it uses moving
  into its kit. The one thing a kit can't hold is text from the app's
  string catalogues, which a module's package declares English for and
  the app looks up, as `SecondChanceKit`'s text is today (AGENTS.md).
- **`SecondChance/Builders/` goes.** The sources go in
  `SecondChance/Sources/`, a few hundred lines each.
  `WrappBuildStrategy` becomes `WrappSourceProvider`.
- **The legacy values go**: `completeBuild`'s `gameExePath`,
  `installerDir`, `configureINI` and `steamID`, now that the recorded
  launch (the bundle plan's decision 19) says how the wrapp starts.
  `wrappConfigured(exePath:installerDir:gameInfo:)` becomes
  `wrappConfigured(launch:)`.

### 23. Stores: data kept outside the app

A **store** is a named folder kept outside any app, which build steps and a
launch can mount. It replaces the `cache` and `secret` mount types and
`VOLUME`, and gives a place to what Swift keeps today in
`SteamSessionStore`, `SteamClientCache` and the one-Steam-at-a-time lock,
whose rules move into the steam module's kit.

```dockerfile
STORE <name> [--retention=keep|cache|session] [--scope=app|global] [--exclusive[=<lock>]]
```

- **A store is a folder, and may hold anything.** The builder never looks
  inside one.
- **`--retention` says how long it lasts and where it lives:**

  | Retention | Lives in | Ends when |
  | --- | --- | --- |
  | `keep` (the default) | Application Support | someone removes it on purpose |
  | `cache` | `~/Library/Caches/SecondChance/stores/` | space is needed, or someone clears it (`sc clean stores --retention=cache`; `sc clean layers` leaves stores alone, so a developer clearing layers isn't signed out of Steam) |
  | `session` | the per-user temporary folder (`$TMPDIR`, mode 700; macOS also removes what's gone unused there for a few days) | the build, or the launch, that made it ends |

  A `session` store is always one build's or one launch's own, so
  `--retention=session` with `--scope=global` is an error: another build
  could still be using it when the one that made it ends.

- **`--scope` says which apps share it:**
  - **`app`** (the default): one store for each app id (decision 25). Every
    build of an app with that id, and every copy of it, has the same one,
    as a rebuilt game keeps its saves today. Two different games have
    their own.
  - **`global`**: one store for every app. That's how one Steam sign-in
    serves every game Second Chance builds from Steam, whatever its id.
  - A store for one build or one launch only is `--retention=session`.
- **A store's name is its owner's.** The name is namespaced by whoever
  declares it, so two owners can't collide:
  - a module's stores by the module's id: `steam:sign-in`, whatever its
    scope;
  - a Wrappfile's `app` stores by the app's id, and its `global` stores as
    `global:<name>`, shared by every Wrappfile that declares one by that
    name. The declaration check (below) keeps them agreeing.

  A store is named by its short name in its owner's own files
  (`source=sign-in` in the steam module's), and by its full name anywhere
  else (`source=steam:sign-in`). Any of the person's apps can reach any
  store. That's intended: a store is in their home folder, readable by
  them and root only, which is where Steam's own Mac app keeps its
  sign-in. It does mean an added bundle could mount Steam's sign-in store
  and hand it to a program it runs at launch, which the host path rule
  (decision 24) wouldn't stop. (At build time it can't: a `keep` store
  can't be mounted by a build step.) That's accepted (decided 2026-11-04):
  a bundle someone adds is already trusted to run programs, and is warned
  about as such (decision 10).
- **A module declares its stores in a file of `STORE` lines**, named in
  its `module.yaml` (`stores: ["stores"]`), so every stage and function of
  the module sees the same ones. A Wrappfile declares its own before its
  first `FROM`, as it does `INPUT`s.
- **Where each lives on disk:**
  - an `app` store kept: `~/Library/Application Support/<app id>/stores/<owner>/<name>/`,
    the owner being `app` for the Wrappfile's own or a module's id, so a
    module's `saves` and a bundle's `saves` don't share a folder. That's
    the folder the person's files are in today, with `volumes/` renamed
    `stores/`. No released Second Chance built an app with volumes, so
    nothing needs moving or linking back;
  - a `global` store kept: `~/Library/Application Support/SecondChance/stores/<owner>/<name>/`,
    the owner being a module's id or `global`;
  - a `cache` or `session` store: the same `<owner>/<name>` under its
    retention's folder.

  These folders are named for Second Chance (`SecondChance`), which the
  builder shouldn't know. That's left for now, and noted in "To come back
  to": the roots become the caller's to give before `wrapp-builder` is
  split out.

  `UserFilesLayout` gives the paths, in WrappKit, so the builder and the
  wrapp agree. Under test, `SECOND_CHANCE_APP_SUPPORT_DIR` moves every
  store's root, `global` stores included, so a test launch starts with
  none and never touches the person's. The Steam smoke test, which needs a
  real sign-in, points the steam module's stores at the one it's given
  (`TEST_RUNNER_STEAM_SMOKE_STORE`), as it does today.
- **A step mounts a store**: `--mount=type=store,source=<name>,target=<path>[,snapshot]`.
  - While it's mounted, the target is a link to the store's folder, so
    whatever the step changes, it changes in the store.
  - When the step ends, the link is removed, unless the next step mounts
    the same store, in which case it stays until the run ends (decision
    16). With `snapshot`, it's then replaced by a clone of what the store
    holds, which stays in the tree and so in a layer and the app.
  - A target that already exists in the tree is an error naming it, so a
    mount never hides or replaces what a step made. That goes for a
    launch's mounts too: keeping the target free is the Wrappfile's job
    (decided 2026-11-05). The Wine games' bundles end their install with
    `REMOVE "C:/users/crossover/Documents"`, so the launch can mount their
    saves there, and the checker refuses a launch mount whose target a step
    of the target's ancestry leaves in place, naming both.
  - One store may be mounted at more than one target in a step, as the
    Wine games' saves are seen at both A: and Documents (below).
- **An instruction can take a store as an argument**, for a module that
  does more than put files somewhere. The option's role is `store` in
  `module.yaml`, so the checker knows a store is named, checks it's
  declared, and puts its full name in the key, just as for a mount:

  ```dockerfile
  STEAM.INSTALL ${input.game} --into=${input.into} --sign-in-store=sign-in
  ```

  The executor gets a handle (`context.store("…")`) and decides what to
  do with the contents. Steam's sign-in needs that: it's three files in
  two folders and a registry value (`docs/steam.md`). Wine keeps a
  prefix's registry in three files (`system.reg`, `user.reg`,
  `userdef.reg`), which wineserver loads when it starts and writes back
  when it ends. It doesn't merge other `.reg` files into them, so Steam's
  value can't live in a file of its own. It's imported with `reg import`
  and read back from `user.reg` once Wine has stopped, which only the
  steam executor knows to do.
- **A `keep` store can't be used by a build step**, with one exception.
  Its point is that it lasts, so a build mustn't change it. The checker
  refuses a `keep` store mounted or named by a build step, naming the
  store and the step. `LAUNCH` may mount one (below).
  - **The exception: a module's own executor may use its own module's
    `keep` stores at build time**, through an option whose role is
    `store` (decided 2026-11-04). The module knows what its store holds and
    how to change it safely; Steam's sign-in is the case. A `--mount`
    of a `keep` store, or a module's executor using another owner's, is
    still refused.
- **Seeding one store from another** (`--seed-from`) was designed and left
  out: nothing needs it now that Steam has one sign-in store. It's in "To
  come back to".
- **`--exclusive`** says only one user at a time.
  - **On its own**, it locks just that store, with the store's scope: an
    `app` store has a lock for each app, and a `global` store one lock for
    everyone.
  - **`--exclusive=<lock>`** names a lock shared by every store that names
    it, declared with its own scope:

    ```dockerfile
    LOCK steam --scope=global
    ```

    A lock is namespaced like a store (`steam:steam`). An `app` lock is one
    lock for each app id; a `global` lock is one lock for everyone. So an
    `app` store and a `global` store can share a lock, and what's locked
    is whatever the lock's scope says, not the stores'. Holding a lock for
    any store that names it holds it for all of them. A store naming a
    lock that isn't declared is an error.
  - A build holds the lock for each store run that uses such a store
    (decision 16), from its first step to its last. A launch holds it
    while its program runs.
  - The lock records its holder: the process, and the app's name.
  - A build that finds it taken emits `waiting(lock:, holder:)` and
    waits, and `acquired(lock:, after:)` once it has the lock. The caller
    decides what to do: Second Chance's window offers today's choices
    (quit the other app, or give up), and a headless build waits up to
    `SECOND_CHANCE_LOCK_WAIT` (30 minutes by default), then fails, saying
    who held it, so an integration run behind a stuck Steam app ends.
    Either way, both are logged (`notice`: "Waiting for the steam lock,
    held by Blue Moon (pid 4211)", then "Got the steam lock after
    3m12s"). So a test that took far longer than expected shows it was
    waiting.
  - A launch that finds it taken shows a message itself, naming the app
    that holds it.
- **A store's full name is in the key** of each step that mounts it;
  its contents never are. Mounting a store without `snapshot` is a promise
  that its contents don't change what the step makes: a cache only saves
  time, and a sign-in changes what you may install, not how it's
  installed. With `snapshot` the contents do end up in the tree, so a
  `snapshot` mount is only for a store whose contents are interchangeable,
  as an updated Steam client is with an older one that updates itself on
  start.
- **A declaration is recorded with the store** (`store.json` beside its
  contents). A Wrappfile or module whose `STORE` disagrees with it
  (retention, lock or seed) is an error naming both. A module that needs
  to change a store's retention gives it a new name, or the old store is
  removed (`sc store remove <owner>:<name>`).
- **`LAUNCH` mounts stores too**, recorded with the launch as volumes are
  today, so the wrapp needs no Wrappfile to find them:

  Launch mounts are inherited through `FROM`, as `VOLUME` lines were: a
  stage built from one with a `LAUNCH` keeps its mounts, adds any its own
  `LAUNCH` gives, and drops one with `--mount=…,remove`. So a function every
  edition runs can give the saves mount once.

  ```dockerfile
  # A Wine game: one store, seen at A: and in Documents, as wine-documents is today
  STORE wine-documents
  LAUNCH --mount=type=store,source=wine-documents,target=A: \
         --mount=type=store,source=wine-documents,target="C:/users/crossover/Documents" \
         ${const.program}

  # A ScummVM game: its saves and settings where ScummVM keeps them
  STORE scummvm-saves
  STORE scummvm-settings
  LAUNCH --mount=type=store,source=scummvm-saves,target=scummvm:saves/ \
         --mount=type=store,source=scummvm-settings,target=scummvm:settings/ \
         /SharedSupport/game/ nancy:nancy4

  # A DOS game: what it writes laid over its C: (VOLUME --dosbox.overlay today)
  LAUNCH --mount=type=store,source=dosbox-saves,target=C:/,dosbox.overlay …
  ```

  Each `VOLUME` form has its mount: a drive or a folder by the target's
  path type, and `dosbox.overlay` as a mount field of the dosbox module's
  (decision 5). `VOLUME` goes, and so does `RecordedLaunch.volumes`, which
  becomes the launch's store mounts. No released app has a recorded
  launch, so the format changes without a version. The manifest's `volumes:` (each one's `display-name`
  and `in-use-when`, which Second Chance shows and uses) are keyed by
  store name instead. They stay in the manifest, as they're Second
  Chance's, not the builder's.
- **A store can hold files that sit beside a program's own**, as a
  `files=` mount (added 2026-11-05, by Claude for Callum, from porting
  LaserTank and Iji with the port-program skill). A folder mount covers a
  program that saves into a folder of its own, wherever it is
  (`target=C:/WINDOWS/INGPREFS`). It can't cover one that writes loose files
  into the folder its program is in, as many old games do: a store mounted
  at that folder would hide the program, and a target that already exists
  is an error.

  *The case:* LaserTank (`freeware/laser-tank`) keeps its settings in
  `C:/LaserTank/LaserTank.ini`, beside `lasertank.exe`, and its high
  scores in `LaserTank.hs` beside the level file it's playing, with
  recordings (`*.lpb`) the same way (`LTANK.C`, `LTANK2.C` in its
  published source). Iji (Game Maker 7) saves into its own folder the same
  way. Today these files stay inside the app: kept between launches, but
  lost when the app is rebuilt or updated, which is exactly what a store
  is for. The bundle can't say otherwise, since a Wine volume today is
  always the prefix's Documents (`WineRuntime.connectSaves`,
  `RecordedLaunch.savesVolume`).

  ```dockerfile
  STORE saves
  LAUNCH --mount=type=store,source=saves,target=C:/LaserTank/,files="LaserTank.ini;*.hs;*.lpb" \
         C:/LaserTank/lasertank.exe
  ```

  - **`files=`** lists the patterns of the files that are the store's,
    `;`-separated, matched by name in the target folder (not its
    subfolders). The target must be a folder that exists; it isn't hidden,
    and the rule that a target mustn't exist doesn't apply.
  - **Before the program starts**, each of the store's files that matches is
    linked into the folder, replacing the tree's file of that name.
  - **A file the build left there** (a default `LaserTank.ini`) is moved
    into the store the first time, when the store has none of that name,
    so the person's copy starts from it. After that the store's wins.
  - **After the program exits**, a file in the folder that matches and
    isn't a link yet, one the program made (a first high-score file, a new
    recording), is moved into the store and left as a link. A program that
    writes through a link writes into the store as it goes, so only new
    names wait for the exit; a crash before it leaves them in the app
    until the next clean exit.
  - It's the core's mount, on any path type with folders (Wine's, DOSBox's,
    the app's own), so no module needs it. The manifest's `in-use-when` for
    the store can name the same patterns.

**Steam, as stores:**

```dockerfile
# Modules/steam/stores, named in its module.yaml (stores: ["stores"])
LOCK steam --scope=global
LOCK client --scope=global
STORE client --retention=cache --scope=global --exclusive=client
STORE sign-in --scope=global --exclusive=steam

# stages/client: Steam installed, and left to update itself once, inside
# the mount, so the store keeps the updated client and the snapshot leaves
# it in the tree
STEAM.CLIENT --mount=type=store,source=client,target="C:/Program Files (x86)/Steam",snapshot

# functions/install
STEAM.INSTALL ${input.game} --into=${input.into} --sign-in-store=sign-in

# A game launched through Steam
LAUNCH --steam.sign-in-store=steam:sign-in --steam.exe=… steam://rungameid/…
```

- **One sign-in, kept, for builds and every Steam app**, as today's
  shared session is. Builds use it through `STEAM.INSTALL
  --sign-in-store=` (the exception above), and apps at launch. The steam
  executor's `close`, and the runtime module's at launch, keep today's
  rules for saving it back (`docs/steam.md`):
  - **only a run that signed in is saved**, since Steam rewrites
    `local.vdf` without a token when it rejects one;
  - **the newer session wins**: if another run saved since this one
    restored (by `local.vdf`'s modification time), this one's is dropped;
  - **a save is made beside the old session and swapped in**, under the
    store's lock, so a failure leaves the old one whole.

  So a token Steam refreshes while someone plays reaches the next build,
  and signing in during a build reaches every app.
- **Steam shipped in 1.1.0, so its old paths are moved and linked back.**
  Released Steam apps keep the session in
  `…/SecondChance/Steam/session/`, take `…/Steam/session.lock` to save it,
  and take `…/Steam/active-wrapp.lock` (an `flock`, its file holding the
  holder's pid and bundle id, one per line) to run Steam. When Second
  Chance starts, it moves each into the new store's folder, if it hasn't
  already, and leaves a symbolic link at the old path. A 1.1.0 app follows
  the link, so it reads and saves the same session, and an `flock` through
  the link locks the same file, so old and new still exclude each other.
  The lock file keeps its format (pid, then bundle id), which old apps
  read to name the holder. This is Second Chance's, run by the app as it
  starts (`AppMigrations`), not the builder's.
- **Big Fish's sign-in isn't released**, so its `…/BigFish/sign-in.reg`
  simply moves into `big-fish:sign-in` with no link left.
- **`STEAM.CLIENT` starts Steam once**, so it updates itself inside the
  mount. Today that first-start update happens during the sign-in, where
  no step mounts the client store.
- **The client store has a lock of its own** (`client`), so two first
  builds at once don't both have Steam update itself into the one folder.
  The second waits for the first, then finds an updated client. Today
  `SteamClientCache` lays a copy over each tree, so this never came up.
- **The sign-in during identification** (decision 20) uses `sign-in`
  through the steam executor's handle on it, since
  identifying isn't a step. The source says which store in its own Swift.

**Big Fish, as stores:**

```dockerfile
# Modules/big-fish/stores
LOCK manager --scope=global
STORE sign-in --scope=global --exclusive=manager

# functions/install: a game the person owns, signed in with their account
BIG-FISH.INSTALL ${input.game} --into=${input.into} --sign-in-store=sign-in

# functions/install-trial: a free trial, which never touches the person's
# account: a session store, empty each build, thrown away after
STORE trial-sign-in --retention=session
BIG-FISH.INSTALL ${input.game} --into=${input.into} --trial --sign-in-store=trial-sign-in
```

- **A trial is its own function**, used by its own edition stage, so it
  has its own steps and keys (`--trial` and another store in its text). An
  owned build never restores a trial's install, or the other way round.
- **The test harness's account is a session store too**
  (`BIG_FISH_TEST_SIGN_IN` gives the build a stage using
  `test-sign-in --retention=session`), so a test run never saves the test
  account over the person's kept sign-in.
- **The integration tests clear Big Fish's trial layers between runs**
  (`sc clean layers --module=big-fish`), since a Game Manager restored from
  a layer may carry state from an earlier trial, and trials stop after a
  few launches.

### 24. A host path is read only when the Wrappfile knows it, or was given it

Any place where a Wrappfile has the builder read a path on the Mac (`COPY`'s
source, a `bind` mount's `source=`, `--answer-file=`, `--automation=`,
`INSTALLER.RUN`'s program, `FROM ${input.…}`) reads it only when one of
these holds:

1. **Its folder is allowed for the bundle, or by the module's
   `module.yaml`**, as folders inside that bundle's or module's own
   folder, which can't reach out of it. A file there is then read as a
   relative path (`assets/disc.iss`) or `module:<id>:/<path>`. Nothing is
   allowed by being beside the Wrappfile.
   - **For a bundle, it's the caller's grant.** Second Chance keeps a
     bundle's in its manifest (`allow-paths: ["assets/"]`), since the
     manifest is Second Chance's, and passes each to the builder as
     `--allow-path` (rule 4). The builder never reads a manifest.
   - **For a module, it's the module's own**, in `module.yaml`, which is
     the builder's: a caller can't know which of a module's files its
     functions read.

   Every shipped bundle and module that reads its own files gets one in
   phase 1.
2. **It's an input's path, or inside one**: `${input.installer}`,
   `${input.disc-1}/setup`. The caller chose to give it. The path is
   checked after `..` and symbolic links are resolved, so
   `${input.x}/../../foobar`, or a link inside the input that points out
   of it, is refused.
3. **The Wrappfile pins its contents**: `--checksum=sha256:<hash>` on the
   step, the file's hash, or `EngineTree`'s hash for a folder. It's
   checked as it's read, and what was checked is what's used.
4. **The caller allowed a folder it's in**: `sc wrapp build
   --allow-path=<folder>`, or the same argument through the builder's
   API. Second Chance doesn't offer it to the people using it. The
   manifest's `allow-paths` (rule 1) is the same permission, given by the
   bundle for its own folder.
   `--allow-path=*` allows any path, for someone experimenting with a
   Wrappfile of their own, so copying in a new asset doesn't mean changing
   the build's arguments each time. The build logs a warning that host
   paths aren't being checked, and the rule still applies to everything
   else: a manifest's `allow-paths` can't be `*`, and Second Chance never
   passes it.

Anything else is an error when planning (every value is known by then),
naming the path and the four ways it could be allowed.

- **This replaces "no Mac paths"** from the draft's trust rules with a
  rule that says what is allowed, so `COPY --checksum=… /opt/thing …`
  works where it once couldn't.
- **It's about what the builder reads for a Wrappfile.** Programs run
  under Wine are the draft's business (no Z:), and a module's program is
  trusted when it's imported (decision 10).
- **The roles say where it applies.** An option or argument whose role is
  `.file` or `.input` (`InstructionSpec`) is a host path, so the checker
  knows which values to check without a list of its own.

### 25. `APP` says what the app is

```dockerfile
APP [--default-id=<reverse-dns id>] [--name="<name>"] [--icon=/Resources/<name>.icns]
```

- **It takes in `ICON`**, which goes.
- **It's a step that writes the tree's `Info.plist`.** `APP` creates
  `Contents/Info.plist` if the tree has none yet, and sets its keys in it,
  where it's written. It's a higher-level instruction than `EDIT`, and
  doesn't name the file it changes, so making the file is part of what it
  does. `EDIT /Info.plist --plist=<key>=<value>` sets a key in the same
  file, but, like any `EDIT`, fails if there's no `Info.plist` yet unless
  it says `--create`. So the file is real from then on: a `RUN` that reads it sees
  what's there, and a stage built `FROM` this one has it, as it has any
  other file. Both are keyed and kept in layers like any step.
- **The assembler merges it with the template's at the end.** The
  template's `Info.plist` gives every key the launcher needs, and the
  tree's keys are laid over it, so a key the Wrappfile set wins. The few
  the launcher must own (`CFBundleExecutable`,
  `SecondChanceLauncherRevision`) are reserved: setting one is an error
  naming it.
- **The app's id is its bundle id** (`CFBundleIdentifier`), which names
  more than the app: its stores (decision 23), the folder the person's
  files are in, and its update lock. Today `WrappBuildHelper` writes it
  from the program id (`WrappLock.wrappBundleID`).
- **The caller's id wins; the Wrappfile's is a default.** The id is, in
  order:
  1. the one the caller gives (`wrapp-builder build --app-id=…`, or the
     builder's API), which Second Chance always gives:
     `au.gare.callum.second-chance.program.<program id>`, as today, and
     for an update the old app's (decision 21);
  2. else the Wrappfile's: `APP --default-id`, or an `EDIT` of
     `CFBundleIdentifier`, whichever comes last among the steps the target
     is built from. The name `--default-id` says it can be overridden;
  3. else the build fails, saying an id is needed. A bundle id must be
     given somewhere, so an app is never named by accident, and no folder
     name ends up in an id or a report (decided 2026-11-05).

  Every value is known when planning, so the id is always known before
  any store is mounted. The manifest's `former-bundle-ids` stay Second
  Chance's.
- **Any `Info.plist` key** can be set with `EDIT /Info.plist
  --plist=<key>=<value>`, as `EDIT --ini` sets an `.ini`'s, `APP`'s keys
  included, for an author who wants that lower level.
  - A key set both ways, or more than once, has the last value written,
    as with any file. Since each stage has its own tree, only the steps
    the target is built from count.
  - The id as planned is above. The keys the launcher needs stay reserved
    (`CFBundleExecutable`, `SecondChanceLauncherRevision`); that a bundle
    could set others the launcher or reports read, or write `Info.plist`
    with a `COPY`, is accepted for now (decided 2026-11-05).

### 26. `wrapp-builder`: the builder's own command-line tool

A command-line tool beside `sc`, `wrapp-builder` (a working title), that
builds, checks and formats Wrappfiles. It's the builder's, not Second
Chance's: if the builder becomes a repository of its own, the tool goes
with it. So it knows nothing Second Chance does, and that makes it the test
of where the line between them is. Anything it can't do without Second
Chance shows that something of Second Chance's has leaked into the
builder, or that something of the builder's has stayed in the app.

- **It's a package of its own, `Packages/WrappBuilderCLI`**, so it moves
  with the builder and links the module packages without a cycle (decision
  22). It depends on the builder, `WrappKit`, `WrappModuleKit` and the
  modules' packages, and nothing of Second Chance's.
- **What it does** (names provisional):

  ```text
  wrapp-builder check  <bundle>                 parse and check, the host path rule included
  wrapp-builder plan   <bundle> --target=<stage> [--input name=value]…   the plan, as `sc bundle plan` shows it, with --layers
  wrapp-builder build  <bundle> --target=<stage> [--input …] [--app-id=…] [--allow-path=…] [--template=<app>] --out=<app>
  wrapp-builder fmt    <Wrappfile>… [--check]    format in place, or only report
  wrapp-builder module check | release <module>  what `sc module` does today
  wrapp-builder engine prepare | fetch <module>  what `sc engine` does today
  wrapp-builder layers list | clean              the layer store
  wrapp-builder stores list | remove <owner>:<name>
  ```

- **It speaks only the builder's language.** A build is a Wrappfile, a
  target stage, inputs by name and value, and the caller's choices: the
  app id (`--app-id`, which wins over the Wrappfile's `APP --default-id`,
  decision 25), allowed paths, the layer policy. It has no editions,
  sources, game detection, catalogue, manifest `volumes:`, Second Chance
  phases or failure reports. Those stay Second Chance's, in `sc` and the
  app.
- **The template is the caller's to give, for now.** The launcher is
  Second Chance's (`WrappTemplate.app`, built by its Xcode project), so
  `--template=<app>` names the one to lay in at the end; without it, the
  tool makes the tree and says it isn't a runnable app. What the template
  gave a build is moving to modules (decision 22): the in-process helpers
  to wine, winetricks to wine, AutoIt to an `autoit` module. That's the
  start of separating the template from Second Chance; a launcher of the
  builder's own is later work ("To come back to").
- **It prints what it emits.** Events go to stdout as they happen: plain
  lines on a terminal, or one JSON object per line with `--events=json`,
  `replayed` included, so a script (or a future front end) can read them.
  `EMIT` strings are printed as they are, unread. Logs go to stderr.
- **It asks the generic questions on a terminal**, the three kinds an
  added module can ask (`choose`, `confirm`, `instructions`, decision 20),
  and has a flag for each answer when there's no terminal
  (`--answer <question id>=<answer>`). A step that needs a question it
  can't ask fails, saying which.
- **It runs every shipped executor and module program**, since every
  shipped module's Swift is in its own package and none needs Second
  Chance's (decision 22). Until a module's executor has moved there (the
  installer and Her's in phase 4, Steam and Big Fish in phase 6), a plan
  that needs it fails when planning, naming the modules the tool can't
  run yet. Steam's sign-in is Steam's own window under Wine, so the tool
  needs nothing of Second Chance's to show it; it says, on the terminal,
  to sign in there.
- **`sc` keeps Second Chance's side and calls the builder for the rest.**
  `sc bundle check` checks the manifest and the catalogue, then the
  Wrappfile through the same library code `wrapp-builder check` uses.
  `sc bundle plan` turns an edition into a target and inputs, then plans.
  `sc module`, `sc engine`, `sc clean layers` and the stores commands
  become thin calls to the same code, kept so existing habits and docs
  still work. `sc lint` runs `wrapp-builder fmt --check` over every
  bundle and module.
- **`fmt` needs a parser that keeps everything.** Formatting rewrites a
  file, so it can't lose a comment or a blank line. The parser grows a
  lossless syntax tree beside the one planning uses: every comment, blank
  line and continuation kept with its position, as Swift's own syntax
  tree does. Planning still ignores them. The style it writes:
  - instructions in upper case (the bundle plan's decision 9);
  - two spaces of indent per block (`FUNCTION`, `IF`, `LAYER-HINT`);
  - a continued line indented four spaces past its instruction;
  - one blank line between stages;
  - comments kept where they are, with their text unchanged.
- **`fmt --migrate` carries out phase 1's syntax changes.** It applies
  `module:<id>:/<path>`, `FROM --module=`, `APP` for `ICON`, `base` gone
  and `EMIT` for `--progress` over every bundle and module, so that phase's
  edits are made by a tool rather than by hand, and checked by `fmt
  --check` afterwards.
- **Which of a bundle's folders it may read is the caller's to say**
  (decision 24). Second Chance reads the manifest's `allow-paths` and
  passes each as `--allow-path`, so the tool never reads a manifest.
  Someone building with the tool directly passes them, or
  `--allow-path=*`.

### 27. Fullscreen when the program asks for it, `--wine.window` to override

Added 2026-11-05, by Claude for Callum, from porting LaserTank with the
port-program skill, and revised the same day; the design is the user's.
LaserTank is a small fixed-size GDI window, and nothing could say a program
stays windowed. Native fullscreen (`native_fullscreen.m`) takes a window
fullscreen when Wine has marked it fullscreen-capable (any resizable window
with no parent) or when it's a borderless window covering the screen that
Direct3D draws into. That judges the window's shape, not what the program
wants: it got LaserTank right by luck, and would take a resizable window
meant to stay windowed (Iji's "Press Escape to run in windowed mode").

- **Wine: the helper detects the program asking for fullscreen**, from
  inside the game's process. Any of these counts:
  - a display mode change (`ChangeDisplaySettings`, which EmulateModeset
    and the mode scaling helper already see);
  - DirectDraw's exclusive fullscreen (`SetCooperativeLevel` with
    `DDSCL_FULLSCREEN` or `DDSCL_EXCLUSIVE`), including when cnc-ddraw
    turns it into a window;
  - a Direct3D device created with `Windowed = FALSE`;
  - a borderless window covering the screen (already detected).

  When one is seen, native fullscreen does what it does today; when none
  is, the window is left alone. It keeps watching for the whole session,
  since a game may switch later, and catches a request made before the
  program's window exists. Its 90 s "no eligible window" give-up goes.
- **The helper reports what it decided and why** ("fullscreen: the program
  set DirectDraw's exclusive mode", "windowed: the program hasn't asked"),
  through the helper report path, for the wrapp's log and WrappPuppeteer.
- **`--wine.window=fullscreen|windowed` is an override**, a wine module
  `LAUNCH` option (the user's call: a Wine matter, so not the core's), for
  a program detection gets wrong. Left out, the helper detects. No shipped
  bundle needs it.
- **ScummVM and DOSBox stay fullscreen**, as today (`-f`, DOSBox's
  setting): their games were made for a full screen, and the engine scales
  them. No override.
- **The tests say what they expect**: `tests: { window: fullscreen |
  windowed }` in the manifest, Second Chance's, since it's an expectation,
  not how the program runs. WrappPuppeteer fails when the result differs:
  an expected fullscreen game must reach a fullscreen Space (and, once
  detection reports, the report must agree); an expected windowed one
  mustn't. Every Nancy Drew bundle says `fullscreen`; SkiFree `windowed`,
  Lure of the Temptress and Tyrian 2000 `fullscreen`. A bundle that says
  nothing is held to the helper's report.
- **Built in two parts.** Phase 1: the override, the test expectation and
  WrappPuppeteer's check, with the helper's behaviour as today. Phase 2c,
  with the helpers moving into the wine module's package: the detection
  and its report.
- Docs: `docs/wrappfile.md` (the launch), `docs/wine-in-process-helpers.md`
  (native fullscreen, its "which window"), `docs/testing.md`,
  `docs/program-bundles.md` (`tests.window`) and the manifest schema.

### 28. The cursor lock is the launch's choice: `--wine.cursor-lock`

Added 2026-11-05, by Claude for Callum, from porting Iji; the design is the
user's. The lock exists only because cnc-ddraw runs a game in a window and
swallows its first click, but it was inferred from the exe importing
`ddraw.dll`, and inconsistently: Iji (Game Maker 7) imports both
`ddraw.dll` and `d3d8.dll` and declares `--wine.graphics=direct-3d`, and
its log said cursor lock wasn't needed (`WineRuntime`'s report reads the
declared graphics) while the helper armed it anyway
(`inProcessHelperVariables(gameExe:game:)` reads the imports) and sent 15
middle clicks.

- **A wine module `LAUNCH` option, `--wine.cursor-lock`** (a flag). The
  runtime arms the lock only when the launch asks for it, never from the
  exe or from `--wine.graphics`. The other places that inferred it
  (`SteamClient`, `BigFishGameManager`) read the launch too.
- **Every bundle that runs `DO wine.cnc-ddraw` adds it to its `LAUNCH`**
  (the Nancy Drew DirectDraw games), so they behave as today; their
  integration tests' first-click check covers it. The planner's check
  that cnc-ddraw and `--wine.graphics=direct-draw` go together grows to
  the lock: a launch with cnc-ddraw and no lock is an error.
- **A launch recorded before the option keeps today's inference**, as
  `GameGraphicsAPI` already falls back for launches recorded before
  `--wine.graphics`. The marker is `RecordedLaunch.format`: a launch
  recorded with format 2 or later says what it wants, and one without
  (format 1) is inferred.
- Mode scaling (`mayUseDirect3D`) stays inferred.
- Tests: `InProcessHelperVariablesTests`. Docs:
  `docs/wine-in-process-helpers.md` (cursor lock) and AGENTS.md's gotcha
  that names `Wine.inProcessHelperVariables`.

### 29. cabextract, for winetricks, at build time only

Added 2026-11-05, by Claude for Callum, from porting Iji; the design is the
user's. Second Chance doesn't carry cabextract, so no winetricks verb that
unpacks a Microsoft redistributable works in a build (`directmusic`,
`d3dx9*`, `quartz`, `vcrun*`, `corefonts`). Iji sat on "Loading, please
wait" for more than six minutes with Wine's own DirectMusic synth, and
loads in about ten seconds with `winetricks directmusic`.

- **It's already downloaded.** Sikarugir's wrapper template, the wine
  package's `wineskin` source, holds
  `Template-1.0.11.app/Contents/Configure.app/Contents/Resources/cabextract`
  (x86_64, linking only libSystem and libiconv). `WineBuild.prepare`
  keeps it in a `build-tools/` folder of the prepared tree.
- **It never reaches a wrapp.** `build-tools/` is left out of what's
  installed into one (the `engines/<module>.files` list).
- **The wine executor puts it on winetricks' PATH** when it runs
  `WINE.WINETRICKS` (today, `Winetricks`), so it's the builder's, not the
  app's.
- The prepared hash changes, so the wine module gets a new release with
  the new hash. A build tool isn't part of the prefix layer's key beyond
  the engine's prepared hash.
- Docs: `docs/modules.md` (engine packages) and `docs/steam.md`'s line
  about cabextract.

## Syntax by example

**An added module that installs from a shop**, with a program, a signal
and a store for its sign-in:

```yaml
# someone/gog/module.yaml
format: 1
id: "someone/gog"
release: 1
program: "bin/gog-module"
depends-on: ["wine@10"]
functions: ["functions/install"]
signals: ["signals/alive"]
stores: ["stores"]              # LOCK gog --scope=global, then STORE sign-in --scope=global --exclusive=gog
build:
  instructions:
    INSTALL:   { layer: suggested, required: [into],
                 options: { into: { kind: value, role: location },
                            sign-in-store: { kind: value, role: store } },
                 arguments: { count: 1, roles: [input] } }
```

```dockerfile
# someone/gog/functions/install
FUNCTION install
  INPUT game
  INPUT into
  GOG.INSTALL ${input.game} --into=${input.into} --sign-in-store=sign-in \
      --alive=self.alive
END
```

```dockerfile
# A bundle's Wrappfile
FROM --module=wine@10 prefix AS gog
USE someone/gog
DO gog.install --game=${input.game} --into="C:/GOG Games/Example"
LAUNCH "C:/GOG Games/Example/game.exe"
```

The bundle's manifest would give `game` as the download source does an
input (decision 20): a value the person picks or a URL, since a shop
someone adds a module for has no source of its own in Second Chance.

**A patcher that never exits by itself**, closed by its signal rather
than by AutoIt:

```dockerfile
SIGNAL patched
  WATCH --log="${input.into}/patch.log" --contains="Update complete"
END

RUN --name=example-patch --on-failure=ask --done=patched \
    --mount=type=fetch,url=…,sha256=…,target=${input.into}/patch.exe \
    ${input.into}/patch.exe
```

## Phases

Each phase leaves every source building, ends with the unit tests passing
and an integration run of one game per source it touched on a test Mac
(the remote one, not the user's), and updates the docs its change makes
wrong. Commit each phase and carry on. Keep running notes in
`.local/notes/builders-refactor/implementation-notes.md`.

The old builders keep working until the phase that moves their source: they
keep making their wrapp from the template first (`createBaseWrapp`), and
the helpers they call (`runAppSteps`, `installMissingEngines`,
`cleanupUnusedEngine`) are deleted only with the last builder that calls
them.

0. **Event streams, recorded.** First, run an update on a test Mac, since
   none has run since engines moved to the store, and fix what that finds.
   Then record the event stream of one integration build per source as
   fixtures, with paths and times normalised: a disc game (Blue Moon), a
   ScummVM disc (Royal Tower), a Her Windows download, a Her Mac download,
   Steam, Big Fish trial, a download (SkiFree) and an update. The disc and
   Her Windows ones are run cached and uncached, since they're the only
   sources cached today. The fixtures are an ordered list of the events
   each source must publish, not every event, so they don't break on
   timing, `stepProgress` or which games an account owns. They're the
   contract decision 17 keeps, and every later phase's integration runs
   are checked against them, with the differences a phase means to make
   (new events, `stepProgress(nil)` at each step) listed beside them. Unit
   tests with fake executors check only the runner's own events.
1. **Declarations, syntax and the tool** (decisions 5, 24 to 26):
   - the schema's `build:` (with `setup:` and `reads-data:`), and every
     `BuildModule` declaration moved into it; the checker and planner read
     data; the test comparing each executor's instructions and options
     with its YAML, against today's builders for now, and the options no
     one reads removed or carried out (decision 5);
   - `Packages/WrappBuilderCLI` with `wrapp-builder check`, `plan`, `fmt`
     and the lossless syntax tree `fmt` needs, and `module` and `engine`
     moved from `sc`;
   - the syntax every bundle and module needs, in one pass by
     `wrapp-builder fmt --migrate`: `module:<id>:/<path>`,
     `FROM --module=`, `APP` for `ICON`, `base` gone, `--must-exist`
     renamed `--keys-must-exist`, `allow-paths` in every manifest and
     `module.yaml` that reads its own files, and the retired
     `type=source`, `wine.drive=` and `RUN`'s unused `describe`,
     `if-skipped` and `ask` options gone. `--progress` and `VOLUME` stay
     until phase 6, when `--migrate` runs again for them;
   - the host path rule in the checker; the app id rule (the caller's,
     else `APP --default-id`, else an error), with Second Chance passing
     `--app-id` for every build; and `when-changed` comparing planned
     text, with each stage's planned text recorded in a wrapp's lock;
   - `docs/wrappfile.md`'s stale paragraph on `WrappfileTodayTests`, and
     the `assemble` comment in `Modules/nancy-drew/functions/configure-ini`,
     corrected;
   - new releases of every module;
   - `--wine.window` and `tests.window` (decision 27), and
     `--wine.cursor-lock` (decision 28), recorded with the launch and read
     by the wrapp and WrappPuppeteer, every Nancy Drew bundle saying what
     it does today.

   Nothing a build does changes, and no game launches differently.
2. **The runner and the core**, in three parts, each checked before the
   next (decisions 1, 3, 4, 17, 22):
   - **2a. The runner, the core and the download source.**
     `WrappModuleKit`'s local half (`ModuleExecutor`, `StepContext`,
     `EventEmitter`, `InputProvider`, and `PlannedStep`, `ModuleData` and
     `KeyInputs` moved into it), `PlanRunner` and `LocalStepContext`, its
     calls `@concurrent`, its events on one ordered stream, and
     `context.ask` cancellable. `COPY`, `ADD` (emitting byte progress as
     `stepProgress`, with `Downloader` streaming in chunks), `EDIT --ini`
     (with `--create`), `RUN` with `bind` and `fetch` mounts,
     `context.runProgram` with its exit code and time limit, and
     `--on-failure` in general. The download source moves onto it, and
     `wrapp-builder build` arrives, with `--app-id`, `--template`,
     `--events=json` and the generic questions on a terminal. SkiFree is
     built `FROM --module=wine@10 prefix`, so until 2c the runner makes
     that stage with today's `WineManager.makeWinePrefix`. Verify:
     SkiFree, Lure of the Temptress and Tyrian 2000 build and launch.
   - **2b. Events and `EMIT`.** The runner's events (`stepStarted`,
     `stepRestored`, `stepDone`, `stepSkipped`, `emitted`), each kind
     lasting or moment as decision 17's table says, and `EMIT` planned
     through functions. In the app: turning them into `WrappBuildEvent`s,
     `emit-vocabulary.yaml` and the code made from it, its table of phases
     by instruction (for restored steps too), the phase never going back,
     its check of every shipped bundle's `EMIT`s, and `AutomationBridge`
     serialising the new events. `--progress` stays beside `EMIT` until
     phase 6, since the old builders still read it. Verify: the
     event-stream checks pass for every source.
   - **2c. The wine and nancy-drew modules' packages.** `WineKit` moved
     into the wine module's package as its kit, with winetricks; the
     in-process helpers' source and build script moved there from
     `WrappTemplate/InProcessHelpers/`. Wine's executor: `DRIVES`,
     `REGISTRY`, `WINETRICKS`, `MOUNT`, and its setup steps `HELPERS` and
     `PREFIX`. `NANCY-DREW.CONFIGURE-INI`. Both portable, used by the old
     builders in place of `WineSteps` and `configureGameINI`, which go.
     cabextract in the wine engine's `build-tools/`, on winetricks' PATH
     (decision 29). Native fullscreen detecting the program asking for
     fullscreen, with its report (decision 27).
     Verify: one Wine disc game and one Her download build and launch,
     and a build's Wine process logs `[CocoaStart]`, showing the helpers
     loaded.

   Stages still share one wrapp until phase 3.
3. **Stages as trees** (decision 2), for builds the runner carries out:
   trees starting empty, shared down a linear chain and cloned where
   stages branch, `COPY --from=<stage>` between them, and the target's tree
   as the wrapp. `USE` planning a module's setup: the core `ENGINE` step,
   which installs, replaces or leaves an engine, and the module's own
   setup steps. The assembler laying in the template's files (reserved by
   its file list) and merging `Info.plist` at the end. `APP` and
   `EDIT --plist` as steps. The working folder in `$TMPDIR`, and the
   sweep deleting a tree whose run never closed. Verify: the download
   source's three games, and Royal Tower's disc edition built through the
   runner as a test (a ScummVM target `FROM scratch`), with no prefix or
   Wine in it. Its Her and Steam editions are checked when those sources
   move (phases 4 and 6).
4. **Installs**: the installer, disc, her-download and autoit modules'
   packages (decision 22), with `GameInstallerRunner`, `InstallerPlan`,
   `InstallStallWatch`, `CiderPackage` and `ISOMounter` moved out of the
   app into their kits, and AutoIt into the autoit module. The installer,
   `WINE.KEEP-DISCS` (with `--into` and `--combined` carried out rather
   than checked), `disc` and `her-download` executors, and the disc
   module's `InputProvider` handing every disc, or image, as a mounted
   folder. Patches become ordinary steps (`runPatchStep` goes). The disc
   and Her sources move onto the runner, with `identify`, the edition from
   detection, and the input provider. Then the update source (decision
   21): `updates` and `previous` as inputs, lists, objects and `has`,
   `FROM ${input.…}`, `wine.prefix-settings` and the wine module's update
   stage, with `${previous.wine}` and `${previous.bundle}` becoming
   `${input.previous.wine}` and `${input.previous.bundle}`. The update
   builder's call to `cleanupUnusedEngine` goes with it. Verify: Royal
   Tower's Her edition carries no prefix, and an update of an app built
   before this phase keeps its id and saves.
5. **Layers at every expensive step** (decisions 12 to 15, 18). Step key
   chains with `LayerKey.formatVersion`, the restore walk over stages,
   executor revision numbers in `executor-revisions.json` (generated into
   Swift) with their source hashes, `sc module revise`, and `sc release`
   and `sc test integration` refusing a stale one; the wine executor and
   the core split by instruction. `keyInputs` and `reads-data`, checkpoints
   (checking for a wineserver first), `LAYER-HINT` blocks (the parser's
   `LAYER` renamed; a function's steps keyed and kept as the call site's),
   locks held for steps that can't ask and not for those that may
   (`may-ask`), `--debug layer-every-step`, and replay of lasting events.
   The policy's `modules`. `sc bundle plan --layers`. Room to build: the
   runner adds up what a plan's kept layers and trees are likely to take,
   checks before each expensive step, tells a full disk apart from other
   failures, prunes the layer and engine stores to make room, and offers
   to try again from the last kept layer. `InstallLayer` and
   `WineBuild.prefixLayerKey` go, and the first build of this version
   clears the old layer store and `wine-prefix-cache/`, since no key made
   before it could match one made after.
   - **Verify on a test Mac**, with `--debug layer-cache=all` (the test
     default, `modules`, keeps no install layers): two builds of every
     disc game, the second's log showing `stepRestored` for the install.
     A build whose patch step changed restores the install and redoes only
     the patches. A changed prefix stage makes everything fresh. The log
     says what each checkpoint cost, idle and with every core busy
     (`SystemLoad`), which decides whether the nancy-drew bundles need
     `LAYER-HINT` blocks around their patches.
6. **Stores, then Steam and Big Fish** (decisions 4, 16, 20, 23). First
   stores: `STORE` and `LOCK`, `type=store` mounts with `snapshot`,
   retention and its folders (`stores/<owner>/<name>/`), the test root,
   the `keep`-store exception for a module's own executor, store runs
   (opened and closed by the runner, no layer inside one, closing in order
   and finishing after a cancel), `--exclusive` locks with their
   `waiting` and `acquired` events, log lines and headless limit
   (`SECOND_CHANCE_LOCK_WAIT`), stores on `LAUNCH` in place of `VOLUME`
   (each `VOLUME` form's mount, inherited through `FROM`, and the checker
   refusing a launch mount whose target is still in the tree), the
   recorded launch's store mounts, `sc store list`, `sc store remove` and
   `sc clean stores`, and `wrapp-builder fmt --migrate` again for
   `VOLUME` and `--progress`. Then Steam and Big Fish:
   - their modules' packages, depending on the wine module's, with
     `SecondChanceKit/Steam/` and `SecondChanceKit/BigFish/` moved into
     their kits, apart from the windows and prompts, which stay; their
     events defined there; and the wrapp's `SteamRuntime` and
     `BigFishRuntime` and Second Chance's menus importing them;
   - the "Sign Out of Steam" menu and `sc clean steam-session` and
     `sc clean steam-client` calling the steam kit;
   - Second Chance's `AppMigrations` moving 1.1.0's Steam session and
     locks into the store and linking back, and Big Fish's sign-in moving
     in;
   - their executors, `identify` in a throwaway clone of the module stage
     (built once for the build when there's no layer), their stores, the
     Big Fish trial and test-account stages, and their sign-in stores'
     `open` and `close`, with `SIGN-OUT` gone;
   - their installs keyed on the game, so a later build may restore a
     version older than the store's, said in `docs/steam.md` and
     `docs/big-fish.md`.

   `--progress` goes here, and so do the old builders and the helpers
   only they called (`runAppSteps`, `installMissingEngines`,
   `cleanupUnusedEngine`, `createBaseWrapp`).
   - **Verify:** with `--debug layer-cache=all`, a second Steam build
     restores Steam's client and the game's install from their layers,
     without signing in to install again. A 1.1.0 Steam app still signs
     in after Second Chance has moved its session, and an old app and a
     new build still exclude each other. Big Fish's trial builds (fresh,
     since its trial runs out: rebuild for a new one, and end leftovers by
     pid), with the integration tests clearing Big Fish's layers between
     runs. WrappPuppeteer's Steam launches start with no stores, and the
     Steam smoke test still finds its sign-in.
7. **Signals for builds** (decision 19), with `EMIT --on` and `--off`,
   `${signal.…}` and `${program.…}`. `SIGNAL`/`WATCH` parsing, checking and
   planning, the watcher in `ProcessKit` (with `LaunchActivityMonitor`),
   `--grows` and `--wine.busy` (counting the step's own processes only),
   the `--alive`, `--done` and `--asks` step options, coalescing a busy
   listener, and `installer.alive`. `InstallStallWatch` reads the signal.
   - **Verify:** the stall test (`kill -STOP` under a 30 s window) still
     stops the install about 31 s after its last sign. A full pass of
     disc installs logs a longest quiet within what the window allows.
8. **Module programs** (decisions 7 to 9, 11, 20). Load modules someone
   adds from Application Support, as the draft laid out. Add `sc module
   import <folder>`, with the importer's checks (schema, the as-imported
   hash, architectures, protocol version, a signed copy and its cdhash,
   quarantine after agreement). Build the protocol, `ExternalExecutor` and
   `WrappModuleKit`'s remote half (`RemoteStepContext`,
   `ModuleProgram.serve`), the test that the protocol's calls match the
   two protocols' methods (less `hello` and `$/cancelRequest`), and
   `runProgram`'s mounts held to the host path rule. Added modules'
   questions get answers when nobody's there: `--answer` on
   `wrapp-builder`, and `SECOND_CHANCE_ANSWERS` (JSON) for a headless
   Second Chance build. Add a fixture module, `example/copy-tree`, in
   `TestFixtures/`, a Swift program that copies an input into the tree
   through the protocol and emits progress. Run every portable shipped
   executor out of process in a unit test, which is what keeps a later
   graduation (`docs/plans-for-consideration/module-graduation.md`) a
   move.
   - **Verify:** an integration build of SkiFree through a test bundle
     whose `COPY` is replaced by the fixture module's instruction.
   - The app's import window isn't built here (out of scope).
9. **The sandbox spike** (decision 10). Run the fixture module under a
   write-limited, no-network profile on macOS 15 and 26, and record what
   it showed. Then either sandbox every module program or keep agreement
   alone, and update decision 10's warning text to match. Nothing waits on
   it.
10. **What's left.** Delete `SecondChance/Builders/`, and with it
    `CacheManager` and its development cache. Move `WrappBuildHelper` into
    `WrappAssembler`, the legacy values out of `completeBuild`, and rename
    `patchApplied` and `patchFailed` one release after phase 4, which made
    patches ordinary steps. Update AGENTS.md (the architecture diagram, its
    "Adding a source" and key abstractions, the Gotchas about the layer
    cache). Then the plan goes into `docs/historical-plans/` with its "As
    implemented".

## Testing

- **Runner, in the package, with `swift test`.** These use fake
  executors, so nothing runs: steps in order, stage trees and
  `COPY --from`, `--on-failure`, a step nobody declares failing at check
  time, `finish` called on failure and cancel.
- **Layers.** Each layer rule, the deepest hit restored, the chain
  invalidating forward only, an edit to an executor changing its steps'
  keys and no others, in a split executor an edit to one instruction's
  folder changing only its steps' keys and an edit to `Shared/` changing
  all of them,
  hints changing no key, a skip putting `skipped: <name>` in every later
  key, a block's steps keeping no layer before its last,
  `keyInputs` ending look-ahead, a function's steps keyed and kept as if
  written at the call site, a nested block joining its outer one's layer,
  empty blocks and a bare `LAYER` refused, a module's
  store runs worked out from the plan (ended by another step and by a
  stage's end, a layer inside one kept after it, every open run closed on
  failure and cancel), checkpoint order, replay of lasting events only,
  tagged `replayed`. Use a temporary layer store, as
  `LayerStoreTests` does.
- **Declarations.** Each executor's static list against its module's
  YAML (phase 1).
- **`EMIT`.** In the package: emitted in order with the steps around it,
  carried through a function's expansion, dropped with an untaken branch,
  in no key, and recorded and replayed with a layer. In the app: unknown
  `second-chance.` strings refused, a phase reached and kept, never going
  back, the table's defaults, a substep applying to the next step, and
  every shipped bundle's `EMIT`s checked.
- **Event streams.** `EventStreamTests` against phase 0's fixtures,
  through the runner with fake executors that emit what the real ones
  would. The integration suite still compares real runs.
- **Protocol.** The fixture module program over real pipes: hello and
  version refusal, a run with `runProgram` stubbed, an emit, an error of
  each kind, cancel and its 10 s, a program that dies mid-step. Plus the
  `disc` executor out of process.
- **Signals.** The parser, checker and planner, and the watcher against a
  fake program writing a log and growing a folder. `--done` ending a
  program that waits for ever.
- **Integration**, on a test Mac: every phase that touches
  orchestration runs one game per source it touched. Phases 5 and 6 run
  the whole disc suite, since they change what every build restores.

## Docs

- `docs/wrapp-build.md`:
  - rewrite its shape, the disc build step by step, "Who owns what",
    "Events are the contract", "The layer cache", "What a step says is
    what happens", "Updating a wrapp" and "Adding a source";
  - "A stalled install" now reads the signal.
- `docs/modules.md`: `build:` in `module.yaml`, executors and their
  packages and kits, revision numbers, `program:`, stores, and "What lives
  where".
- `docs/wrappfile.md`: `EMIT` (passed to the caller, never read),
  `LAYER-HINT` … `END` (and a function's steps being the call site's for
  layers), `STORE`, `LOCK` and `type=store` mounts, `bind`'s `source=`,
  `EDIT --create`, `APP` and the default id, the host path rule, `FROM
  --module=`, `FROM ${input.…}`, list values and `has`, `SIGNAL`/`WATCH`,
  `--alive`/`--done`/`--asks`. Its stale paragraph on what
  `WrappfileTodayTests` checks (Steam editions built by default stages,
  Big Fish by its builder, patches from `GamePatchCatalog`) is corrected
  in phase 1, or before.
- `docs/program-bundles.md`: `allow-paths`, `build.base` gone, `volumes:`
  keyed by store, the `app-id` input.
- `docs/updates.md` and `docs/wrapp-build.md#updating-a-wrapp`: updates as
  inputs (decision 21).
- `docs/wrapp-launch.md`: the user files folder's `stores/`, and stores
  mounted at launch.
- `docs/dev-cli.md`: `wrapp-builder`, `sc store …`, `sc clean stores`,
  `sc module import`, `sc module revise`, `--allow-path`, `--debug
  layer-every-step` and `sc bundle plan --layers`.
- `docs/failure-reports.md`: an added module's id and release in a report.
- `docs/logging.md`: a module program's stderr, and the lock waits.
- New `docs/module-programs.md`: the protocol, `WrappModuleKit`, import,
  trust, what an added module can't do. Add a row in AGENTS.md's table.
- `docs/steam.md`, `docs/big-fish.md`, `docs/her-download.md` and
  `docs/game-patches.md`: where their build code now is, their layers, and
  for Steam and Big Fish, that an install may be restored at an older
  version.
- `docs/testing.md`: the event-stream fixtures, the fixture module, and
  stores under test.
- `docs/plans-for-consideration/signals.md`: the dated note (decision 19).
- AGENTS.md: the architecture diagram, `WrappBuildStrategy`'s bullet
  becoming the source's, "Detect the game once" (now `identify`), the layer
  cache Gotcha (`prefixCodeRevision` goes: executors have revision numbers,
  checked by `sc release`), the module packages and their kits, and the
  shared-code section for the runner and `WrappModuleKit`.
- `docs/wine-in-process-helpers.md`: the helpers as the wine module's,
  laid in by its setup steps, and needed at build time.
- `docs/wrapp-build.md` also: "The template" and "What a wrapp holds" (the
  template laid in at the end, engine and setup steps), "Running Wine"
  (`context.runProgram`, the wine kit), "Seam 1" (`context.ask`),
  "Cancelling" (store runs' cleanup), "Headless runs"
  (`SECOND_CHANCE_ANSWERS`, `SECOND_CHANCE_LOCK_WAIT`) and "The download
  source".
- `docs/modules.md` also: engine packages and the `ENGINE` step, the
  autoit module, `setup:` and `reads-data:`.
- `docs/steam.md`: the session moved into the store and linked back for
  1.1.0 apps.
- CHANGELOG: written by `sc release` from commit messages, as always, so
  nothing by hand.

## Out of scope

- **A runtime or test facet for an added module**: a program in the wrapp
  or in WrappPuppeteer. Needed for path types and launchers someone adds.
- **Sources in modules**: a store someone adds with its own sign-in
  screen.
- **The app's import window** and its Settings controls (the draft's).
  Phase 8 imports with `sc` only.
- **`SERVICE` and `LAUNCH`'s events**: the rest of the signals plan.
- **Translating an added module's text.**
- **Remote or shared layer caches.**
- **Layers chosen by timing** (decision 13 has why).

## Open questions

Settled on 2026-11-04, among much else recorded in each decision:
executors have revision numbers checked against their source by
`sc release` (decision 14); a module program runs programs only as a `RUN`
would, with no services between modules (decisions 8 and 22); a Wrappfile
suggests where layers go with `LAYER-HINT` blocks, and nothing marks a step
"always run" (decision 13); a Wrappfile `EMIT`s strings the builder never
reads, and Second Chance declares the ones it reads (decision 17); only
lasting events are kept with a layer (decision 18); stages share a tree
down a linear chain (decision 2); `base` goes (decision 21); Steam and
Big Fish each have one kept sign-in store, which a module's own executor
may use at build time (decision 23).

Still open, with the answer the plan assumes:

1. **Is the sandbox worth its warning text?** Phase 9 decides.

## To come back to

- **Before `wrapp-builder` is split out of this repository** (noted
  2026-11-05):
  - the store and layer roots become the caller's to give. Today they're
    `Application Support/SecondChance/…` and `Caches/SecondChance/…`,
    named for Second Chance;
  - a launcher of the builder's own, or a clear way for a caller to give
    one, so `--template` isn't needed to make a runnable app;
  - nothing else of Second Chance's in what the builder lays into an app.
- **Seeding a store from another** (`--seed-from`): designed (a store
  made, the first time it's used, as a clone of another's contents, one
  way) and left out until a module needs it.

- **A module program in the wrapp**, once the sandbox question is
  settled, so an added module can add a launcher or a path type.
- **A way for a player to start fresh.** Building without layers is a
  debug setting and an `sc` command today. Nobody playing should normally
  need it, since keys are meant to be right. If a bad layer ever reaches
  someone, the error screen could offer "Try again from the start", which
  rebuilds with the policy `off`.
- **Layer sizes that account for shared blocks**, if pruning by size
  turns out to remove layers that cost almost nothing.

## As implemented

Built 2026-11-05, on `refactor/builders-into-modules`, phase by phase.
Where the code differs from the plan, or a phase left something out:

- **Phase 0's event-stream fixtures weren't recorded.** Each phase was
  checked with integration runs on a test Mac instead, of the sources it
  moved, and the update source by updating apps built before the branch.
- **Executors aren't all portable yet.** The installer and her-download
  executors (`InstallerExecutor`, Her's) wrap app-side code
  (`GameInstallerRunner`, the Cider unpacking), which is tied to the bus,
  `WrappBuildError` and reports; the disc input provider (`DiscInputs`) and
  `ISOMounter` stay in the app; AutoIt isn't a module. An edition is the
  bundle's one edition for the source, as no shipped bundle has two.
- **Executor revisions are a `static var revision`** on each executor (and
  `CoreInstructions.revision`), not `executor-revisions.json` with source
  hashes and `sc module revise`. A skipped step taints the rest of the
  build (nothing more is kept) rather than naming itself in later keys.
  Layer locks hold only while a layer is cloned in. There's no room-to-build
  estimate or `sc bundle plan --layers`.
- **Stores** (decision 23): only app stores move under test; global ones
  stay real, as the integration tests sign in with the saved Steam session.
  Steam keeps `SIGN-OUT` and its client cache laid over each tree rather
  than a `snapshot` mount; Big Fish has no separate trial or test-account
  functions, so no session stores, and `STORE` inside a function wasn't
  built. A store is used per step, not across consecutive steps. Steam's
  identification runs its client stage in a tree of its own, so a build
  starts Steam twice. `sc store list`, `sc store remove` and
  `sc clean stores` are built, and `files=` launch mounts (`FilesMount`),
  which no shipped bundle uses yet.
- **Signals** (decision 19): the watcher is in WrappBuilder, not ProcessKit,
  and `LaunchActivityMonitor` didn't move. `--done` and `--asks` are planned
  and watched, but nothing acts on them yet. A step's key names its signal,
  not its expanded watches.
- **Module programs** (decisions 7 to 10): not built are the importer's
  signed copy, cdhash and quarantine; `runProgram`'s mounts held to the
  host path rule; the protocol's generated schema and its methods test;
  shipped executors run out of process in a test; `--answer` and
  `SECOND_CHANCE_ANSWERS`; and the SkiFree integration through the fixture
  module.
- **The sandbox spike** (phase 9) chose to sandbox every module program:
  `sandbox-exec` with no network and writes only to the temporary folder
  and the cache stores, tried on macOS 15 and 26 (docs/module-programs.md).
  The profile has to name real paths (`/private/var/…`).
- **Updates** (decision 21): `previous` is the old app's prefix alone in a
  tree, as an old app without engine records has its engine's files where
  `ENGINE` would refuse to install over them. The first plan of an update
  `USE`s each engine the app runs, through the wine module's update stage
  when `wine-prefix` applies or Wine moves; a module's `update-setup`
  (Wine's: `HELPERS` alone) is what `USE` plans in such a tree, since
  `wineboot -u` over an old prefix waited for ever on Wine's Mono
  installer, and a Wine move adds `WINE.PREFIX` itself. The prefix's
  settings went into `functions/prefix-settings` without its drives: the
  old update's `DRIVES --only=C:` took away an old disc game's disc drives.
  `cleanupUnusedEngine` stays, for old ScummVM apps' prefixes.
- **Fullscreen detection** (decision 27) wasn't built: DirectDraw's
  exclusive mode happens inside cnc-ddraw, which the Mac-side helper can't
  see without hooking PE code, and it needs experiments on a screen.
  `--wine.window` works as the override, and SkiFree's `tests.window`
  stays out.
- **Phase 10 is partly done.** The development cache (`CacheManager`), the
  old prefix making (`WineManager`'s, `WineBuild.prefixLayerKey`) and
  `createBaseWrapp` are gone. `SecondChance/Builders/` stays, each builder
  now a source that identifies the game and hands the runner its plan;
  `WrappBuildHelper` isn't in `WrappAssembler`, `completeBuild` still takes
  the legacy values, and `patchApplied`/`patchFailed` keep their names until
  a release after phase 4.
- **Found on the way**: `sc` rebuilds itself when anything in `Packages/`
  changes; the disc drives are marked after the discs copy, not while they
  do (a Wine run in a restored prefix during the copy made it fail with
  EPERM); a failure summary lists the Wine programs its stage started and
  ended; `--keep-failed-builds` keeps a failed build's folder.
