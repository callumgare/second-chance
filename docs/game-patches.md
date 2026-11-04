# Game patches

Her Interactive published free patches for many of the classic games — fixes for
crashes, softlocks, and puzzles that could not be completed. They are Windows
patchers written for a real Windows install, and Second Chance applies them
inside the wrapp at build time so a finished game app arrives already patched.

The catalogue is scraped from Her Interactive's
[game patches page](https://www.herinteractive.com/support/game-patches/).

## The manifest is the source of truth

Everything about patches lives in one file:
the nancy-drew module's
[patches.json](../Modules/nancy-drew/patches.json) ([modules.md](modules.md)),
checked against `patches.schema.json` beside it. Two very
different consumers read it, which is the whole point of the format:

| Consumer | When | What it does with it |
| --- | --- | --- |
| [setup-game-patches.sh](../WrappTemplate/setup-game-patches.sh) | Building Second Chance | Downloads each archive, caches it, stages it in the app bundle |
| [GamePatchCatalog.swift](../SecondChance/Services/GamePatchCatalog.swift) | Building a wrapp | Reads the patch a Wrappfile's `DO nancy-drew.patch` step names |

**Adding a patch means editing the manifest, and naming it in the Wrappfiles
of the editions it applies to; not the script or the Swift.**

The build script parses it with `plutil`, which reads JSON natively and ships
with macOS — so the build needs no `jq`, no Python, no extra tooling.

### Fields

```jsonc
{
  "id": "castle-malloy-walk-in-place-cd",   // unique; used in logs
  "game": "castle-malloy",        // must match a GameInfo.id
  "title": "Walk-in-place and Kyler freeze (CD)",
  "url": "https://www.herinteractive.com/wp-content/uploads/HAU-1.1-patch1.zip",
  "archive": "HAU-1.1-patch1.zip",  // filename as staged in the bundle
  "sha256": "…",                    // the archive's SHA-256, checked on download
  "payload": "HAU 1.1 patch.exe",   // the single file inside the archive
  "action": "run-installer",        // or "copy-into-game-dir"
  "fixes": "…",
  "sourceUrl": "https://…",         // the page documenting this patch
  "automation": "her-update-wizard" // optional: the AutoIt script that drives it
}
```

`payload` is named explicitly rather than discovered, because the filenames
follow no pattern worth guessing at: `cur-full.exe`, `sha-full.exe`,
`IceUpdater1.1.2.exe`, `HAU 1.1 patch.exe`, `DecodePuzzle_SC.cif`. An earlier
version of this code looked for exe files whose name contained `"patch"`, which
matched five of the twenty-three and silently copied the rest into the game
folder without ever running them.

### `action`

- **`run-installer`** — the payload is a Windows installer. It is put in the
  game's folder and run under Wine there. Twenty-one of the twenty-three
  patches are this.
- **`copy-into-game-dir`** — the payload is a data file to drop into the game
  directory, optionally under `destinationSubdirectory`. Only Tomb of the Lost
  Queen's decode-puzzle fix works this way; it is a `.cif` that belongs in
  `Ciftree`.
- **`extract-into-game-dir`** — the payload is a self-extracting zip, unzipped
  straight into the game directory (optionally under `destinationSubdirectory`)
  rather than run, since its dialog only asks where to put the files. Secret
  of the Scarlet Hand's phone/monolith fix is a WinZip self-extractor holding
  one `.CIF`, whose dialog offers `<game>\DataFiles`.

### Which patches apply

**A Wrappfile's `DO nancy-drew.patch --id=<patch>` is what applies one**,
in each edition's stage: the manifest only describes the patches. So an
edition has a patch because its stage names it, and none otherwise.
`TestFixtures/edition-patches.json` records which each disc and Her download
edition applies, and the tests check the Wrappfiles against it, so a patch
dropped or added is a change made there on purpose too.

- **CD and download builds.** Her Interactive shipped separate CD and
  digital-download builds of some patches, and the wrong one does nothing
  useful: Castle Malloy and White Wolf of Icicle Creek each have both, and
  each edition's stage names its own.
- **No patch applies to a Steam or Big Fish build.** Steam ships its own
  current build of each game, and Her's patchers refuse it: Shadow Ranch's
  says "This program cannot update the installed version of …". Big Fish's
  build is its own, wrapped in its DRM.

Some patches are listed but no Wrappfile names them:

- **Puzzle solvers.** `haunted-mansion-bird-inlay-solver` and `ghost-dogs-cola-solver` mark a
  puzzle as already solved. Her Interactive's own pages say in capitals not to
  install them unless you cannot solve the puzzle yourself — applying them
  would quietly remove a puzzle from the game.
- **Difficulty tweaks.** `stay-tuned-senior-detective-timer` grants more time on
  Senior Detective, and `deception-island-clamming` lets the clam bucket be handed in early.
  These are preferences, not defects.
- **Superseded updaters.** `white-wolf-isis-command-box` is ICE Updater 1.0.1, older
  than the 1.1.2 the CD edition applies. Applying it afterwards would roll the
  game back.
- **Nothing for a wrapp to gain.** `secrets-can-kill-flower-puzzle` is a 16-bit
  DOS self-extractor whose only file is a new `GAME.EXE`; the wrapp runs Secrets
  Can Kill under ScummVM, which never runs `GAME.EXE` (and the bundled Wine
  can't run 16-bit programs anyway). `final-scene-install-patch` only rewrites
  the uninstall registry entries and Start-menu shortcuts that clash when
  Treasure in the Royal Tower is installed too; it holds no game files.

Where a game has several updaters, its Wrappfile names the newer one first,
so an older one can never overwrite it.

## Build time: downloading and staging

The `Download And Copy Game Patches` build phase runs
`setup-game-patches.sh`, which for every manifest entry:

1. Downloads the archive to `~/Library/Caches/SecondChance/game-patches/<game>/`,
   skipping anything already cached, so rebuilds do not re-fetch ~10 MB. A
   download, or a cached copy, whose SHA-256 isn't the manifest's `sha256` is
   discarded (`download-verified.sh`, shared with the Wine, AutoIt and ScummVM
   downloads), so an error page or a re-uploaded file never ships. A new patch
   needs its hash: `shasum -a 256 <archive>`.
2. Copies it into the app's download cache, `Contents/Resources/downloads/`,
   named by its `sha256`: content-addressed, as a build finds what it
   downloads (`DownloadCache`), so a wrapp build downloads nothing Second
   Chance ships.

`GamePatchCatalog` reads the manifest from the nancy-drew module in the app's
resources (`Contents/Resources/Modules/nancy-drew/patches.json`). The cache
is rebuilt from scratch each time, so a patch removed from the manifest does
not linger in an incremental build.

**A failed download fails only a Release build.** In Debug the script reports
it and exits 0: the resulting Second Chance simply ships without that patch,
and the applier treats a missing archive as a patch failure like any other, so
a flaky download never stops development. A Release (`CONFIGURATION=Release`,
which `sc release` builds) must ship every patch, so there the script exits 1.

## Wrapp build time: applying

A patch is applied by the steps `DO nancy-drew.patch` expands to
(`Modules/nancy-drew/functions/patch`), ordinary steps the runner carries out
as it does any other ([wrapp-build.md](wrapp-build.md#the-runner)), in the
order the Wrappfile names the patches; each is named after its patch
(`--name=<id>`), which is how Second Chance publishes `patchApplied` and
`patchFailed` for it. The update source, which doesn't build through the
runner yet, carries them out with `GameInstallerRunner.runPatchStep`. The
step its `action` takes:

| Patch | Step | Carried out |
| --- | --- | --- |
| `copy-into-game-dir` | `ADD --checksum=… --unpack=zip --member=<payload> <url> <folder>` | The archive, found in the download cache by its hash, unzipped, and its member copied into the folder |
| `extract-into-game-dir` | the same, with `--extract` | The member, a self-extracting zip, unzipped into the folder |
| `run-installer`, no `automation` | `INSTALLER.RUN --patch --into=<folder> --mount=type=fetch,…,target=<folder>/<payload> <folder>/<payload>` | The payload put where its mount says, run silently as its installer type allows, in `--into`, and taken away. It isn't an install: nothing is looked for afterwards |
| `run-installer` with `automation` | `RUN --mount=type=fetch,… --mount=type=bind,source=assets/<script>.au3,… --mount=type=bind,source=module:installer:/autoit,… C:/autoit/AutoIt3.exe /ErrorStdOut C:/patch.au3 <payload>` | Each mount put at its target, AutoIt run with the script, and the mounts taken away |

- **A patch goes where its `--into` says**: the game's folder the Wrappfile
  names, not one worked out from where the exe was found.
- **What counts as success** is the program's exit code. The AutoIt scripts
  exit 0 only once the patcher says it updated the game. An Inno Setup
  patcher's `/LOG` must also say `Installation process succeeded.` (most
  patchers are self-extracting updaters with no log). A program is run by
  its Windows path (`C:\…`), and the run waits for the prefix's Wine
  processes to end, since a patcher can hand over to a program it unpacks
  and exit first (Her Interactive's patch stubs run `_upd1.exe`).
- **What a failure does** is the step's `--on-failure=ask`: it asks whether
  to carry on without the patch ([below](#failure-is-not-fatal)). A step
  without it fails the build.

Copies overwrite rather than fail, so rebuilding a wrapp is idempotent.

### Installers are run silently or through AutoIt, and on a timer

Most of Her Interactive's patchers have no silent mode: they are wizards that
wait for clicks. A patch whose manifest entry names an `automation` script is
run through AutoIt with that script from the nancy-drew module's `assets/`
(the patch function's `RUN` step), which clicks through the wizard and exits 0 only
once the patcher says the game was updated; anything else fails the patch, and
the script's log lines, which name each page it saw, are in the build log.
When a page stops changing for 60 seconds a script logs every visible window
(a message box the patcher raised is a window of its own), and when it gives
up it closes the patcher, which would otherwise keep the Wine session alive
until the build's wait for it times out. The scripts wait up to five minutes
for the wizard to appear and ten for it to finish: with every core busy, Wine
takes minutes to start a patcher that opens in seconds on an idle machine.
AutoIt is copied into the prefix for the run and removed afterwards.

| Script | Patchers | What it drives |
| ------ | -------- | -------------- |
| `update-installation-wizard` | Crystal Skull, Water's Edge, Trail of the Twister, Castle Malloy (both editions), White Wolf (CD) | An "Update Installation Wizard" that finds the game and patches on its own, then stops on a Finished page with a Close button; its Details pane lists each file backed up, updated or added. Castle Malloy's CD updater first asks for the game folder, which it can't find in the registry ("Folder \"(null)\" doesn't exist"), so the script fills in the folder the patcher runs from |
| `her-update-wizard` | Stay Tuned (cabinet), Haunted Mansion, Ghost Dogs, Deception Island (wood/C-sound), Shadow Ranch, Blackmoor Manor, Blue Moon (taffy sort) | A small stub that unpacks and runs an "Update Program" wizard (window class `UpdShClass`): Welcome, Information, Directory, Confirmation (Start), End, which says "has been successfully updated". Pages are told apart by their text, since only some builds name the page in the window title. The Directory box is filled from the game's registry entry, so for a ScummVM game (no installed copy) it is empty and the patcher would write to the root of `C:`; the script sets it to the folder the patcher runs from, which the build makes the game folder. A patcher still running 15 s after its End page (Blue Moon's shows a Clickteam Patch Maker advert after Exit) has its open windows logged and is closed, since it would otherwise hold the Wine session open until the patch timeout |

To probe a new patcher's dialogs without a screen, run it under AutoIt with a
script that logs `WinList()`, each window's `WinGetText` and its controls
after every step; that is how these pages were found. Pass AutoIt
`/ErrorStdOut`, or a script error becomes an invisible dialog and AutoIt exits
1 with no output. Querying every control of the Update Installation Wizard
crashed AutoIt there, so start with `WinGetText` and `WinGetClassList`.

Without an `automation` script, there is no recorded `.iss` answer file for
patches the way there is for the game installers, so `silentPatchArguments`
uses the generic silent flags for whichever installer family
`detectInstallerType` reports — `/s /sms` for InstallShield,
`/verysilent /norestart` for Inno Setup, `/qn` for MSI.

If an installer ignores those and puts up a wizard, nothing would ever answer
it, so a patcher gets the same time limit as any unattended install
(`SECOND_CHANCE_INSTALL_TIMEOUT`, 30 minutes by default). On timeout
`Wine.run` stops the prefix's wineserver — the only thing that
ends a Windows process — and the patch is reported as failed.

### Failure is not fatal

A patch that fails is reported (`FailureReporter.sendWithoutAsking`, tagged
with the patch's id, when the reporting setting sends without asking) and then
routes through the build's `WrappBuildInput.confirmPatchFailure`, the seam
described in [wrapp-build.md](wrapp-build.md), which the step's
`--on-failure=ask` reaches through the runner's question
(`StepQuestion.confirmStepFailure`, answered by `AppRunner`; it isn't state
on anything shared, since builds run side by side). `PATCH_FAILURE_POLICY=continue|cancel` answers it; otherwise the GUI
asks whether to carry on without the fix, naming what it fixes rather than why
it failed (a page of the main window, `BuildQuestion`), and headless runs
continue without prompting, as nobody is there to answer.
Only an explicit "don't continue" turns a patch failure into a cancelled
build. Cancelling the build while a patcher runs stops the build there; it
isn't counted as the patch failing.

Each patch publishes `.patchApplied` or `.patchFailed` on the bus (and a
`patch-failed` record in the headless progress file). The integration test
fails a game whose edition's patches didn't all apply, since the build itself
succeeds without them.

## The catalogue

| Game | Patch | Editions applying it | Applied | What it fixes |
| --- | --- | --- | --- | --- |
| Secrets Can Kill | `secrets-can-kill-flower-puzzle` | — | **no** | Corrects the flower puzzle in Aunt Eloise's safe. |
| Stay Tuned for Danger | `stay-tuned-cabinet` | disc and download | yes | Clicking Mattie's cabinet wrongly sends the player to Dwayne's office. |
| Stay Tuned for Danger | `stay-tuned-senior-detective-timer` | — | **no** | Grants more time for puzzles on the Senior Detective difficulty. |
| Message in a Haunted Mansion | `haunted-mansion-full` | disc and download | yes | Resolves multiple freezes and assorted CSound errors. |
| Message in a Haunted Mansion | `haunted-mansion-bird-inlay-solver` | — | **no** | Marks the bird inlay puzzle as already solved. |
| The Final Scene | `final-scene-install-patch` | — | **no** | Closing Simone's purse with closed captioning off, a Modify/Repair/Remove prompt when Treasure in the Royal Tower is already installed, and being confined to the projector room on day 3. |
| Secret of the Scarlet Hand | `scarlet-hand-phone-monolith` | — | **no** | Freezes while on the phone or at the monolith. ScummVM applies the same file itself. |
| Ghost Dogs of Moon Lake | `ghost-dogs-full` | disc and download | yes | Dead navigation arrows, exits while photographing birds, being unable to leave the journal, repeated bird-photo requests, and the bucket not leaving inventory. |
| Ghost Dogs of Moon Lake | `ghost-dogs-cola-solver` | — | **no** | Marks the cola puzzle as already solved. |
| Danger on Deception Island | `deception-island-wood-csound` | disc and download | yes | Crash with a CSound/DirectSound error when talking to Casey about the wood samples. |
| Danger on Deception Island | `deception-island-clamming` | — | **no** | Lets the clam bucket be handed in when not all clams can be found. |
| The Secret of Shadow Ranch | `shadow-ranch-full` | disc and download | yes | Zrender error during the campfire scene, a scene-stack error at the painting, and the fifth key vanishing before it reaches inventory. |
| Curse of Blackmoor Manor | `blackmoor-manor-full` | disc and download | yes | The cricket ball never being added to inventory, and the column key vanishing before it reaches inventory. |
| Last Train to Blue Moon Canyon | `blue-moon-taffy-sort` | disc and download | yes | Cursor freeze during the taffy sort puzzle. |
| The White Wolf of Icicle Creek | `white-wolf-updater-cd` | disc | yes | Ned phone freeze, Guadalupe availability, S3/VIA Unichrome picture-in-picture, and slow end-game chase performance. |
| The White Wolf of Icicle Creek | `white-wolf-updater-download` | download | yes | The digital-download build of the same four fixes as ICE Updater 1.1.2. |
| The White Wolf of Icicle Creek | `white-wolf-isis-command-box` | — | **no** | The Isis command menu staying on screen after saving with it open. |
| Legend of the Crystal Skull | `crystal-skull-mushroom` | disc and download | yes | Inventory showing only four mushrooms after five have been collected. |
| The Haunting of Castle Malloy | `castle-malloy-walk-in-place-cd` | disc | yes | Nancy walking in place on the map early on, and the conversation with Kyler freezing later. |
| The Haunting of Castle Malloy | `castle-malloy-walk-in-place-download` | download | yes | The digital-download build of the same two fixes as HAU 1.1. |
| Trail of the Twister | `trail-of-the-twister-doppler-radar` | disc and download | yes | Flickering or black screen on the Doppler cable puzzle with GeForce 2/4 MX cards. |
| Shadow at the Water's Edge | `waters-edge-recorder-tea-ceremony` | disc and download | yes | Being unable to delete recorder channels when all are full, and missing item labels during the tea ceremony. |
| Tomb of the Lost Queen | `lost-queen-decode-puzzle` | disc and download | yes | Letters A, F and N locked in the wrong position or duplicated in the Amateur Sleuth decode puzzle. |

## Caveats worth knowing

- **The early games run under ScummVM, but their patches are Windows
  installers.** Secrets Can Kill, Stay Tuned for Danger, Message in a Haunted
  Mansion, The Final Scene, Secret of the Scarlet Hand and Ghost Dogs of Moon
  Lake all use the ScummVM engine, yet Her Interactive only ever shipped
  Windows patchers, which rewrite the game's data files. Those data files are
  what ScummVM reads, so patching them is meaningful — and Wine is still in the
  stage that patches them: an edition whose game needs a patch copies the
  disc (or installs the download) and patches it in a Wine stage
  (`disc-files` in Stay Tuned's, Haunted Mansion's, Ghost Dogs'), then
  copies the patched data into a `scummvm` stage `FROM scratch`, which has
  no Wine. One with no patch copies the disc's data into the app as it is. These patchers were written to target a normal
  Windows install rather than the disk layout a ScummVM wrapp uses, so treat
  them as best-effort: the timeout and the failure path exist precisely because
  one may not find what it expects. A patcher that adds a file there puts it
  loose beside the CD's `data1.cab`, which also holds a copy; whether ScummVM
  prefers the loose one has not been checked.
- **Shadow at the Water's Edge is labelled "PC only".** Her Interactive's Mac
  build self-updates over the internet instead. A wrapp runs the Windows build,
  so the PC patch is the correct one.
- **The site's White Wolf page links the CD updater from its digital-download
  section.** Both "Attached File" links on the Isis command box page point at
  `IceUpdater1.0.1.zip`. The manifest records it as `cd` only.
- **Mystery of the Seven Keys (#34) is listed on the page but not here.** It is
  a Unity-era game, outside what Second Chance supports, and the page describes
  its fix in prose without offering a download link.
- **Secrets Can Kill's patch has no detail page.** The index links the archive
  directly, so `sourceUrl` points at the index rather than a per-patch page.
  The remastered edition is a different game (`secrets-can-kill-remastered`)
  and this patch does not apply to it.

## Adding or updating a patch

1. Add an entry to `Modules/nancy-drew/patches.json`, and raise the module's
   release ([modules.md](modules.md#releases)). Check what is actually
   inside the archive — every current one holds exactly one file — and set
   `payload` to that exact name.
2. Make sure `game` matches a real `GameInfo.id`. A typo means the patch is
   downloaded, bundled, and never applied; `GamePatchCatalogTests` fails on
   unknown slugs for exactly this reason.
3. Decide `edition` and `automatic` deliberately. If Her Interactive's page
   warns against installing it casually, it is `automatic: false`.
4. Rebuild. The manifest is a build-phase input, so changing it re-runs the
   download script.

`GamePatchCatalogTests` covers the manifest as data — unknown slugs, duplicate
ids, edition selection, and the opt-in patches staying opt-in. Run it with
`./sc test unit`; see
[testing.md](testing.md) for how the test suite is run and what the `unit`
filter does.
