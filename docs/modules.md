# Modules

A module is what a program needs beyond its own files: an engine to run it
(Wine, ScummVM), a service beside it (Steam), or knowledge shared by a series
(Nancy Drew's installers and patches). Each is a folder in `Modules/`, of data,
and may name Swift compiled into Second Chance (`native:`). The Swift is
described in [wrapp-launch.md](wrapp-launch.md#modules) (what each module does
in the wrapp), [testing.md](testing.md) (in WrappPuppeteer) and
`Packages/WrappBuilder/Sources/WrappBuilder/Modules/` (in a build); this doc
covers the data.

```text
Modules/
  module.schema.json        the schema every module.yaml is checked against
  releases.json             each module's releases, as recorded (generated)
  wine/
    module.yaml
    stages/prefix           the Wrappfile a new prefix is set up by (FROM --module=wine@10 prefix)
    functions/cnc-ddraw     cnc-ddraw, for a DirectDraw game (DO wine.cnc-ddraw)
    routine-errors.yaml     Wine's err: lines that say nothing is wrong
  scummvm/  dosbox/  steam/  big-fish/  nancy-drew/  installer/  disc/  her-download/
```

`installer`, `disc`, `her-download` and `big-fish` are, so far, a `module.yaml`
naming their Swift and declaring the instructions a Wrappfile gives them
([wrappfile.md](wrappfile.md)), which today's builders carry out.

What a module adds to a build (its instructions, and the options and mount
fields it adds to the core's) is data, its `module.yaml`'s `build:`
([below](#what-a-module-declares)). Its path types (`wine:`, `scummvm:`) are
still Swift, in `PathTypeRegistry` in WrappKit, since the app reads them too
([wrappfile.md](wrappfile.md#what-modules-add)). A module's Swift
(`BuildModule`) now only prepares its engine, for a module with one. An
addition needs something to carry it out, so for now only a module whose
Swift today's builders know can declare any. `sc module check` and the unit
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
native: "wine"                 # the Swift compiled into Second Chance it is
versions:                      # what this release provides, as a bundle names it with @
  - version: "10.0_8"
    package: { … }             # an engine's: what it is made from (below)
data: ["routine-errors.yaml"]
retired: ["prefix.yaml"]       # data only Second Chance's Swift read, dropped (below)
stages: ["stages/prefix"]      # Wrappfiles a bundle builds FROM (FROM --module=wine@10 prefix)
functions: ["functions/cnc-ddraw"]
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
    VOLUME: { drive: value }
```

- **An instruction's `options`** are each a kind: `value` (`--into=…`),
  `flag` (`--patch`) or `repeated` (`--mount=…`, as many as needed). Written
  as `{ kind, role }`, the role says what the value is, where it isn't text:
  a `location` (a place in the app or the engine), a `program`, an `input`,
  a `copy-source`, a `file` the build reads, or `text`. The checker and
  planner read the roles to know which words are paths.
- **`required`** names the options it can't do without; each must be one it
  declares.
- **`arguments`** says how many it takes (`count`: `1`, `1...2`, or `1...` for
  any number from 1; none when left out), and what each is (`roles`, in
  order, the last going for every argument after it).
- **`layer: suggested`**, **`may-ask`** and **`reads-data`** (the module's
  data tables its Swift reads, which would go into its steps' keys) are
  read and kept with the instruction, for the builder to come. Nothing acts
  on them yet.
- **`core-options`** are the options it adds to core instructions, by
  instruction, in a stage that has the module: the wine module's `LAUNCH
  --wine.graphics`, the dosbox module's `VOLUME --dosbox.overlay`, the steam
  and big-fish modules' `LAUNCH --steam.exe` and `--big-fish.exe`. Each is a
  kind or `{ kind, role }`, as an instruction's options are.
- **`mount-fields`** are the fields it adds to core mount types, by type,
  written `<module>.<field>=…` in a `--mount=`. No shipped module declares
  any yet.
- **`provided-files`** are files its Swift provides rather than its folder,
  which a Wrappfile names as `module:<id>:/<path>`: the installer module's
  `autoit`, AutoIt, which Second Chance carries.
- **`setup`** lists the instructions `USE` would plan in a tree that doesn't
  have the module yet, in order, each one of its own instructions. No
  shipped module has any, and nothing plans them yet.

Today's builders carry the declared instructions out, so a declaration
could promise what no builder does. `BuilderDeclarations`
(`SecondChance/Builders/BuilderDeclarations.swift`) lists, by module, the
instructions the builders carry out and the options each reads, and
`ModuleDeclarationTests` holds every shipped module's `build:` to it: every
instruction declared is carried out, none is carried out that isn't
declared, and every option declared is read, so none is accepted and
ignored. A change to what a builder carries out changes both. An option the
builder accepts only in certain forms checks them and refuses the rest:
`STEAM.INSTALL`'s mounts must be the shared sign-in and the kept client
(`SteamWrappBuilder.checkMounts`).

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
- Wine's 32-bit `ntdll.dll` gets the Rosetta fault fix (`RosettaFaultFix`),
  which lets programs wrapped in Armadillo, as Big Fish's games are, run
  under Rosetta ([big-fish.md](big-fish.md#armadillo-under-rosetta)).
- The wrapper's Swift modules are dropped, and the framework they were in
  is sealed again.
- Every unsigned program and DLL is signed, deepest first: signing a
  framework's binary seals the hashes of every file in it, so they must be
  signed before it.

ScummVM's copies the program, its frameworks, the data its GUI needs and the
engine data files `engine-data` names, out of its disk image. DOSBox
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

It is a cache: a wrapp holds its own copy of its engine, so clearing it costs
only the next build's download. `sc engine fetch [<id>…]` fills it here, as
a build would.

A build installs the engines it needs from the store
([wrapp-build.md](wrapp-build.md#the-template)); Second Chance itself carries
none.

## What lives where

| Module | Data | Read by |
| --- | --- | --- |
| `wine` | `stages/prefix`: the Wrappfile stage a new prefix is made by — its drives (`WINE.DRIVES`), `EmulateModeset` (`WINE.REGISTRY`) and `isolate_home` (`WINE.WINETRICKS`), in order; `functions/cnc-ddraw`, cnc-ddraw and its `ddraw.ini` settings, which a DirectDraw game's stage runs (`DO wine.cnc-ddraw`) | `WineManager`, as it makes a prefix, and `WineSteps`, which carries the steps out; Steam's and Big Fish's builders run `cnc-ddraw` themselves for a DirectDraw game until their editions have stages |
| `wine` | `routine-errors.yaml`: Wine's routine `err:` lines | the wrapp's quit check (`GameQuitCheck`), compiled in by `sc generate` |
| `steam` | `stages/client`: Steam's client in the wine module's prefix, ⌘ acting as Ctrl in its windows (`FROM --module=steam@1 client`); `functions/install`, the game installed by Steam with the shared sign-in, then signed out (`DO steam.install`) | `SteamWrappBuilder`, which carries the client stage out before the game is known and the edition's steps after ([steam.md](steam.md#building)) |
| `big-fish` | `stages/manager`: the Game Manager in the wine module's prefix, from its installer pinned by its hash, ⌘ acting as Ctrl in its window (`FROM --module=big-fish@1 manager`); `functions/install`, the game installed and activated, then the account taken out (`DO big-fish.install`); `functions/cnc-ddraw`, cnc-ddraw hooking the functions themselves, as Armadillo rebuilds a game's imports (`DO big-fish.cnc-ddraw`) | `BigFishWrappBuilder`, which carries the manager stage out before the game is known and the edition's steps after ([big-fish.md](big-fish.md#the-build)) |
| `wine`, `scummvm`, `dosbox` | `module.yaml`'s `runtime: { save-warning }`: whether their programs get the save warning before they start (Wine's do) | the wrapp (`ModuleID.showsSaveWarning`), compiled in by `sc generate` |
| `steam` | `routine-errors.yaml`: what Steam logs as it starts | the same, for a game launched through Steam |
| `nancy-drew` | `patches.json`: Her Interactive's patches ([game-patches.md](game-patches.md)) | `GamePatchCatalog`, and `setup-game-patches.sh`, which stages their archives in the app's download cache |
| `nancy-drew` | `ini.yaml`: what every `.ini` in a game's folder has changed once it's installed (LCD mode, saves in Documents) | `WrappBuildHelper`, configuring the wrapp |
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
