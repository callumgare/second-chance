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
  `LAYER` … `END` and `FUNCTION <name>` … `END`. A condition compares two
  expressions, each a `${…}` or a quoted string, with `=` or `!=`, spaced or
  not: `IF ${platform.arch} = "arm64"`.

## Instructions

| Instruction | Does |
| --- | --- |
| `FROM scratch` / `FROM <stage>` / `FROM --module=<module>[@<constraint>] <stage>` `[AS <name>]` | Starts a stage from the bare template, another stage (`previous`, the old wrapp an update is built from, is supplied), or a module's (`FROM --module=steam@1 client`), named with a flag as Docker's `FROM --platform=` is. The older `FROM steam@1/client` is refused. A stage built from another keeps its modules. |
| `INPUT <name> [--default=<value>] [--secret]` | Declares a value from outside, before the first `FROM` or at a function's top ([Values](#values)). |
| `CONST <name> = <value>`, `VAR <name> [= <value>]`, `SET <name> = <value>` | A fixed value; a value worked out in the Wrappfile; and a new value for a `VAR`. |
| `USE <module>[@<constraint>] [AS <name>]` | Adds a module, and what it depends on: its instructions are then `<NAME>.INSTRUCTION`, its functions `DO <name>.<function>`, and its path types, options and mount fields are the stage's ([below](#what-modules-add)). |
| `RUN [--mount=…]… [--env NAME=<value>]… <program> <args>` | Runs a program inside an engine: its path type says which. Mounts: `cache`, `secret`, `bind`, `fetch`. `--env` is the only way a value reaches a program's environment. |
| `COPY [--from=<stage or ${input.<name>}>] <src> <dest>` | Copies files: from another stage or an input, or without `--from`, a bundle's or module's file. |
| `ADD --checksum=sha256:<hash> [--unpack=zip --member=<file> [--extract]] <url> <dest>` | A download, found in the download cache first. |
| `MOVE`, `REMOVE`, `EDIT <file> --ini=<section>.<key>=<value>… [--keys-must-exist] [--create]` | File changes the builder makes itself. `EDIT` changes each setting in its section, or adds it; with `--keys-must-exist`, each setting must already be in the file, or the step fails naming those that aren't. The file must exist unless the step says `--create`. The older `--must-exist` is refused, with a message saying so; `--from-data` is gone, replaced by `NANCY-DREW.CONFIGURE-INI`. |
| `EMIT "<string>"` | A string for whoever runs the build, passed on unread as the build reaches it: not a step ([below](#emit)). |
| `LAUNCH [--fallback=<program>] [--env NAME=<value>]… <program> [<argument>…]` | How the app starts its program ([below](#the-launch-volumes-and-app)). |
| `VOLUME [--<module>.<option>]… <volume> <location>`, `VOLUME --remove <volume>` | Where the program sees one of the manifest's volumes. |
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
| `STEAM.CLIENT` | Installs Steam's client in the prefix (the steam module's `client` stage). |
| `STEAM.INSTALL <input> --into=<folder> [--mount=…]` | Has Steam install the input's app, signed in with the shared sign-in (`--mount=type=secret,id=steam-sign-in`) and with the kept client (`--mount=type=cache,id=steam-client`), and makes `--into` a link to the folder Steam put it in. |
| `STEAM.SIGN-OUT` | Takes the sign-in out of the prefix, saved for the next build first, so the app carries none. |
| `BIG-FISH.MANAGER --mount=type=fetch,url=…,sha256=…,target=…` | Installs Big Fish's Game Manager from its installer, pinned by its hash (the big-fish module's `manager` stage). |
| `BIG-FISH.INSTALL <input> --into=<folder> [--decline-directx]` | Has the Game Manager download, install and activate the input's game, declining DirectX's setup, and makes `--into` a link to the folder it installed it in. |
| `BIG-FISH.SIGN-OUT` | Signs the Game Manager out, or keeps a person's sign-in for the next build, then takes the account out of the prefix. |
| `STEAM.REMOVE` | Takes Steam away: the game moved to where `STEAM.INSTALL --into` linked it, then Steam's folders and the client stage's registry settings removed. |
| `HER-DOWNLOAD.INSTALL <input> [--into=<folder>] [--creates=<program>] [--answer-file=…] [--automation=<script>]` | Installs Her Interactive's download: a Windows installer as `INSTALLER.RUN` runs one, or a Mac download's game taken out. |
| `WINE.MOUNT <folder> <drive> [--cdrom]` | Gives a folder in the prefix a drive letter, kept for later steps and at launch; `--cdrom` makes it a CD drive. |
| `WINE.HELPERS`, `WINE.PREFIX` | The wine module's `setup` steps: the in-process helpers laid in, and wineboot's prefix. Declared, and carried out by its executor, but nothing plans them yet ([modules.md](modules.md#what-a-module-declares)). |
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

No shipped bundle uses `EMIT` yet: the wine module's prefix stage still
names its text with `--progress=<key>` until it does.

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
  VOLUME --wine.drive=A: wine-documents C:/users/crossover/Documents
END

FROM --module=wine@10 prefix AS prefix
DO pre-install-setup
LAUNCH --wine.cursor-lock --wine.graphics=direct-draw ${const.program}
```

What a bundle repeats in several stages it writes once: a `CONST` for a
path (the program, which `--creates` and each `LAUNCH` name), a `FUNCTION`
of its own for steps (`pre-install-setup`, above, called by the `prefix` stage and by
Steam's and Big Fish's, which are built from module stages instead;
`post-install-setup`, the `.ini` settings every install ends with; `patch`, Her's
patches where two editions share them), and a
module's function for what every program of a series does (the Nancy Drew
games' icon). What a function records (its `APP`, `VOLUME`s) and the modules it `USE`s
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
- **`--wine.cursor-lock` asks for the cursor lock**, which keeps cnc-ddraw
  from swallowing the game's first click
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#cursor-lock)):
  the wrapp arms it only when the launch says so. Planning refuses a target
  that sets cnc-ddraw up (`DO wine.cnc-ddraw`) and whose launch doesn't ask
  for it, and every Nancy Drew DirectDraw game's launches do. A launch
  recorded before the option (format 1) keeps having it worked out from what
  the game draws with.
- **`--wine.window=fullscreen` or `windowed`** overrides native fullscreen,
  for a program the wrapp gets wrong: `windowed` leaves it unarmed, keeping
  the program in its window, and `fullscreen` is to make it fullscreen
  whatever it asks for, though the helper doesn't act on that yet
  ([wine-in-process-helpers.md](wine-in-process-helpers.md#native-fullscreen)).
  Left out, native fullscreen works as it always has. Any other value is
  refused when planning. ScummVM and DOSBox games are always fullscreen.
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
- **`VOLUME`s build up**, inherited through `FROM`; `--remove` takes one
  off. The location is a path type's: `wine:C:/users/crossover/Documents`
  with `--wine.drive=A:`, `scummvm:saves/` and `scummvm:settings/`, or
  `--dosbox.overlay` laid over a DOSBox drive.
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
| **Fields** on a core mount type | `<module>.<field>=…` in `--mount=` | `--mount=type=cache,id=…,wine.size=1`, were the wine module to declare a `size` field |

No shipped module declares mount fields yet; what each module adds is in
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
  function; a `VOLUME` names one of the manifest's volumes, and an `APP
  --icon` an `.icns` in the app's `/Resources/`;
- no syntax that has gone is used: `ICON`, `EDIT --must-exist`, `FROM
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
`LAYER` blocks.

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
- two spaces of indent for each block (`FUNCTION`, `IF`, `ELSE`, `LAYER`), a
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
