# Wrappfiles

A program bundle's `Wrappfile` says how its game's app is built: Dockerfile-like
steps, in stages, one stage per edition (or shared by several). Each edition in
the bundle's manifest names the stage it builds (`build: { target: "disc" }`).
For now Wrappfiles are parsed and checked, and each game's says what its builder
does today; the builders don't run them yet.

```dockerfile
# A fixed value, and the inputs the editions give, written once
CONST install-dir = "C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"
INPUT disc-1
INPUT disc-2

FROM scratch AS prefix
USE wine@10 # a module, with a version constraint

# The CD edition (its manifest says build: { target: "disc" })
FROM prefix AS disc
USE installer
USE nancy-drew AS nd # a module, known in this stage as nd
WINE.KEEP-DISCS ${input.disc-1} ${input.disc-2} --into=C:/nancy-drew-installer --combined=C:/nancy-drew-installer/disk-combined
INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir} --answer-file=assets/disc.iss
DO nd.patch --id=blue-moon-taffy-sort --into=${const.install-dir}
```

## Syntax

- **Keywords are case-insensitive, and written in upper case**, as in
  Docker: `from` and `run` are `FROM` and `RUN`. A module's instructions
  follow the same convention, its name included (`WINE.REGISTRY`, not
  `wine.REGISTRY`), and the module part matches whatever case it's written in.
  Everywhere else a module is named it's in lower case, as a name: `USE
  nancy-drew AS nd`, `FROM --module=steam client`, `DO nd.patch`, `--wine.drive`.
  Two module names that differ only in case are the same name.
- **A module's name can match a core instruction, and the core always
  wins.** `USE foo AS copy` is allowed, with a warning, and `COPY` is still
  the core's; that module's instructions are written in full,
  `MODULE.COPY.<INSTRUCTION>`, which works for any module
  (`MODULE.WINE.REGISTRY`).
- **Stage and function names follow Docker's rule for stage names**: they
  are case-insensitive (`FROM Prefix` finds `AS prefix`), and must start with
  a letter followed by letters, digits, `-`, `_` and `.`. One written in upper
  case is warned about, to keep names and instructions apart.
- **One instruction a line.** A line ending in `\` continues on the next, and
  that is the only place `\` is special, so Windows paths and registry keys are
  written as they are (`HKCU\Software\Wine`).
- **`#` starts a comment** at the start of a word, outside quotes; a `#` inside a
  word is ordinary.
- **Words** are split on spaces. Double quotes make one word of what's between
  them, and `""` inside them is a quote. There is no shell: `RUN` runs a program
  with its arguments, so pipes and `&&` don't exist.
- **Options** are `--name` or `--name=value`. For `RUN` and a module's `.RUN`,
  the first word that isn't one is the program, and everything after it is the
  program's arguments; other instructions take options anywhere
  (`STEAM.INSTALL game --into=…`).
- **`${…}` reads a value** through its namespace ([Values](#values)):
  `${const.install-dir}`, `${input.game.app-id}`,
  `${self.data.patches[input.id].url}`. `$$` is a `$`.
- **A relative path is a file of the bundle's**, or in a module's file, of the
  module's: `--answer-file=assets/disc.iss`. Another module's is written in
  full, `module:<id>:/<path>` (`module:installer:/autoit`), the `:/` keeping a
  namespaced id's `/` apart from the path's; the older `module:<id>/<path>` is
  refused. Planning writes each in full (`bundle:assets/disc.iss`), and checks
  it's there and is in a folder the build may read
  ([below](#what-a-build-may-read)).
- **Blocks**: `IF <condition>` … `ELSE IF <condition>` … `ELSE` … `END`,
  `LAYER-HINT` … `END` (where a layer is worth keeping: once, after its last
  step, and none inside it, [wrapp-build.md](wrapp-build.md#the-layer-cache);
  a bare `LAYER` is refused) and `FUNCTION <name>` … `END`. A condition compares two
  expressions, each a `${…}` or a quoted string, with `=` or `!=`, spaced or
  not: `IF ${platform.arch} = "arm64"`; or asks whether a list holds a text,
  with `has`: `IF ${input.updates} has "blue-moon-taffy-sort"`.

## Instructions

| Instruction | Does |
| --- | --- |
| `FROM scratch` / `FROM <stage>` / `FROM --module=<module>[@<constraint>] <stage>` / `FROM ${input.<name>}` `[AS <name>]` | Starts a stage from the bare template, another stage, a module's (`FROM --module=steam@1 client`), named with a flag as Docker's `FROM --platform=` is, or the tree an input names: `FROM ${input.previous}`, the old app an update is built from ([Updates](#updates)). The older `FROM steam@1/client` and `FROM previous` are refused. A stage built from another keeps its modules. |
| `INPUT <name> [--default=<value>] [--secret]` | Declares a value from outside, before the first `FROM` or at a function's top ([Values](#values)). |
| `STORE <name> [--retention=keep\|cache\|session] [--scope=app\|global] [--exclusive[=<lock>]]`, `LOCK <name> [--scope=app\|global]` | Declares a store, data kept outside the app, and a lock stores are used under, before the first `FROM` ([Stores](#stores)). |
| `CONST <name> = <value>`, `VAR <name> [= <value>]`, `SET <name> = <value>` | A fixed value; a value worked out in the Wrappfile; and a new value for a `VAR`. |
| `USE <module>[@<constraint>] [AS <name>]` | Adds a module, and what it depends on: its instructions are then `<NAME>.INSTRUCTION`, its functions `DO <name>.<function>`, and its path types, options and mount fields are the stage's ([below](#what-modules-add)). |
| `RUN [--mount=…]… [--env NAME=<value>]… <program> <args>` | Runs a program inside an engine: its path type says which. Mounts: `store` ([Stores](#stores)), `bind` (a file of the bundle's or a module's) and `fetch` (a download, by its hash). `--env` is the only way a value reaches a program's environment. |
| `COPY [--from=<stage or ${input.<name>}>] <src> <dest>` | Copies files: from another stage or an input, or without `--from`, a bundle's or module's file. |
| `ADD --checksum=sha256:<hash> [--unpack=zip --member=<file> [--extract]] <url> <dest>` | A download, found in the download cache first. |
| `MOVE`, `REMOVE`, `EDIT <file> --ini=<section>.<key>=<value>… [--keys-must-exist] [--create]` | File changes the builder makes itself. `EDIT` changes each setting in its section, or adds it; with `--keys-must-exist`, each setting must already be in the file, or the step fails naming those that aren't. The file must exist unless the step says `--create`. The older `--must-exist` is refused, with a message saying so; `--from-data` is gone, replaced by `NANCY-DREW.CONFIGURE-INI`. |
| `EMIT "<string>"` | A string for whoever runs the build, passed on unread as the build reaches it: not a step ([below](#emit)). |
| `LAUNCH [--fallback=<program>] [--env NAME=<value>]… [--mount=type=store,…]… [<program> [<argument>…]]` | How the app starts its program, and the stores it sees ([below](#the-launch-volumes-and-app)). One with mounts alone adds them and leaves the program as it is. `VOLUME`, which this replaces, is refused. |
| `APP [--default-id=<id>] [--name=<name>] [--icon=/Resources/<name>.icns]` | What the app is: the id it gets when the build is given none, its name, and its icon ([below](#the-launch-volumes-and-app)). It replaces `ICON`, which is refused. |
| `FUNCTION <name>` … `END`, `DO <name>` / `DO <alias>.<name>` | Named steps, with `INPUT`s as parameters (`--id=…`): a bundle's own, or a module's (in its `functions/`). |

Every step takes `--name=<id>`, naming it for reports, and
`--on-failure=ask`, which asks whether to carry on without a step that
failed; without it, a failed step fails the build.

Modules' instructions, as each module's `module.yaml` declares them
([modules.md](modules.md#what-a-module-declares)):

| Instruction | Does |
| --- | --- |
| `WINE.WINETRICKS <verb>` | Installs a winetricks verb. |
| `WINE.REGISTRY --set <key>:<name> <value>` / `--remove <key>:<name>` | Sets or removes a registry value. The key is a name the module knows (`x11-driver`, `mac-driver`, `direct3d`) or written in full (`HKEY_CURRENT_USER\Software\Wine\…`). |
| `WINE.DRIVES --only=C:` | The prefix's drives: every other is removed, C: is `drive_c`, and the rest (Z:, the whole Mac, included) blocked. |
| `WINE.KEEP-DISCS <disc input>… --into=<folder> [--combined=<folder>]` | Copies the discs it's given into `<folder>/disk-<n>` (and merged into `--combined` for more than one), each given a drive from D:: for a game that checks for its disc. |
| `INSTALLER.RUN [--from=<input>] --into=<folder> [--creates=<program>] [--answer-file=…] [--automation=<script>] [--patch] [program]` | Runs a Windows installer: silently with an answer file. `--creates` is the program it should leave, linked to what it made if that's elsewhere, and must be the target's `LAUNCH` program when that is under `--into`; `--patch` runs a patcher in `--into`, looking for nothing afterwards. With `--automation`, AutoIt runs the script, given the installer's command (the same as without it) to start, for an installer that installs and never exits; the script clicks where it stops. Without a program, the installer on the input, found as today. |
| `STEAM.CLIENT --client-store=client` | Installs Steam's client in the prefix (the steam module's `client` stage), from the client store when it has one. |
| `STEAM.INSTALL <input> --into=<folder> --sign-in-store=sign-in --client-store=client` | Has Steam install the input's app, signed in with the shared sign-in and with the kept client, the steam module's stores, and makes `--into` a link to the folder Steam put it in. |
| `STEAM.SIGN-OUT` | Takes the sign-in out of the prefix, saved for the next build first, so the app carries none. |
| `BIG-FISH.MANAGER --mount=type=fetch,url=…,sha256=…,target=…` | Installs Big Fish's Game Manager from its installer, pinned by its hash (the big-fish module's `manager` stage). |
| `BIG-FISH.INSTALL <input> --into=<folder> --sign-in-store=sign-in [--decline-directx]` | Has the Game Manager download, install and activate the input's game, declining DirectX's setup, and makes `--into` a link to the folder it installed it in. |
| `BIG-FISH.SIGN-OUT` | Signs the Game Manager out, or keeps a person's sign-in for the next build, then takes the account out of the prefix. |
| `STEAM.REMOVE` | Takes Steam away: the game moved to where `STEAM.INSTALL --into` linked it, then Steam's folders and the client stage's registry settings removed. |
| `HER-DOWNLOAD.INSTALL <input> [--into=<folder>] [--creates=<program>] [--answer-file=…] [--automation=<script>]` | Installs Her Interactive's download: a Windows installer as `INSTALLER.RUN` runs one, or a Mac download's game taken out. |
| `WINE.MOUNT <folder> <drive> [--cdrom]` | Gives a folder in the prefix a drive letter, kept for later steps and at launch; `--cdrom` makes it a CD drive. |
| `WINE.HELPERS`, `WINE.PREFIX` | The wine module's `setup` steps, which `USE wine` plans: the in-process helpers laid in, and wineboot's prefix ([modules.md](modules.md#what-a-module-declares)). |
| `SCUMMVM.KEEP-DATA <file>…` | Takes out of the app every one of ScummVM's data files but those named (`nancy.dat`) and what its own windows need, out of the 80 MB it comes with ([modules.md](modules.md#the-scummvm-modules-data)). Without it, the app keeps them all. |
| `NANCY-DREW.CONFIGURE-INI <folder>` | Gives every `.ini` in the game's folder what the nancy-drew module's `ini.yaml` says (LCD mode, saves in Documents), each written back in the encoding it came in. `DO nancy-drew.configure-ini --into=…` is how a stage says it. |

An input is always written `${input.<name>}` where an instruction takes one.

## EMIT

`EMIT "<string>"` hands its caller a string, which the builder never reads.
It is how a Wrappfile tells whoever runs the build where it has got to,
without the builder knowing what the words mean.

```text
EMIT "second-chance.phase.installing-game"
INSTALLER.RUN --from=${input.disc-1} --into=${const.install-dir}
```

- **It isn't a step.** It is planned with its stage (`PlannedStage.emits`),
  each kept with the index of the step it comes before, so it is in no
  step's key and keeps no layer: adding one changes no cached layer.
- **It is planned as steps are**: `${…}` substituted, expanded where a
  function is `DO`ne, and dropped with an `IF` branch that isn't taken.
- **The runner emits it as the build reaches it**, before the step after it,
  or at the stage's end for one after the last
  ([wrapp-build.md](wrapp-build.md#the-runner)). `wrapp-builder build`
  prints each as it is.

**Second Chance's strings** are listed in
`SecondChance/Resources/emit-vocabulary.yaml`: those starting
`second-chance.`, each a pattern with its placeholders' values.

| String | Means |
| --- | --- |
| `second-chance.phase.<phase>` | The build has reached a phase (`setting-up`, `copying-installer`, `installing-game`, `configuring`): the progress screen's step and headline. A phase never goes back. |
| `second-chance.substep.<key>` | The next step's substep, in Second Chance's own words for the key (`display`, `graphics`, `disc`). |
| `second-chance.progress.<done>/<total>` | How far the current step has got, two numbers. |

`sc generate` makes `SecondChance/Models/EmitVocabulary+Generated.swift`
(`SecondChanceEmits`) from the YAML, as the app reads no YAML, and a test
fails when it is stale. `EmitVocabulary`, in the builder, checks a plan
against a vocabulary: a string with its prefix that no pattern matches is
refused, and so is an ordered value (a phase) that goes back; a string
without the prefix is someone else's and never checked. `sc bundle check`
and a unit test (`EmitVocabularyTests`, in `Tools/sc`) hold every shipped
bundle's editions to Second Chance's.

The wine module's prefix stage and its `cnc-ddraw` function `EMIT` the
progress screen's substep before the steps that take a while
(`second-chance.substep.display`, `disc`, `graphics`); the `--progress`
option they had is gone.

## Stores

A **store** is a named folder kept outside any app, which build steps and a
launch mount: a game's saves, a cache a build keeps, Steam's one sign-in.
The builder never looks inside one. A Wrappfile declares its own before its
first `FROM`; a module declares its own in files its `module.yaml` names
(`stores: ["stores"]`), which every stage and function of the module sees.

```dockerfile
# Modules/steam/stores
LOCK steam --scope=global
LOCK client --scope=global
STORE client --retention=cache --scope=global --exclusive=client
STORE sign-in --scope=global --exclusive=steam
```

- **`--retention` says how long it lasts, and so where it is**: `keep` (the
  default) until someone removes it, in Application Support; `cache` until
  space is needed, in the caches folder; `session` for the build or launch
  that made it, in the temporary folder, removed when it ends. A session
  store can't be `global`.
- **`--scope` says which apps share it**: `app` (the default), one for each
  app id, so every build and copy of an app has the same one; `global`, one
  for every app.
- **A store's full name is its owner's and its own**: a module's by the
  module's id (`steam:sign-in`), a Wrappfile's own by `app` or `global`
  (`app:wine-documents`). Its owner's files name it by its short name; any
  other names it in full.
- **`--exclusive` says one user at a time.** On its own, the store has a
  lock of its own, with its scope; `--exclusive=<lock>` names a `LOCK` the
  file declares, which every store naming it shares. A build holds the lock
  while a step uses the store; one that finds it taken says so
  (`lockWaiting`, the progress screen telling the person something else is
  using it), waits, and fails after `SECOND_CHANCE_LOCK_WAIT` seconds (30
  minutes), naming who held it. Steam's one-at-a-time lock is the steam
  module's `steam` lock, which every Steam app takes while Steam runs.
- **A step mounts one with `--mount=type=store,source=<store>,target=<path>`**:
  the target is a link to the store's folder while the step runs, so what the
  step changes there it changes in the store, then the link goes. With
  `snapshot`, a clone of what the store holds is left at the target instead.
  A target the tree has already is an error.
- **A kept store is never mounted by a build step**: it lasts beyond the
  build, so a build mustn't change it. A module's own instruction may be
  given one of its own module's, as an option whose role is `store`
  (`STEAM.INSTALL --sign-in-store=sign-in`), which its executor takes
  through `context.store` and knows how to change safely.
- **A store's declaration is recorded beside it** (`<name>.store.json`). One
  declared otherwise later (another retention, scope or lock) is refused,
  naming both: a store that changes gets a new name, or the old one is
  removed (`sc store remove <owner>:<name>`).
- **A launch mounts stores too**, which is where a game's saves are
  ([The launch, volumes and app](#the-launch-volumes-and-app)).

Where each lives is `StoreLocations`, in `WrappFormat`, so the builder and
the wrapp agree: an app's kept stores in
`~/Library/Application Support/<app id>/stores/<owner>/<name>/`, global ones
in `…/SecondChance/stores/<owner>/<name>/`, caches under
`~/Library/Caches/SecondChance/stores/`. Under test,
`SECOND_CHANCE_APP_SUPPORT_DIR` moves an app's own stores, so a test launch
starts with none; the global ones stay where they are, as the integration
tests' Steam builds sign in with the saved session. Builds in the test host
(the unit and integration tests both) keep the runner's stores, global ones
too, in a temporary folder of their own; the Steam and Big Fish builders
still use the real sign-ins themselves, and hold the real Steam lock
(`SteamActiveLock`).

`sc store list` shows the kept and cache stores on the Mac, with their
sizes and whether one's lock is held; `sc store remove <owner>:<name>`
removes one (an app's from every app, unless `--app` names one), and
`sc clean stores` the cache ones, or the kept ones with `--retention keep`.
A store whose lock is held is left alone (`StoreInventory`, in
`WrappFormat`). `sc clean layers` leaves stores alone, so clearing layers
doesn't sign anyone out of Steam.

Not built yet: a store declared inside a function.

## Updates

An update brings an app an older Second Chance built up to this one, from
the app itself ([wrapp-build.md](wrapp-build.md#updating-a-wrapp)). Second
Chance decides which updates apply (`UpdatePlanner`); a Wrappfile sees two
inputs:

```dockerfile
INPUT updates --default=[]
INPUT previous

FROM ${input.previous} AS update
IF ${input.updates} has "blue-moon-taffy-sort"
  DO patch
END
DO post-install-setup
```

- **`updates`** is a list of the names of the updates applied, `[]` on a
  fresh build. An unquoted JSON list is a list value (`--default=[]`).
- **`previous`** is the old app's tree: its prefix, game and all, with
  Documents and A: pointed at an empty stand-in, so nothing an update runs
  touches the person's saves. Its fields are what the old app recorded:
  `${input.previous.bundle}` (the bundle's version), `${input.previous.edition}`,
  and each module's version (`${input.previous.wine}`).
- **A stage built `FROM ${input.<name>}`** starts as a clone of that
  input's tree, and keeps its launch, so it reaches none of its own. Nothing
  built from one is kept as a layer: it's one person's app.
- **A module's update is its update stage**: the wine module's
  `stages/update` is `FROM ${input.previous}`, `USE wine` (this Wine, the
  prefix moved with `wineboot -u`) and `DO wine.prefix-settings`, the
  settings its `prefix` stage gives every prefix. A module stage reads the
  caller's `previous`; its file's `INPUT previous` is for the checker.
- **An update that reads the edition's source** (a disc, a download) is a
  fresh build, and Second Chance says the source is needed.

## Signals

A **signal** is what to watch for while a step runs: a named block of
`WATCH` lines, outside every stage and function, or in a module's files its
`module.yaml` names (`signals: ["signals"]`), named `<module>.<signal>`
(`self.<signal>`, or its name alone, in the module's own files).

```dockerfile
# Modules/installer/signals
SIGNAL alive --any
  WATCH --wine.busy
  WATCH --log="${program.log}" --matches="."
  WATCH --grows="C:/Program Files (x86)"
  WATCH --grows="C:/users"
END
```

| Watch | Fires when | Gives |
| --- | --- | --- |
| `--log=<path>` with `--contains="…"` or `--matches="…"` | a line written after the step began has the text, or matches the regex | a `--matches`'s named groups |
| `--output` with `--contains` or `--matches` | the program writes such a line | the same |
| `--file=<path>` | the file appears | `path` |
| `--grows=<path>` | the folder's size changes | `size` |
| `--process=<name>` | a process of that name starts | — |
| `--process-has-window[=<name>]` | a Wine program (or one of that name) puts a window on screen | — |
| `--exits[=<code>]` | the program ends (with that code) | `code` |
| `--<module>.<watch>` | a module's own watch fires: the wine module's `--wine.busy`, its programs in the tree using the CPU or a new one starting | what it declares |

- **More than one `WATCH` says how they combine**: `--any` fires each time
  one does, `--all` once each has since it last fired (with their fields
  together, so no two may give one).
- **A step names the signals it's watched for**, on any step: `--alive`,
  each firing a sign of progress (the installer's stall watch counts them);
  `--done`, the step finished when it fires; `--asks`, its program asking
  the person something. A module's instruction can have a default
  (`signals: { alive: alive }` in its `module.yaml`), as `INSTALLER.RUN`
  has `installer.alive`. Nothing acts on `--done` or `--asks` yet.
- **`${program.…}` is the program the step runs**, known only as it runs:
  `path`, `dir`, `name` and its own `log` (an installer's, which
  `INSTALLER.RUN` writes), each a path on this Mac. A watch reading one
  starts once the executor says which program it ran; a path of one is the
  Mac's, any other a place in the tree.
- **`EMIT --on=<signal> "<string>"`** emits the string each time the signal
  fires while a step runs, from its line to the end of the build, its
  `${signal.<field>}` and `${program.…}` filled in then, at most once a
  second (the last value winning):

  ```dockerfile
  SIGNAL copying
    WATCH --log="${program.log}" --matches="Copying file (?<done>\d+) of (?<total>\d+)"
  END

  EMIT --on=copying "second-chance.progress.${signal.done}/${signal.total}"
  INSTALLER.RUN --from=${input.disc-1} …
  EMIT --off=copying
  ```

  A listener's name is its `--name`, else its signal's; `EMIT --off=<name>`
  stops it. Two listening under one name, or an `--off` naming none, fails.
  What a listener emits is a moment, never kept with a layer: a step
  restored from one runs nothing, so nothing fires.

The watcher (`SignalWatcher`, in the runner) looks at each watch once a
second while the step runs; an executor tells it the program
(`context.watch(program:)`), its output (`programWrote`) and its end
(`programExited`), and hears a signal through `context.onSignal`.

## Values

Every value is read through a namespace in `${…}`, which says where it
comes from:

| Namespace | What it is | Declared by |
| --- | --- | --- |
| `input.<name>` | a value from outside: the edition's (its `build.inputs`), a `DO`'s option, or the `INPUT`'s default | `INPUT` |
| `const.<name>` | a fixed value | `CONST` |
| `var.<name>` | a value the Wrappfile works out | `VAR`, changed by `SET` |
| `platform.arch`, `platform.macos` | the Mac building | the core |
| `module.<name>.version`, `module.<name>.data.<table>…` | a module the stage uses, by its id or `AS` name: the version `USE` picked, and its data | the module |
| `self.…` | in a module's own files, that module, whatever a bundle calls it | the module |

- **Values are text or objects**: a data table's entry, or an input with its
  fields (`${input.game.app-id}`). An `IF` compares text.
- **A module can be named at the root**: `${nancy-drew.data.patches}`,
  `${wine.version}`. The core's namespaces always win: a module named like
  one is warned about, and read through `${module.<name>.…}`.
- **Brackets hold a key worked out from another value**:
  `${self.data.patches[input.id].url}`. A `${…}` never holds another, and
  there are no modifiers (`:-`).
- **A module's data has a schema** (each table's `.schema.json` beside it),
  which the checker reads to check a `${….data.…}` path, and whose
  `default`s fill in a field a table leaves out.
- **Every value is known when planning.** An app never works one out.
- **Scopes**: the file, a stage, a function and an `IF`'s branch, the
  innermost winning. Globals reach every stage, and the bundle's own
  functions, defined in the file. A `CONST` can't be set or
  declared again within its scope; a `VAR` in a branch shadows one outside
  it, and a `SET` changes the innermost `VAR` of its name. Reading a `VAR`
  before anything has set it is an error.
- **`INPUT`s are declared before the first `FROM`**, or as a function's
  parameters at its top. By convention, though nothing checks it, a file's
  `INPUT`s come before its `CONST`s and `VAR`s: what it's given, then what
  it works out. An input missing is an error only if the build
  reads it; an edition giving one its target never reads is an error.
- **A function reads what's declared where it's defined, not where it's
  called**: a bundle's function, the file's `INPUT`s and `CONST`s
  (`${const.install-dir}`); a module's, only what its own file declares.
  A stage's values reach a function only as its `INPUT`s, each given by the
  `DO`'s option or else its default, never by a caller's value that
  happens to share its name. An edition's value always beats an `INPUT`'s
  default.
- **`--secret`** keeps an input out of every step's text: it reaches a
  program only through `--env` or a `secret` mount, the step keeps
  `${input.<name>}`, and the builder fills it in, so it's never in a layer's
  key, a plan or a log.
- **A reference to something undeclared is an error everywhere**, in any
  branch, reached or not. An `INPUT`, `CONST` or `VAR` nothing reads is a
  warning.

`sc bundle plan` and `sc wrapp build` take inputs with `--input
<name>=<value>` (`--input launch-mode=steam`); the app takes them headless
as JSON in `SECOND_CHANCE_INPUTS`.

## The launch, volumes and app

How the app starts its program is decided by the build, as Docker keeps `CMD`
in the Dockerfile: it depends on where the build put the program and which
modules are left in the app.

```dockerfile
CONST program = "${const.install-dir}/Game.exe"

# What the app has whichever edition it's built from
FUNCTION pre-install-setup
  USE nancy-drew
  DO wine.cnc-ddraw
  DO nancy-drew.set-icon      # COPY assets/nancy-drew.icns /Resources/…, APP --icon it
  LAUNCH --mount=type=store,source=wine-documents,target=A: \
      --mount=type=store,source=wine-documents,target=C:/users/crossover/Documents
END

FROM --module=wine@10 prefix AS prefix
DO pre-install-setup
LAUNCH --wine.mouse=grab-early --wine.graphics=direct-draw ${const.program}
```

What a bundle repeats in several stages it writes once: a `CONST` for a
path (the program, which `--creates` and each `LAUNCH` name), a `FUNCTION`
of its own for steps (`pre-install-setup`, above, called by the `prefix` stage and by
Steam's and Big Fish's, which are built from module stages instead;
`post-install-setup`, the `.ini` settings every install ends with; `patch`, Her's
patches where two editions share them), and a
module's function for what every program of a series does (the Nancy Drew
games' icon). What a function records (its `APP`, its `LAUNCH`'s mounts) and the modules it `USE`s
are the calling stage's, as if written there, and it can use the caller's. A module used in a base stage
(`prefix`) needn't be used again in the stages built from it. A ScummVM
game's `scummvm` stage writes the icon's `COPY` and `APP --icon` itself
(`COPY module:nancy-drew:/assets/nancy-drew.icns …`): using
nancy-drew there would bring in Wine, which it depends on, and a ScummVM
app keeps no Wine.

- **`LAUNCH`'s program's path type is what starts it**: `C:/…/Game.exe` in a
  Wine stage is Wine's, `/SharedSupport/game/` ScummVM's (with the game's id
  after it: `nancy:nancy7`), `C:/TYRIAN/TYRIAN2K.EXE` in a DOSBox stage
  DOSBox's. Like `RUN`, it takes options only before the program.
- **A Wine launch says what the program draws with**, `--wine.graphics=direct-draw`,
  `direct-3d` or `unknown` (neither: GDI), which arms the app's helpers
  ([wine-in-process-helpers.md](wine-in-process-helpers.md)). A game whose
  non-zero exit is judged by a log says so with `--wine.clean-exit-log` and
  `--wine.clean-exit-line` (Her's later engine's `Debug.LOG`).
- **`--wine.mouse` says what cnc-ddraw does with the mouse**, for a game it
  draws. cnc-ddraw takes hold of the mouse on a click in the game's window,
  swallowing that click, and lets go whenever the app is left.
  `--wine.mouse=grab-early` has the wrapp's cursor-lock helper get it to take
  hold at the start, so the game's first click counts
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#cursor-lock)), as
  every Nancy Drew DirectDraw game's launches say. `--wine.mouse=free` has it
  never take hold: planning adds an `EDIT` setting cnc-ddraw's `devmode` in
  the launch exe's own section of `ddraw.ini`, for a game played with the
  keyboard, whose window would otherwise pin the drawn cursor at its edge
  while the Mac's pointer left it (Icy Tower). A target that sets cnc-ddraw
  up (`DO wine.cnc-ddraw`) and whose launch says neither still builds, its
  first click swallowed, and `sc bundle check` and `sc lint` warn about it
  (`BuildPlanner.warnings(of:)`); planning refuses any other value, and
  `--wine.mouse` on a launch without cnc-ddraw. A launch
  recorded before the option (format 1) keeps having it worked out from what
  the game draws with.
- **`--wine.window=fullscreen` or `windowed`** overrides native fullscreen,
  for a program the wrapp gets wrong: `windowed` leaves it unarmed, keeping
  the program in its window, and `fullscreen` makes it fullscreen whatever
  it asks for
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#when-the-launch-says)).
  Left out, the program's window goes fullscreen when the program asks for
  fullscreen (a Direct3D game's borderless window covering the screen, a
  DirectDraw game setting a display mode) and stays a window otherwise. Any
  other value is refused when planning. ScummVM and DOSBox games are always
  fullscreen.
- **`--wine.quit-key=<keys>`** makes the app's Quit press those keys in the
  program, written in the [key notation](#key-sequences), for one that
  ignores Wine's quit but quits on a key of its own: Iji's is
  `--wine.quit-key=f12:hold`, F12 held down. Keys that quit through the
  program's own menus are pressed in turn
  (`--wine.quit-key="escape escape return"`). Either way the program's close
  button does the same as Quit
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#a-game-that-ignores-the-apps-quit)).
- **`--wine.quit-confirm-key=<keys>`**, beside a quit key, splits Quit in
  two, for a program whose quit key asks first: the first Quit presses the
  quit keys, and a second within 10 s presses these, as Icy Tower's
  `--wine.quit-key=escape --wine.quit-confirm-key=escape:hold` (Escape asks,
  and Escape held confirms). Without `--wine.quit-key` it's refused when
  planning.
- **Quit keys are checked when planning**, and keys the notation refuses
  are refused, naming the bad part; they're recorded as written. A single
  key with nothing after it keeps the meaning it had before the notation
  had `:hold`: as `--wine.quit-key`, without confirm keys, it's held for
  5 s, and as `--wine.quit-confirm-key` it's held too, while a quit key
  before confirm keys is pressed once. `sc bundle check` warns of a held
  one with its explicit form (`f12:hold`), which a bundle writes.
- **`--wine.fullscreen-setting=<fields>`** names where the program keeps
  its own fullscreen setting, so the app can keep it in step with the
  window's green button: when the player last moved the window into or out
  of fullscreen themselves, rather than through the game's own option, the
  app writes their choice there once the game has quit, and the next start
  opens as they left it
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#the-players-choice-kept)).
  Its fields, comma-separated: `file=`, a file on Wine's C: drive (usually
  one a `files=` mount keeps); `format=allegro-packfile` (an Allegro 4
  game's `pack_fopen` file, `slh!` and LZSS) or `bytes` (the file as it
  is); `offset=` and `bytes=` (1, 2, 4 or 8), where the value is in what
  the format holds; and `fullscreen=` and `windowed=`, its two values, whole
  numbers stored little-endian (`-1`, `0`, `0xFF`). A file that checks
  itself with a sum takes `checksum-offset=` and `checksum-scale=` as well:
  a sum as wide as the value, which counts the value that many times and is
  moved to match. Icy Tower's:

  ```dockerfile
  LAUNCH --wine.fullscreen-setting="file=C:/IcyTower/tower.cfg,format=allegro-packfile,offset=16,bytes=4,fullscreen=-1,windowed=0,checksum-offset=96,checksum-scale=17" \
         C:/IcyTower/icytower13.exe
  ```

  A missing field, an unknown one, a value that doesn't fit or two values
  the same is refused when planning, saying which.
- **A Steam launch is `steam://rungameid/<app id>`**, with no arguments, and
  names the program Steam starts, `--steam.exe=<its path in Wine>`, which the
  app finds the game's process by; as Steam starts a Windows game in the
  app's Wine, it says what it draws with too. **A Big Fish launch** is the
  same, its program the game's `big-fish:C:/…/LaunchGame.bfg`, which Big
  Fish's DRM starts, and `--big-fish.exe` the program it starts.
- **`--fallback=<program>`** is what the person is offered when the launch
  fails or seems stuck, for that one launch: run without the launch's
  launcher, with its options. Steam words it "Start Without Steam". A bundle
  writes one only for a game that can start without its launcher (a DRM-free
  game on Steam).
- **The last `LAUNCH` a stage reaches wins**, counting what it inherits
  through `FROM`, after `IF`s are decided; a stage with none has its
  parent's. Every edition's target must reach one, which planning checks,
  and a build fails when what it runs, a file or a ScummVM game's folder,
  isn't in the app once it's built (`WrappBuildHelper.checkLaunchProgram`).
- **A launch's store mounts build up**, inherited through `FROM`: each
  `LAUNCH --mount=type=store,source=<store>,target=<path>` adds one, a
  `LAUNCH` with mounts alone leaves the program as it is, and
  `--mount=type=store,source=<store>,remove` takes the store's off. The
  target is a path type's: a Wine drive (`A:`) and
  `C:/users/crossover/Documents` for a Wine game's saves, which the wrapp
  points at the store's folder each time it starts, `scummvm:saves/` and
  `scummvm:settings/`, or a DOSBox drive with the dosbox module's
  `dosbox.overlay` field, laid over it. A store the app keeps of its own
  must be one of the manifest's `volumes:`, which say what it holds.
- **A `files=` mount keeps the files beside a program**, for a game that
  writes its settings or high scores loose into its own folder, where a
  store mounted over the folder would hide the program:

  ```dockerfile
  STORE saves
  LAUNCH --mount=type=store,source=saves,target=C:/LaserTank/,files="LaserTank.ini;*.hs;*.lpb" \
         C:/LaserTank/lasertank.exe
  ```

  `files=` lists the names that are the store's, `;`-separated shell
  patterns matched in the target folder alone (not its subfolders). The
  target is a folder ending in `/` that the build made, which it checks
  (`WrappBuildHelper.checkLaunchMounts`), and the store is a kept one of
  the app's own. Before the game starts, a matching file the build left
  there moves into the store when the store has none of that name (so the
  person's copy starts from the default), a link left into another store
  (a test's, since removed) is replaced, its file copied in if it's still
  there, as a link to nothing leaves the game unable to write the file, and
  each of the store's files is linked in; once the game has ended, each matching file that isn't a link
  (one the game made, or wrote afresh) moves into the store and is linked
  back (`FilesMount`, in `WrappFormat`). A game that crashes leaves its new
  files in the app until the next clean exit.
- **`APP --icon` names an `.icns` in the app's `/Resources/`**, which a
  `COPY` put there; the build sets it as the app's icon. An app with no icon
  has the template's own, a generic one. An `.icns`, not an Icon Composer
  `.icon`, as only Xcode compiles those: a module's `assets/<name>.icon` is
  compiled to `<name>.icns` beside it by `sc generate`.
- **`APP --name`** is the app's name, in place of the game's title, and
  **`APP --default-id`** its bundle id when whoever runs the build gives
  none. The caller's id always wins, and Second Chance always gives one
  (`WrappLock.wrappBundleID`), so for now `--default-id` is for another
  builder; with neither, the build fails rather than name an app by
  accident. For each of the three, the last `APP` a stage reaches wins,
  inherited through `FROM`.
- **None of them is a step**: the plan records them (`BuildPlan.launch`,
  `.app`), so they change no layer key, and the build writes the launch
  into the app's settings (`WrappSettings.recordedLaunch`, the `Launch` key),
  which the app reads ([wrapp-launch.md](wrapp-launch.md)). A launch records
  its format, 2 now (`RecordedLaunch.format`), so the app can tell one
  recorded before an option it reads.

### Key sequences

Wherever keys are pressed for a program — a launch's quit keys
(`--wine.quit-key`, `--wine.quit-confirm-key`), `sc puppet do <name> key`
([dev-cli.md](dev-cli.md)) and a scenario's `{ key: … }`
([testing.md](testing.md#scenarios)) — they're written the same way, and
read by one parser, `KeySequence` (WrappKit's `KeyNotation`):

- **Steps are separated by spaces** and done in turn: `up return`.
- **Keys pressed together are joined with `+`**, modifiers first: `cmd+s`,
  `ctrl+alt+delete`, `shift+tab`. The modifiers are `cmd`, `ctrl`, `alt`
  and `shift` (`command`, `control`, `option` and `opt` are read too).
- **A key's name** is one the in-process helpers know
  (`Packages/Modules/wine/InProcessHelpers/key_names.m`): `escape` (`esc`),
  `return` (`enter`), `space`, `tab`, `delete` (`backspace`),
  `forwarddelete`, `home`, `end`, `pageup`, `pagedown`, `up`, `down`,
  `left`, `right`, `f1`–`f12`, or the character a key types: a letter, a
  digit or punctuation (an upper-case letter or a shifted character holds
  shift). Names are read in any case.
- **`*N` presses a step N times** (`return*2`, at most 100), each press down
  and up, with the sequence's usual gap between presses.
- **`:hold` holds a step down** for 5 s, repeating as a held Mac key does
  (the first repeat after 0.25 s, then one each 0.05 s), so a program that
  takes repeats as presses sees what a player holding the key would;
  **`:hold=<duration>`** holds it that long, `500ms`, `2s` or `1.5s`, at
  most 30 s. A step is pressed several times or held, not both.

`f12:hold`, `escape:hold=5s`, `up return*2` and `cmd+q` are all sequences.
An unknown key or modifier, `*0`, a bad duration, a hold over 30 s, `*N`
with `:hold`, or nothing at all is refused, saying which part is wrong.
What the sequence's usual gap is depends on who presses: 2.5 s from one
release to the next press for quit keys, which a program changing screens
needs, and 0.3 s for `sc puppet`. The in-process helpers are handed the
sequence's canonical form, every step explicit
([wine-in-process-helpers.md](wine-in-process-helpers.md#the-canonical-key-sequence)).

## What modules add

A module can add to the core's instructions, in any stage that has it
(through `USE` or `FROM`), with nothing else written. What it adds, it
declares in its `module.yaml`; for now only a module with an executor
([modules.md](modules.md#executors)), or whose Swift today's builders know,
can add anything, since nothing else would carry it out.

| Kind | Written as | Example |
| --- | --- | --- |
| **Path types** | a path in full form, `<type>:<path>`, or a short form the type claims | `wine:C:/Game.exe`, or just `C:/Game.exe` |
| **Options** on a core instruction | `--<module>.<option>=…` | `RUN --wine.desktop=… …` |
| **Fields** on a core mount type | `<module>.<field>=…` in `--mount=` | `--mount=type=store,source=dosbox-saves,target=C:/,dosbox.overlay` |

The dosbox module's `overlay` on a store mount is the one field a shipped
module declares; what each module adds is in
its `module.yaml`'s `build:` ([modules.md](modules.md#what-a-module-declares)).
Options and fields keep their module's name (the stage's name for it, in
lower case), as a bare `--desktop` wouldn't say whose it is. Planning
rewrites a stage's alias to the module's id, so `sc bundle plan`, layer keys
and the app never see an alias. Mount types themselves are the core's.

### Path types

A path's type says which engine handles it, and so whether a module of the
stage can: a place to copy to (a **location**) or something to run (a
**program**). Each module registers its own, in `PathTypeRegistry`
(`Packages/WrappKit/Sources/WrappModules/PathTypes.swift`), which the
builder and the app both read:

| Path type | Module | Roles | Example | Short form |
| --- | --- | --- | --- | --- |
| `wine:` | wine | location, program | `wine:C:/Nancy Drew/Game.exe` | a drive-letter path, `C:/…` |
| `dosbox:` | dosbox | location, program | `dosbox:C:/TYRIAN/TYRIAN2K.EXE` | a drive-letter path, `C:/…` |
| `scummvm:` | scummvm | program, location | `scummvm:/SharedSupport/game/`, `scummvm:saves/` | a folder (`/…/`), as a program |
| `big-fish:` | big-fish | program | `big-fish:C:/…/LaunchGame.bfg` | none |
| `steam:` | steam | program | `steam://rungameid/572740` | none |

- **A type is named after the engine that handles it**, never with one
  letter, so `C:` is always a drive.
- **Every short form is written in full when a build is planned**, so `sc
  bundle plan`, layer keys and the app always say which type took a path.
- **Short forms clash only within a stage.** Wine and DOSBox both claim
  `C:/…`; a stage with both writes `wine:C:/…` or `dosbox:C:/…`.
- **A path starting `/` with no type is in the app**: `/` is its
  `Contents/`, and `/../` its top level, never higher. As a program, `/…/` is
  ScummVM's short form, since a program always runs in an engine.
- **What follows a type's prefix is its module's to interpret**:
  `steam://rungameid/…` is a URL.

## Checking

`sc bundle check`, `wrapp-builder check <bundle folder>` and the unit tests
check every Wrappfile against its manifest and the modules' declarations
(`WrappfileChecker`), naming each problem's line:

- every instruction is the core's or one of a module the stage has, with
  options it takes (a module's `--<module>.<option>` and mount fields
  included) and the right number of arguments;
- every path is in a type a module of the stage registers, in a role the
  type has, and no short form is claimed by two of the stage's modules. A
  `COPY --from=<stage>` source is checked against the stage it's copied
  from. A path a function writes, or one a `${…}` starts, is checked when the
  build is planned, in the stage that has it;
- stage and function names follow Docker's rule;
- every `${…}` names something there is ([Values](#values)), in any branch,
  and a `${….data.…}` path is one its table's schema allows; every file the
  bundle names is in it, in a folder its manifest's `allow-paths` names
  ([below](#what-a-build-may-read)), and every module file is written
  `module:<id>:/<path>`; an input is written `${input.<name>}` wherever one
  is taken; `INPUT`s are only global or at a function's top;
- every stage, function, module (at a version its constraint allows) and
  input named exists, and every function is given its parameters;
- every edition's `build` names a stage, and the manifest's `setup` a
  function; a launch's store of the app's own is one of the manifest's volumes, every store a mount or a `store` option names is declared, a build step mounts no kept store, and an `APP
  --icon` an `.icns` in the app's `/Resources/`;
- no syntax that has gone is used: `ICON`, `VOLUME`, `EDIT --must-exist`, `FROM
  <module>/<stage>` and `module:<id>/<path>` are each refused with what's
  written now, which `wrapp-builder fmt --migrate` rewrites them as
  ([Style](#style));
- every edition's target plans, for either kind of Mac and every value of
  every choice, and reaches a `LAUNCH`, so a problem only a plan shows fails
  the check, not a build.

`sc bundle check` shows warnings as well (a name in upper case, a module named
like a core instruction); they don't stop a bundle loading.

## Highlighting in VS Code

`Tools/vscode-wrappfile/` is a VS Code extension that is only a TextMate
grammar (`syntaxes/wrappfile.tmLanguage.json`) and a language configuration:
no code, no build and never published. `sc setup` links it into
`~/.vscode/extensions/`, so it follows the clone and an edit to it shows on
the next **Developer: Reload Window**. It highlights `Wrappfile`s and the
modules' functions (`Modules/*/functions/*`), and folds `FUNCTION`, `IF` and
`LAYER-HINT` blocks.

It names the core's instructions itself, so an instruction added to
`InstructionSpec.core` is added to its `instruction` rule too
(`WrappfileGrammarTests` fails until it is). A module's instructions are
highlighted by their shape (`WINE.INSTRUCTION`, in any case), as are its
options (`--wine.drive=`), mount fields and path types' prefixes, so a new
one needs nothing but a new path type's name.
A change to the syntax above means a change to the grammar.

## Plans

Before a build runs anything, its edition's target is worked out into a plan
(`BuildPlanner`): the stages it needs, dependencies first; each step with its
functions expanded, `${…}` substituted and `IF`s decided for this build (the
Mac, and the edition's inputs). Every path comes out in full form, every module option keyed
by the module's id, each instruction in upper case, and a whole input as its
token (`input:disc-1`), so a builder tells an input from text. A key into a
module's data is an object's property or, in a list (or a table that is one
list under one key, as `patches.json` is), the item with that `id`. The
files the steps read are recorded with the plan, for install layers to hash.
`sc bundle plan <bundle id> <edition>` prints one, each step with where it
was written:

```text
FROM prefix AS disc   [installer, nancy-drew, wine]
  INSTALLER.RUN --answer-file=bundle:assets/disc.iss --from=input:disc-1 --into=wine:C:/…    # Wrappfile:15
  NANCY-DREW.CONFIGURE-INI wine:C:/…    # nancy-drew/functions/configure-ini:8 from Wrappfile:17
```

`wrapp-builder plan <bundle folder>` prints the same, with `--target` for a
stage other than the edition's, `--edition` for whose inputs it's given,
`--input <name>=<value>`, and `--allow-path` ([below](#what-a-build-may-read)).

`WrappfileTodayTests` checks each Nancy Drew game's Wrappfile against what
its builder does today. Its disc stage keeps the discs (`WINE.KEEP-DISCS`,
with `--combined` exactly when there's more than one) and runs one
`INSTALLER.RUN`, with an answer file exactly when the bundle has
`assets/disc.iss`, into the `install-dir` the game's exe is in; a ScummVM
game's installs nothing, is built from its `scummvm` stage, and keeps the
discs only when it has a `disc-files` stage. Its Her download stage runs
`HER-DOWNLOAD.INSTALL`, with an answer file exactly when the bundle has
`assets/her-download.iss`, and its Her Mac stage patches nothing. Each
edition's patches (`DO nancy-drew.patch`) are the ones its builder applies,
in order (`TestFixtures/edition-patches.json`), and a Steam edition's
`launch-mode` is a choice exactly where today's Steam build asks it.

## What a build may read

A Wrappfile names files on the Mac building it: an answer file, an AutoIt
script, an icon. A build reads only those in folders it has been allowed,
never one for being beside the Wrappfile, so a bundle can't read the rest of
the Mac, or a file of its own it didn't mean to ship:

- **A bundle's are the folders its manifest's `allow-paths` names**, each
  relative to the bundle's folder and ending in `/`: `allow-paths:
  ["assets/"]`, for a Nancy Drew bundle's answer files. Second
  Chance gives the builder these.
- **A module's are its `module.yaml`'s `allow-paths`**, for what its stages
  and functions read, and what a Wrappfile names as `module:<id>:/<path>`:
  the nancy-drew module's `assets/`, its AutoIt scripts and icon. A file the
  module's Swift provides (`provided-files`, the installer module's `autoit`)
  needs none.
- **A path that leaves the folder is never allowed**: one starting `/`, or
  with `..` in it. The schemas refuse `allow-paths` that do either.
- **Planning checks each file** (`HostPaths`, in `BuildPlanner`), and so does
  the checker for a bundle's own. A file that isn't allowed fails the plan,
  saying how it could be: allow its folder, give it as an input, pin it with
  `--checksum=sha256:<hash>`, or allow it for the one build.
- **`wrapp-builder plan --allow-path=<folder>`** allows a folder of the
  bundle's beside the manifest's, for one plan, and `--allow-path=*` any
  path, with a warning that host paths aren't being checked: for someone
  trying a Wrappfile out.

## Style

`wrapp-builder fmt` writes Wrappfiles, and the modules' stages and
functions, in one style, in place, and `sc lint` fails on one that isn't
(`wrapp-builder fmt --check`, over `Bundles/` and `Modules/`):

- instructions in upper case, their keyword alone (`ELSE IF` as two words);
- two spaces of indent for each block (`FUNCTION`, `IF`, `ELSE`, `LAYER-HINT`), a
  stage's own steps not indented;
- a line continued with `\` indented four spaces past its instruction;
- one blank line between stages, before the comments that lead into a
  `FROM`, and never two blank lines in a row;
- comments kept where they are, with their text unchanged, and a comment
  after an instruction kept the distance from it it had.

It reads a file into a syntax tree that loses nothing, comments, blank lines
and continued lines included, as Swift's keeps trivia
(`WrappfileSyntaxTree`, in `WrappfileFormatter.swift`), and writes it back
from that; planning reads the parser's tree instead and ignores all of it.
`wrapp-builder fmt --migrate` first rewrites syntax that has changed, a word
at a time and never in a comment (`WrappfileMigration`): `module:<id>/<path>`
as `module:<id>:/<path>`, `FROM <module>@<v>/<stage>` as `FROM
--module=<module>@<v> <stage>`, `ICON <icon>` as `APP --icon=<icon>`, and
`--must-exist` as `--keys-must-exist`. `sc lint`'s check migrates too, so
old syntax fails it.
