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
  - { version: "10.0_8" }
data: ["prefix.yaml", "routine-errors.yaml"]
```

A module's data tables are YAML, read as YAML 1.2 as bundles are
([program-bundles.md](program-bundles.md#how-a-manifest-is-read)), and a table
with a schema beside it (`prefix.yaml` and `prefix.schema.json`) is checked
against it whenever the module is loaded. The rest of the format (functions,
stages, volumes, a module's updates) is the plan's, and comes with what reads
it.

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
| `nancy-drew` | `needles/`: the splash screens WrappPuppeteer clicks past, and the main menu's quit button | WrappPuppeteer (`NancyDrewNeedles`), from the source tree or its bundle's copy |

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
