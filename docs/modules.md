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
    prefix.yaml             how a new prefix is set up (prefix.schema.json beside it)
    routine-errors.yaml     Wine's err: lines that say nothing is wrong
  scummvm/  steam/  big-fish/  nancy-drew/  installer/  disc/  her-download/
```

`installer`, `disc`, `her-download` and `big-fish` are, so far, a `module.yaml` naming their
Swift: the instructions a Wrappfile gives them ([wrappfile.md](wrappfile.md))
and today's builders.

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
data: ["prefix.yaml", "routine-errors.yaml"]
updates:                       # its default updates, after a bundle's
  - { id: "wine-prefix", when-changed: ["prefix.yaml"] }
```

A module's data tables are YAML, read as YAML 1.2 as bundles are
([program-bundles.md](program-bundles.md#how-a-manifest-is-read)), and a table
with a schema beside it (`prefix.yaml` and `prefix.schema.json`) is checked
against it whenever the module is loaded. A module's `updates` are run after a
bundle's for a wrapp whose copy of the module is behind, as
[wrapp-build.md](wrapp-build.md#updating-a-wrapp) describes; one with no
`build` is done by the module's own Swift. The rest of the format (functions,
stages, volumes) is the plan's, and comes with what reads it.

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
- The wrapper's Swift modules are dropped, and the framework they were in
  is sealed again.
- Every unsigned program and DLL is signed, deepest first: signing a
  framework's binary seals the hashes of every file in it, so they must be
  signed before it.

ScummVM's copies the program, its frameworks, the data its GUI needs and the
engine data files `engine-data` names, out of its disk image.

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
./sc engine prepare wine                   # prepare it here; check, or print, its hash
./sc engine prepare scummvm --into /tmp/s  # and keep the tree
```

A new version is added without `prepared`, prepared, and given the hash
`sc engine prepare` prints. Changing a package changes the module's folder,
so it needs a new release, as any change does.

For now the template still carries both engines, built by `setup-wine.sh`
and `setup-scummvm.sh`, and builds copy them from it. Builds taking engines
from their packages instead, fetched when a build first needs one, is what
comes next.

## What lives where

| Module | Data | Read by |
| --- | --- | --- |
| `wine` | `prefix.yaml`: the registry setting, winetricks verbs and `ddraw.ini` settings a new prefix gets, in order | `WineManager`, as it makes a prefix |
| `wine` | `routine-errors.yaml`: Wine's routine `err:` lines | the wrapp's quit check (`GameQuitCheck`), compiled in by `sc generate` |
| `steam` | `routine-errors.yaml`: what Steam logs as it starts | the same, for a game launched through Steam |
| `nancy-drew` | `patches.json`: Her Interactive's patches ([game-patches.md](game-patches.md)) | `GamePatchCatalog`, and `setup-game-patches.sh`, which stages their archives in the app's download cache |
| `nancy-drew` | `ini.yaml`: what every `.ini` in a game's folder has changed once it's installed (LCD mode, saves in Documents) | `WrappBuildHelper`, configuring the wrapp |
| `nancy-drew` | `clean-exit-log.yaml`: the log Her's later engine writes, and its clean-exit line | the wrapp (`HerEngineLog`), compiled in by `sc generate` |
| `nancy-drew` | `assets/*.au3`: the AutoIt scripts that click through an installer that won't run silently, and patchers with no silent mode | `GameInstallerRunner` |
| `nancy-drew` | `needles/`: the splash screens many games share and the main menu's Exit, and `scenarios/quit-from-menu.yaml`, the test every game's bundle names ([testing.md](testing.md#scenarios)) | WrappPuppeteer (`TestData`), from the source tree or its bundle's copy |

| `nancy-drew` | `functions/patch`, `functions/configure-ini`: Wrappfile functions (`DO nancy-drew.patch --id=… --into=…`), and `assemble`, which runs `configure-ini` after every final stage that uses the module | the Wrappfile checker, for now |

Second Chance's app finds the nancy-drew module through `NancyDrewModule`.
The quit scenario itself is still Swift (`NancyDrewQuitScenario`), until
scenarios are data.

The wrapp reads no YAML, as only the builder does, so what it needs of a
module's data is generated as Swift by `sc generate` and checked in; a test
fails when it isn't what the data makes. A change to `prefix.yaml`, or to
the wine module's release, changes the prefix layer's key, so the next build
makes a fresh prefix by itself
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

So **changing anything in a module's folder means raising its `release:`**
and recording it with `sc module release`. `sc module check` (and the unit
tests) fail on a module whose files differ from what its release recorded,
naming the files. A new release is compared with the one before: for a
version both provide, it may not drop a function or a data table, since a
bundle can't choose a release and must keep working; that needs a new
version. It may stop providing a version altogether.
