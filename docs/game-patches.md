# Game patches

Her Interactive published free patches for many of the classic games — fixes for
crashes, softlocks, and puzzles that could not be completed. They are Windows
patchers written for a real Windows install, and Second Chance applies them
inside the wrapp at build time so a finished game app arrives already patched.

The catalogue is scraped from Her Interactive's
[game patches page](https://www.herinteractive.com/support/game-patches/).

## The manifest is the source of truth

Everything about patches lives in one file:
[WrappTemplate/game-patches.json](../WrappTemplate/game-patches.json). Two very
different consumers read it, which is the whole point of the format:

| Consumer | When | What it does with it |
| --- | --- | --- |
| [setup-game-patches.sh](../WrappTemplate/setup-game-patches.sh) | Building Second Chance | Downloads each archive, caches it, stages it in the app bundle |
| [GamePatchCatalog.swift](../SecondChance/Services/GamePatchCatalog.swift) | Building a wrapp | Decides which patches apply to this game and edition |

**Adding a patch means editing the manifest, not the script or the Swift.**

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
  "payload": "HAU 1.1 patch.exe",   // the single file inside the archive
  "action": "run-installer",        // or "copy-into-game-dir"
  "edition": "cd",                  // "any" | "cd" | "digital-download"
  "automatic": true,                // false = listed but never auto-applied
  "fixes": "…",
  "sourceUrl": "https://…"          // the page documenting this patch
}
```

`payload` is named explicitly rather than discovered, because the filenames
follow no pattern worth guessing at: `cur-full.exe`, `sha-full.exe`,
`IceUpdater1.1.2.exe`, `HAU 1.1 patch.exe`, `DecodePuzzle_SC.cif`. An earlier
version of this code looked for exe files whose name contained `"patch"`, which
matched five of the twenty-three and silently copied the rest into the game
folder without ever running them.

### `action`

- **`run-installer`** — the payload is a Windows installer. It is staged next to
  the game and run under Wine. Twenty-two of the twenty-three patches are this.
- **`copy-into-game-dir`** — the payload is a data file to drop into the game
  directory, optionally under `destinationSubdirectory`. Only Tomb of the Lost
  Queen's decode-puzzle fix works this way; it is a `.cif` that belongs in
  `Ciftree`.

### `edition`

Her Interactive shipped **separate CD and digital-download builds** of some
patches, and the wrong one does nothing useful. The catalogue maps the wrapp's
`WrappSource` onto the edition:

| `edition` | Applies to |
| --- | --- |
| `any` | every source |
| `cd` | `.disk` |
| `digital-download` | `.herDownload`, `.steam` (Steam copies are digital builds, not pressed discs) |

Castle Malloy and White Wolf of Icicle Creek each have both, so exactly one is
picked per build. There is a unit test asserting precisely that.

### `automatic`

`false` means the patch is downloaded and bundled but never applied on its own.
Three reasons a patch is marked opt-in:

- **Puzzle solvers.** `haunted-mansion-bird-inlay-solver` and `ghost-dogs-cola-solver` mark a
  puzzle as already solved. Her Interactive's own pages say in capitals not to
  install them unless you cannot solve the puzzle yourself — applying them
  automatically would quietly remove a puzzle from the game.
- **Difficulty tweaks.** `stay-tuned-senior-detective-timer` grants more time on
  Senior Detective, and `deception-island-clamming` lets the clam bucket be handed in early.
  These are preferences, not defects.
- **Superseded updaters.** `white-wolf-isis-command-box` is ICE Updater 1.0.1, older
  than the 1.1.2 that ships as the automatic CD patch. Applying it afterwards
  would roll the game back.

Manifest order is applied order, so where a game has several updaters the newer
one is listed first and an older one can never overwrite it.

## Build time: downloading and staging

The `Download And Copy Game Patches` build phase runs
`setup-game-patches.sh`, which for every manifest entry:

1. Downloads the archive to `~/Library/Caches/SecondChance/game-patches/<game>/`,
   skipping anything already cached, so rebuilds do not re-fetch ~10 MB.
2. Copies it into the bundle at `Contents/Resources/game-patches/<game>/`.
3. Copies the manifest itself to `Contents/Resources/game-patches/manifest.json`,
   which is what `GamePatchCatalog` reads at runtime.

The bundle directory is rebuilt from scratch each time, so a patch removed from
the manifest does not linger in an incremental build.

**A failed download never fails the build.** The script reports it and exits 0.
The resulting Second Chance simply ships without that patch, and the applier
treats a missing archive as a patch failure like any other. Second Chance
building is more important than any one patch being present.

## Wrapp build time: applying

`GameInstallerRunner.applyGamePatches` runs after the game's own installer has
finished and the game exe has been located, from **both** engine paths.

For each applicable patch, in manifest order:

1. Unzip the bundled archive to a temp directory.
2. Find the payload by its exact manifest name.
3. Either copy it into the game directory, or stage it there and run it under
   Wine.
4. Remove a staged installer afterwards, so the game directory is left as it was
   found — patched, but without a stray Windows exe in it.

Copies overwrite rather than fail, so rebuilding a wrapp is idempotent.

### Installers are run silently, and on a timer

There is no recorded `.iss` answer file for patches the way there is for the
game installers, so `silentPatchArguments` uses the generic silent flags for
whichever installer family `detectInstallerType` reports — `/s /sms` for
InstallShield, `/verysilent /norestart` for Inno Setup, `/qn` for MSI.

If an installer ignores those and puts up a wizard, nothing would ever answer
it. **Wine execution in this codebase has no timeout of its own**, so a patch
installer showing a dialog would hang the build forever. `runPatchInstaller`
therefore races the Wine call against a 180-second sleep, and on timeout kills
the prefix's wineserver — cancelling the Swift task alone does not stop a
Windows process. The patch is then reported as failed.

### Failure is not fatal

A patch that fails routes through `confirmPatchFailure`, the same seam described
in [wrapp-build.md](wrapp-build.md): the GUI asks whether to continue, and
headless runs continue without prompting, because a modal alert under a
`.prohibited` activation policy would be invisible and hang the build. Only an
explicit "don't continue" turns a patch failure into a cancelled build.

## The catalogue

| Game | Patch | Edition | Applied | What it fixes |
| --- | --- | --- | --- | --- |
| Secrets Can Kill | `secrets-can-kill-flower-puzzle` | any | automatic | Corrects the flower puzzle in Aunt Eloise's safe. |
| Stay Tuned for Danger | `stay-tuned-cabinet` | any | automatic | Clicking Mattie's cabinet wrongly sends the player to Dwayne's office. |
| Stay Tuned for Danger | `stay-tuned-senior-detective-timer` | any | **opt-in** | Grants more time for puzzles on the Senior Detective difficulty. |
| Message in a Haunted Mansion | `haunted-mansion-full` | any | automatic | Resolves multiple freezes and assorted CSound errors. |
| Message in a Haunted Mansion | `haunted-mansion-bird-inlay-solver` | any | **opt-in** | Marks the bird inlay puzzle as already solved. |
| The Final Scene | `final-scene-install-patch` | any | automatic | Closing Simone's purse with closed captioning off, a Modify/Repair/Remove prompt when Treasure in the Royal Tower is already installed, and being confined to the projector room on day 3. |
| Secret of the Scarlet Hand | `scarlet-hand-phone-monolith` | any | automatic | Freezes while on the phone or at the monolith. |
| Ghost Dogs of Moon Lake | `ghost-dogs-full` | any | automatic | Dead navigation arrows, exits while photographing birds, being unable to leave the journal, repeated bird-photo requests, and the bucket not leaving inventory. |
| Ghost Dogs of Moon Lake | `ghost-dogs-cola-solver` | any | **opt-in** | Marks the cola puzzle as already solved. |
| Danger on Deception Island | `deception-island-wood-csound` | any | automatic | Crash with a CSound/DirectSound error when talking to Casey about the wood samples. |
| Danger on Deception Island | `deception-island-clamming` | any | **opt-in** | Lets the clam bucket be handed in when not all clams can be found. |
| The Secret of Shadow Ranch | `shadow-ranch-full` | any | automatic | Zrender error during the campfire scene, a scene-stack error at the painting, and the fifth key vanishing before it reaches inventory. |
| Curse of Blackmoor Manor | `blackmoor-manor-full` | any | automatic | The cricket ball never being added to inventory, and the column key vanishing before it reaches inventory. |
| Last Train to Blue Moon Canyon | `blue-moon-taffy-sort` | any | automatic | Cursor freeze during the taffy sort puzzle. |
| The White Wolf of Icicle Creek | `white-wolf-updater-cd` | CD | automatic | Ned phone freeze, Guadalupe availability, S3/VIA Unichrome picture-in-picture, and slow end-game chase performance. |
| The White Wolf of Icicle Creek | `white-wolf-updater-download` | download | automatic | The digital-download build of the same four fixes as ICE Updater 1.1.2. |
| The White Wolf of Icicle Creek | `white-wolf-isis-command-box` | CD | **opt-in** | The Isis command menu staying on screen after saving with it open. |
| Legend of the Crystal Skull | `crystal-skull-mushroom` | any | automatic | Inventory showing only four mushrooms after five have been collected. |
| The Haunting of Castle Malloy | `castle-malloy-walk-in-place-cd` | CD | automatic | Nancy walking in place on the map early on, and the conversation with Kyler freezing later. |
| The Haunting of Castle Malloy | `castle-malloy-walk-in-place-download` | download | automatic | The digital-download build of the same two fixes as HAU 1.1. |
| Trail of the Twister | `trail-of-the-twister-doppler-radar` | any | automatic | Flickering or black screen on the Doppler cable puzzle with GeForce 2/4 MX cards. |
| Shadow at the Water's Edge | `waters-edge-recorder-tea-ceremony` | any | automatic | Being unable to delete recorder channels when all are full, and missing item labels during the tea ceremony. |
| Tomb of the Lost Queen | `lost-queen-decode-puzzle` | any | automatic | Letters A, F and N locked in the wrong position or duplicated in the Amateur Sleuth decode puzzle. |

## Caveats worth knowing

- **The early games run under ScummVM, but their patches are Windows
  installers.** Secrets Can Kill, Stay Tuned for Danger, Message in a Haunted
  Mansion, The Final Scene, Secret of the Scarlet Hand and Ghost Dogs of Moon
  Lake all use the ScummVM engine, yet Her Interactive only ever shipped
  Windows patchers, which rewrite the game's data files. Those data files are
  what ScummVM reads, so patching them is meaningful — and Wine is still in the
  wrapp at that moment, because `cleanupUnusedEngine` strips it one step later.
  This is why `installGameWithScummVM` applies patches at all, and it is the
  only window in which it can. These patchers were written to target a normal
  Windows install rather than the disk layout a ScummVM wrapp uses, so treat
  them as best-effort: the timeout and the failure path exist precisely because
  one may not find what it expects.
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

1. Add an entry to `WrappTemplate/game-patches.json`. Check what is actually
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
