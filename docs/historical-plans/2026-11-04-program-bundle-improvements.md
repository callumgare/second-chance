# Program bundle improvements: plan

Proposed 2026-11-03, after the generic-programs work. Facts about the code
are as of `20ccfc2` (that branch's DOSBox commit). The generic-programs plan
is now `docs/historical-plans/2026-11-03-generic-programs.md`, and "draft"
below means it; its line numbers are that frozen file's.

What it covers, all making a bundle say plainly what its program needs:

- **Modules extending core instructions** (decisions 1 and 2): path types,
  options and mount fields, brought in by `USE` alone.
- **The launch in the Wrappfile** (decisions 3 to 5): `LAUNCH`, its
  `--fallback`; `SERVICE` waits for signals.
- **Manifest fields nothing should read** (decision 8): `drm` becomes a note
  on the edition it describes, which means editions can have `notes` too.
- **The `volume` mount type removed** (decision 1).
- **Instructions case-insensitive, written in upper case**, a module's name
  in an instruction included: `WINE.MOUNT` (decision 9).
- **Values** (decisions 10 to 13): every value read through a namespace in
  `${…}` (`input.`, `const.`, `var.`, `platform.`, `module.`, `self.`),
  with no modifiers; `INPUT`, `CONST`, `VAR` and `SET` in place
  of `ARG`; an edition's inputs, choices included, under its `build`, keyed
  by name; and `--env` as the only way a value reaches a program's
  environment.
- **The program's runtime set-up in the Wrappfile** (decision 14):
  `VOLUME`, and a launch's environment and module options. Variants, then
  left with nothing, go (decision 15).
- **What each step depends on, written where it's used** (decision 16):
  the nancy-drew module's `assemble`, `EXPORT` and the manifest's
  `installer: { stubborn }` and `--stubborn` go, for the AutoIt script
  named on the step; the discs kept and where a Mac download
  installs are written in the step.
- **ScummVM games' editions share one `scummvm` stage** (decision 17), and
  the disc editions that need no Wine build without it.
- **The Wrappfile is what happens** (decisions 18 to 22): every option a
  builder reads is carried out or checked, patches run as their steps say,
  the wrapp runs what the build recorded, which patches apply lives only in
  Wrappfiles, and what the Steam, Big Fish and wine modules do unseen
  becomes steps or module data.
- **The app's icon in the Wrappfile** (decision 24): `ICON`, with the Nancy
  Drew icon in the nancy-drew module and a generic one for any app that
  names none.
- **`SERVICE` waits for signals** (decision 4): nothing needs a service
  yet, and one needs a way to say it's ready. Signals are a plan for
  consideration
  ([signals.md](../plans-for-consideration/signals.md)).

## Why

A Wrappfile is meant to be where someone reads what a program needs and why.
Two gaps keep that from being true:

1. **How a wrapp starts its program isn't in the Wrappfile, or anywhere a
   reader would look.** The draft puts it on the manifest's variant
   (`launch: { wine: { exe } }`), but what the wrapp actually runs is worked
   out in Swift:
   - the composition comes from `GameInfo.gameEngine` (`Composition(legacy:)`);
   - a Steam game's comes from `GameInfo.steamEngine(launchMode:)`, the
     launch-mode answer and its DRM;
   - the exe the wrapp records comes from `GameInfo.internalGameExePath`,
     which `sc generate` takes from the variant's launch, and is then checked
     or found by `GameInstallerRunner` after the install.

   Launch-mode is the clearest case: the manifest declares the choice, but
   what each answer does (move the game out of Steam's library, take Steam
   out, start through `-applaunch`, offer "launch without Steam" when Steam
   fails) is spread over `SteamWrappBuilder`, `GameInfo`, `WrappSettings` and
   the wrapp's `GameConfig.canLaunchWithoutSteam`.
2. **The draft designs ways for a module to extend core instructions, and
   none is built.** Things are already slipping through as a result (below).
   These are:
   - a `RUN` executor (`--with=<module>`);
   - module fields on a mount (`wine.drive=D:`);
   - `COPY` path roots (`C:` is Wine's).

This plan builds that extension point, and through it **`LAUNCH`**, a core
instruction whose program says which engine starts it.

**The guiding rule:** `USE <module>` is all a stage needs to get a module's
additions to the instructions that follow, its own and the core's alike.
What a module adds should still be visible to a reader, but it needn't be
spelled out where its form already shows it: a Windows-style path is
plainly Wine's.

## Where things stand

- **Module instructions exist; extensions don't.** A module's build facet
  (`BuildModule`, `Packages/WrappBuilder/Sources/WrappBuilder/Modules/BuildModule.swift`)
  declares `instructions` (`WINE.MOUNT`, `STEAM.INSTALL`) and `stages`. It
  has no way to add to `RUN`, `COPY` or a mount.
- **Mount types are a fixed core list**, `InstructionSpec.mountTypes`:
  `source, cache, secret, bind, fetch, volume`. The checker
  (`WrappfileChecker.checkOptions`) checks only `type=`; any other field
  passes unchecked. Only `bind` and `fetch` are used, twice each, in
  `nancy-drew.patch`. Nothing uses `volume`.
- **`RUN --with` is accepted and means nothing.** It's in `RUN`'s spec, but
  the checker doesn't check its value.
- **Paths aren't checked.** A `COPY` destination can be anything, whatever
  the stage `USE`s.
- **Nothing runs a step generically.** Builders recognise steps by shape and
  call the Swift that did the job before Wrappfiles
  (`DiskWrappBuilder.swift:180-229`, likewise the Her, download and update
  builders). A step they don't recognise fails as a recipe problem. So
  mounts are written but never carried out: `nancy-drew.patch`'s `fetch` and
  `bind` mounts describe what `applyGamePatch(id:)` does from `patches.json`.
- **`DownloadWrappBuilder` hardcodes `C:/`** for every `COPY`, mapping it to
  the Wine prefix's `drive_c` whatever the stage uses
  (`DownloadWrappBuilder.swift:190-193`).
- **What has slipped through:**
  - **Lure of the Temptress** has only `USE scummvm` but copies to
    `C:/Lure of the Temptress`. The draft says a ScummVM program goes in the
    wrapp's own files (`/game`), and that a `C:` path in a stage without
    Wine is an error.
  - **Tyrian 2000** has only `USE dosbox` and copies to `C:/Tyrian 2000`.
    That `C:` isn't DOS's: `DOSBoxRuntime` mounts the game's own folder as
    DOS's `C:`, so the variant's `C:/Tyrian 2000/tyrian2k.exe` is really a
    path under the Wine-style `drive_c`, and DOS sees `C:\TYRIAN2K.EXE`.
- **Neither freeware program has reached anyone yet.** The download source
  is hidden until the last phase, and neither has been launched
  (the generic-programs work's notes on its loose threads). So
  moving their files needs no migration.
- **Steam and Big Fish editions have no stage.** Their builders are
  imperative and read no plan.
- **Every wrapp has the Nancy Drew icon**, the template's own, whatever
  its program (decision 24).
- **`sc bundle check` doesn't plan editions.** Only `sc bundle plan` does, so
  a problem only planning finds (a function's step in a stage that lacks a
  module) shows up at build time.

## Decisions

Decisions 1 to 23, and the convention for comments, were settled in discussion on 2026-11-03, and decision 24 on 2026-11-04. The open
questions at the end are still to decide; the plan assumes their
recommended answers.

### 1. What a module can add to core instructions

Only modules with Swift can add anything. That matches the draft's rule that
a module someone adds has functions alone (draft 2912-2914), since nothing
would be there to carry an extension out. A module's additions apply in any
stage that has the module, through `USE` or `FROM`, with nothing else
written.

| Kind | Written as | Example |
| --- | --- | --- |
| **Path types** | a path in its full form, `<type>:<path>`, or a short form the type claims | `wine:C:/Game.exe`, or just `C:/Game.exe` |
| **Options** on a core instruction | `--<alias>.<option>=…` | `RUN --wine.desktop=… …` |
| **Fields** on a core mount type | `<alias>.<field>=…` in `--mount=` | `--mount=type=source,from=disc-1,wine.drive=D:` |

- **Path types replace the draft's executors and path roots, and launchers
  too.** A path's type says which engine handles it, whether it's a place to
  copy to, a program to `RUN`, or a program to `LAUNCH`. So `RUN --with`
  goes, and `LAUNCH` needs no flag to say what starts it.
- **Options and fields keep their prefix.** A path's form shows whose it is,
  but a bare `--desktop` or `drive=D:` doesn't. The prefix is the stage's
  name for the module, in lower case as options are (`--w.desktop` after
  `USE wine AS w`), where an instruction writes it in upper case
  (`W.MOUNT`, decision 9). The planner rewrites aliases to module ids, so
  builders, keys and settings never see an alias.
- **Mount types stay core**, as the draft decided (draft 420-430). Modules
  add fields to them, not types (Out of scope).
- **The `volume` mount type goes.** Mounting the person's files into a build
  step is the wrong place to change them: they can change after the build,
  a failed build leaves them half-changed, and the build may not run on the
  Mac where they are. Docker has no such mount either; its named volumes
  exist only when a container runs. Nothing uses it, so it's removed in
  phase 1. What it was for is designed separately, as steps the app runs
  before launch (Out of scope).

### 2. Path types

A module registers each path type it supports. A registration records:

- **Its name**, which is the full form's prefix (`wine:`).
- **The module** that registered it. It's recorded with the registration and
  never written in a Wrappfile or the settings: anything needing the module
  looks the type up.
- **Its roles**: a **location** (`COPY`, `MOVE`, `REMOVE`, `EDIT`'s file,
  `RUN --creates`, a mount's `target`), a **program**, or both. A program
  is one `RUN` and `LAUNCH` alike can start: anything one can run, the
  other can too. Running a game at build time is rarely wanted, but there
  is nothing to gain from forbidding it, and it has uses: `RUN /SharedSupport/game/ --add`
  has ScummVM detect the game and record it in its settings during the
  build.
- **Where it is in a wrapp**, for a type that is a location.
- **Its short form**, if it has one, and in which role. A type with no short
  form is always written in full.

The shipped modules would register these:

| Path type | Registered by | Roles | Example | Short form |
| --- | --- | --- | --- | --- |
| `wine:` | wine | location, program | `wine:C:/Nancy Drew/Game.exe` | a drive-letter path, `C:/…`, in both roles |
| `dosbox:` | dosbox | location, program | `dosbox:C:/TYRIAN/TYRIAN2K.EXE` | a drive-letter path, `C:/…`, in both roles |
| `scummvm:` | scummvm | program, location (its `saves/` and `settings/`, for `VOLUME`) | `scummvm:/SharedSupport/game/`, `scummvm:saves/` | a folder (`/…/`), as a program |
| `big-fish:` | big-fish | program | `big-fish:C:/…/LaunchGame.bfg` | none |
| `steam:` | steam | program | `steam://rungameid/572740` | none |
| `bundle:`, `module:` | core | a file the build reads | `bundle:assets/disc.iss`, `module:installer/autoit` | a relative path (below) |

The rules:

- **A type is named after the engine that processes it**, so a reader knows
  what will handle the path. That is a guideline, not a link: the name
  needn't be the module's id, and the registry, not the name, says which
  module handles it. A module may register several types. If Steam later
  needed a type for paths in its library, it would be named for Steam too
  (`steam-library:`, say). `steam:` happens to make the full form Steam's
  own URL (`steam://rungameid/…`).
- **A type's name is never a single letter**, so `C:` is always a drive.
- **Every short form is rewritten to its full form when the build is
  planned.** So `sc bundle plan`, the layer keys and the wrapp's settings
  always say which type took a path, even where the Wrappfile left it
  implicit.
- **Short forms clash only within a stage.** When two of a stage's modules'
  types claim the same short form, the short form is an error there, and
  the stage writes the full form (`wine:C:/…` or `dosbox:C:/…`). Only Wine
  and DOSBox overlap, and no stage needs both today.
- **Two modules registering the same type name is an error in the
  modules**, caught by `sc module check` and the unit tests, not in a
  Wrappfile.
- **A path starting `/` with no prefix is core, and is in the app**: `/` is
  the app's `Contents/`, so `/SharedSupport/game/` is
  `<app>/Contents/SharedSupport/game/`. Where a program's own files go is
  the Wrappfile's choice, not a folder the core names; the bundles here
  put a ScummVM game's data in `/SharedSupport/game/`.
  - **`/../` reaches the app's top level**, for anything that must sit
    beside `Contents/`. Nothing goes higher: a path whose `..` would leave
    the app, the host's file system, is refused by the checker, and when
    the build resolves a path it doesn't follow a link out of the app (a
    volume's link, say).
  - **It can reach an engine's folders**, such as the Wine prefix under
    `/SharedSupport/prefix/`. The checker warns when it does, since that
    place has a path type of its own (`C:/…`) that says what it is.
  - **As a program, a bare `/…/` is ScummVM's short form**, since a
    program always runs in an engine, never on the Mac, so the two never
    meet: `COPY … /SharedSupport/game/` is core, and `LAUNCH
    /SharedSupport/game/` is ScummVM's.
- **DOSBox's `C:` is DOS's `C:`.** The dosbox module's type is at a folder of
  its own in the wrapp, and `DOSBoxRuntime` mounts that folder, not the
  game's. A bundle then writes the paths DOS uses (`C:/TYRIAN/…`), so what
  the Wrappfile says is what the program sees. That fixes the Tyrian
  mismatch above. It also means DOS-style names (`TYRIAN`, not
  `Tyrian 2000`). The folder is `Contents/SharedSupport/dosbox/c/`, as
  Wine's `C:` is `prefix/drive_c`.
- **A relative path is one of the bundle's files, or of the module's whose
  file it's written in**: `--answer-file=assets/disc.iss`, `COPY
  assets/game.ini C:/…`, a mount's `source=assets/patch.au3`. It's the
  build context, as a Dockerfile's relative `COPY` source is, and replaces
  `${assets/…}`, which fitted no namespace.
  - **It's resolved where it's written**, as a short form, and rewritten when
    planning to its full form: `bundle:assets/disc.iss`, or
    `module:nancy-drew/assets/patch.au3` in that module's function whoever
    calls it. A path a bundle passes into a module's function keeps its
    meaning.
  - **Another module's files are written in full**
    (`module:installer/autoit`), which replaces `from=<module>` on a bind
    mount, and `from=self` isn't needed.
  - **It's a file only where an instruction takes a path**: a location, an
    option declared as a file, or a mount's `source`. A program's arguments
    are its text, and a bundle file reaches a program through a mount, as
    today. After `COPY --from=<stage>` or `--from=${input.…}`, the source
    is in that stage or input, as now.
  - **The checker checks the file exists**, and a layer key hashes its
    contents, as `asset:` paths are hashed today (`InstallLayer`).
- **What follows a type's prefix is the registering module's to
  interpret.** `big-fish:C:/…` is a path Big Fish resolves through Wine,
  which it depends on, and `steam://rungameid/…` is a URL.

### 3. `LAUNCH` is a core instruction (replacing C5 for the launch)

The draft's C5 says runtime settings live only in the manifest (draft 525).
For the launch, this plan replaces it: **a launch is decided by the build**.
It depends on where the build put the program and which modules are left in
the wrapp, as Docker keeps `CMD` in the Dockerfile.

```text
LAUNCH [--fallback=<program>] [--name=<id>] <program> [<argument>…]
```

- **It's called `LAUNCH`**, the word the app's loading window uses. Docker's
  `CMD` (default arguments `docker run` can override) and `ENTRYPOINT`
  mean other things.
- **The program's path type is what starts it.** A launch has no other way
  to say so. `LAUNCH C:/…/Game.exe` in a Wine stage is a Wine launch, and
  `LAUNCH steam://rungameid/…` is Steam's.
- **The type must be a program type, and its module must be in the
  stage**: the same rule as `RUN`'s program. Like `RUN`, `LAUNCH` takes
  options only before its program, so a program's own `--flags` are its
  arguments.
- **`--fallback` names a program the person is offered when the launch fails
  or seems stuck.** It's today's "Start Without Steam", written where a
  reader can see it (below). The fallback follows the same rules as the
  program: any program path type whose module the wrapp contains. It is:
  - **an offer, never automatic**, shown on the loading window's "may not be
    starting" and failure screens, as today;
  - **for one launch**: the next open tries the main launch again, as today;
  - **run without the main launch's launcher**, which is why Steam's case
    needs nothing special: Steam is that launch's launcher, so the fallback
    runs without it;
  - **worded by the failed launch's module**, since that's what the person
    gives up: Steam supplies "Start Without Steam" and its Steam Cloud
    note, already in the app's string catalog. The Wrappfile carries no
    text people see;
  - **part of its `LAUNCH`**, so a stage that replaces the launch replaces
    its fallback with it, and none is left over from a parent stage;
  - **run with the main launch's options**: its `--env` and its module
    options (`--wine.graphics`, the clean-exit options), which the fallback
    can't set for itself, so falling back to the exe loses none of them.

  Writing the fallback is what says the game can start without Steam: a
  bundle writes one only for a DRM-free game. Today's rule ("DRM-free, and
  launched through Steam", `GameConfig.canLaunchWithoutSteam`) is then in
  the Wrappfile, and the manifest's `drm` stops being read (decision 8).
- **Which `LAUNCH` wins:** the last one a stage reaches, after `IF`s are
  decided, counting what it inherits through `FROM`. A stage with none
  inherits its parent's. A module stage can set a default that a bundle's
  stage built `FROM` it overrides.
- **Every build must end with a `LAUNCH`, and planning knows whether it
  will.** A plan whose target reaches none is an error when it's planned,
  whatever it's for: an edition's target, an update's, or any stage `sc
  bundle plan` is asked for. `FROM previous`, the stage an update starts
  from, carries the old app's recorded launch (or the one its legacy
  settings translate to), so an update that doesn't change the launch
  inherits it, and one built from anywhere else must reach its own.
  `sc bundle check` plans every target, so it's found there. Editions
  without a stage (Steam and Big Fish, until phases 4 and 5) keep their
  builders' launch.
- **The final stage's modules are what the wrapp holds.** So the stage that
  launches should hold only what the wrapp runs. A ScummVM game installed
  under Wine takes the shape the draft already shows (draft 569-579): a
  final stage built from `scratch` with `USE scummvm`, and a `COPY
  --from=<install stage> … /SharedSupport/game/`. Wine isn't in that stage, so it isn't
  in the wrapp. Decision 17 gives each such bundle one `scummvm` stage its
  editions build from.
- **The program's runtime set-up moves too** (decision 14): volumes, the
  launch's environment and its module options. What's about the wrapp,
  not the program (`aspect`, `save-warning`), stays in the manifest, as C5
  says. **The variant's `launch:` goes away**, with variants (decision 15):
  an edition names its `build.target`, and that stage's launch is the
  edition's. **The draft's "a choice can change it, through a `when` on a launch"** (draft
  2152-2155) becomes an ordinary `IF` around `LAUNCH`.

### 4. `SERVICE` waits for signals

A program running beside the game (a service) would have an instruction of
its own, `SERVICE <program>`, rather than a flag on `LAUNCH`. Nothing needs
one: the only service today would be Steam running beside a game Steam
doesn't start (`wineSteamSilent`), which is no longer built, since it left
Blue Moon running with no window (`docs/steam.md`); every game that needs
Steam is started by it (`-applaunch`). And a service has to say when it's
ready, which is what signals are for. So `SERVICE` is designed with them,
in [signals.md](../plans-for-consideration/signals.md), and this plan
adds none. The composition a launch records is its launcher's module and
the modules it depends on, as today.

### 5. A launch is plan metadata, not a step, and never part of a layer

The planner takes `LAUNCH` and `VOLUME` out of the step list and gives the
plan a resolved launch (`BuildPlan.launch`). That has three effects:

- **Builders' step switches never meet them**, so none has to learn to skip
  them.
- **No layer key changes.** `InstallLayer.key` hashes the steps'
  descriptions, and the launch isn't a step. That matches the draft's
  "Runtime settings are not layers" (draft 1887).
- **A change to only the launch rebuilds nothing.** It is only written to
  the wrapp's settings. Whether an update can then change only the launch of
  an old wrapp is the update planner's business (Out of scope).

### 6. Where problems are found

- **The checker** checks what it can see within a stage:
  - each path's type, written or worked out from its short form, is
    registered by a module the stage has, and has the role the path is in
    (a location, or a program for `RUN` or `LAUNCH`). A `COPY --from`
    source is the exception: it's in the stage it's copied from, so it's
    checked against that stage's modules (a ScummVM stage copies a `C:/…`
    folder out of a Wine one);
  - no short form is claimed by two of the stage's modules;
  - an option's or mount field's alias is a module the stage has, and that
    module declares it for this instruction or mount type;
  - the value rules (decisions 10 and 11): every reference's namespace and
    declaration, with a warning where a name clashes (decisions 9 and 10);
  - every target reaches a `LAUNCH` (decision 3).

  **To know which arguments and options are paths, programs, files or
  inputs, an instruction's spec says so.** `InstructionSpec` has only
  `OptionKind` and `firstArgumentIsInput` today. It gains a role for each
  argument and option: a location, a program, a file the build reads, an
  input, or plain text. `WINE.MOUNT <folder> <drive>`'s first argument is
  a location, `INSTALLER.RUN --answer-file` a file, `--from` an input, a
  program's own arguments text. The checks above, decision 2's short
  forms and decision 18's rule all read these roles.

  Messages follow today's style, written for a bundle's author:

  ```text
  line 14: COPY C:/Lure of the Temptress/: no module of this stage handles C: paths (it uses scummvm)
  line 9: LAUNCH steam://rungameid/572740: steam: paths are steam's, which the stage doesn't USE
  line 6: COPY C:/TYRIAN/: both wine and dosbox take C: paths here; write wine:C:/… or dosbox:C:/…
  line 22: RUN --mount=…,wine.letter=D:: the wine module adds no field letter to a source mount (drive)
  line 40: COPY … ${input.instal-dir}/: no INPUT called instal-dir here (inputs: install-dir, launch-mode)
  manifest.yaml's edition cd builds disc, which reaches no LAUNCH
  manifest.yaml's edition steam builds steam, which uses ${input.launch-mode} (line 12), but the edition gives no launch-mode and the INPUT has no default
  ```

- **The planner checks what only a plan shows.** A function's body is
  checked against every module (`WrappfileChecker.allModuleAliases`), since
  it runs in whichever stage calls it. So the planner repeats the
  stage-dependent checks on the steps a `DO` expands to, throwing
  `PlanError`, rather than trusting the checker.
- **`sc bundle check` and `ProgramBundleTests` plan every edition's
  target**, for `arm64` and `x86_64` and each value of each `choice` input.
  Then a planner-only problem fails the check, not a build.
- **`sc module check` and the unit tests** check that no two modules
  register one path type, and that no type's name is a single letter.

### 7. Launches are a shared contract, in WrappKit

The builder checks launches and the wrapp starts them, so both read one
registry. That is the pattern of the shared wrapp contract
(`docs/historical-plans/2026-11-01-shared-wrapp-contract.md`).

- **Program path types are registered in `WrappModules`**,
  each with the `ModuleID` that handles it. The builder's checker and the
  wrapp's `RuntimeModules` both read them, so the two can't disagree. A
  program type can be launched, so the wrapp must know it, even if only
  `RUN` uses it today.
- **So are location types' places in the app.** The wrapp mounts recorded
  volumes at their locations (`scummvm:saves/`, `wine:C:/users/…`), so where
  each location type is in an app is in WrappKit too, beside the program
  types. What only the build needs of a location type (its short form, its
  roles) stays in `BuildModule`.
- **`WrappFormat` gets the launch as recorded**:
  - the program in its full form, its arguments, its `--env` and its
    module options (`--wine.graphics`);
  - the fallback's program, in its full form, if there is one;
  - the volumes (decision 14).

  **A Steam launch takes no arguments** for now: Steam would pass them on
  (`-applaunch <id> <args>`), but no game needs them, so the checker
  refuses them until one does.

  **A Steam launch says which program Steam will start**, as the steam
  module's option `--steam.exe`:

  ```dockerfile
  LAUNCH --steam.exe="${const.install-dir}/Game.exe" steam://rungameid/${input.game.app-id}
  ```

  Steam starts the game, not the wrapp, so the wrapp needs its exe to find
  the game's process: to tell it has started and quit, and for the quit
  watch (`SteamRuntime` gives back its name). WrappPuppeteer finds the
  window to drive the same way (`gameExePath`). So `--steam.exe` is
  required on a Steam launch, and the checker refuses one without it. It
  replaces the Steam input's `exe`, which goes: the program is said once,
  on the launch, as a path in the stage, not as a name in the manifest. A
  Steam launch with a `--fallback` usually names the same program in both;
  the steam module's `install` function writes both.

  `WrappSettings` stores it under a new key, `Launch`. The wrapp finds the
  launcher by looking up the program's type. `WrappSettings.composition` is
  that module plus the modules it depends on, read from `Launch` when it's there and from
  the legacy fields otherwise.
- **Everything reads the launch from phase 3**, before decision 17 and
  decision 2's bare paths change where things are. The legacy keys
  (`GameExePath`, `GameInstallerDir`, `GameEngine`, `SteamGameId`,
  `SteamLaunchMode`) mean "a path from the root of `C:`" and an engine
  name, which can't say "ScummVM's data at `/SharedSupport/game/`, with no
  prefix" or DOSBox's own `C:`. So in phase 3, `UpdateWrappBuilder`,
  WrappPuppeteer and the wrapp's runtimes read `Launch` (or the legacy keys
  translated into one, for an old app). The build keeps writing the legacy
  keys where they can say what the launch does, for an older Second
  Chance's update of a newer app, and leaves them out where they can't.
- **The app's lock records the launch, not `args`.** `WrappLock` holds
  what an update compares an app against, and three of its parts lean on
  what this plan removes:
  - **`args`** comes from the Wrappfile's global `ARG`s
    (`BuildPlanner.globalArgs`). `UpdatePlanner` reads
    `args["install-dir"]` to build afresh when the game's folder moved, and
    `DownloadWrappBuilder` finds ScummVM's data folder there
    (`NancyDrewModule.swift`): a name only Swift knows. It goes. The lock
    records the plan's launch instead, and the update planner builds
    afresh when the launch's program moved. An old lock's `args` translate
    to the launch they mean.
  - **`volumes`, `savesVolume` and `scummvmSettingsVolume`** come from the
    variants, which decision 15 removes. They come from the plan's
    recorded `VOLUME`s instead: the saves volume is the one the launch's
    module says holds saves (Wine's `Documents`, ScummVM's `saves/`), not
    the first one listed.
  - **`composition`** would say again what `Launch` says. The lock keeps
    it, derived from the launch, since an update compares it before reading
    anything else, and `Launch` is the one the wrapp reads.
  - **The module stages' hashes**, for the `wine-prefix` update
    (decision 21).
- **Name it `launch`, not `launcher`.** `WrappLock.launcher` is already the
  launcher code's revision.

### 8. `drm` becomes a note on its edition

A Steam edition's `drm` is read in exactly two places, and both only ask
whether it is `"no"`:

- **`GameInfo.offersSteamLaunchChoice`** (DRM-free, on Steam, not ScummVM):
  whether the build asks the launch-mode question. Its readers are
  `SteamWrappBuilder`, `sc`'s `--steam-launch` check and the Steam
  integration suite.
- **`GameInfo.steamEngine(launchMode:)`**: a DRM-free game launched directly
  runs without Steam.

The other two values, `launch-when-steam-running` and
`launch-via-steam-only`, are read by nothing: every DRM game is started
through Steam (`-applaunch`) whichever it is (`docs/steam.md`).

This plan replaces both readers with what the bundle writes:

- **The question is asked because the edition has a `launch-mode`
  input** (decision 12). Shadow Ranch and Old Clock declare it today. Royal Tower and
  Haunted Mansion say `drm: "no"` but are ScummVM games, which declare none.
- **What each answer does is in the Wrappfile**: `STEAM.REMOVE` and a Wine
  launch, or a Steam launch with `--fallback`.

So `drm` stops being a field and becomes a note, kept as a record of what
was worked out about each game: read by people and `sc bundle list --where`,
never by a build. Nothing checks a fallback or a choice against it, since a
check against a note would make it a field again.

**Editions can have `notes` too,** so a note sits on what it
describes. Today `notes` is only the manifest's top level. With it on an
edition, Steam's DRM is a note on the Steam edition, under the same name it
has now:

```yaml
editions:
  - id: "steam"
    source: "steam"
    build:
      inputs:
        game: { type: "steam-game", app-id: 572740, common-folder: "Nancy Drew The Secret of Shadow Ranch" }
    notes:
      drm: "no"
```

- **They're notes as the top level's are**: one key the schema doesn't
  check, never read by a build, the app or a wrapp. They're not inherited
  or merged with the top level's: each says something about what it's on.
- **`sc bundle list --where` finds them** through its usual paths, as
  `editions.notes.drm=no` (any edition whose note says so), with no change
  to `ManifestQuery`.
- **Other per-edition facts can move down too** as bundles are next
  touched, such as the quirks about Her's Windows download, which today sit
  in the top-level `notes`. That is tidying, not part of this plan.

### 9. Instructions are case-insensitive, and written in upper case

As in Docker, an instruction's keyword is case-insensitive and upper case
is the convention. Today the parser and checker match keywords exactly
(`"FROM"`, `"IF"`, `keyword == "COPY"` in `WrappfileParser` and
`WrappfileChecker`), so `from` or `run` is an error. This plan makes them
case-insensitive.

**A module's instructions follow the same convention, the module's name
included**: `INSTALLER.RUN`, `WINE.KEEP-DISCS`, `STEAM.INSTALL`, not
`installer.RUN`. The whole keyword reads as one instruction, and the module
part matches whatever case it's written in.

**Everywhere else a module is named, it's in lower case**, as it's a name,
not an instruction:

| Where | Written |
| --- | --- |
| `USE` and its `AS` name | `USE nancy-drew AS nd` |
| `FROM` a module's stage | `FROM steam/client` |
| a module's function | `DO nancy-drew.patch`, `DO nd.patch` |
| a module's option or mount field | `--wine.desktop`, `wine.drive=D:` |
| a module in `${…}` | `${nd.data.patches}`, `${module.wine.version}` |

So **a module's name, and a stage's name for one, is case-insensitive**:
`WINE.MOUNT` after `USE wine` finds it, and `W.MOUNT` after
`USE wine AS w`. Two names differing only in case are the same name:

- **`sc module check` and the module tests reject two modules whose ids
  differ only in case.**
- **The checker rejects a `USE … AS` name that matches another module's in
  the stage whatever its case**, as it rejects one that matches exactly
  today.

**A module's name can match a core instruction; the core always wins.**
`USE foo AS launch` isn't an error, though the checker warns about it.
`LAUNCH` is still the core's, and
so is anything starting `LAUNCH.`. That module's instructions are then
written in full, `MODULE.LAUNCH.<INSTRUCTION>`, which works for any module
(`MODULE.WINE.MOUNT`). It's the same rule as for `${…}` (decision 10): the
core's names never change meaning, and a clash costs only the longer form.
The checker's message for an unknown instruction that clashed names the
module and the full form.

The planner's steps keep the module's id (`wine`), as now. A step's
description writes its instruction in upper case (`WINE.MOUNT`), so `sc
bundle plan` reads as the convention does. That changes the descriptions
install layers are keyed on, which phase 1's other changes already do.

The draft's rule that "upper case after the dot is always Swift, `DO` and
lower case always a function" (draft 975-977) still holds in effect: an
instruction is anything not started by `DO`, and only `DO` runs a function.

**Stage names follow Docker's rule**, as BuildKit has it:

- **They're case-insensitive.** A name is lowercased where `AS` defines it
  and wherever `FROM` or `COPY --from` names it (BuildKit's
  `parseBuildStageName` and `statesByName[strings.ToLower(name)]`), so
  `FROM Prefix` finds `AS prefix`, and two stages differing only in case
  are one name, which is an error.
- **Lowercased, a name must match `^[a-z][a-z0-9-_.]*$`**: no starting
  digit, no other symbols.
- **The checker warns about one written in upper case**, as Docker's
  `StageNameCasing` check does, to keep names and instructions apart.

**Function and signal names follow the same rule**, since they're named
and referred to as stages are. **The names of inputs, constants and
variables stay case-sensitive**, as Docker's `ARG` and `ENV` are.

### 10. Every value is read through a namespace in `${…}`

`ARG`s and the manifest's inputs are read today as `${install-dir}`,
`${inputs.game.app-id}`, `${data.patches.${id}.url}` and `${assets/…}` (a
bundle file, now a relative path: decision 2), and
conditions as bare `launch-mode=direct` or `arch=arm64`. This plan gives
every value a namespace saying where it comes from:

| Namespace | What it is | Known | Declared by |
| --- | --- | --- | --- |
| `input.<name>` | a value from outside: the edition's (`build.inputs`), a `DO` caller's option, or the `INPUT`'s default | when planning | `INPUT` (decision 11) |
| `const.<name>` | a fixed value | when planning | `CONST` |
| `var.<name>` | a value the Wrappfile works out | when planning | `VAR` |
| `platform.<field>` | the Mac building: `arch`, `macos` | when planning | core |
| `module.<name>.…` | a module the stage uses, by its id or its `AS` name: its `version` and its read-only `data.<path>` | when planning | the module, brought in by `USE` |
| `self.…` | in a module's own files, that module, with the same fields | when planning | the module |
| `program.<field>` | the program of the step a signal is attached to | when planning (`path`, `dir`, `name`) | `LAUNCH` (and `SERVICE`), once signals exist |

- **Values are text or objects**, for now. Numbers, true/false and lists
  will likely come later; until then an `IF` compares text.
- **Namespaces are why reserved words are safe.** An input called `self` is
  `${input.self}`, which can't be mistaken for anything else.
- **A module can be named at the root, but the core always wins.**
  `${nancy-drew.data.patches}` and `${wine.version}` work without `module.`.
  If a module's name is one of the core's (`input`, `const`, `var`,
  `platform`, `module`, `self`, `program`), that's not
  an error, though the checker warns about it: the name means the core's,
  and the module is reached through `${module.<name>.…}`. The checker's message for a reference that fails
  that way names the module and its full path. This is a general rule of
  the syntax (decision 9 has the same for instructions).
- **`version` is the module's release**, as `USE wine@10` picked it, so a
  function can branch on it rather than a bundle hardcoding it.
- **A module's data has a schema.** A module with data declares its shape
  (a JSON Schema beside it, as bundles have `manifest.schema.json`).
  `sc module check` checks the data against it, and the checker checks each
  `${….data.…}` path against it, so `${nancy-drew.data.patches[input.id].ulr}`
  is caught by `sc bundle check`, not when planning. A key worked out from
  a value (`[input.id]`) is checked as far as the schema allows: against
  the patch's fields, not which patches exist. The schemas exist already
  (each `data` file's `.schema.json` beside it, which `sc module check`
  uses); what's new is the checker reading them.
- **A missing field reads as the schema's `default`.** A field a data
  schema gives a `default` always has a value, so a function needs no
  fallback: `patches.schema.json` gives `destinationSubdirectory` `""` and
  `automation` `"none"`. A field with no default that's missing is an
  error.
- **`self` keeps a module's files working whatever a bundle calls it.** A
  function reads `${self.data.patches}`, and is `DO self.patch` from its own
  functions. That doesn't depend on its id (which
  can then change) or on a bundle's `AS` name. Outside a module, `self` is
  an error.
- **A local function or signal wins over a module of the same name.**
  `FUNCTION steam` beside `USE steam` isn't an error, though the checker
  warns about it: `DO steam` is the local function, and the module's are
  reached in full, `DO module.steam.install`. So the order is always the
  core's, then what the Wrappfile defines, then modules.
- **`${…}` holds a reference**, with brackets for a key worked out from
  another value: `${nd.data.patches[input.id].url}`. Brackets replace a
  nested `${…}`.
- **Modifiers go, and nothing replaces them yet.** `${x:-default}` is only
  used for optional data fields, which a schema's defaults cover (above).
  Functions inside `${…}` (`default(…)`, a module's `unix-path(…)`) were
  considered and put off until something needs one: a plan for
  consideration,
  [functions-in-values.md](../plans-for-consideration/functions-in-values.md).
  A reference to nothing is an error.
- **Every value is known when planning.** A wrapp never evaluates a `${…}`:
  what it's given is data, as the before-launch steps' plan relies on.
- **`IF` compares expressions.** It's `IF <a> = <b>` or `!=`, where each side
  is a `${…}` or a quoted string, with or without spaces around the `=`.
  `IF arch=arm64` becomes `IF ${platform.arch} = "arm64"`, and
  `IF launch-mode=direct` becomes `IF ${input.launch-mode} = "direct"`.
  Bare names in a condition go for good, since every value is a `${…}`.
  `>=`, `<=`, `>` and `<` go until values can be numbers, and `has` until
  they can be lists (To come back to); nothing shipped uses any of them.
- **A whole input stands for the input itself.** Where an instruction takes
  an input, it's written as one: `INSTALLER.RUN --from=${input.disc-1}`,
  `STEAM.INSTALL ${input.game}`, `HER-DOWNLOAD.INSTALL ${input.installer}`,
  not by bare name. An option or argument declared as taking an input
  accepts only that, and the checker sees each use, which decision 11's
  check needs.

### 11. `INPUT`, `CONST`, `VAR` and `SET` replace `ARG`

```text
INPUT <name> [--default=<value>] [--secret]
CONST <name> = <value>
VAR <name> [= <value>]
SET <name> = <value>
```

- **`INPUT` declares a value the Wrappfile uses from outside.** It doesn't
  supply it. The edition supplies it (decision 12), or a `DO`'s option
  does, or its `--default` does.
- **A Wrappfile declares its `INPUT`s at the top, before any stage**, so
  every input a bundle takes is in one place, under its `CONST`s. A
  function declares its own at its top, as its parameters. An `INPUT` in a
  stage or a branch is an error, for now.
- **A missing input is an error only if the build uses it**: if a step or
  condition the target reaches, once `IF`s are decided, refers to it. That
  check runs for each edition. `sc bundle check` plans every target, so it
  finds it, not a build.
- **A reference to something undeclared is an error everywhere**, in every
  branch, reached or not, so a typo in a branch no edition takes is still
  caught. An `INPUT`, `CONST` or `VAR` that nothing uses is a warning.
- **`CONST` is a fixed value**, for what isn't an input: Shadow Ranch's
  install folder is `CONST install-dir = "C:/Nancy Drew/Secret of Shadow
  Ranch"`, read as `${const.install-dir}`. A `CONST` can't be assigned again
  or declared again in a scope within its own.
- **`VAR` declares a value worked out in the Wrappfile**, with a first value
  or without one. **`SET` assigns to one already declared**, in its scope
  or one around it, so an `IF` can change it:

  ```dockerfile
  VAR exe = "Game.exe"
  IF ${platform.arch} = "arm64"
    SET exe = "Game64.exe"
  END
  ```

  `SET` of a name with no `VAR` in scope, or of a `CONST` or `INPUT`, is an
  error; so is reading a `VAR` before anything has set it. A `VAR` in a
  branch is that branch's own, and shadows one outside it.
- **The right-hand side** of `CONST`, `VAR` and `SET` is a quoted string, which may
  hold `${…}`, or a single `${…}` alone, which keeps its value as it is. So
  `VAR patch = ${self.data.patches[input.id]}` holds the whole entry, and
  `${var.patch.url}` reads it.
- **Scopes:** the file, a stage, a `FUNCTION`, a signal's block (once
  signals exist), and an `IF`'s branch, as a branch's `ARG`s and `USE`s
  are scoped today. **The innermost declaration wins.** `INPUT`s are only
  the file's or a function's (above).
- **Globals reach every stage.** Today a stage has to repeat a global
  `ARG install-dir` to use it, as in Docker; that boilerplate goes.
- **A function reads what its caller has, but only through its own
  `INPUT`s.** That's deliberate, so a function can wrap behaviour that
  depends on how the Wrappfile calling it is set up, while what it reads
  stays declared at its top, where the checker can see it:
  - its `INPUT`s are its parameters, and the only names from outside it
    may read: a `${const.…}` or `${var.…}` of the caller's, read directly
    in a function's body, is an error;
  - an `INPUT` is supplied by the `DO`'s option, or else by the caller's
    input or constant of that name, or else by its default;
  - so `DO steam.install` reads the edition's `launch-mode` and the
    bundle's `install-dir` with nothing passed, because it declares
    `INPUT launch-mode` and `INPUT install-dir`.

  The checker checks a function's body against its `INPUT`s, as it checks
  anything else; the planner finds an `INPUT` nothing supplies, and
  reports the `DO` that led there.
- **An edition's value beats an `INPUT`'s default**, everywhere: the
  default is only for when the edition gives none. So `steam.install`'s
  `INPUT launch-mode --default="direct"` matters only to an edition that
  doesn't ask the question, and an edition that does (with its own
  `default: "direct"`) gets the person's answer.
- **No layer key changes from a declaration.** `INPUT`, `CONST`, `VAR` and
  `SET` aren't steps. Substitution comes before hashing, as now, so only a step
  whose text holds a value changes when the value does.
- **`--secret` keeps a value out of every step's text** (Big Fish's
  password). It can reach a program only through `--env` or a `secret`
  mount, and the step's description keeps `${input.password}`
  unsubstituted. So the password never gets into a layer's key, `sc bundle
  plan` or a log, and changing it rebuilds nothing.
  - **The builder fills it in** when it runs the step: the planner leaves
    the reference, the build hands the builder the edition's input values,
    and the builder puts the secret into the program's environment or the
    mount, and nowhere else. It's the one value not substituted when
    planning, and only builders, not the wrapp, ever see it.
  - **A secret can't be recorded.** The checker refuses one in `LAUNCH
    --env`, a `VOLUME` or anything else the app's settings would hold, since
    `AppSettings.plist` is readable by anyone with the app.
- **`sc` can give inputs**: `sc wrapp build <slug> --input launch-mode=steam`
  and `sc bundle plan --input …`, checked against the edition's
  `build.inputs` and its types. A file input takes a path. That's what
  `--steam-launch` does today, for any input, and it can replace the
  per-source environment variables `sc` sets for `WrappBuildInput` as
  those move to inputs (`DISK_1_PATH`, `HER_INSTALLER_PATH`,
  `STEAM_LAUNCH_MODE`). The app's headless mode takes inputs the same way,
  as one variable, `SECOND_CHANCE_INPUTS`, holding JSON
  (`{"launch-mode":"steam"}`), since an environment variable's name can't
  keep an input's case and hyphens.

### 12. An edition's inputs are under its `build`, keyed by name

The manifest says how each input is given (its type, and for a question,
its wording). The Wrappfile's `INPUT` says it's used. Choices become inputs
of type `choice`, so there's one list, and one way the Wrappfile reads them:

```yaml
editions:
  - id: "cd"
    source: "disc"
    build:
      target: "disc"
      inputs:
        disc-1: { type: "disc" }
  - id: "steam"
    source: "steam"
    build:
      target: "steam"
      inputs:
        game: { type: "steam-game", app-id: 572740, common-folder: "Nancy Drew The Secret of Shadow Ranch" }
        launch-mode:
          type: "choice"
          options: ["direct", "steam"]
          default: "direct"
          prompt: "How should the game start?"
    notes:
      drm: "no"
```

- **Keyed by name, as `volumes` are.** The name is what the Wrappfile
  declares (`INPUT launch-mode`) and reads (`${input.launch-mode}`).
- **`type` says how the person gives it**, and which fields it has:
  `disc`, `her-download`, `steam-game`, `big-fish-game`, `download`,
  `choice`. The source-specific `$defs` become the types' definitions, and
  `source` stays as the edition's kind of build.
- **`inputs` belongs to the edition's `build`.** An edition without a stage yet (Steam and
  Big Fish, until phases 4 and 5) has a `build` with `inputs` and no
  `target`, so `target` stops being required there.
- **The checker matches the two for each edition.** Every input the target
  uses that has no default must be in the edition's `build.inputs`, and every
  entry there must be used by a step or condition the target reaches,
  through a function's `INPUT` included. One nothing uses is an error,
  since it's either a typo or something asked for no reason. An edition
  with no target yet (Steam and Big Fish, until phases 4 and 5) isn't
  checked: its builder reads its inputs itself.
- **A question's wording is text people see**, so it's looked up in the
  string catalog, as `prompt` is today.
- **Asking stays as it is for now** (`getSteamLaunchMode`). What changes is
  where the choice is declared and how the Wrappfile reads it.

### 13. `--env` is the only way a value reaches an environment

`RUN` and `LAUNCH` take `--env NAME=<value>`, as many as needed.
Nothing else puts a value in a program's environment: no instruction sets
one for later steps, so Docker's split between `ARG` and `ENV` never
arises. A launch's `--env` is recorded with the launch, which gives a game's
own runtime environment (`WINEDLLOVERRIDES`, say) a place in the Wrappfile.
Environment a module sets itself (Wine's own) stays the module's.

### 14. The program's runtime set-up is in the Wrappfile: `VOLUME`

With the launch in the Wrappfile, the rest of what describes how the program
runs is too. Today a variant mounts the manifest's volumes:

```yaml
variants:
  - id: "wine"
    volumes:
      - { source: "wine-documents", target: "C:/users/crossover/Documents", wine: { drive: "A:" } }
```

That's a location, a path type and a module's field: the same things
`COPY` and a mount are written with. So it becomes an instruction:

```text
VOLUME [--<module>.<option>=…]… <volume> <location>
VOLUME --remove <volume>
```

```dockerfile
VOLUME --wine.drive=A: wine-documents C:/users/crossover/Documents
VOLUME scummvm-saves scummvm:saves/
VOLUME scummvm-settings scummvm:settings/
```

- **The manifest keeps what's about the volume itself**: that it exists,
  under `volumes`, with its `display-name` (text people see, translated),
  its `in-use-when`, and how it's brought forward. The Wrappfile says
  where the program sees it. A `VOLUME` naming a volume the manifest lacks
  is an error. A manifest volume no stage mounts is fine, with no warning:
  the ScummVM games' `wine-documents` holds saves from before they ran in
  ScummVM, and is kept so they come forward.
- **Like `LAUNCH`, it's recorded with the launch**, not a step: no layer key
  changes, and a change only to volumes rebuilds nothing. Volumes build up
  and are inherited through `FROM`. `VOLUME --remove` takes
  one off.
- **The location is a path type's**, under decision 2's rules, and its
  module must be in the final stage. Today a ScummVM volume has no target
  and the module mounts it where it keeps saves and settings. Those become
  locations the scummvm module registers, written in full
  (`scummvm:saves/`, `scummvm:settings/`).
- **A DOSBox volume is an overlay**, not a folder of its own: Tyrian's
  `dosbox-saves` holds what the game writes, laid over its `C:` (`mount c
  … -t overlay`). So it's written as one, on the drive it covers:

  ```dockerfile
  VOLUME --dosbox.overlay dosbox-saves C:/
  ```

- **Every edition of a program runs it the same way.** The checker
  compares what each edition's target records (its volumes, and the
  launch's module options: graphics, the clean-exit options), and refuses a
  bundle whose editions differ, naming the edition and what differs. The
  program and launcher may differ (that's what an edition is); how the
  game is run may not. That catches a
  Steam or Big Fish stage, which starts from its module's stage rather than
  the bundle's `prefix`, forgetting the saves volume the disc edition
  mounts, and a player's saves going missing after a rebuild from another
  edition. A program with no saves (SkiFree) mounts none, in every
  edition.
- **Module fields are options**, as on other core instructions
  (`--wine.drive=A:`).
- **The variant's `volumes` go**, with variants (decision 15).

**The launch's environment and module options move with it.** The manifest's
`runtime.environment` overlaps `LAUNCH --env` (decision 13), so it goes, for
`--env` on `LAUNCH`. The variant's launch has module options
today (`wine: { exe, graphics: "direct-draw" }`). `exe` is `LAUNCH`'s
program, and `graphics` becomes the wine module's option on `LAUNCH`:
`LAUNCH --wine.graphics=direct-draw "${const.install-dir}/Game.exe"`.
The manifest's `runtime` goes altogether, as nothing reads it (decision 22).

### 15. Variants go

A variant today is an id (`wine` or `scummvm`), the volumes it mounts and
its launch. Decisions 3 and 14 move the last two into the Wrappfile, which
leaves only the id, and that is read for one thing: the catalogue takes a
variant called `scummvm` as `gameEngine: .scummvm`. So variants go from the
schema, `Manifest` and every manifest:

- **The edition's target stage is what a variant was.** What it runs and
  mounts is that stage's `LAUNCH` and `VOLUME`s, and what the wrapp holds
  is its modules.
- **The catalogue reads the default edition's plan.** `GameCatalogSource`
  takes `gameEngine` from the module of its planned launch, as it takes
  `internalGameExePath` from the launch's program and `graphics` from its
  `--wine.graphics`.
- **`sc generate` plans for both architectures**, `arm64` and `x86_64`,
  and fails if the two launches disagree on any of those. A plan decides
  its `IF ${platform.arch}` branches for one Mac, and the catalogue it
  generates is committed, so it must not depend on which Mac ran it.
- **Building one game with different engines** is what variants were
  for, and nothing does it yet. When a game needs it, something like them
  comes back, designed for that game. The draft's variant design is the
  starting point (Out of scope).

### 16. What each step depends on is written where it's used

The bundles have a few dependencies a reader of the Wrappfile can't see.
Each moves into the step it's about:

- **The nancy-drew module's `assemble` goes.** It ran `DO
  nancy-drew.configure-ini --into=${install-dir}` after every final stage
  using the module, relying on every bundle having a global
  `install-dir`. It also ran where it does nothing: `sc bundle plan
  nancy-drew/scarlet-hand cd` shows it editing `*.ini` in the install folder
  of a ScummVM disc stage, which only ever has the disc's files. Each stage
  that installs a Wine game writes the step itself:
  `DO nancy-drew.configure-ini --into=${const.install-dir}`. The ScummVM
  games' Her download stages don't, which changes nothing: the disc builder
  already skips the step for a ScummVM game (`DiskWrappBuilder`, its
  `EDIT --from-data=ini` case). `assemble` goes
  from the module schema, as nothing else uses it.
- **`EXPORT` goes.** The ScummVM disc stages use it to say which folder is
  the game's data; decision 3's final stage (`FROM scratch`, `USE scummvm`,
  `COPY --from=<install stage> … /SharedSupport/game/`) says it instead.
- **`WINE.KEEP-DISCS` names the discs it keeps**: `WINE.KEEP-DISCS
  ${input.disc-1} ${input.disc-2} --into=… --combined=…`. Today it keeps
  every disc without saying so, and the 12 two-disc bundles' `disc-2` is
  read by nothing a checker can see, which decision 12's check would refuse.
- **A Mac download says where it installs**: `HER-DOWNLOAD.INSTALL
  ${input.installer} --into=${const.install-dir}` in the `her-mac` stages.
  Today it has no `--into`, and the game goes where the Cider app's
  `Info.plist` puts it (`CedegaGameDir`, moved to `Program Files (x86)`),
  which happens to be the install folder. The builder moves it to
  `--into`, and fails if the folder the app names isn't there, so the
  stage's `LAUNCH` holds.
- **The step names its AutoIt script, in place of "stubborn".** Some of
  Her's InstallShield installers, run silently with their answer file,
  install the game and never exit, so the build has AutoIt drive them: the
  nancy-drew module's `installshield-custom-dialog-automate.au3`, one
  script for all five games. Today that's said twice, as the manifest's
  `installer: { stubborn: true }` (read only by the catalogue, as
  `doesNotExitInNonInteractiveMode`) and `INSTALLER.RUN --stubborn`, and
  neither says AutoIt runs or which script. Both go, for:

  ```dockerfile
  INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir} \
      --answer-file=assets/disc.iss \
      --automation=module:nancy-drew/assets/installshield-custom-dialog-automate.au3
  ```

  - **The answer file stays the step's.** It's what the installer reads;
    the script only clicks where the installer stops.
  - **The script is given the command to run.** The installer module works
    out the installer's command as it would with no script (its type, its
    silent switches, the answer file mounted where it chooses) and, with
    `--automation`, runs the script with that command as its arguments:
    `AutoIt3.exe <script> D:/setup.exe /s /sms /f1C:\…`. The script starts
    what it's given and clicks Install, then Exit Setup. So:
    - the script knows nothing of InstallShield's switches, answer files or
      where anything is, and `C:\nancy-drew-installer\setup.iss` goes from
      it;
    - the Swift loses its special case for AutoIt
      (`InstallerPlan.installerArguments` giving no arguments, "AutoIt runs
      it its own way"): with a script or without, the installer's command is
      built one way;
    - the answer file needn't be copied to a fixed place: the module mounts
      it, and puts its path in the command;
    - the script still owns the installer's process, as now, so a failed
      click closes the installer at once and says why, rather than leaving
      it for the stall watch.

    The patches' scripts (`her-update-wizard.au3`,
    `update-installation-wizard.au3`) start their patcher themselves, from
    its path. They could take a command the same way, but nothing needs it
    yet.
  - **`--automation` takes the script as a file path** (decision 2), so the
    checker checks it exists and its contents are in the layer's key. A
    script driving a wizard with no answer file is allowed too, as the
    patches' are; that one script needs an answer file, and says so
    when it hasn't one.
  - **It runs on the first attempt**, as `InstallerPlan.usesAutoIt` does
    today. A build that may fall back to the interactive installer still
    does.
  - **`HER-DOWNLOAD.INSTALL` takes it too**, for a Windows download, which
    installs as a disc does. The five `her-windows` editions that set
    `stubborn` today need nothing: their downloads have no answer file, so
    the flag already did nothing there.

### 17. A ScummVM game's editions share one `scummvm` stage

The 7 Nancy Drew games that run in ScummVM get their data under Wine (a disc
kept and patched, or Her's installer run) and run without it. With
`EXPORT` gone, each bundle says that with a stage of its own for how the
game runs, as Wine games have `prefix`, and each edition's target copies
its data into it:

Ghost Dogs of Moon Lake, whose patch runs under Wine:

```dockerfile
CONST install-dir = "C:/Program Files (x86)/Her Interactive/Ghost Dogs of Moon Lake"
INPUT disc-1
INPUT installer

FROM wine@10/prefix AS prefix

# How the game runs, whichever edition it came from
FROM scratch AS scummvm
USE scummvm
COPY module:nancy-drew/assets/nancy-drew.icns /Resources/nancy-drew.icns
ICON /Resources/nancy-drew.icns
VOLUME scummvm-saves scummvm:saves/
VOLUME scummvm-settings scummvm:settings/
LAUNCH /SharedSupport/game/ nancy:nancy7

FROM prefix AS disc-files
USE nancy-drew
WINE.KEEP-DISCS ${input.disc-1} --into=C:/nancy-drew-installer
DO nancy-drew.patch --id=ghost-dogs-full --into=C:/nancy-drew-installer/disk-1

FROM scummvm AS disc
COPY --from=disc-files C:/nancy-drew-installer/disk-1 /SharedSupport/game/

FROM prefix AS her-download-files
USE her-download
USE nancy-drew
HER-DOWNLOAD.INSTALL ${input.installer} --into=${const.install-dir}
DO nancy-drew.patch --id=ghost-dogs-full --into=${const.install-dir}

FROM scummvm AS her-download
COPY --from=her-download-files ${const.install-dir} /SharedSupport/game/
```

- **How the game runs is written once**, in `scummvm`: the engine, its
  icon, its volumes and the launch. Each edition's target is a `FROM scummvm` and one
  `COPY` of where that edition left the game's data. Steam's, in phase 4,
  is the same.
- **The targets keep their names** (`disc`, `her-download`), so the
  manifests' `build.target`s don't change; the stages doing the Wine work
  become `*-files`.
- **The app holds ScummVM alone** because the target's modules are
  ScummVM's alone, which the Wrappfile now shows rather than the builder
  knowing it from the catalogue.

**A disc edition that needs nothing from Wine builds without it.** Royal
Tower, Final Scene and Secrets Can Kill have no patch, so their discs are
only copied, and Wine was there only to hold them:

```dockerfile
FROM scummvm AS disc
COPY --from=${input.disc-1} . /SharedSupport/game/
```

- **No prefix is built for them**, so their builds are quicker, and their
  Wrappfiles shorter.
- **Two discs are copied in turn.** Secrets Can Kill's two are combined
  today by `WINE.KEEP-DISCS --combined`, which links each top-level entry
  of both discs into one folder, disc 1's winning a name both have. Copying
  disc 2, then disc 1 over it, gives disc 1 the same priority:

  ```dockerfile
  FROM scummvm AS disc
  COPY --from=${input.disc-2} . /SharedSupport/game/
  COPY --from=${input.disc-1} . /SharedSupport/game/
  ```

  The difference is inside a folder both discs have: linking takes disc
  1's whole, and copying merges the two. Phase 3 compares the two results
  on Secrets Can Kill's discs; if they differ in a way the game notices, it
  keeps the Wine route.
- **Scarlet Hand moves over too, without its patch.** ScummVM applies that
  fix itself: Her's patch is one file, `s1671.CIF`, byte for byte the
  `S1671.cif` ScummVM ships in `nancy.dat` (since February 2024, "Add
  official nancy6/7 patches"), applied while its "Fix softlocks" option is
  on, which it is by default and nothing of ours changes. So Scarlet
  Hand's Wrappfile drops `DO nancy-drew.patch --id=scarlet-hand-phone-monolith`
  from both editions, and its disc edition is a plain copy. The patch's
  catalogue entry says why in its `fixes`, as Secrets Can Kill's does.
- **Ghost Dogs, Haunted Mansion and Stay Tuned keep the Wine route** for
  now: their patches run Her's update wizard under Wine.
  - **Ghost Dogs' may be ScummVM's too.** The same commit added three
    files for it (`S2027`, `S2224`, `S2886`), on by default. Her's patch is
    a packed wizard that couldn't be opened to compare.
  - **Haunted Mansion's may be in part.** ScummVM ships only a missing sound
    file for it (`han92b.his`); Her's patch also fixes freezes.
  - **Stay Tuned's cabinet fix isn't in ScummVM**, which ships Her's
    final-timer patch and a softlock fix of its own for it.

  Phase 3 builds Ghost Dogs and Haunted Mansion once each and compares the
  files their patchers change with ScummVM's. Any game whose patch ScummVM
  already applies drops it and moves to the plain copy.
- **The leftover prefix is real today.** A ScummVM app built from a disc
  holds the whole Wine prefix it was built in: a built Final Scene app has
  938 MB of `Contents/SharedSupport/prefix` it never uses, because the
  build removes only Wine's engine files. This decision's stages remove it
  by construction: a target built `FROM scratch` (or `FROM scummvm`) holds
  only what it copies in. A stage that needs Wine for a step and not after
  it uses the same shape, so the wine module needs no instruction to take
  itself out. Until phase 3, a fix in the build's clean-up (removing the
  prefix when the engine isn't Wine) can ship on its own.

### 18. Every option a builder reads is carried out or checked

The builders recognise steps by their shape and call older Swift, which
does things its own way. So some lines in Wrappfiles look meaningful but
aren't:

- **A patch step is read only for its name.** The disc, Her and update
  builders take a step named after a patch and call `applyGamePatch(id:)`,
  which reads `patches.json` again and does it its own way: silent
  switches by installer type, a 900 s timeout, a patcher copied into the
  game's folder and deleted, and a failed patch stopping the build only if
  the person says so. The `ADD`, `INSTALLER.RUN` and `RUN` with mounts
  `nancy-drew.patch` expands to are thrown away.
- **Folder options are ignored.** `--into` on `INSTALLER.RUN`,
  `HER-DOWNLOAD.INSTALL` and `DO nancy-drew.patch` isn't read: the game
  goes where its answer file puts it, and patches where the exe was found.
  `WINE.KEEP-DISCS --combined` isn't read either, and the discs' folders
  and drive letters are written in Swift.

**The rule:** every value a builder takes from a step is either what it
does, or checked against what it does. A builder that would do otherwise
fails, with what the Wrappfile says and what the build would do:

```text
Wrappfile:14: WINE.KEEP-DISCS --combined=C:/nancy-drew-installer/discs: this build combines the discs in C:/nancy-drew-installer/disk-combined
```

So every line of a Wrappfile is true, even before a builder can run any
step itself.

**Patches run as their steps say.** The builders carry out the steps the
patch function expands to, and `applyGamePatch(id:)` goes:

- `ADD --checksum … --unpack=zip --member=… [--extract] <url> <folder>`:
  fetched through the download cache by its hash, unpacked, and the member
  (or, with `--extract`, what's in it) put in the folder;
- `INSTALLER.RUN` for a patcher with a silent mode, the installer module
  running it as it runs any installer;
- `RUN` with `fetch` and `bind` mounts for a wizard driven by AutoIt: each
  mount put where its `target` says before the program runs and removed
  after, and the program run under Wine.

That's a small runner for three shapes, not the draft's generic one: a
step in another shape is still a recipe problem. What the old code
decided by itself is written on the steps the function makes:

- **What a failure does.** `--on-failure=ask`, on the function's steps.
  `--on-failure` is a core option every step takes, where today only
  `RUN` has it: a failed step asks the person whether to carry on
  without it, and an unattended build follows `PATCH_FAILURE_POLICY`, as
  today. Without it, a failed step fails the build.
- **What counts as success** is the program's exit code. The AutoIt
  scripts already exit 0 only once the patcher says it updated the game,
  so the old "a scripted patch that changed no files failed" check isn't
  needed.
- **How long it may take** is the stall watch's business, as for any
  program the build runs, rather than a patch's own 900 s.

**`--into` is where the program goes.**

- **The installer still finds where the game went.** People have other
  versions of a disc than ours (another language, a reissue), so
  `INSTALLER.RUN` and `HER-DOWNLOAD.INSTALL` stay flexible about the
  installer: which program on the disc is it, which type, silent or a
  wizard, and where it put the game.
- **The step says what it expects to find**: `--creates=<exe>`, the
  program it should leave, under `--into` (the draft's `RUN --creates`).
  The checker requires it to be the target's launch program when the
  launch is under the same `--into`, so the two can't drift apart.
- **`INSTALLER.RUN` finds what the installer actually made**, with today's
  search, kept for discs that aren't ours: the expected exe; any new
  `game.exe`; the only new exe that isn't a helper (`unins…`, `setup…`,
  and so on); otherwise the person picks from the new exes.
- **If what it found isn't what was expected, it links the expected path
  to it**, as the draft decided for the folder (draft 135, 1465): `--into`
  becomes a link to the folder the game went to, and if the exe's name
  differs too (a reissue's `Game2.exe`), the expected exe becomes a link to
  the one found. Nothing after the step needs to know: the launch,
  patches and `configure-ini` all use the expected paths. The links are
  relative and inside the app, and phase 2c checks the quit watch and
  WrappPuppeteer find the game's process through them.
- **A patcher isn't an install.** The patch function runs a silent patcher
  with `INSTALLER.RUN --patch`, which runs it as an installer is run (its
  type, its silent switches) but looks for no game and makes no link:
  `--into` is only the folder the patcher is run in, and `--creates` isn't
  taken.
- **A patch goes where its `--into` says**, the folder the step names, not
  the one the exe was found in.
- **`WINE.KEEP-DISCS --into` and `--combined` are read**: the discs go in
  `<into>/disk-N`, and the combined view where `--combined` says, made only
  when the step asks for it.

### 19. The wrapp runs what the build recorded

At launch, the wrapp still decides some things in Swift that the plan's
recorded launch now says:

- **Graphics are declared.**
  `LAUNCH --wine.graphics=direct-draw|direct-3d|unknown` says what a Wine
  game draws with, and the wrapp arms its helpers from
  that (cursor lock only for DirectDraw, mode scaling only for Direct3D,
  and the quit check's rules for Direct3D). Reading the exe's imports
  (`GameGraphicsAPI`) becomes a check: the build warns when the imports
  say otherwise, and an exe whose imports can't be read (Armadillo) just
  isn't checked. Today the imports win and the manifest's value is only a
  fallback, taken from the first variant for every edition, and a game
  Steam starts gets no fallback at all (`SteamClient` arms the helpers
  without it). The recorded value fixes all three. The option is required
  on a Wine launch. `unknown` is for a program that draws through neither
  (SkiFree, which uses GDI), and arms both helpers, as an unknown game gets
  today; the build warns when the imports find DirectDraw or Direct3D in
  an exe declared `unknown`.
- **Volumes are mounted as recorded.** `WineRuntime.connectSaves` mounts
  the saves volume as `A:` and points `Documents` at it, whatever the
  manifest says, and a program with no volumes gets `wine-documents`. The
  wrapp instead mounts each recorded `VOLUME` where it says, with the
  drive its `--wine.drive` gives; a program with no `VOLUME` has none. Old
  wrapps' settings translate to the volumes they mount today.
- **ScummVM is told the game.** `LAUNCH /SharedSupport/game/ nancy:nancy6`: the
  argument after the folder is ScummVM's game id, passed in place of
  `--auto-detect`, so the app runs the game the bundle says rather than
  whatever ScummVM detects in the folder. The checker requires one on a
  ScummVM launch. An old app's settings have no game id, so a launch
  translated from them keeps `--auto-detect`.
- **The Nancy Drew clean-exit rule is the bundle's.** A non-zero exit
  counts as a clean quit when a `Debug.LOG` written since launch ends with
  Her's "good exit" line. Today that applies to every Wine game. It
  becomes the wine module's launch options, written by the bundles that
  need it (Ghost of Thornton Hall on), with the values from the nancy-drew
  module's data:

  ```dockerfile
  LAUNCH --wine.graphics=direct-3d \
      --wine.clean-exit-log="${nancy-drew.data.clean-exit-log.file}" \
      --wine.clean-exit-line="${nancy-drew.data.clean-exit-log.marker}" \
      "${const.install-dir}/Thornton.exe"
  ```

  Signals would say it more generally, as `LAUNCH`'s `--quit-cleanly`
  ([signals.md](../plans-for-consideration/signals.md)); these
  options are what they'd replace.
- **A program's name comes from its bundle.** `GameInfo.appName` defaults
  to "Nancy Drew - <title>" and `programID` to `nancy-drew/<id>`, in
  `GameCatalog`. The app's name becomes the manifest's `display-name`, or
  `<series> - <title>` when it has a series, or the title alone; the
  program id is always the bundle's id.

### 20. Which patches apply lives only in Wrappfiles

`patches.json`'s `automatic` and `edition` are read only on the Steam and
Big Fish path, where no patch ever matches (`GamePatchCatalog`'s
`Edition.matches`), and the Wrappfiles choose the disc and download
editions' patches by hand. Both fields go, with `applyGamePatches` in the
Steam and Big Fish builders. `patches.json` describes each patch; a
Wrappfile's `DO nancy-drew.patch` is what applies one. A Steam or Big Fish
edition has no patch because its stage names none.

- **The tests lose their oracle.** `WrappfileTodayTests` and
  `GamePatchCatalogTests` check each Wrappfile's patches against
  `automaticPatches(…source:)`, which reads those fields. Before they go,
  the tests' expectation becomes a fixture of its own: each edition's
  patch ids today, written out once from `automaticPatches`, so a
  Wrappfile that drops or gains a patch still fails a test, and the change
  is made in the fixture on purpose (as Scarlet Hand's is, decision 17).
- **`GameInstallerRunner`'s `applyPatches:` paths go** with them: patches
  are only ever the Wrappfile's steps (decision 18).

### 21. A module's stages are Wrappfiles, and `prefix.yaml` goes

A module's stage today is only a name it declares in Swift
(`BuildModule.stages`, `["client"]` for Steam): `FROM steam/client` adds the
module to the stage and nothing else, so there's nowhere for a stage's steps
to be written. And the Wine prefix every Wine game starts from is made by
Swift from `prefix.yaml`, a list of set-up entries in a format of its own.

**A module's stage is a Wrappfile**, in `Modules/<id>/stages/<name>`, as its
functions are in `functions/`:

```dockerfile
# Modules/wine/stages/prefix
FROM scratch AS prefix
USE wine
WINE.DRIVES --only=C:   # C: at drive_c; every other drive blocked, Z: included
WINE.REGISTRY --progress=display --set "x11-driver:EmulateModeset" Y   # most of these games switch display modes
WINE.WINETRICKS --progress=disc isolate_home
```

A bundle starts from it, and names the version there:

```dockerfile
FROM wine@10/prefix AS prefix
```

- **`prefix.yaml` goes**, with its schema and the Swift that reads it
  (`WineManager.applyPrefixSetup`, `prefixSetup()`). What it set up is the
  stage's steps, carried out by the builders under decision 18's rule.
  cnc-ddraw, which it also set up, is the DirectDraw games'
  `DO wine.cnc-ddraw` (decision 23).
- **The version is the `FROM`'s.** A module stage's own `USE wine` names no
  version, and takes the one the stage was built `FROM` with
  (`wine@10/prefix`). The rule is general: **a stage's `USE` of a module it
  already has, inherited or not, names the same version or none**; another
  version is an error, naming both. So `FROM wine@10/prefix` followed by
  `USE wine@9` is refused, and `USE wine` after it is `wine@10`.
- **`wineboot` stays implicit in `USE wine`** in a stage built from
  `scratch`: making the empty prefix is what having Wine means, as a base
  image is in Docker, and is documented with the module.
- **`WINE.DRIVES`** is a new wine module instruction, replacing
  `WineManager`'s hard-coded layout: every drive removed, `C:` at
  `drive_c`, the rest blocked. `A:` is what a `VOLUME --wine.drive=A:`
  makes it, and the CD drives `WINE.KEEP-DISCS` lends while it copies are
  that instruction's, as documented.
- **`--progress=<id>`** is a core option on any step: the progress text the
  build shows while it runs, named by an id the app has in its string
  catalog (`display`, `graphics`, `disc`, as `prefix.yaml` named them), so
  the Wrappfile carries no text people see.
- **The layer is keyed on the stage's steps**, as any layer is, in place of
  `prefix.yaml`'s hash. `WineBuild.prefixCodeRevision` stays for changes to
  the Swift that carries the steps out.
- **The `wine-prefix` update** (`when-changed: ["prefix.yaml"]`) becomes
  "the `wine/prefix` stage's steps changed": the app's lock records the
  hash of each module stage it was built from, and an update reruns the
  stage's steps over the old prefix, with the game left installed, as it
  reapplies `prefix.yaml` today.
- **Wine's environment** (`WINEDLLOVERRIDES`, `WINEDEBUG`, the sync and
  Metal variables) stays the module's Swift, the same for every program,
  and is listed in `docs/modules.md`. A game that needs its own sets it with
  `LAUNCH --env`.

**Steam's and Big Fish's stages and functions are written the same way**,
when their editions get stages (phases 4 and 5), so what their builders do
unseen today is read there.

The steam module's `steam/client` stage (`FROM wine@10/prefix`) and
`install` function:

- `WINE.REGISTRY --set` of Cmd acting as Ctrl for Steam's programs, and
  `STEAM.REMOVE` removing it with Steam, where today it stays;
- the cached Steam client as a `cache` mount on `STEAM.INSTALL`, rather
  than restored and saved around the build unseen;
- the sign-in, a `secret` mount on `STEAM.INSTALL` as today, taken out of
  the prefix by `STEAM.SIGN-OUT` in the `install` function, after the
  install that needs it;
- the game's folder: `STEAM.INSTALL --into` makes `--into` a link to
  Steam's folder for the app, and `STEAM.REMOVE` replaces the link with
  the game itself, moved there, then deletes Steam's folders. One step
  places the game, the other only takes Steam away.

The big-fish module's:

- the Game Manager's installer as an `ADD` with a pinned `--checksum`,
  where today the current version is fetched unpinned, and installed with
  `INSTALLER.RUN --automation=…`;
- the same Cmd-as-Ctrl `WINE.REGISTRY` step;
- DirectX's web installer declined while the game downloads, as an option
  of its install instruction (`--decline-directx`);
- the account taken out of the registry and its browser data removed, as
  `BIG-FISH.SIGN-OUT`, after the install;
- a ScummVM game's Game Manager left behind by decision 17's shape, not
  deleted by the builder.

### 22. Settings nothing reads go

Some fields are in the schemas but read by nothing:

- **The manifest's `runtime`**, on the bundle, an edition or a variant:
  `aspect`, `save-warning`, `environment`, `when` (settings decided per Mac
  at launch) and the per-engine `wine`, `scummvm`, `steam` and `dosbox`
  options. `Manifest.swift` doesn't decode it and no bundle uses it. It goes
  from the schema. A launch's environment is `LAUNCH --env` (decision 13),
  and the rest comes back, where it's read, when a program needs it.
- **A module's `runtime: { save-warning }`.** The wine, scummvm and dosbox
  modules each say whether their programs get the save warning, but the
  wrapp hard-codes the same answers in Swift (`showsSaveWarning`). The
  module's value becomes the one read: `sc generate` carries it into the
  wrapp's modules, as it carries Wine's routine errors, and the Swift's
  own answers go. A save warning a bundle writes is the before-launch
  steps plan's
  ([before-launch-steps.md](../plans-for-consideration/before-launch-steps.md)).

### 23. cnc-ddraw is set up only by the games that use it

Every Wine prefix gets cnc-ddraw and its `ddraw.ini` settings from
`prefix.yaml`, though only DirectDraw games use them: 8 of the bundles
today. It moves out of `prefix.yaml`, and those games' `prefix` stages call
a wine module function, so a change to it reaches all of them:

```dockerfile
# Modules/wine/functions/cnc-ddraw
FUNCTION cnc-ddraw
  WINE.WINETRICKS cnc_ddraw
  EDIT C:/windows/syswow64/ddraw.ini --must-exist --ini=ddraw.maintas=true --ini=ddraw.windowed=true
END
```

```dockerfile
FROM wine@10/prefix AS prefix
DO wine.cnc-ddraw
```

- **`EDIT --must-exist`** is a new flag: each setting it changes must
  already be in the file, or the step fails, naming the missing ones.
  Today `WineManager.configureDdrawIni` logs an error for a missing
  setting ("is this another cnc-ddraw?"), carries on, and doesn't cache
  the prefix. As a step, failing is the honest version: a step can't be
  kept but not cached, and a cnc-ddraw that renamed its settings would
  otherwise leave every DirectDraw game windowed wrongly, without an
  error. Without the flag, `EDIT --ini` adds a missing setting, as now.
- **The shared prefix stops holding cnc-ddraw**, so each DirectDraw game
  builds a small layer of its own on top of it.
- **The `wine-prefix` update**, which reruns the `wine/prefix` stage's
  steps over old apps (decision 21), reruns the function's steps too, for
  an app whose bundle calls it.
- **`--wine.graphics=direct-draw` then says the same as the function**,
  so the checker requires each with the other.

`EmulateModeset` is different: most of these games switch display
modes, so it stays for every prefix.

### 24. `ICON` says what the app looks like

Every wrapp has the Nancy Drew icon today, SkiFree and Tyrian included,
because it's the template's own (`WrappTemplateIcon.icon`, compiled into
the template's `Assets.car` and `WrappTemplateIcon.icns`, and named by its
`Info.plist`), so no bundle can say which icon its app has. Instead:

```text
ICON <location in the app>
```

```dockerfile
COPY module:nancy-drew/assets/nancy-drew.icns /Resources/nancy-drew.icns
ICON /Resources/nancy-drew.icns
```

- **It names a file in the app**, a bare path (decision 2), which an
  earlier step put there; `ICON` copies nothing. The checker requires it
  under `/Resources/` (`Contents/Resources/`, the only place macOS looks for
  an app's icon) and ending `.icns`.
- **An `.icns`, not an `.icon`.** An Icon Composer `.icon` has to be
  compiled (`actool`), which only Xcode has, and Second Chance builds apps
  on Macs without it. So:
  - the nancy-drew module's icon is `Modules/nancy-drew/assets/nancy-drew.icns`;
  - its source, today's `WrappTemplateIcon.icon`, moves beside it as
    `nancy-drew.icon`, and `sc generate` compiles one into the other
    (`xcrun actool`), as it makes the module's other generated files;
  - an `.icns` has no dark or tinted appearance, which the `.icon` has
    (To come back to).
- **It's recorded like `LAUNCH`** (decision 5): the planner takes it out of
  the steps into `BuildPlan.icon`, so it changes no layer key, is inherited
  through `FROM`, the last one wins, and `FROM previous` carries the old
  app's. The `COPY` before it is a step like any other.
- **The build carries it out** (decision 18): at the end it checks the file
  is there, failing the build if not, then sets the app's
  `CFBundleIconFile` to it and removes `CFBundleIconName`, which names the
  template's icon in `Assets.car` and would win over the file.
- **An app with no `ICON` has the generic icon.** The template's own icon
  becomes `WrappTemplate/Resources/GenericWrappIcon.icon`
  (`ASSETCATALOG_COMPILER_APPICON_NAME`), compiled into the template when
  Second Chance is built. Every app is copied from the template, so one that
  writes no `ICON` keeps it, with nothing added by the planner. That's the
  template's default, as its launcher is, written in the docs, not a step
  hidden in the plan. `WrappTemplateIcon.icon` goes from the template.
- **Every Nancy Drew bundle writes it**, in the stage every edition is
  built from: `prefix` for a Wine game, `scummvm` for a ScummVM one
  (decision 17), so it's written once per bundle. In `prefix` the `COPY`
  comes before the installs, so a new Nancy Drew icon rebuilds every
  game's layers. An icon changes rarely enough for that to be the right
  trade for writing it once.
- **The freeware programs write none**, so they get the generic icon, and
  stop looking like Nancy Drew games.
- **Updates** take the plan's icon as they take its launch. A Nancy Drew
  app updated from before this has the icon it had; a freeware one keeps
  the Nancy Drew icon until it's updated or rebuilt, which matters to no
  one (Where things stand: none has reached anyone).
- **The template's icon and the bundles' `ICON`s change together**, in
  phase 3, or Nancy Drew apps built in between would get the generic icon.

### Comments in the bundles this plan changes

A comment in a manifest or Wrappfile says something about *this* program:
why its config is as it is. One that explains the format itself, the same
in every bundle, belongs in the docs instead (`notes:` followed by "for
people only; nothing reads these" is one). An end-of-line comment has one
space before its `#`, not padding to line comments up.

The rewrites of every bundle in phases 1 to 3 apply that to all of them,
since every line is touched anyway. The comments that go include the
header every Wrappfile has ("how Second Chance builds it. Written from
what its builders did…"), `# set up as the wine module's prefix.yaml says`
on every `USE wine`, the line saying Steam's edition names no stage, and
the manifests' `# kept outside the app: …` and `# for people only; …`.

## Syntax by example

**The disc edition, as Shadow Ranch's would read.** The Wine launch is
written once, in `prefix`, and every stage built from it inherits it:

```dockerfile
CONST install-dir = "C:/Nancy Drew/Secret of Shadow Ranch"
INPUT disc-1

FROM wine@10/prefix AS prefix
DO wine.cnc-ddraw
COPY module:nancy-drew/assets/nancy-drew.icns /Resources/nancy-drew.icns
ICON /Resources/nancy-drew.icns
VOLUME --wine.drive=A: wine-documents C:/users/crossover/Documents
LAUNCH --wine.graphics=direct-draw "${const.install-dir}/Game.exe"

FROM prefix AS disc
USE installer
USE nancy-drew
# The game checks for its disc, so the disc is kept in the app
WINE.KEEP-DISCS ${input.disc-1} --into=C:/nancy-drew-installer
INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir} \
    --creates="${const.install-dir}/Game.exe" --answer-file=assets/disc.iss \
    --automation=module:nancy-drew/assets/installshield-custom-dialog-automate.au3
DO nancy-drew.patch --id=shadow-ranch-full --into=${const.install-dir}
DO nancy-drew.configure-ini --into=${const.install-dir}
```

`sc bundle plan` shows the launch in its full form:

```text
ICON /Resources/nancy-drew.icns                               # Wrappfile:8
LAUNCH wine:C:/Nancy Drew/Secret of Shadow Ranch/Game.exe    # Wrappfile:10
```

**Steam, with the launch-mode choice** (phase 4). The steam module's
`install` function holds what launch-mode does, where a reader of the
module can see it:

```dockerfile
# Modules/steam/functions/install
FUNCTION install
  INPUT game
  INPUT install-dir
  INPUT exe
  INPUT graphics
  INPUT launch-mode --default="direct"
  STEAM.INSTALL ${input.game} --into=${input.install-dir}
  STEAM.SIGN-OUT
  IF ${input.launch-mode} = "direct"
    STEAM.REMOVE
    LAUNCH --wine.graphics=${input.graphics} "${input.install-dir}/${input.exe}"
  ELSE
    # A game with a launch-mode question is DRM-free, so it can start
    # without Steam when Steam fails
    LAUNCH --wine.graphics=${input.graphics} --fallback="${input.install-dir}/${input.exe}" \
        --steam.exe="${input.install-dir}/${input.exe}" steam://rungameid/${input.game.app-id}
  END
END
```

A bundle's Steam edition then says what's its own: the volume its other
editions mount, the exe and its graphics. `game`, `launch-mode` and
`install-dir` come from the edition and the bundle's `CONST` with nothing
passed (decision 11):

```dockerfile
FROM steam/client AS steam
VOLUME --wine.drive=A: wine-documents C:/users/crossover/Documents
DO steam.install --exe=Game.exe --graphics=direct-draw
```

`STEAM.REMOVE` is the draft's name for it (draft 2199-2202). The fallback's
path works whichever way the game launches, because `STEAM.INSTALL --into`
links it to Steam's folder for the app, and `STEAM.REMOVE` puts the game
there (decision 21). An edition whose game needs the clean-exit options
passes them the same way (`--clean-exit-log`, `--clean-exit-line`, which
the function declares with empty defaults, meaning none). The checker's
comparison of editions (decision 14) refuses a Steam edition whose
volumes, graphics or clean-exit options differ from the disc edition's.

**A DRM that needs Steam to start the game**, with no fallback:

```dockerfile
LAUNCH --wine.graphics=direct-3d --steam.exe="${const.install-dir}/Alibi.exe" \
    steam://rungameid/${input.game.app-id}
```

**A module's function, reading its own data** (`nancy-drew.patch`, today
`${data.patches.${id}.url}` a dozen times over):

```dockerfile
FUNCTION patch
  INPUT id
  INPUT into
  VAR patch = ${self.data.patches[input.id]}
  VAR target = "${input.into}/${var.patch.destinationSubdirectory}"
  IF ${var.patch.action} = "copy-into-game-dir"
    # A data file, dropped into the game's folder
    ADD --name=${input.id} --on-failure=ask --checksum=sha256:${var.patch.sha256} \
        --unpack=zip --member=${var.patch.payload} ${var.patch.url} ${var.target}
  ELSE IF ${var.patch.action} = "extract-into-game-dir"
    # A self-extracting zip, unpacked into the game's folder rather than run
    ADD --name=${input.id} --on-failure=ask --checksum=sha256:${var.patch.sha256} \
        --unpack=zip --member=${var.patch.payload} --extract ${var.patch.url} ${var.target}
  ELSE IF ${var.patch.automation} = "none"
    # A patcher with a silent mode, run in the game's folder
    INSTALLER.RUN --name=${input.id} --on-failure=ask --patch --into=${input.into} \
        --mount=type=fetch,url=${var.patch.url},sha256=${var.patch.sha256},unpack=zip,member=${var.patch.payload},target=${input.into}/${var.patch.payload} \
        ${input.into}/${var.patch.payload}
  ELSE
    # A wizard with no silent mode, clicked through by its AutoIt script.
    # Both are module files: this module's, and the installer module's.
    RUN --name=${input.id} --on-failure=ask \
        --mount=type=fetch,url=${var.patch.url},sha256=${var.patch.sha256},unpack=zip,member=${var.patch.payload},target=${input.into}/${var.patch.payload} \
        --mount=type=bind,source=assets/${var.patch.automation}.au3,target=C:/patch.au3 \
        --mount=type=bind,source=module:installer/autoit,target=C:/autoit \
        C:/autoit/AutoIt3.exe C:/patch.au3 ${input.into}/${var.patch.payload}
  END
END
```

`--on-failure` is a core option on every step, where today only `RUN` has
it (decision 18).

`destinationSubdirectory` and `automation` read as `""` and `"none"` when a
patch leaves them out, from the defaults `patches.schema.json` gains
(decision 10).

**The freeware programs** (phase 2d). None writes an `ICON`, so each has
the generic icon (decision 24):

```dockerfile
# Lure of the Temptress: ScummVM reads the data from the app's own folder.
INPUT game

FROM scratch AS download
USE scummvm
COPY --from=${input.game} lure /SharedSupport/game/
LAUNCH /SharedSupport/game/ lure

# Tyrian 2000: DOSBox's C: is the C: the game sees.
INPUT game

FROM scratch AS download
USE dosbox
COPY --from=${input.game} tyrian2000 C:/TYRIAN/
LAUNCH C:/TYRIAN/TYRIAN2K.EXE

# SkiFree: one program, copied in as it comes.
CONST install-dir = "C:/SkiFree"
INPUT game

FROM wine@10/prefix AS download
COPY --from=${input.game} . ${const.install-dir}/
LAUNCH --wine.graphics=unknown "${const.install-dir}/ski32.exe"
```

**Big Fish** (phase 5), whose type has no short form:

```dockerfile
LAUNCH --wine.graphics=direct-3d "big-fish:${const.install-dir}/LaunchGame.bfg"
```

**A Nancy Drew ScummVM game**: decision 17's Scarlet Hand, and Royal
Tower's disc edition, which needs no Wine.

**A Mac download** (decision 16):

```dockerfile
INPUT installer

FROM prefix AS her-mac
USE her-download
USE nancy-drew
# Her's patches update builds older than this one, so none apply
HER-DOWNLOAD.INSTALL ${input.installer} --into=${const.install-dir}
DO nancy-drew.configure-ini --into=${const.install-dir}
```

## Declaring path types and the rest

The Swift is a sketch; settle names while building.

```swift
// WrappModules (shared with the wrapp): program path types, which RUN and
// LAUNCH alike start.
public nonisolated struct ProgramType: Sendable {
    public let name: String                 // "wine", written as the prefix "wine:"
    public let module: ModuleID             // who handles it; looked up, never written
    public let shortForm: ShortForm?        // .driveLetter, .folder, or nil
}

public nonisolated enum ProgramRegistry {
    public static let types: [ProgramType] = [
        ProgramType(name: "wine", module: .wine, shortForm: .driveLetter),
        ProgramType(name: "dosbox", module: .dosbox, shortForm: .driveLetter),
        ProgramType(name: "scummvm", module: .scummvm, shortForm: .folder),
        ProgramType(name: "big-fish", module: .bigFish, shortForm: nil),
        ProgramType(name: "steam", module: .steam, shortForm: nil),
    ]
}

// WrappBuilder: what a module adds to building.
public nonisolated protocol BuildModule: Sendable {
    // … as now …
    /// Its path types that are locations, each with its short form and where
    /// it is in a wrapp. A type that is a program too has the same name in
    /// `ProgramRegistry`.
    static var locationTypes: [LocationType] { get }
    /// Options it adds to core instructions, by instruction, written `--<alias>.<option>`.
    static var coreOptions: [String: [String: InstructionSpec.OptionKind]] { get }
    /// Fields it adds to core mount types, by type, written `<alias>.<field>=…`.
    static var mountFields: [String: [String: InstructionSpec.OptionKind]] { get }
}
```

**A seam for tests.** The checker and planner call `BuildModules.native(_:)`
and would call the program registry directly. Give both a registry parameter
defaulting to the shipped ones, so tests can declare stub modules and path
types rather than depending on what the shipped ones happen to declare.

## Planning

- **`PlannedStep`**:
  - Every path is in its full form, so `wine:C:/…` where the Wrappfile wrote
    `C:/…`.
  - Options and mount fields are keyed by module id (`wine.drive`), not
    alias.
  - A step's description changes as a result, so install layers keyed on a
    plan miss once after this lands. That's acceptable (they rebuild), and
    is said in the commit.
- **`BuildPlan.launch`**: the target's resolved launch (program in full
  form, arguments, fallback and volumes), or nil for a plan with none,
  which is an error (decision 3). Launches and volumes are inherited
  across `FROM` as `modulesByStage` already carries aliases.
- **`BuildPlan.icon`**: the target's `ICON`, in full form, or nil for the
  template's generic icon (decision 24). Inherited across `FROM` as the
  launch is.
- **The plan's composition** is the launch's module and those it depends on. Builders
  stop deriving one from `GameInfo` for any edition with a plan.

## Building

- **`WrappBuildHelper.completeBuild`** takes the plan's launch and writes it
  to `WrappSettings` (with the legacy keys derived from it), instead of
  being handed `gameExePath`, a composition and `steamLaunchMode`. The
  `gameExeDetected` and `engineRouted` events still carry what they do now,
  derived from the launch, so the integration tests' expectations hold.
- **`completeBuild` sets the app's icon** from `BuildPlan.icon`: the file
  checked, `CFBundleIconFile` set to it, `CFBundleIconName` removed
  (decision 24). With none, it leaves the template's.
- **The exe check after an install** (`GameInstallerRunner` finding or
  checking `Game.exe`) checks the launch's program exists instead. That is
  the draft's `RUN --creates` idea, kept until `INSTALLER.RUN` takes it over.
- **Locations are resolved through their path type** where builders copy.
  `DownloadWrappBuilder` resolves a `COPY` destination through its type's
  place in the wrapp, or a bare path's under `Contents/`, rather than assuming
  `C:/`. The disc and Her builders don't `COPY` yet.
- **Programs `RUN` runs, and mount fields, are checked and planned, not
  carried out.** Carrying them out arrives with a builder that runs steps
  generically, which is the draft's work, not this plan's. Until then a
  builder that meets one it doesn't know still fails as a recipe problem, so
  nothing is silently ignored.

## The wrapp

- **`GameConfig` reads `WrappSettings.launch`.** The launcher is the module
  registered for the program's path type. Its `launchInfo` takes the
  program, arguments and what it recorded from there, rather than
  `gameExePath`, `steamGameId` and `bigFishLaunchFile`. Old wrapps'
  settings have no `Launch`, so it is made from their legacy fields when
  read, in one place (`WrappSettings`), tested.
- **The fallback is generic.** A recorded launch with a fallback is offered
  it where "Start Without Steam" is offered today (`InfoWindowView`'s
  failure and "may not be starting" screens), worded by the failed launch's
  module. Choosing it reopens the wrapp with a general `--fallback`
  argument in place of `--launch-without-steam`, which is still accepted
  from older wrapps' relaunches. `GameConfig.withoutSteam()` becomes "with
  the fallback launch", and `canLaunchWithoutSteam` becomes "the launch has
  a fallback".
- **`DOSBoxRuntime` mounts the `dosbox:` type's `C:` folder** and runs the
  program at its DOS path (phase 2d).
- **ScummVM's `--path`** is the launch's folder, resolved to its place in
  the wrapp.

## Phases

Each phase ends with unit tests, `./sc lint`, the integration runs named, a
commit, and its docs (Docs). Integration runs go on the test Mac.

**Phases 1 to 3 each rewrite every bundle** (about 36 Wrappfiles, their
manifests and the modules' functions), and phase 4 every Steam edition.
So:

- **The rewrites are done by a migration script**, not by hand: one run
  per phase over `Bundles/` and `Modules/`, kept in `.local` and not
  shipped, its output checked by `sc bundle check`, `sc bundle plan` of a
  sample, and `WrappfileTodayTests`. Hand edits follow only where a bundle
  needs judgement (the ScummVM games' new stages, the comments).
- **Phases 1 to 3 are released together.** Each changes the step
  descriptions install layers are keyed on, so released one at a time,
  cached builds would miss three times; together, once.
- **The comments are tidied in the same rewrite** (Comments in the bundles
  this plan changes).
- **VS Code's highlighting follows each phase.** `Tools/vscode-wrappfile`'s
  grammar (`syntaxes/wrappfile.tmLanguage.json`) names the core's
  instructions and the syntax's shapes itself, so each phase that changes
  the syntax changes it too, in the same commit (below).
  `WrappfileGrammarTests` checks only its instruction list against
  `InstructionSpec.core`; the rest is checked by opening a shipped
  Wrappfile and a module function in VS Code after **Developer: Reload
  Window**.

1. **Path types and module extensions, checked and planned.**
   - The registry seams.
   - The shipped modules' path types, Wine's `source` mount `drive` field,
     and `coreOptions`/`mountFields` on `BuildModule`.
   - Checker and planner support: short forms rewritten to full forms,
     clashes, options and fields.
   - `RUN --with` removed from `RUN`'s spec.
   - The `volume` mount type removed from `InstructionSpec.mountTypes` and
     from `docs/wrappfile.md`. Nothing uses it, so no bundle changes.
   - Keywords and module names case-insensitive in the parser, checker and
     planner (decision 9): keywords compared in upper case, including the
     parser's `RUN`/`.RUN` test and its block words (`IF`, `ELSE`, `END`,
     `FROM`, `AS`, `FUNCTION`, `LAYER`); module ids and aliases compared
     ignoring case. Every shipped Wrappfile and module function rewritten
     to `WINE.KEEP-DISCS`, `INSTALLER.RUN` and so on, as are
     `docs/wrappfile.md`'s and `docs/modules.md`'s examples.
   - `sc module check` checks type names, and that no two module ids differ
     only in case. `sc bundle check` and
     `ProgramBundleTests` plan every target.
   - The grammar: keywords matched whatever their case; a module's
     instruction as `WINE.MOUNT`, in any case, and `MODULE.<NAME>.<X>` in
     full; a module's option (`--wine.drive=`) and mount field
     (`wine.drive=`) with its prefix, where today an option can't hold a dot;
     path types' prefixes (`wine:`, `dosbox:`, `scummvm:`, `steam:`).

   This phase finds Lure's `C:` path wrong (Tyrian's is a `dosbox:` path
   now, if a misplaced one), so it must pass. Accept it until phase 2d
   through a temporary allowance named in the test that fails once phase 2d
   removes it.

   **The builders change too.** They recognise steps by their exact text,
   and this phase changes it: paths come out of planning in full form
   (`wine:C:/nancy-drew-installer`, Tyrian's `dosbox:C:/…`) and
   instructions in upper case. So each builder's matching is updated in
   this phase: `DiskWrappBuilder`'s `option("into") == "C:/…"`,
   `DownloadWrappBuilder`'s `hasPrefix("C:/")`, the Her and update
   builders' cases. Integration: disc (one game) and download (all three),
   so a matcher that no longer matches is found here, not phases later.
2. **Values and inputs** (decisions 10 to 13). Phase 2a; 2b follows.
   - References in `${…}`: namespaces and brackets. `${x:-…}` and nested
     `${…}` refused with a message saying what replaces them.
   - Data schemas' defaults filled in when data is read;
     `patches.schema.json` gains them for `destinationSubdirectory` and
     `automation`.
   - `INPUT`, `CONST`, `VAR` and `SET`, with their scopes and the function
     rule; `ARG` removed. `IF` comparing expressions, with `${platform.…}`.
   - Modules at the root of `${…}` and in instructions, the core winning a
     clash (`MODULE.<NAME>.…` in full); `version`, `data` and `self`.
   - Module data schemas, checked by `sc module check`, and `${….data.…}`
     paths checked against them.
   - Bundle and module files as relative paths (the `bundle:` and `module:`
     types), replacing `${assets/…}` and a bind mount's `from=<module>`.
   - Inputs written `${input.<name>}` where an instruction takes one.
   - `sc wrapp build --input` and `sc bundle plan --input`.
   - `--env` on `RUN` (and on `LAUNCH` as it arrives).
   - `--secret` inputs kept out of step text.
   - The schema: an edition's `build.inputs` keyed by name, each with a
     `type`, and `choices` folded in. `Manifest`, `GameCatalogSource` and
     the builders reading an edition's inputs follow. `target` optional on
     an edition's `build`.
   - **How an input is written in a planned step.** A whole input
     (`--from=${input.disc-1}`) plans to a typed token, `input:disc-1`, so
     a builder knows an input from text that looks like one. The builders'
     matching (`from == "disc-1"`, `inputs[from]`) reads the token.
   - **Bundle files' new full forms in the builders.** `bundle:` and
     `module:` replace `asset:`: `InstallLayer.key`'s filter, which hashes
     the files a plan reads, `installAnswerFile` and the Her builder read
     the new forms, so layer keys keep hashing bundle files.
   - Every shipped Wrappfile, module function, manifest and doc example
     rewritten. Planned step descriptions should come out the same apart
     from the namespaces, which `WrappfileTodayTests` checks.
   - The grammar: `ARG`'s rule replaced by `INPUT`, `CONST`, `VAR` and `SET`
     (with `=` spaced or not), and `WrappfileGrammarTests`' exceptions with
     it; `${…}` showing its namespace (`input.`, `const.`, `var.`,
     `platform.`, `module.`, `self.`) and brackets, with `:-` gone;
     `IF`'s operators as decision 10 leaves them; `bundle:` and `module:`
     paths.

   Integration: disc (one game with a patch), Her (Windows), download (one).

   **2b. What each step depends on** (decision 16, but for the Mac
   download's `--into`, which needs phase 3's launch):
   - The nancy-drew module's `assemble` removed from it and the module
     schema; each stage installing a Wine game writes
     `DO nancy-drew.configure-ini`.
   - `WINE.KEEP-DISCS` taking the discs as inputs.
   - `--automation` on `INSTALLER.RUN` and `HER-DOWNLOAD.INSTALL`, in
     place of `--stubborn`; `InstallerPlan` taking its script from the
     step and passing it the installer's command, built as without one;
     `installshield-custom-dialog-automate.au3` starting the command it's
     given; the answer file mounted rather than copied to
     `C:\nancy-drew-installer\setup.iss`. The editions'
     `installer: { stubborn }` removed from the schema and manifests, with
     `GameInfo.doesNotExitInNonInteractiveMode`.
   - The bundles rewritten for these.
   - `automatic` and `edition` removed from `patches.json` and its schema,
     with `GamePatchCatalog.Edition` and the Steam and Big Fish builders'
     `applyGamePatches` (decision 20).

   Integration: disc, Shadow Ranch (`--automation`) and a two-disc game.

   **2c. Steps that do what they say** (decision 18):
   - The rule: each builder checks every value it reads against what it
     does, and fails on a difference.
   - The patch function's steps carried out (`ADD`, `INSTALLER.RUN
     --patch`, and `RUN` with `fetch` and `bind` mounts); `--on-failure` a
     core option on every step; the function rewritten with all four
     branches; `applyGamePatch(id:)` and `GameInstallerRunner`'s
     `applyPatches:` paths removed.
   - `--into` and `--creates` on `INSTALLER.RUN` and `HER-DOWNLOAD.INSTALL`:
     the exe search kept, and the expected folder and exe linked to what it
     found when they differ. `WINE.KEEP-DISCS` reading `--into` and
     `--combined`.
   - `InstructionSpec`'s argument and option roles (decision 6), which the
     rule and the checks read.

   Integration: a game whose patch takes each shape (Lost Queen's copy,
   Scarlet Hand's extract until phase 3 drops it, a silent patcher, a
   wizard: Shadow Ranch), and a disc game whose installer takes its own
   folder, launched to check the quit watch and WrappPuppeteer find the
   game through the links.

   **2d. Locations realised** (decisions 2 and 14), before phase 3, which
   relies on them:
   - `DownloadWrappBuilder` copies through path types.
   - Bare `/…` paths resolved under the app's `Contents/`, refused past
     its top level, in `WrappLayout`.
   - The `dosbox:` type's `C:` folder, and `DOSBoxRuntime` mounting it.
   - Lure moves to `/SharedSupport/game/` and Tyrian to `C:/TYRIAN/`.
   - Phase 1's allowance removed.

   Integration: download (all three), with Tyrian's first launch (its
   loose thread).
3. **`LAUNCH` for Wine, ScummVM and DOSBox.**
   - The parser treats `LAUNCH` as taking a program.
   - **Every reader moves to the launch** (decision 7): the wrapp's
     runtimes, `UpdateWrappBuilder` and WrappPuppeteer read `Launch`, or
     the legacy keys translated into one for an old app, before decision 17
     and bare paths change where things are.
   - **The lock records the launch** in place of `args`, its volumes from
     `VOLUME`, and module stages' hashes; old locks translated (decision 7).
   - **`FROM previous` carries the old app's launch**, and every plan, an
     update's included, is refused at planning if it reaches no `LAUNCH`
     (decision 3).
   - **Old ScummVM apps are brought over by their update.** Their data is
     in the old prefix, and the new shape copies it from a disc an update
     doesn't have. So the update moves it: the data folder the old app's
     `GameInstallerDir` names goes to `/SharedSupport/game/`, the prefix is
     removed, and the launch recorded is decision 17's. That also frees the
     938 MB a Final Scene app carries today.
   - WrappKit's program registry and recorded launch.
   - `BuildPlan.launch`, and `completeBuild` writing it.
   - The wrapp reading it, with legacy settings translated.
   - Every Wrappfile stage that's a target gets its `LAUNCH`. The Nancy
     Drew ScummVM games' editions take decision 3's shape, and `EXPORT`
     goes.
   - **The disc, Her and Steam builders recognise decision 17's shapes**,
     a target whose stages back to `scratch` have ScummVM's module alone:
     - one step, `COPY --from=<a stage of this plan> <folder> /SharedSupport/game/`:
       they build the stages before it as now, and at the `COPY` take that
       folder as the game's data, which is what `EXPORT` makes them do
       today (`DiskWrappBuilder`'s `dataInstalled()`);
     - for the disc builder, `COPY --from=${input.disc-N} . /SharedSupport/game/` steps
       alone: it copies the discs straight into the game's folder, with no
       prefix built and no Wine started.

     Either way the target's modules say Wine isn't kept. No builder learns
     to copy between stages in general: any other step in such a stage is
     still a recipe problem, until a builder runs steps generically (the
     draft's work). The Steam builder learns the first in phase 4, with its
     stage.
   - Secrets Can Kill's two discs copied in turn compared with today's
     combined folder (decision 17), before its Wrappfile moves over.
   - Variants removed from the schema, `Manifest` and the manifests
     (decision 15). `GameCatalogSource` takes `gameEngine`,
     `internalGameExePath` and `graphics` from the default edition's
     planned launch, so `sc generate`'s output doesn't change. Check with
     `ProgramBundleTests`.
   - The grammar: `LAUNCH` and `VOLUME` in its `instruction`
     rule, and `EXPORT` out of it (`WrappfileGrammarTests` fails until it
     is).
   - `HER-DOWNLOAD.INSTALL --into` for a Mac download: `CiderPackage`
     moving the game there, and failing when the app's folder isn't found.
   - `VOLUME` (decision 14), recorded with the launch, and the scummvm and
     dosbox modules' save locations. Variants' `volumes`, the manifest's
     `runtime.environment`, and the launch's `graphics` move into the
     Wrappfiles; `LAUNCH --env` and `--wine.graphics`.

   - The wrapp running what's recorded (decision 19): helpers armed from
     `--wine.graphics`, with the import check at build time; volumes
     mounted as recorded; ScummVM's game id in place of `--auto-detect`;
     the clean-exit options, written by the bundles that need them; names
     from the bundle.
   - The launch's exe checked after the install, and the guessing in
     `findGameExecutable` and `chooseGameProgram` removed (decision 18).
   - Scarlet Hand's patch dropped and its disc edition a plain copy; Ghost
     Dogs and Haunted Mansion built once each and their patched files
     compared with ScummVM's `nancy.dat` (decision 17).
   - Module stages as Wrappfiles (`Modules/<id>/stages/<name>`), planned
     and keyed as a bundle's stages are; `wine/prefix` written, `WINE.DRIVES`
     and `--progress`, and `prefix.yaml`, its schema and
     `WineManager.applyPrefixSetup` removed; every bundle starting
     `FROM wine@10/prefix`; the `wine-prefix` update keyed on the stage's
     hash in the lock; a stage's `USE` of a module it has refused at another
     version (decision 21).
   - The manifest's `runtime` removed from the schema, and the modules'
     `save-warning` read by the wrapp in place of `showsSaveWarning`
     (decision 22).
   - `ICON` (decision 24): parsed, checked (`/Resources/`, `.icns`),
     recorded in `BuildPlan.icon` and set by `completeBuild`; the grammar's
     `instruction` rule; `nancy-drew.icns` in the nancy-drew module, made
     from `nancy-drew.icon` by `sc generate`; the template's icon switched
     to `GenericWrappIcon.icon` and `WrappTemplateIcon.icon` removed, in
     the same change as every Nancy Drew bundle's `ICON`.
   - cnc-ddraw out of `prefix.yaml` and into `DO wine.cnc-ddraw`, written
     by the 8 DirectDraw games' `prefix` stages; `EDIT --must-exist`; the
     checker requiring `--wine.graphics=direct-draw` and the function
     together; the `wine-prefix` update rerunning the function's steps on
     an old DirectDraw app (decision 23).

   Integration: disc (one Wine game; Ghost Dogs, through Wine; Royal Tower,
   Scarlet Hand and Secrets Can Kill, without it; Thornton Hall, for the
   clean-exit options), Her (Windows, a Wine game and a ScummVM one; Mac),
   and download (all three). Each built app's icon looked at in Finder:
   Nancy Drew's for the games, the generic one for the freeware.
4. **Steam through its stage.**
   - Steam editions get a target, using the steam module's `install`
     function.
   - `STEAM.REMOVE` declared.
   - `SteamWrappBuilder` follows the plan by recognising
     `STEAM.INSTALL`/`STEAM.REMOVE`, as the disc builder recognises its
     steps, and takes its launch, fallback included, from the plan.
   - `LAUNCH --fallback`, and the wrapp's generic fallback in place of
     "Start Without Steam"'s own wiring.
   - `GameInfo.steamEngine`, `SteamLaunchMode` and
     `GameConfig.canLaunchWithoutSteam` go.
   - `notes` allowed on editions in the schema, and `drm`
     moved into the Steam edition's own `notes` (decision 8): out of the
     schema's edition and `Manifest.Edition`, with `GameInfo.steamDRM`,
     `GameInfo.SteamDRM` and `GameCatalogSource`'s mapping. Each manifest's
     value moves as it is, still called `drm`.
   - `LAUNCH --steam.exe`, required on a Steam launch and recorded with it,
     in place of the `steam-game` input type's `exe` (decision 7).
     `SteamRuntime` and WrappPuppeteer take the game's exe from there.
   - Whether to ask the launch-mode question comes from the edition
     having a `launch-mode` input (phase 2), carried into the catalogue as
     a flag where `offersSteamLaunchChoice` is computed from `drm` today.
     Its readers follow: `SteamWrappBuilder`, `sc`'s `--steam-launch` check
     (`Wrapps.swift`, `Catalog.swift`), and the Steam integration suite.

   - Decision 21's steam steps: Cmd as Ctrl set and removed, the client
     cache as a mount, `STEAM.SIGN-OUT`.

   Asking the question stays as it is (`getSteamLaunchMode`). Integration:
   Steam, both modes, on Shadow Ranch and one Steam-launched game.
5. **Big Fish through its stage.** The same shape for `BigFishWrappBuilder`,
   with `LAUNCH big-fish:…`. The Game Manager starts the game as Steam
   does, so if the wrapp needs the game's exe to find it, the launch takes
   it the same way (`--big-fish.exe`). `WrappSettings.composition`'s
   `bigFishLaunchFile` special case goes. Decision 21's big-fish steps: the
   Game Manager's installer pinned, `--decline-directx`, `BIG-FISH.SIGN-OUT`.
   Integration: Big Fish (trial, and the test account).
6. **Legacy keys: what's left.** Every reader has moved to `Launch` in
   phase 3. The build still writes the legacy keys it can, for an older
   Second Chance updating a newer app. Note in the docs which keys are kept
   for that and why, and remove the reading code's legacy paths that no
   shipped app can need (an app from before volumes, say), each with the
   app version it stops supporting.

## Testing

- **`WrappfileCheckerTests`**: each new check passing and failing, against
  stub modules through the registry seams:
  - a path whose type's module the stage lacks, or whose type lacks the
    role (a location type as a program, a program type as a location);
  - the same program type accepted by both `RUN` and `LAUNCH`;
  - a short form claimed by two of the stage's modules, and the full form
    resolving it;
  - an option or mount field from a module the stage lacks, or one it
    doesn't declare;
  - a `--fallback` whose type isn't a program, or whose module the wrapp
    lacks;
  - a `--mount=type=volume`, now refused like any unknown type;
  - a target with no `LAUNCH`.
- **`BuildPlanTests`**:
  - short forms rewritten to full forms, and aliases to ids
    (`USE wine AS w`);
  - a launch inherited through `FROM`, overridden, and chosen by `IF` on a
    choice;
  - the last `LAUNCH` winning, its fallback replaced with it, and volumes
    building up;
  - `VOLUME --remove` dropping an inherited volume;
  - a function's step rejected by the planner in a stage without its module;
  - a launch-only change leaving `InstallLayer`'s key's plan input as it
    was.
- **Values** (`WrappfileExpressionTests`, new, in the package, and
  `WrappfileCheckerTests`, `BuildPlanTests`):
  - references parse: namespaces and brackets; `${x:-…}` and nested
    `${…}` refused with a message saying what replaces them;
  - a missing data field reads as its schema's default, and one with no
    default is an error;
  - an undeclared reference is an error in a branch no edition takes;
  - a missing input is an error only when a reached step or condition uses
    it, and a default fills it;
  - the innermost declaration wins; a `CONST` can't be assigned or declared
    again within its scope; a `SET` in a branch changes the outer `VAR`, and
    a `VAR` in a branch shadows it;
  - a function reads the caller's input when the `DO` passes none, and its
    own `INPUT`'s default when neither has one;
  - `self` resolves to the module whatever its `AS` name, and is refused
    outside a module;
  - a local function or signal named like a used module wins, with a
    warning, and `module.<name>.…` reaches the module's;
  - a module named like a core name or instruction warns, and is reached
    in full;
  - a `--secret` input never appears in a step's description, and changing
    it leaves `InstallLayer`'s key's plan input as it was;
  - an edition's `build.inputs` matched against what its target uses, both
    ways; an `INPUT` in a stage or a branch refused.
- **More values** (same suites): `SET` without a `VAR` refused, and a
  `VAR` read before it's set; a module named `input` or aliased `launch`
  reached only in full, with the message naming it; a `${….data.…}` path
  against a module's schema; a relative path resolving to the module whose
  function it's written in, and a missing bundle file refused; a bare input
  name where an input is taken refused.
- **`VOLUME`** (`BuildPlanTests`, WrappKit): volumes inherited, removed and
  recorded; one naming no manifest volume refused; one mounted by nothing
  allowed, with no warning; older wrapps' recorded volumes translating to the same mounts.
- **`--automation`** (`InstallerPlanTests`): an InstallShield installer's
  command is the same with a script as without, and with one the script is
  run with that command as its arguments; the answer file's path in the
  command is where it was mounted. Integration: one disc build of a game
  that needs the script (Shadow Ranch, phase 2b).
- **Decisions 15 and 16** (`ProgramBundleTests`, `ManifestSchemaTests`,
  `WrappfileCheckerTests`): a manifest with `variants`, an edition's
  `installer`, a module's `assemble` or a Wrappfile's `EXPORT` refused; the
  catalogue's `gameEngine`, exe and `graphics` the same from the planned
  launch as from today's variants, for every shipped bundle; a two-disc
  edition's `disc-2` reached through `WINE.KEEP-DISCS`; `CiderPackage`
  moving a Mac download's game to `--into`, and failing without its folder.
- **Launch details** (`WrappfileCheckerTests`, `ProgramBundleTests`, `DiskWrappBuilder`'s tests):
  a Steam launch without `--steam.exe` refused; a bundle whose launch
  differs between `arm64` and `x86_64` failing `sc generate`; the disc
  builder building a ScummVM disc edition from its discs alone, with no
  prefix, and taking a ScummVM target stage's `COPY --from=… /SharedSupport/game/` folder as
  the game's data, and refusing any other step in that stage.
- **`ICON`** (decision 24; `WrappfileCheckerTests`, `BuildPlanTests`,
  `WrappBuildHelper`'s tests): one outside `/Resources/` or not `.icns`
  refused; inherited through `FROM`, the last winning; a plan with none
  leaving the template's icon; `completeBuild` failing when the file isn't
  there, and otherwise setting `CFBundleIconFile` and removing
  `CFBundleIconName`; `ProgramBundleTests` checking every Nancy Drew
  target has the module's icon and no freeware one has an `ICON`.
- **Module stages** (decision 21): a stage file planned and keyed as a
  bundle's; `FROM wine@10/prefix` then `USE wine` getting 10, and `USE
  wine@9` refused; `WINE.DRIVES`; `--progress` resolving to app text; the
  `wine-prefix` update rerunning a changed stage over an old app.
- **Decision 18's checks** (each builder's tests): a builder refusing a
  step whose value it would not honour, naming both; the exe search
  linking `--into` and a renamed exe; `INSTALLER.RUN --patch` making no
  link; the patch function's four branches carried out against fixtures.
- **Locks and old apps** (WrappKit, `UpdatePlannerTests`): an old lock's
  `args` translated to a launch; a fresh build when the launch's program
  moved; an update of an old ScummVM app moving its data and dropping the
  prefix; an update target reaching no `LAUNCH` refused.
- **Every edition the same** (`ProgramBundleTests`): each shipped bundle's
  editions record the same volumes and launch options.
- **cnc-ddraw** (decision 23): `EDIT --must-exist` failing on a missing
  setting and naming it, and adding it without the flag; a DirectDraw
  launch without `DO wine.cnc-ddraw` refused, and the reverse; the shared
  prefix no longer holding cnc-ddraw; an old DirectDraw app updated still
  having it, and a Direct3D one not gaining it. Integration: one
  DirectDraw game and one Direct3D game.
- **`ManifestSchemaTests`**: `build.inputs` keyed by name, each type's
  fields, `choice` among them, and `choices` refused.
- **`ProgramBundleTests`**: every shipped target plans, for both
  architectures and every `choice` input's value, and reaches a launch whose module
  the composition has.
- **`drm` as a note** (phase 4): `ManifestSchemaTests`' `drm` cases become
  an edition's bare `drm` refused as a mistyped key, and `notes` accepted,
  unchecked, on an edition. `ManifestQueryTests` finds an
  edition by `editions.notes.drm=no`. `GameInfoSteamTests` asks whether the edition has the
  `launch-mode` input rather than about its DRM, and `WrappfileTodayTests`' comparison of
  the two goes, as they are now one fact.
- **Module tests**: no two modules register one path type, no type's name
  is a single letter, and no two module ids differ only in case.
- **Case** (`WrappfileParserTests`, `WrappfileCheckerTests`,
  `BuildPlanTests`): a Wrappfile written in lower case (`from`, `run`,
  `if`/`end`, `wine.mount`) parses, checks and plans the same as one in
  upper case; `W.MOUNT` and `w.MOUNT` both find `USE wine AS w`; a
  `USE … AS` name differing from another module's only in case is
  rejected; a step's description writes `WINE.MOUNT`.
- **WrappKit tests**:
  - the recorded launch round-trips through `AppSettings.plist`, with and
    without a fallback;
  - an older wrapp's Steam launch with `SteamLaunchMode` `steam` translates
    to a launch whose fallback is its exe, so "Start Without Steam" keeps
    working for wrapps built before this;
  - each legacy engine's settings translate to the launch and composition
    they mean today. These are the cases `Composition(legacy:)` and
    `WrappSettings.composition` cover now, Big Fish included.
- **`WrappfileTodayTests`**: updated with each phase. Each Wrappfile's launch
  matches the exe today's catalogue names.
- **Integration**: per phase, above. Only the integration test catches a
  dropped bus event, and phase 3 moves what `completeBuild` publishes.

## Docs

Updated in the phase that changes each, as AGENTS.md requires:

- **`docs/wrappfile.md`**:
  - its syntax section: instructions are case-insensitive with upper case
    the convention, a module's name in an instruction included, and lower
    case wherever else a module is named;
  - `LAUNCH` (with `--fallback`) in the instructions table;
  - `VOLUME`, and bundle and module files as relative paths;
  - the rule that the core wins a name clash, for instructions and `${…}`;
  - a section on values: the namespaces and references, data defaults,
    `INPUT`/`CONST`/`VAR`/`SET` and their scopes, the function rule, `--secret`,
    `--env`, and `IF`'s comparisons, replacing what it says of `ARG`;
  - `volume` gone from the mount types, and `EXPORT` from the instructions;
  - a section on what modules add: path types (full and short forms,
    clashes), options and fields, and where each is checked;
  - each shipped module's path types.
- **`docs/modules.md`**: what a module declares, now including path types,
  extensions, and that only modules with Swift can
  have them; `self` in a module's files; `assemble` gone (decision 16); a
  module's data schema and its defaults, and `version` (phase 2); the save
  locations the scummvm and dosbox modules register (phase 3); the
  nancy-drew module's icon and how it's made (phase 3).
- **`docs/program-bundles.md`**:
  - phase 2: an edition's `build.inputs` and their types, `choices` gone,
    and the edition's `installer`;
  - phase 3: variants gone (decision 15), and with them their `volumes`;
    `runtime.environment` gone; `volumes` saying the Wrappfile mounts them;
    the `GameInfo` mapping table's `gameEngine`, `internalGameExePath` and
    `graphics` rows saying they come from the planned launch;
  - phase 4: the edition's `drm` moved into its `notes` (below).
- **`docs/dev-cli.md`**: `--input` (phase 2); `sc generate` compiling
  the nancy-drew module's icon (phase 3).
- **`docs/wrappfile.md`** and **`docs/wrapp-build.md`**: `ICON`, and the
  template's generic icon for an app with none (phase 3, decision 24).
- **`Tools/sc/Sources/SCKit/Support/Wrapps.swift`**: `updateTemplate`'s
  comment, whose asset catalog now holds the generic icon.
- **`docs/wine-in-process-helpers.md`**: helpers armed from the declared
  `--wine.graphics`, the import check as a warning, `unknown`, and the
  clean-exit options in place of the rule for every Wine game (phase 3).
- **`docs/game-patches.md`**: patches applied as their function's steps,
  `--on-failure`, `INSTALLER.RUN --patch` (phase 2c); `automatic` and
  `edition` gone, and Scarlet Hand's patch left to ScummVM (phases 2b, 3).
- **`docs/wrapp-build.md`**: builders checking every value (decision 18),
  the exe search and its links, layer keys from module stages and bundle
  files, the lock recording the launch, updates of old ScummVM apps.
- **`docs/testing.md`**: WrappPuppeteer taking the game's exe from the
  launch (phase 3).
- **`AGENTS.md`**: its cnc-ddraw bullet (graphics from the declared launch,
  not `GameInfo.graphics`; cnc-ddraw from `DO wine.cnc-ddraw`); its "Disk
  path resolution" gotcha (`WINE.KEEP-DISCS --into` and `--combined`); its
  bullets naming `prefix.yaml` (the prefix layer's key, `EmulateModeset`),
  which become the `wine/prefix` stage (phase 3).
- **`docs/wrappfile.md`'s "Highlighting in VS Code"**: a module's
  instructions highlighted by their shape, now `WINE.INSTRUCTION` rather
  than `name.INSTRUCTION` (phase 1).
- **`docs/her-download.md`**: a Mac download installing to `--into`
  (phase 3).
- **`docs/wrapp-launch.md`**: how the launcher is chosen (from
  the recorded launch), and the fallback ("Start Without Steam").
- **`docs/steam.md`**: launch-mode as the Wrappfile now says it, and its
  table of what each `steamDRM` builds replaced by what the Wrappfile says
  (phase 4).
- **`docs/program-bundles.md`**'s phase 4 change: the edition's `drm`, in its
  example and its `GameInfo` table, moved into the edition's `notes`, and
  its section on `notes` saying editions can have them, each
  about what it's on.
- **`docs/big-fish.md`**: its launch (phase 5).
- **`AGENTS.md`**: the `GameInfo.GameEngine` bullet once `steamEngine` and
  the engine values stop being how a wrapp's modules are chosen (phase 4 or
  6).
- **`docs/historical-plans/2026-11-03-generic-programs.md`**: it is frozen,
  so not amended. A dated post-implementation note at C5 says these were
  decided again here, and links to this plan's historical copy:
  - the launch (C5), and the launch-override `when`;
  - `RUN --with` executors and `COPY` path roots, replaced by path types;
  - the `volume` mount type, removed;
  - the rule that `USE` alone brings a module's additions;
  - module instructions written `WINE.REGISTRY`, not `wine.REGISTRY`;
  - `ARG` and `${data.…}`, replaced by `INPUT`, `CONST`, `VAR` and
    namespaces, and an edition's `inputs` and `choices` moved under its
    `build`;
  - variants, `EXPORT` and modules' `assemble`, removed.
- **On completion**: this plan moves to
  `docs/historical-plans/<date>-program-bundle-improvements.md`, with its row in
  AGENTS.md's table.

## Out of scope

- **Steps the app runs before launch**, to change the person's files (an
  update's save migration), which is what the `volume` mount type was
  meant for: a plan for consideration, built when a program needs it, in
  [docs/plans-for-consideration/before-launch-steps.md](../plans-for-consideration/before-launch-steps.md).
  This plan only removes `volume`; it doesn't depend on that one.
- **Signals**: a Wrappfile saying what a program's readiness or other
  events look like, so any program can be a service. A plan for
  consideration, in
  [docs/plans-for-consideration/signals.md](../plans-for-consideration/signals.md),
  built on this plan's `LAUNCH` and values, with `SERVICE` designed there
  (decision 4).
- **Functions inside `${…}`**: a plan for consideration, in
  [docs/plans-for-consideration/functions-in-values.md](../plans-for-consideration/functions-in-values.md).
- **Building one game with different engines**, which variants were for
  (decision 15).
- **A module's dependencies per instruction or function**, so a stage using
  only a part of a module that needs no Wine needn't have it. Scarlet
  Hand, which raised it, no longer needs its patch (decision 17).
- **Asking for inputs generically.** Decision 12 moves where an input is
  declared, not how the person is asked: the disc, download and launch-mode
  screens stay as they are. Input types provided by modules, and one screen
  asking for any edition's inputs, are later work.
- **Mount types from modules.** Keep the draft's core list until a module
  needs one.
- **Carrying out `RUN`'s programs and mount fields.** That's the generic
  step runner, the draft's work.
- **An update that changes only a wrapp's launch.** Possible once launches
  are in plans, but deciding when one applies is the update planner's work.

## Open questions

None: decisions 1 to 24 settle what was open.

## To come back to

- **An icon with its dark and tinted appearances.** An `.icns` has one
  look (decision 24). Keeping the `.icon`'s would mean the build merging a
  compiled `Assets.car` into the app's, which needs `actool`, or
  modules shipping one ready-made. Worth it if the plain icon looks wrong
  beside other apps on a Mac in dark mode.

- **`previous` and `base` as values rather than special words.** `FROM
  previous` names a stage the update planner supplies, and `base` one the
  manifest's `build.base` picks. With namespaces they could be inputs:
  `FROM ${input.previous}`, given by the update planner. That needs `FROM`
  to take an expression, and a stage to be a value, which nothing else
  does yet.
- **Values known only at launch**, such as a program's pid for a signal.
  Nothing needs one yet; every value is known when planning (decision 10).
  If one's needed, the planner would leave it for the wrapp to fill in, and
  the checker keep it out of build steps and functions.
- **More value types**: numbers, true/false and lists, and `IF` with `and`,
  `or` and `in`, when a bundle needs them (decision 10).

## As implemented

Built 2026-11-04, in the phases above. Where the code differs from the plan:

- **`prefix.yaml` went under the same Wine version.** The release rule
  refuses a release that drops data a version had, so a module may name
  data only Second Chance's own Swift read, never a bundle, as `retired`
  (the wine module's `prefix.yaml`), and it may go.
- **A Steam or Big Fish stage repeats the bundle's `prefix` stage's lines**
  (cnc-ddraw, the icon, the saves volume): it's built `FROM steam@1/client`
  or `FROM big-fish@1/manager`, and a stage has one parent. The module
  stages chain (`steam/client` is built from `wine/prefix`), each planned
  once.
- **The Steam client's cache is put back before Steam first starts**, since
  Steam must be signed in to say which games an account owns, and saved at
  `STEAM.SIGN-OUT`; the `cache` mount on `STEAM.INSTALL` declares it.
- **The Game Manager's installer is a `fetch` mount on `BIG-FISH.MANAGER`**,
  pinned by its sha256, rather than an `ADD` and `INSTALLER.RUN
  --automation`: its AutoIt script takes the installer and the client's
  path, not an installer's command.
- **Decision 18 kept the search for what an installer made**, as it says;
  what went is the fallback to the catalogue's exe when a step has no
  `--creates`. A build also fails when its recorded launch's program isn't
  in the app.
- **An `IF` branch's `LAUNCH`, `VOLUME` and `USE` are the stage's.** Planning
  had dropped them with the branch's scope, which the Steam launch choice
  needs.
- **A module's option on a core instruction can have a role**
  (`coreOptionRoles`), so `--steam.exe` and `--big-fish.exe` are written in
  full form.
- **The catalogue's names are the bundle's**: every game carries its program
  id, series and app name, and `GameInfo` has no Nancy Drew defaults.
- **Nothing legacy could go but a lock's `args`**: no released Second
  Chance (1.1.0 and earlier) built a wrapp with a lock, volumes or a
  recorded launch, so the translation of their settings stays.
