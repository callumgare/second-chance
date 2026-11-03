# Wrappfiles

A program bundle's `Wrappfile` says how its game's app is built: Dockerfile-like
steps, in stages, one stage per edition (or shared by several). Each edition in
the bundle's manifest names the stage it builds (`build: { target: "disc" }`).
For now Wrappfiles are parsed and checked, and each game's says what its builder
does today; the builders don't run them yet.

```dockerfile
# A global build argument, written once
ARG install-dir="C:/Program Files (x86)/Nancy Drew/Last Train to Blue Moon Canyon"

FROM scratch AS prefix
USE wine@10                         # a module, with a version constraint

# The CD edition (its manifest says build: { target: "disc" })
FROM prefix AS disc
ARG install-dir                     # a stage brings in a global ARG to use it
USE installer
USE nancy-drew AS nd                # a module, known in this stage as nd
wine.KEEP-DISCS --into=C:/nancy-drew-installer --combined=C:/nancy-drew-installer/disk-combined
installer.RUN --from=disc-1 --into=${install-dir} --answer-file=${assets/disc.iss}
DO nd.patch --id=blue-moon-taffy-sort --into=${install-dir}
```

## Syntax

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
  (`steam.INSTALL game --into=…`).
- **`${…}` substitutes**: an `ARG` the stage has brought in (`${install-dir}`,
  with a default `${name:-default}`), an input's field (`${inputs.game.app-id}`),
  a bundle file (`${assets/disc.iss}`), or in a module's function, its data
  (`${data.patches.${id}.url}`, nested). `$$` is a `$`.
- **Blocks**: `IF <condition>` … `ELSE IF <condition>` … `ELSE` … `END`,
  `LAYER` … `END` and `FUNCTION <name>` … `END`. Conditions are `name=value`,
  `!=`, `>=`, `<=`, `>`, `<`, `name has value`, or a bare name.

## Instructions

| Instruction | Does |
| --- | --- |
| `FROM scratch` / `FROM <stage>` / `FROM <module>[@<constraint>]/<stage>` `[AS <name>]` | Starts a stage from the bare template, another stage (`base` and `previous` are supplied), or a module's (`FROM steam/client`). A stage built from another keeps its modules. |
| `ARG <name>[=<value>]` | Before the first `FROM`, a global build argument with its value; in a stage, brings a global one or a choice in. |
| `USE <module>[@<constraint>] [AS <name>]` | Adds a module, and what it depends on: its instructions are then `<name>.INSTRUCTION`, its functions `DO <name>.<function>`. |
| `RUN [--mount=…] [--creates=…] <program> <args>` | Runs a program inside an engine. Mounts: `source`, `cache`, `secret`, `bind`, `fetch`, `volume`. |
| `COPY [--from=<stage or input>] <src> <dest>` | Copies files. |
| `ADD --checksum=sha256:<hash> [--unpack=zip --member=<file> [--extract]] <url> <dest>` | A download, found in the download cache first. |
| `EXPORT`, `MOVE`, `REMOVE`, `EDIT <file> --ini=…` / `--from-data=<table>` | File changes Second Chance makes itself. |
| `FUNCTION <name>` … `END`, `DO <name>` / `DO <alias>.<name>` | Named steps, with `ARG`s as parameters (`--id=…`): a bundle's own, or a module's (in its `functions/`). |

Every step takes `--name=<id>`, naming it for conditions and reports.

Modules' instructions, as the build modules declare them
(`Packages/WrappBuilder/Sources/WrappBuilder/Modules/BuildModule.swift`):

| Instruction | Does |
| --- | --- |
| `wine.WINETRICKS <verb>` | Installs a winetricks verb. |
| `wine.REGISTRY --set <key>:<name> <value>` / `--remove <key>:<name>` | Sets or removes a registry value. |
| `wine.MOUNT <folder> <drive> [--cdrom]` | Gives a folder in the prefix a drive, kept at launch. |
| `wine.KEEP-DISCS --into=<folder> [--combined=<folder>]` | Copies every disc the edition declares into `<folder>/disk-<n>` (and merged into `--combined` for more than one), each given a drive from D:: for a game that checks for its disc. |
| `installer.RUN [--from=<input>] --into=<folder> [--answer-file=…] [--stubborn] [program]` | Runs a Windows installer: silently with an answer file, watched and closed when it won't exit (`--stubborn`). Without a program, the installer on the input, found as today. |
| `steam.INSTALL <input> --into=<folder>` | Installs the input's Steam app. |
| `her-download.INSTALL <input> [--into=<folder>] [--answer-file=…]` | Installs Her Interactive's download. |

## Checking

`sc bundle check` and the unit tests check every Wrappfile against its manifest
and the modules (`WrappfileChecker`), naming each problem's line:

- every instruction is the core's or one of a module the stage has, with
  options it takes and the right number of arguments;
- every `${…}` names something there is: an `ARG` the stage brought in, an
  input an edition has, an asset in the bundle;
- every stage, function, module (at a version its constraint allows) and
  input named exists, and every function is given its parameters;
- every edition's and variant's `build` names a stage, and the manifest's
  `setup` a function.

## Plans

Before a build runs anything, its edition's target is worked out into a plan
(`BuildPlanner`): the stages it needs, dependencies first; each step with its
functions expanded, `${…}` substituted and `IF`s decided for this build (the
Mac's `arch` and `macos`, the edition's choices, the updates it applies); and
each module's `assemble` steps after the target's own. A module function's
`${data.<table>.<key>.<field>}` reads the module's table, where a key is an
object's property or, in a list (or a table that is one list under one key,
as `patches.json` is), the item with that `id`. `${assets/…}` becomes
`asset:<path>`, for the step to mount. `sc bundle plan <game> <edition>` prints
one, each step with where it was written:

```text
FROM prefix AS disc   [installer, nancy-drew, wine]
  installer.RUN --answer-file=asset:…/blue-moon/assets/disc.iss --from=disc-1 --into=C:/…    # Wrappfile:15
  EDIT --from-data=ini C:/…/*.ini    # nancy-drew/functions/configure-ini:9 from nancy-drew/module.yaml (assemble):2
```

`WrappfileTodayTests` checks each game's Wrappfile against what its builder
does today: the discs it keeps, the installer's options and answer file, and
the patches `GamePatchCatalog` applies, for the disc and Her download editions.
Steam editions name no stage: the steam module's default stages build them.
Nor do Big Fish's: `BigFishWrappBuilder` builds them, as it did before
Wrappfiles.
