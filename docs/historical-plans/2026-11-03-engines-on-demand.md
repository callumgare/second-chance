# Engines on demand: plan (draft, 2026-11-03)

_Post-implementation note, 2026-11-03, added by Claude (Claude Code) as the
plan was filed: its phases were implemented and merged, with DOSBox the first
engine added this way, but builds that run Wine, updates of old wrapps, and
DOSBox's first launch had not yet been tested on a second Mac. The
`prepared` hashes below were later joined by a new Wine release whose
preparation also adds the Rosetta fault fix Big Fish's games need. It follows
[2026-11-03-generic-programs.md](2026-11-03-generic-programs.md)._

Second Chance stops carrying Wine and ScummVM in its own app. It fetches the engine
a build needs, the first time a build needs it, keeps it in a cache, and copies it
into the wrapp. A wrapp still holds its own engine, so it stays standalone: it starts
offline, can be copied to another Mac, and keeps working after Second Chance
updates or its caches are cleared.

This comes before DOSBox, so a third engine is added the new way from the start.

## What is bundled today

Measured on a Debug build; a Release build is about the same apart from the
launcher.

| Part | Where it ends up | Size (unpacked) | Download |
| --- | --- | --- | --- |
| Wine (Sikarugir 10.0_8) | `WrappTemplate.app/Contents/SharedSupport/wine` | 750 MB | 166 MB tar.xz |
| Wineskin's frameworks (GStreamer, MoltenVK, `renderer/`, ICU, …) | `…/Contents/Frameworks` | 350 MB | 85 MB tar.xz |
| ScummVM 2026.3.0 (a universal binary, its `.dat` files, its own Sparkle) | `…/Contents/MacOS/scummvm`, `Resources/`, `Frameworks/Sparkle.framework` | 210 MB | 164 MB dmg |
| The launcher (WrappTemplate itself, the in-process helpers) | `…/Contents/MacOS`, `Frameworks/in_process_helpers.dylib` | about 20 MB | (built) |
| AutoIt (a build tool, run under Wine) | `Second Chance.app/Contents/Resources/autoit` | 39 MB | 17 MB zip |
| Her's patches | `Second Chance.app/Contents/Resources/downloads` | 11 MB | |

So Second Chance is about 1.5 GB, and about 1.3 GB of that is the engines. Every
build copies the entire template and then deletes the engine it doesn't use
(`cleanupUnusedEngine`, driven by `wine-files` and `scummvm-files`).

Some things already work on demand, and their patterns can be reused:

- Steam's client (`SteamClientCache`).
- The download source's `Downloader`, which checks each file's SHA-256, caches by
  that hash, resumes partial downloads and has fallback URLs.
- winetricks' `cnc_ddraw`, which the prefix set-up downloads from GitHub. A disc
  build's first prefix therefore already needs the internet, so going on demand
  doesn't take away offline first builds. (Check that this is true before relying
  on it.)

## Decisions (recommended)

1. **An engine is a module version's package.** In `module.yaml`, each entry under
   `versions` gains a `package`:

   ```yaml
   versions:
     - version: "10.0_8"
       package:
         prepared: "…"        # the hash of the prepared tree, which preparing must give
         sources:             # each checked by its sha256; the URLs only say where to look
           - sha256: "2a6b…"
             size: 166321980
             urls: ["https://github.com/Sikarugir-App/Engines/…/WS12WineSikarugir10.0_8.tar.xz", "<a Wayback copy>"]
           - sha256: "9fa1…"
             size: 84533420
             urls: ["https://github.com/Sikarugir-App/Wrapper/…/Template-1.0.11.tar.xz", "<a Wayback copy>"]
   ```

   Changing a package changes the module's folder, so it raises the module's
   release, as any change does today.

2. **The upstream downloads are fetched and prepared on the person's Mac; we
   host nothing** (revised 2026-11-03).

   The only step that needed Xcode's tools was `install_name_tool -add_rpath`,
   and it turns out to do nothing:
   - The built template's `bin/wine` has no `LC_RPATH`. The command fails and
     `|| true` hides the failure.
   - Wine finds its frameworks through `DYLD_FALLBACK_LIBRARY_PATH`, which
     `Wine.swift` sets. Only `wineserver` uses `@rpath` (for `libinotify`), and
     that path resolves too.

   Each of the other steps works on a stock Mac:
   - unpacking with `tar` (or mounting with `hdiutil`), then copying;
   - patching `winemac.so`, which is our own Swift: `patch-winemac.swift` moves
     into WineKit;
   - ad hoc signing with `/usr/bin/codesign`, which every macOS has;
   - trimming ScummVM to the files we use.

   A module version records two things:
   - the upstream files: their URLs (with Wayback copies as fallbacks), their
     SHA-256 and their size;
   - the hash of the tree once prepared.

   Preparing the engine on the person's Mac must produce that same hash. That keeps
   "every Mac runs the bytes we tested", and anything that went wrong while
   preparing fails the build rather than reaching the game. If ad hoc signatures
   turn out not to be byte-identical from one Mac to the next, the hash leaves
   them out.

   If an upstream download disappears, a copy of our own goes into the URL list.
   The format doesn't change. `sc engine prepare <module> <version>` runs the same
   code here and prints the hashes to put in `module.yaml`.

3. **The prepared tree.**
   - A folder in the store that mirrors a wrapp's `Contents/`, which is what the
     setup scripts' `TEMP_DIR` already is (`SharedSupport/wine/…`,
     `Frameworks/…`, `MacOS/scummvm`).
   - It contains its own file list at `Resources/engines/<module>.files`, replacing
     the template's `wine-files` and `scummvm-files`.
   - The layout stays mirrored, rather than moving to a self-contained
     `engines/<id>/` folder, for two reasons:
     - ScummVM must stay in the wrapp's `Contents/MacOS`, so that it runs under
       the wrapp's bundle identity (its Dock icon and name).
     - `winemac.so` finds the helpers through `@loader_path/../../../../../Frameworks`.
   - **Copies must keep extended attributes** (`ditto`, or a clone). Files that
     aren't Mach-O, such as the Windows DLLs under `Frameworks/renderer/`, keep
     their code signatures in extended attributes (`verifyTemplateSignatures`).
     Preparing signs them, and the store checks them as the template is checked
     today.

4. **The store.**
   - Packages are kept unpacked in `~/Library/Caches/SecondChance/engines/<sha256>/`,
     next to the layer store, with the archive in `Downloader`'s cache.
   - The store unpacks into a temporary folder, checks it, then renames it into
     place, so a half-unpacked engine is never used.
   - A file lock per package stops two builds running at once (as the integration
     tests do) from both unpacking the same engine.
   - It is a cache: if macOS purges it, the engine is downloaded again. Wrapps
     don't depend on it, because each holds its own copy (a clone on the same
     volume, so it costs no disk space there; a real copy across volumes, as the
     template copy is today).

5. **When it's fetched.**
   - At the start of a build: once the game has been detected and the plan says
     which modules it uses, and before the first step that needs Wine.
   - Progress shows as a build step in plain words ("Downloading what the game needs
     to run"), with the download meter that Steam's and the download source's
     downloads use.
   - With no connection and nothing cached, the build stops with a plain message
     saying it needs the internet the first time.
   - Optionally, the default Wine could be fetched in the background after Second
     Chance first starts, so a first disc build doesn't wait for it. See the open
     questions.

6. **Locks and updates.**
   - A carried module's `ModuleRef` gains `package` (its SHA-256).
   - `UpdatePlanner`'s rule for carried modules becomes:
     - a different package of the same version: swap the engine's files, with no
       prefix move;
     - a different version within the same major: swap the engine, then move the
       prefix (`wineboot -u`), as today;
     - anything else: a fresh build.
   - An update downloads the engine as a build does.

7. **More than one version becomes possible.**
   - Old versions stay listed and downloadable, so `USE wine@10` picks the newest
     version that hasn't been withdrawn.
   - A bundle can pin an exact version for a game that breaks on a newer Wine.
   - An update can keep a wrapp on the version it already has.
   - This is plan item 3045, which Porting Kit already does. Today it isn't
     possible, because only one Wine fits in the app.

8. **The template becomes the launcher alone**, about 20 MB in Release. With no
   engine left in it to delete, a build copies the launcher and then installs the
   engines its composition uses. `cleanupUnusedEngine` goes. The collision check
   (`check-output-collisions.sh`) moves to packaging time: no file of a package may
   be one of the launcher's.

9. **The layer cache.** The base layer and the prefix layer are keyed on each
   package's SHA-256 in place of the engine's `version` file. Raising a package
   therefore makes a fresh prefix by itself.

10. **Development and tests never need a published package.**
    - `sc wrapp build` and `sc test …` prepare what is missing before they start,
      so a test never waits on the network partway through.
    - `sc --on <host>` does the same on the remote Mac.
    - `sc release` refuses to release if a listed source's first URL no longer
      answers with its size (it checks this with a HEAD request).

11. **Licences.** We no longer redistribute Wine or ScummVM: the person's Mac
    fetches them from their makers. The wrapps still carry them, as they do
    today, along with their licence files.

## Phases

1. **Preparing in Swift, and `sc engine prepare`, for wine and scummvm.**
   - Port what the setup scripts do.
   - Check that a tree prepared here matches today's template file for file,
     including extended attributes.
   - Check that two Macs prepare the same hash.
   - Nothing is switched over yet.
2. **`EngineStore`.** It goes in `WrappBuilder`, the package that holds
   `Downloader`, and provides `ensure(module, version) → folder`. It covers
   downloading, verifying, unpacking atomically, the per-package lock, and
   progress. It gets unit tests against a local HTTP server, as `Downloader` has.
3. **Builds install from the store.**
   - `createBaseWrapp` copies the launcher and installs the composition's engines.
   - The layer keys change as decision 9 says.
   - `cleanupUnusedEngine` and the file lists in the template go.
   - Every source's integration test on `<host>` passes, with a cold store and a
     warm one.
4. **The template drops the engines.**
   - Remove the `setup-wine.sh` and `setup-scummvm.sh` build phases. Their work now
     lives in `sc engine package`.
   - Anything that reads the template's Wine reads the store instead:
     `WindowsExecutableTests` uses explorer.exe from it, and WrappPuppeteer might
     too.
   - Check that the size of Second Chance and of its Sparkle update both drop.
5. **Updates.**
   - The lock records each package.
   - The planner swaps the engine as decision 6 says.
   - The launcher becomes a module of its own (see "The launcher as a module"
     below).
6. **Release checks and docs.**
   - `sc release`'s check that the sources still answer.
   - Docs: a section in `docs/modules.md` on packages, and changes to
     `docs/wrapp-build.md`'s build steps and layer cache. Rows in AGENTS.md; the
     `setup-wine.sh` mentions in AGENTS.md and the docs change.
   - Once implemented, this plan goes into `docs/historical-plans/`.
7. **Then DOSBox.** A DOSBox Staging package, and a native `dosbox` module with
   runtime, build and test parts and a `launcher` value. The candidate for it is
   Tyrian 2000 or Wolfenstein 3D's shareware.

AutoIt and Her's patches could follow later the same way. Both are only used
during a build, so they need no update logic at all. Leave them until the engines
work.

## The launcher as a module

The launcher becomes an implicit module that every composition has.

- **Its version** is a hash of the launcher's files, written into the template at
  build time.
- **It is not `builtBy`.** Every release of Second Chance changes `builtBy`, even
  when the launch code hasn't changed, and then every update would find something
  to do.
- **Its default update** replaces the wrapp's shell (`MacOS`, our `Frameworks`, the
  runtime's `Resources`) and keeps `SharedSupport`. That takes seconds and runs no
  Wine.
- **Old locks.** A lock with no launcher entry counts as behind.

Things to check:

- whether the built launcher's files hash the same from build to build. Hash them
  with their code signatures removed. If they still differ, hash the build's
  inputs instead;
- that a Debug build gets its own value, so it never matches a release.

## Decided

- **Caches**, not Application Support (2026-11-03). Packages that no listed
  version uses any more are removed.
- **Hosting**: none. The upstream files are fetched (decision 2).
- **Nothing is fetched ahead** (2026-11-03). An engine is fetched only when a
  build needs it. With many engines and versions to come, fetching any of them
  in the background doesn't scale. The optional background fetch in decision 5
  is dropped.

## Open questions for you

None at the moment.

## Updates beyond engines (discussed 2026-11-03)

- **An update with nothing to apply** shows an alert saying the app is up to
  date, with two choices: reinstall from scratch, or cancel.
- **Discs.**
  - The planner works out before anything runs whether any step in the update
    reads a disc. If none does, it never asks.
  - If one does, the person is told at the start that the update needs their
    discs.
  - Each disc is asked for only when it is about to be copied, as the disc
    builder already does (disc 2 is asked for once disc 1 is copied). Asking for
    both up front would let someone swap disc 1 out before it was read.
  - Every disc is copied before any step changes the game, so cancelling at a
    disc prompt leaves nothing half done.
- **A fresh build goes to its source's builder.**
  - `UpdateWrappBuilder` doesn't call another builder. It returns "fresh build
    from <source>", and the ViewModel, which already dispatches through
    `WrappBuildStrategy`, routes it with an input made from the old app's
    settings.
  - Steam needs nothing from the person: the game slug and launch mode come from
    the old app, and the shared sign-in (or its usual sign-in flow, if it has
    expired) does the rest.
  - The download source needs nothing either.
  - A disc or a Her download leads to the "reinstall from scratch" alert, which
    asks for it.
  - The output replaces the old app in place, and the person's saves stay where
    they are, since they live outside the app under its bundle id. Check this for
    a Steam game.
