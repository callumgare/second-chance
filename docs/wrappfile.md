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
  follow the same convention, its name included (`WINE.MOUNT`, not
  `wine.MOUNT`), and the module part matches whatever case it's written in.
  Everywhere else a module is named it's in lower case, as a name: `USE
  nancy-drew AS nd`, `FROM steam/client`, `DO nd.patch`, `--wine.drive`.
  Two module names that differ only in case are the same name.
- **A module's name can match a core instruction, and the core always
  wins.** `USE foo AS copy` is allowed, with a warning, and `COPY` is still
  the core's; that module's instructions are written in full,
  `MODULE.COPY.<INSTRUCTION>`, which works for any module
  (`MODULE.WINE.MOUNT`).
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
  full, `module:installer/autoit`. Planning writes each in full
  (`bundle:assets/disc.iss`), and checks it's there.
- **Blocks**: `IF <condition>` … `ELSE IF <condition>` … `ELSE` … `END`,
  `LAYER` … `END` and `FUNCTION <name>` … `END`. A condition compares two
  expressions, each a `${…}` or a quoted string, with `=` or `!=`, spaced or
  not: `IF ${platform.arch} = "arm64"`.

## Instructions

| Instruction | Does |
| --- | --- |
| `FROM scratch` / `FROM <stage>` / `FROM <module>[@<constraint>]/<stage>` `[AS <name>]` | Starts a stage from the bare template, another stage (`base` and `previous` are supplied), or a module's (`FROM steam/client`). A stage built from another keeps its modules. |
| `INPUT <name> [--default=<value>] [--secret]` | Declares a value from outside, before the first `FROM` or at a function's top ([Values](#values)). |
| `CONST <name> = <value>`, `VAR <name> [= <value>]`, `SET <name> = <value>` | A fixed value; a value worked out in the Wrappfile; and a new value for a `VAR`. |
| `USE <module>[@<constraint>] [AS <name>]` | Adds a module, and what it depends on: its instructions are then `<NAME>.INSTRUCTION`, its functions `DO <name>.<function>`, and its path types, options and mount fields are the stage's ([below](#what-modules-add)). |
| `RUN [--mount=…] [--creates=…] [--env NAME=<value>]… <program> <args>` | Runs a program inside an engine: its path type says which. Mounts: `source`, `cache`, `secret`, `bind`, `fetch`. `--env` is the only way a value reaches a program's environment. |
| `COPY [--from=<stage or ${input.<name>}>] <src> <dest>` | Copies files. |
| `ADD --checksum=sha256:<hash> [--unpack=zip --member=<file> [--extract]] <url> <dest>` | A download, found in the download cache first. |
| `EXPORT`, `MOVE`, `REMOVE`, `EDIT <file> --ini=…` / `--from-data=<table>` | File changes Second Chance makes itself. |
| `FUNCTION <name>` … `END`, `DO <name>` / `DO <alias>.<name>` | Named steps, with `INPUT`s as parameters (`--id=…`): a bundle's own, or a module's (in its `functions/`). |

Every step takes `--name=<id>`, naming it for reports, and
`--on-failure=ask`, which asks whether to carry on without a step that
failed; without it, a failed step fails the build.

Modules' instructions, as the build modules declare them
(`Packages/WrappBuilder/Sources/WrappBuilder/Modules/BuildModule.swift`):

| Instruction | Does |
| --- | --- |
| `WINE.WINETRICKS <verb>` | Installs a winetricks verb. |
| `WINE.REGISTRY --set <key>:<name> <value>` / `--remove <key>:<name>` | Sets or removes a registry value. |
| `WINE.MOUNT <folder> <drive> [--cdrom]` | Gives a folder in the prefix a drive, kept at launch. |
| `WINE.KEEP-DISCS <disc input>… --into=<folder> [--combined=<folder>]` | Copies the discs it's given into `<folder>/disk-<n>` (and merged into `--combined` for more than one), each given a drive from D:: for a game that checks for its disc. |
| `INSTALLER.RUN [--from=<input>] --into=<folder> [--creates=<program>] [--answer-file=…] [--automation=<script>] [--patch] [program]` | Runs a Windows installer: silently with an answer file. `--creates` is the program it should leave, linked to what it made if that's elsewhere; `--patch` runs a patcher in `--into`, looking for nothing afterwards. With `--automation`, AutoIt runs the script, given the installer's command (the same as without it) to start, for an installer that installs and never exits; the script clicks where it stops. Without a program, the installer on the input, found as today. |
| `STEAM.INSTALL <input> --into=<folder>` | Installs the input's Steam app. |
| `HER-DOWNLOAD.INSTALL <input> [--into=<folder>] [--creates=<program>] [--answer-file=…] [--automation=<script>]` | Installs Her Interactive's download: a Windows installer as `INSTALLER.RUN` runs one, or a Mac download's game taken out. |

An input is always written `${input.<name>}` where an instruction takes one.

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
  innermost winning. Globals reach every stage. A `CONST` can't be set or
  declared again within its scope; a `VAR` in a branch shadows one outside
  it, and a `SET` changes the innermost `VAR` of its name. Reading a `VAR`
  before anything has set it is an error.
- **`INPUT`s are declared before the first `FROM`**, or as a function's
  parameters at its top. An input missing is an error only if the build
  reads it; an edition giving one its target never reads is an error.
- **A function reads its caller's values only through its own `INPUT`s**:
  each is given by the `DO`'s option, or else the caller's input or
  constant of the same name, or else its default. An edition's value always
  beats an `INPUT`'s default.
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

## What modules add

A module with Swift can add to the core's instructions, in any stage that has
it (through `USE` or `FROM`), with nothing else written. A module someone adds
with functions alone adds nothing, since nothing would carry it out.

| Kind | Written as | Example |
| --- | --- | --- |
| **Path types** | a path in full form, `<type>:<path>`, or a short form the type claims | `wine:C:/Game.exe`, or just `C:/Game.exe` |
| **Options** on a core instruction | `--<module>.<option>=…` | `RUN --wine.desktop=… …` |
| **Fields** on a core mount type | `<module>.<field>=…` in `--mount=` | `--mount=type=source,from=disc-1,wine.drive=D:` |

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

`sc bundle check` and the unit tests check every Wrappfile against its manifest
and the modules (`WrappfileChecker`), naming each problem's line:

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
  bundle names is in it; an input is written `${input.<name>}` wherever one
  is taken; `INPUT`s are only global or at a function's top;
- every stage, function, module (at a version its constraint allows) and
  input named exists, and every function is given its parameters;
- every edition's and variant's `build` names a stage, and the manifest's
  `setup` a function;
- every edition's target plans, for either kind of Mac and every value of
  every choice, so a problem only a plan shows fails the check, not a build.

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
  EDIT --from-data=ini wine:C:/…/*.ini    # nancy-drew/functions/configure-ini:9 from Wrappfile:17
```

`WrappfileTodayTests` checks each game's Wrappfile against what its builder
does today: the discs it keeps, the installer's options and answer file, and
the patches `GamePatchCatalog` applies, for the disc and Her download editions.
Steam editions name no stage: the steam module's default stages build them.
Nor do Big Fish's: `BigFishWrappBuilder` builds them, as it did before
Wrappfiles.
