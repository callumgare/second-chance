# Program bundles

Every game Second Chance knows is described by a **program bundle**: a folder
in `Bundles/` with a `manifest.yaml` saying what the program is, the editions it
was sold as and where each comes from, and the volumes the person's files are
kept in; its `Wrappfile` says how each edition is built and how the program
runs ([wrappfile.md](wrappfile.md)). This is the
first step of making Second Chance work for programs other than Nancy Drew's
games. For now the bundles only replace the hand-written table of games: the
build still works as before, reading the same facts from a table generated
from the bundles.

```text
Bundles/
  manifest.schema.json         the JSON Schema every manifest is checked against
  nancy-drew/                  a namespace: who the bundles come from
    blue-moon/                 one program
      manifest.yaml
      Wrappfile                how each edition is built (docs/wrappfile.md)
      assets/                  files the Wrappfile names: disc.iss, her-download.iss (allowed by allow-paths)
```

## The manifest

A manifest is YAML, starting with a line that tells editors which schema it
follows, so an editor with a YAML extension (yaml-language-server) completes and
checks it as it's written:

```yaml
# yaml-language-server: $schema=../../manifest.schema.json
format: 1                       # the manifest format; a newer one than the app reads is refused
id: "nancy-drew/old-clock"      # <namespace>/<name>, matching the folder
version: 1                      # the bundle's own revision
title: "Secret of the Old Clock"
series: "Nancy Drew"
series-order: 13                # where it comes in lists of the series
former-bundle-ids: ["au.gare.callum.SecondChance.nancy-drew.old-clock"]
allow-paths: ["assets/"]        # the folders of its own its Wrappfile may read files from

volumes:                        # kept outside the app, in its Application Support folder
  wine-documents:
    display-name: "saved games"   # text people see, in the string catalog

editions:                       # what it was sold as, and where each comes from
  - id: "cd"
    source: "disc"
    build:
      target: "disc"            # the Wrappfile's stage that builds it
      inputs:                   # what its INPUTs are given, by name
        disc-1: { type: "disc" }
  - id: "her-windows"
    source: "her-download"
    build:
      target: "her-download"
      inputs:
        installer: { type: "her-download", format: "windows" }
  - id: "steam"
    source: "steam"
    build:
      target: "steam"
      inputs:
        game: { type: "steam-game", app-id: 31880, common-folder: "Nancy Drew Secret of the Old Clock" }
        launch-mode:            # a question, whose answer is the input's value
          type: "choice"
          options: ["direct", "steam"]
          default: "direct"     # what a headless build takes
          prompt: "How should the game start?"
    notes:                      # for people only, about this edition
      drm: "no"
  - id: "big-fish"
    source: "big-fish"
    build:
      target: "big-fish"
      inputs:
        game: { type: "big-fish-game", product: 1297 }   # its number in Big Fish's SKUs

tests:                          # what WrappPuppeteer does with it
  scenario: "nancy-drew/quit-from-menu"
  window: "fullscreen"          # the window its program must end up in: fullscreen or windowed

notes:                          # for people only; nothing reads these
  installer: "installshield"
```

An edition's `build.inputs` are keyed by the name its Wrappfile's `INPUT`
declares and `${input.<name>}` reads ([wrappfile.md](wrappfile.md#values)).
`type` says how the person gives it, and which fields it has: `disc`,
`her-download`, `steam-game`, `big-fish-game`, `download`, or `choice`, a
question whose prompt is looked up in the string catalog. An edition's
inputs are of its source's type, or choices. Every input the target reads
with no default must be given, and every one given must be read: one nothing
reads is a typo, or something asked for no reason.

The bundle's id, an edition's `id` and an input's name are also where tests
and `sc` find that input's file on a Mac: a `disc` or `her-download` input
is `<bundle id>/<edition id>/<input name>.<ext>` in the installers store
(`nancy-drew/old-clock/cd/disc-1.iso`), so renaming one moves where its
installers are kept ([testing.md](testing.md#the-installers-store)).

`allow-paths` names the folders of the bundle's own its Wrappfile may read
files from, each relative to its folder and ending in `/`; a file is never
readable for being beside the Wrappfile, and a path with `..` or starting `/`
is refused ([wrappfile.md](wrappfile.md#what-a-build-may-read)). A bundle with
answer files allows `assets/`; one with nothing to read, as most without an
answer file are, allows nothing.

The schema describes every field. `updates` is read when an old wrapp is updated
([wrapp-build.md](wrapp-build.md#updating-a-wrapp)), and `tests` (the
scenario, its parameters, and `window`, the window the program is expected to
end up in) by WrappPuppeteer, with the needles in the
bundle's `tests/needles/` ([testing.md](testing.md#needles)). `window` is
`fullscreen`, which every Nancy Drew bundle, Lure of the Temptress and Tyrian
2000 say, or `windowed`, which LaserTank's does
([testing.md](testing.md#scenarios)). What today's code reads
into `GameInfo`, by field:

| Manifest | Today's `GameInfo` |
| --- | --- |
| `id` (the part after the `/`) | `id`, the game's slug |
| `title` | `title` |
| the `disc` edition's `build.inputs`, one per disc | `diskCount` |
| the module of the first planned edition's `LAUNCH` | `gameEngine`: `.scummvm`, `.dosbox`, otherwise `.wine` |
| that launch's program, on Wine's or DOSBox's C: | `internalGameExePath`, without `C:` |
| that launch's `--wine.graphics` | `graphics`: what the game draws with, for an `.exe` that can't say (`GameGraphicsAPI`) |
| the `steam` edition's `steam-game` input: `app-id`, `common-folder` | `steamAppID`, `steamInstallDir` |
| the `steam` edition's launch: its `--steam.exe`, or its Wine program | `steamExePath`, its name |
| whether the `steam` edition has a `launch-mode` input | `offersSteamLaunchChoice` |
| the `big-fish` edition's `big-fish-game` input: `product` | `bigFishProduct` |
| editions' `detect.aliases` and `detect.codes` | `detectionAliases`, `detectionCodes` |
| `series`, then `series-order` | the order of `allGames()` |

Editions are what the game was ever sold as, not what is sold now: someone who
bought one long ago must still be able to build it. Each game has a Her
Interactive Windows download edition, and the games Her also sold for Mac
(Secrets Can Kill Remastered, and Trail of the Twister to Sea of Darkness) a Mac
one. Only Trail of the Twister's Mac download has been looked inside; the notes
say so for the others.

`notes` is for what is worth recording but changes nothing: which installer a
game uses, its quirks. It is one key the schema doesn't check, rather than
unchecked keys anywhere, since rejecting a mistyped key is what catches real
mistakes. Nothing reads it but `sc bundle list --where`. An edition has
`notes` too, about itself: a Steam edition's `drm` (`no`,
`launch-when-steam-running`, `launch-via-steam-only`, left out when not
known), found as `editions.notes.drm=no`. They aren't merged with the top
level's, and no build reads them: what a game's DRM allows is what its Steam
stage's `LAUNCH` says.

### How a manifest is read

**As YAML 1.2, as the editor reads it.** In YAML 1.1, a bare `no`, `off` or
`yes` is a boolean and `10.10` is the number 10.1; in YAML 1.2, which the editor
extension reads, the first three are text. Second Chance reads bundles with
[Yams](https://github.com/jpsim/Yams) given a YAML 1.2 core-schema resolver
(`YAML12.swift`), so a manifest means the same thing to both. Strings are still
quoted by convention, which keeps a bundle clear of any reader's quirks.

**Checked from the raw YAML, then decoded.** A manifest is checked against
`Bundles/manifest.schema.json` before it is decoded into Swift types: decoding
alone reads a bare `no` as the text written and drops a mistyped key without a
word. The schema is JSON Schema draft 2020-12, checked by
[ajv](https://ajv.js.org) run in JavaScriptCore (`SchemaValidator.swift`; why
ajv, and how to update it, is in `Packages/WrappBuilder/JavaScript/README.md`).
Its errors are reworded for a bundle's author:

```text
nancy-drew/old-clock: manifest.yaml at /editions/2: dmr isn't something this can have; is it mistyped?
```

Checks the schema can't make, across fields or against the folder (the id
matches its folder, no two editions share an id), are in
`ProgramBundleLoader`.

### Volumes

`volumes` names what's kept outside the app, the person's: its
`display-name`, which files in it are theirs (`in-use-when`), and how it's
brought forward, each by the name of a store the Wrappfile declares
(`STORE wine-documents`), whose `LAUNCH --mount=type=store,…` says where the
program sees it ([wrappfile.md](wrappfile.md#stores)); a volume no stage
mounts is fine, as the ScummVM games' `wine-documents` keeps saves from before
they ran in ScummVM. There are no variants: how a program runs is its
edition's target's `LAUNCH`, and `sc generate` reads the catalogue's engine,
program and graphics from the first planned edition's, planned for both
kinds of Mac, failing if they differ.

## Download editions

An edition with `source: download` is a program its makers give away, which
Second Chance downloads ([wrapp-build.md](wrapp-build.md#the-download-source)):

```yaml
editions:
  - id: "download"
    source: "download"
    build:
      target: "download"
      inputs:
        game:
          type: "download"
          urls: # tried in order; the hash alone decides
            - "https://ski.ihoc.net/ski32.exe"
            - "https://web.archive.org/web/20110929074042id_/http://ski.ihoc.net/ski32.exe"
          sha256: "3572d375…"
          size: 118784
          unpack: "none"
          install: "none"
    licence: "free-release"
    licence-from: "the author's website"
```

- **`urls`**: the publisher's, or a distributor it names; then the Wayback
  Machine's `id_` copy of that same URL with its full 14-digit timestamp (a
  partial one redirects to whichever capture is nearest); then archive.org
  items. No fan sites and no servers of ours. Every lookup in an archive is done
  when the bundle is written, never by the app: the Wayback index's `digest`
  is the file's SHA-1, so a capture can be checked without downloading it.
- **`licence`** says what the person is told before it downloads, never a
  gate on where it comes from: `freeware-licensed` (its makers say anyone may
  share it), `free-release` (they give it away, saying nothing more),
  `shareware` (a free first part) or `abandonware` (no longer sold, nothing
  said). `licence-from` says where the permission comes from.
- **`unpack`** is `none` or `zip` so far; `install` is `none`.
- **`licence-file`** names the licence's own words in the unpacked input
  (`lure/LICENSE.txt`), saved into the app after what the person is told.

The shipped ones are SkiFree (`freeware/skifree`, a bare exe under Wine),
Lure of the Temptress (`freeware/lure-of-the-temptress`, a zip ScummVM hosts,
under ScummVM) and Tyrian 2000 (`freeware/tyrian-2000`, a zip of DOS files,
under DOSBox, whose `LAUNCH` names the DOS program at its path on DOSBox's
own C:, `C:/TYRIAN/TYRIAN2K.EXE`). A ScummVM game needs its engine's data file in ScummVM's
engine: the scummvm module's package names the ones the shipped bundles'
engines use (`engine-data`, [modules.md](modules.md#engine-packages)), and a
game whose file is missing stops at ScummVM's "Unable
to locate the 'lure.dat' engine data file", naming its engine's.

A download edition is the first of a **program beyond Nancy Drew**, in a
namespace of its own (`freeware/skifree`). Its catalogue entry carries its
bundle id and app name (`GameInfo.program`, `GameInfo.displayName`), so its app
is "SkiFree", its bundle id `au.gare.callum.second-chance.program.freeware.skifree`,
and the code that finds a game's bundle goes by `GameInfo.programID` rather than
`nancy-drew/<slug>`.

## Detection

Every bundle is recognised by its `title` (less a leading "The"), matched
anywhere in what a disc or download says of itself, case aside, with nothing
written. An edition's `detect` adds:

```yaml
detect:
  aliases: ["Blue Moon Canyon"]      # other names, matched as the title is
  codes: ["TRN"]                     # short codes, in capitals, as a whole word
  matchers:                          # anything else, when names can't tell editions apart
    - { file-exists: "Data/*.cif" }
    - { file-contains: { file: "autorun.inf", text: "Blue Moon" } }
    - { file-hash: { file: "Data/game.dat", size: 123456, md5: "…", bytes: 5000 } }
    - { exe-version: { file: "setup.exe", key: "ProductName", text: "Blue Moon" } }
    - { msi-summary: { subject: "Blue Moon" } }     # file: "*.msi" when left out
    - { volume-name: "BLUEMOON" }
```

Aliases and codes count for the whole bundle, as they always have; a
`matchers` entry names its edition. Matchers have no order: where more than
one bundle matches, the most specific wins — the longest text matched (which
is how Remastered wins over Secrets Can Kill, whose title it contains), a
glob or volume name by its length without wildcards, and a file's hash over
any text. Two bundles matching equally are a tie, which is asked about as a
game nothing recognised is. A source nothing recognises is reported as a near
miss when a hash matcher's file is there with another size or md5, or else
more than half of a title's words are (common words aside), or else only the
series' name.

## The table of games

`GameCatalog` stays Foundation-only, so the apps, the wrapps, WrappPuppeteer and
`sc` never read YAML. Its table of games,
`Packages/GameCatalog/Sources/GameCatalog/GameInfoProvider+Bundles.swift`, is
generated from the bundles by `sc generate` and checked in, and a test
(`ProgramBundleTests`) fails when it isn't what the bundles make. So **a game is
added or changed in its bundle**, followed by `sc generate`; the generated
file is never edited by hand.

A program's names come from its bundle too: its program id is the bundle's
`id`, and its app is called the manifest's `display-name` (with `{title}` and
`{series}` filled in), or "{series} - {title}" when it has a series, or its
title alone — "Nancy Drew - Secret of the Old Clock", "SkiFree".

Loading and checking bundles lives in `Packages/WrappBuilder/`, the package that
will hold everything that turns a bundle into a wrapp, kept apart from the app.

## Commands

```bash
./sc bundle check                         # check every bundle: its manifest and its Wrappfile
./sc bundle check Bundles/nancy-drew/old-clock
./sc bundle list --where notes.installer=installshield
./sc bundle list --where editions.source=steam --where series="Nancy Drew"
./sc generate                             # regenerate GameCatalog's table (and modules' Swift)
```

Second Chance ships `Bundles/` in its resources, where a build finds a game's
answer file (`assets/disc.iss`, `assets/her-download.iss`), in the folders
its manifest's `allow-paths` allows. `wrapp-builder check <folder>` and
`wrapp-builder plan <folder>` do what `sc bundle check` and `sc bundle plan`
do, for a bundle anywhere, with the modules `--modules` names
([dev-cli.md](dev-cli.md#wrapp-builder)). Each edition names
the Wrappfile stage it builds (`build: { target: "disc" }`).

`--where` takes a path into the manifest and a value; a list along the path
matches when any item does, so `editions.source=steam` is any edition. Repeat it
to need every condition. The unit tests check every bundle too, so `sc test unit`
fails on an invalid one.
