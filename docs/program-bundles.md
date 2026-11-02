# Program bundles

Every game Second Chance knows is described by a **program bundle**: a folder
in `Bundles/` with a `manifest.yaml` saying what the program is, the editions it
was sold as and where each comes from, and the variants it runs as. This is the
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
      assets/                  files the Wrappfile names: disc.iss, her-download.iss
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

variants:                       # how it runs: in Wine, starting this program
  - id: "wine"
    launch: { wine: { exe: "C:/Nancy Drew/Secret of the Old Clock/Game.exe", graphics: "direct-draw" } }

editions:                       # what it was sold as, and where each comes from
  - id: "cd"
    source: "disc"
    inputs:
      - { id: "disc-1" }
    installer: { stubborn: true }   # its installer doesn't exit when run silently
  - id: "her-windows"
    source: "her-download"
    inputs: [{ id: "installer", format: "windows" }]
  - id: "steam"
    source: "steam"
    inputs:
      - { id: "game", app-id: 31880, common-folder: "Nancy Drew Secret of the Old Clock", exe: "Game.exe" }
    drm: "no"                   # left out when not known
  - id: "big-fish"
    source: "big-fish"
    inputs: [{ id: "game", product: 1297 }]   # its number in Big Fish's SKUs

notes:                          # for people only; nothing reads these
  installer: "installshield"
```

The schema describes every field, including those nothing reads yet
(choices). `updates` is read when an old wrapp is updated
([wrapp-build.md](wrapp-build.md#updating-a-wrapp)), and `tests` (the
scenario and its parameters) by WrappPuppeteer, with the needles in the
bundle's `tests/needles/` ([testing.md](testing.md#needles)). What today's code reads
into `GameInfo`, by field:

| Manifest | Today's `GameInfo` |
| --- | --- |
| `id` (the part after the `/`) | `id`, the game's slug |
| `title` | `title` |
| the `disc` edition's `inputs`, one per disc | `diskCount` |
| a variant called `scummvm` | `gameEngine: .scummvm`; otherwise `.wine` |
| the `wine` variant's `launch.wine.exe` | `internalGameExePath`, without `C:` |
| the `wine` variant's `launch.wine.graphics` | `graphics`: what the game draws with, for an `.exe` that can't say (`GameGraphicsAPI`) |
| the `steam` edition's input: `app-id`, `common-folder`, `exe` | `steamAppID`, `steamInstallDir`, `steamExePath` |
| the `steam` edition's `drm` | `steamDRM`: `no`, `launch-when-steam-running`, `launch-via-steam-only`, or left out when not known |
| the `big-fish` edition's input: `product` | `bigFishProduct` |
| any edition's `installer.stubborn` | `doesNotExitInNonInteractiveMode` |
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
mistakes. Nothing reads it but `sc bundle list --where`.

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

## Download editions

An edition with `source: download` is a program its makers give away, which
Second Chance downloads ([wrapp-build.md](wrapp-build.md#the-download-source)):

```yaml
editions:
  - id: "download"
    source: "download"
    build: { target: "download" }
    licence: "free-release"
    licence-from: "the author's website"
    inputs:
      - id: "game"
        urls:                                # tried in order; the hash alone decides
          - "https://ski.ihoc.net/ski32.exe"
          - "https://web.archive.org/web/20110929074042id_/http://ski.ihoc.net/ski32.exe"
        sha256: "3572d375…"
        size: 118784
        unpack: "none"
        install: "none"
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

The shipped ones are SkiFree (`freeware/skifree`, a bare exe under Wine) and
Lure of the Temptress (`freeware/lure-of-the-temptress`, a zip ScummVM hosts,
under ScummVM). A ScummVM game needs its engine's data file in the template:
`setup-scummvm.sh` copies the ones the shipped bundles' engines use
(`ENGINE_DATA`), and a game whose file is missing stops at ScummVM's "Unable
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
answer file (`assets/disc.iss`, `assets/her-download.iss`). Each edition names
the Wrappfile stage it builds (`build: { target: "disc" }`).

`--where` takes a path into the manifest and a value; a list along the path
matches when any item does, so `editions.source=steam` is any edition. Repeat it
to need every condition. The unit tests check every bundle too, so `sc test unit`
fails on an invalid one.
