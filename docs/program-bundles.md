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

The schema describes every field, including those nothing reads yet (volumes,
updates, choices, tests). What today's code reads, by field:

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
./sc bundle check                         # check every bundle against the schema
./sc bundle check Bundles/nancy-drew/old-clock
./sc bundle list --where notes.installer=installshield
./sc bundle list --where editions.source=steam --where series="Nancy Drew"
./sc generate                             # regenerate GameCatalog's table (and modules' Swift)
```

`--where` takes a path into the manifest and a value; a list along the path
matches when any item does, so `editions.source=steam` is any edition. Repeat it
to need every condition. The unit tests check every bundle too, so `sc test unit`
fails on an invalid one.
