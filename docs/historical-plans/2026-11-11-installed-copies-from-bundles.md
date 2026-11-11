# Telling an installed copy from its installer, by the bundles

Proposed and implemented 2026-11-11. The plan as written is below, with
the questions it left open answered at the end, and **As built** saying
where the implementation went another way.

It builds on detection as it is now
([program-bundles.md](../program-bundles.md#detection)): `DetectionIndex`
loaded at run time from the shipped bundles and `sc --bundle`'s extras
(`GameDetector.shippedIndex`), and its file matchers (`file-exists`,
`file-contains`, `file-hash`, `exe-version`) evaluated over a `SourceFiles`
listing. If detection changes before this is taken up, check this plan
against it first.

## What happens today

`GameDetector.isInstalledGame(at:games:)`
(`SecondChance/Services/GameDetector.swift`) is called once, by
`DiskWrappBuilder.resolveGame`, on the chosen folder or mounted disc, before
the program is detected. When it says yes the build stops with
`WrappBuildError.installedGameNotInstaller`. Its rules, all in code:

| Rule | Where it comes from |
| --- | --- |
| Only the folder's **top level** is looked at, hidden files left out. | `topLevelFileNames(in:)` |
| Only files ending **`.exe`** count, so only Windows (and DOS) programs can ever be an installed copy. | the filter in `isInstalledGame` |
| A file counts when its name, case aside, is the **last path component** of any game's `internalGameExePath` or `steamExePath`. | `GameInfo`, from the generated `GameInfoProvider+Bundles.swift` |
| `internalGameExePath` is the program of the **first planned edition's `LAUNCH`**, when the program's module puts it on a drive (`PathPlaces.legacyProgramPath`). So, **per engine**: Wine and DOSBox programs have one; ScummVM and Basilisk II programs have none and are never refused. | `GameCatalogSource.gameInfo` |
| `steamExePath` is the **Steam edition's** `--steam.exe`, or its Wine program. Today every one equals its `internalGameExePath`'s name, so it adds nothing but would for a Steam-only program. | `GameCatalogSource.gameInfo` |
| The names of **every game are pooled**: a folder is refused for holding _any_ program's name, before anyone knows which program it is. Ten Nancy Drew games' program is `Game.exe`, so any folder with a `Game.exe` at its top, of any program, is refused. | `games.flatMap` over `gameInfoProvider.allGames()` |
| An installer beside the program **doesn't** make it a disc (InstallShield leaves `Setup.exe` and `Setup.ini` in the installed folder). | the doc comment; no check |
| **Per source**: only the disc source checks (a folder, or an image mounted). Her downloads are a file, and Steam, Big Fish and downloads install the program themselves. | the one call site |
| The error's text names a Nancy Drew source ("the installer you downloaded from Her Interactive"), whatever the program. | `WrappBuildError.playerMessage` |

What that means per program today:

- **Nancy Drew, Wine** (26 games): `Game.exe` for Haunted Carousel to Crystal
  Skull, a name of its own from Phantom of Venice on (`CastleMalloy.exe`,
  `Secrets.exe` for the remastered Secrets Can Kill, …).
- **Nancy Drew, ScummVM** (Secrets Can Kill to Ghost Dogs): nothing; an
  installed copy goes on to detection. ScummVM runs from the disc's files, so
  that may even work.
- **Bioscopia** (Wine, disc): `Bioscopia.exe`. Its disc 1 has
  `Transfer/Bioscopia.exe`, which is a folder down and so not counted.
- **SkiFree, Icy Tower, Iji, LaserTank** (Wine, download only):
  `ski32.exe`, `icytower13.exe`, `iji.exe`, `lasertank.exe`. They have no
  disc edition, so these only refuse _other_ programs' discs.
- **Tyrian 2000** (DOSBox, download only): `TYRIAN2K.EXE`, though a DOS
  program's installed files are exactly what DOSBox runs.
- **Lure of the Temptress** (ScummVM) and **Ingenious** (Basilisk II):
  nothing.

The tests are `SecondChanceTests/InstalledGameDetectionTests.swift`: ten real
discs' top levels must not count, three installed folders must.

## What this changes

Each bundle says what its program looks like once installed, in its
manifest, with the matchers detection already has. The pooled names, the
`.exe` filter and the derivation from the launch go. The check still runs
before detection, over every bundle, so an installed copy is still refused
without anyone being asked which program it is, but each refusal names the
bundle whose signs matched.

### The manifest

A top-level `installed`, beside `editions`: a list of signs, any one of which
says a folder holds the program already installed. Top level rather than in
an edition's `detect`, because what an install leaves is the program's,
whichever edition installed it (every Steam edition's program is the disc's
today). Each sign is one matcher, of the kinds that look at files, with the
same globs as `detect.matchers`, from the top of the folder:

```yaml
# Bundles/nancy-drew/castle-malloy/manifest.yaml
installed:                           # a folder holding the game already installed
  - { file-exists: "CastleMalloy.exe" }
```

```yaml
# Bundles/nancy-drew/haunted-carousel/manifest.yaml: Game.exe alone is too
# common a name, so both files, as the installed game has them (phase 4)
installed:
  - all-of:
      - { file-exists: "Game.exe" }
      - { file-exists: "Nancy.cid" }
```

```yaml
# Bundles/tivola/bioscopia/manifest.yaml
installed:
  - { exe-version: { file: "Bioscopia.exe", key: "ProductName", text: "Bioscopia" } }
```

```yaml
# Bundles/freeware/skifree/manifest.yaml
installed:
  - { file-exists: "ski32.exe" }
```

A bundle with no `installed` is never refused as installed, as the ScummVM
and Basilisk II bundles aren't today. `installed: []` says so on purpose,
which quiets the checker's warning (below).

### The schema and the checker

`Bundles/manifest.schema.json`:

- `installed`: an array of `$defs/installed-sign`, `uniqueItems`.
- `installed-sign`: `oneOf` an `installed-matcher`, or an object with only
  `all-of`, an array of two or more `installed-matcher`s.
- `installed-matcher`: `$defs/matcher` limited to `file-exists`,
  `file-contains`, `file-hash` and `exe-version` (a `volume-name` or
  `msi-summary` says nothing about an installed folder). Easiest as its own
  `$def` with those four properties, sharing their sub-schemas by `$ref`.

`ProgramBundleLoader.problems` (what the schema can't say):

- A `file-exists` whose glob is nothing but wildcards and an extension
  (`*.exe`) is refused: it would refuse every disc with a program on it.

`ProgramBundleLoader.warnings` (`sc bundle check`, which `sc lint` fails on):

- A bundle with an edition whose source installs from what the person
  chooses (`disc` today, `her-download` if it ever takes a folder) and whose
  planned launch's program is a `.exe` on a drive, but no `installed` at
  all: "an installed copy chosen instead of its disc wouldn't be turned
  down; say what one looks like, or `installed: []`".
- A sign that matches one of the bundle's own committed disc layouts, should
  one be kept (open question 3).

### How the value reaches the code: at run time, through `DetectionIndex`

Not through `sc generate` and `GameInfoProvider+Bundles.swift`. The check
already runs where the bundles are loaded (the app, with `Bundles/` in its
resources, and the extras `sc --bundle` passes), it needs the matchers'
file reading that `GameCatalog` mustn't have, and it belongs with the
builder, which is meant to stand apart from Second Chance (AGENTS.md, "The
builder stands on its own"). So `GameCatalog`, its generated table and
`GameCatalogSource` don't change, and `internalGameExePath` and
`steamExePath` keep their other readers (Steam, the integration tests,
`WrappfileTodayTests`).

- `Manifest` (`Packages/WrappBuilder/Sources/WrappBuilder/Bundles/Manifest.swift`):
  `public let installed: [InstalledSign]?`, where `InstalledSign` is a
  matcher or `allOf([Matcher])`, decoded alongside `Matcher`'s own
  `Decodable` (`Detection/Matcher.swift`).
- `DetectionIndex` (`Detection/DetectionIndex.swift`): the bundles' signs
  kept apart from the rules `detect` ranks, so a sign never recognises a
  program, and counted in `fileDepth`.
  `public func installedCopy(_ source: DetectionSource, readers:) -> InstalledMatch?`
  evaluates them over one `SourceFiles` listing and gives the most specific
  match (`Specificity`, an `all-of` as the sum of its parts), with its
  bundle id and the sign, or nil. Two bundles tied are still an installed
  copy; the log names both.
- `GameDetector.isInstalledGame(at:)`: drops `games:`, builds a
  `DetectionSource` with only `location: .folder(url)`, asks
  `index.installedCopy`, and logs as now, naming the bundle and the sign
  ("… is nancy-drew/castle-malloy already installed (file-exists
  CastleMalloy.exe), not an installer"). It runs in `Blocking.run`, as
  matchers read files.
- `GameDetector.catalogueIndex`, the fallback when the bundles fail to load
  (which the unit tests rule out), has no signs: nothing is refused, and the
  error already logged says why.
- `DiskWrappBuilder.resolveGame`: the call loses `games:` and stays where
  it is, before detection.

## Migrating every bundle

Done in one commit by a script kept out of the repo (in a scratch folder),
which writes, for each bundle, today's rule exactly: a `file-exists` for the
last component of its `internalGameExePath` and, when different, its
`steamExePath`, from the generated table. That's:

| Bundles | `installed` |
| --- | --- |
| The 10 Nancy Drew `Game.exe` games (Haunted Carousel, Deception Island, Shadow Ranch, Blackmoor Manor, Old Clock, Blue Moon, Danger by Design, Kapu Cave, White Wolf, Crystal Skull) | `{ file-exists: "Game.exe" }` (narrowed in phase 4) |
| The 15 later Nancy Drew Wine games, and Secrets Can Kill Remastered | `{ file-exists: "<its exe>" }` |
| The 7 Nancy Drew ScummVM games | `[]` |
| Bioscopia | `{ file-exists: "Bioscopia.exe" }` |
| SkiFree, Icy Tower, Iji, LaserTank | `{ file-exists: "<its exe>" }` |
| Tyrian 2000 | `{ file-exists: "TYRIAN2K.EXE" }` (open question 2) |
| Lure of the Temptress, Ingenious | `[]` |

Then `wrapp-builder fmt` over `Bundles/`, `./sc bundle check` and
`./sc lint`. Since the result is today's rule, nothing anyone sees changes
until phase 4.

## Order

1. **The field, read and checked; nothing uses it.**
   `Bundles/manifest.schema.json`, `Manifest.swift`, the loader's problem
   and warning in `ProgramBundle.swift`, and a section in
   `docs/program-bundles.md` (after "Detection", and the `installed` row in
   its table of what's read where: "read at run time by detection, not into
   `GameInfo`"). Package tests in
   `Packages/WrappBuilder/Tests/WrappBuilderTests/` for decoding, the schema
   refusing a `volume-name` sign and a one-item `all-of`, and the
   `*.exe` problem. The warning is off until phase 3, or every bundle warns.
2. **The index evaluates signs.** `DetectionIndex.installedCopy`, with
   package tests in `DetectionTests.swift`: a sign matching, `all-of` needing
   every part, a sign a folder down not matching a top-level glob, a sign
   never making `detect` recognise a program, and the most specific of two
   bundles' matches winning.
3. **The switch.** Migrate every bundle (above); change
   `GameDetector.isInstalledGame` and its call in `DiskWrappBuilder`; turn
   the warning on; update `WrappBuildError`'s doc comment and
   `docs/wrapp-build.md`'s step 3 to say the check is the bundles' `installed`
   signs. `InstalledGameDetectionTests` keeps its discs and installed folders
   and runs them against the shipped index; add a test that every bundle's
   signs match none of the ten committed disc layouts, and a non-Nancy Drew
   case (a folder with `ski32.exe` at its top refused as `freeware/skifree`,
   and with `Bioscopia.exe` as `tivola/bioscopia` once its sign is the
   `exe-version` one, with a fixture exe carrying that version string, or a
   `file-exists` until one exists). Then a disc integration run of one
   `Game.exe` game and one later game
   (`./sc test integration haunted-carousel`, `castle-malloy`) as the change
   touches the disc builder's flow.
4. **Narrowing, case by case** (each its own commit, each needing evidence):
   - the `Game.exe` games to `all-of` `Game.exe` and `Nancy.cid`, once each
     game's installed folder is seen to have `Nancy.cid` (White Wolf's and
     Haunted Carousel's do; a built wrapp's `drive_c` shows the rest);
   - Bioscopia's to its `exe-version`;
   - the error naming the program it found: `installedGameNotInstaller`
     carries the matched title, and the text says "This is <title>, already
     installed, …" with "choose its disc or its installer" in place of Her
     Interactive, as whole sentences in both string catalogs (AGENTS.md,
     "Text people see can be translated").

Phases 1 and 2 change no behaviour and can land on their own; 3 is the one
that does.

## Open questions, answered

1. **Explicit or derived?** Explicit: every bundle states `installed`, and
   the schema requires it.
2. **Programs whose installed copy is a fine input.** Turn one down only
   where giving it to the build would break the build. So the ScummVM Nancy
   Drew games (their disc stages copy the disc, or patch it with Her's
   patch installers, as they would an installed copy) and Lure of the
   Temptress say `installed: []`, and Ingenious too, which installs inside
   the emulated Mac. Every Wine disc game, whose build runs an installer,
   keeps its signs.
3. **Testing signs against real discs.** Yes: the disc layouts moved into
   the bundles.
4. **Download-only bundles.** Keep their signs.
5. **Her downloads.** Unchanged.

## As built

- **Layouts are in the manifest**, as `tests.layouts`, a list of `{ disc:
  "<edition>/<input>", installer, files }` and `{ installed: "<edition>",
  files }`, rather than a file of their own: the schema checks them with
  the rest, and a list, not a mapping keyed by `cd/disc-1`, because
  decoding camel-cases a mapping's keys. The ten disc layouts and three
  installed ones that were in `InstalledGameDetectionTests` are in their
  bundles (the White Wolf copy as its disc build installed it, the Castle
  Malloy one from Her's Windows download).
- **The checks are problems, not warnings**, made when bundles load: a
  `file-exists` sign naming only an extension, a layout naming no disc
  input or edition the bundle has, an installed copy none of the bundle's
  signs matches, and a sign matching the bundle's own disc
  (`ProgramBundleLoader.installedProblems`) or another bundle's
  (`installedSignProblems`, in `loadAll`). With `installed` required, the
  planned warning for a bundle that says nothing had nothing left to say.
- **A tie is every tied bundle.** `DetectionIndex.installedCopy` returns
  every bundle whose sign ties for most specific, and the error names the
  program only when one bundle matched: with ten `Game.exe` bundles, picking
  one would name the wrong game. The integration tests' installed-game
  check accepts the program's title or none.
- **`Manifest.installed` is optional in Swift** (`installedSigns` gives
  `[]`): the builder decodes manifests of its own for modules' stages
  (`BuildPlan`), which have none. The schema still requires it of every
  bundle.
- **The error** is `installedGameNotInstaller(title:)`, its text no longer
  naming Her Interactive.
- **Not narrowed:** the ten `Game.exe` games stay `file-exists: "Game.exe"`
  for want of each one's installed folder to check `Nancy.cid` against
  (only White Wolf's and Haunted Carousel's were to hand), and Bioscopia
  stays `file-exists: "Bioscopia.exe"`: its program's version strings are
  Macromedia Director's projector's ("Director 8 Shockwave Studio"), with
  nothing of Bioscopia's for an `exe-version` sign.
- `sc generate`, `GameCatalog` and its generated table are unchanged.
