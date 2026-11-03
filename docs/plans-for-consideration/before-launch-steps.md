# Steps before launch

Proposed 2026-11-03. **Not planned yet: build it when a program needs it.**
Nothing does today. That will be when a bundle's update first has to change
the person's files (a save format, a settings file) rather than the app.

It builds on the work proposed with it, which isn't built yet either: path
types (`wine:C:/…`, with short forms such as `C:/…`), a launch recorded in
the wrapp's settings from the Wrappfile's `LAUNCH`, and the `SERVICE`
instruction. If that work changes before this is taken up, this plan
changes with it.

## Why

The generic-programs plan
(`docs/historical-plans/2026-11-03-generic-programs.md`, draft 430) gives
`RUN --mount` a `volume` type: an update that has to change the person's
files mounts their volume into a build step, copied aside first, in a layer
that's never cached. Nothing has used it, it's being removed with the
module-extensions work, and it was the wrong place for that work:

- **Docker has no such thing.** Its build mounts are `bind`, `cache`,
  `tmpfs`, `secret` and `ssh`. Named volumes exist only when a container
  runs, and changes to existing data are made then: entrypoint scripts,
  migration jobs, init containers.
- **The files can change after the build.** The person can keep playing the
  old app while the new one builds, so a migration at build time runs on
  saves that aren't the last ones.
- **A build that fails partway leaves the files half-changed**, and a
  rebuild can run the change again.
- **The build may not run where the files are.** An app can be copied to
  another Mac, and the generic-programs plan keeps a command-line builder
  possible, which could run anywhere. The files belong to the Mac the game
  runs on.
- **It mixes two kinds of state.** Everything else a build touches can be
  reproduced and cached; the person's files can be neither.

So changes to the person's files are made by the app, before it starts the
game: Wrappfile steps the build records and the app runs.

## The shape

```dockerfile
BEFORE-LAUNCH --id=saves-to-documents --volume=wine-documents
  MOVE "C:/users/crossover/Documents/Nancy Drew/Saves" "C:/users/crossover/Documents/Nancy Drew/Saved Games"
  EDIT "C:/users/crossover/Documents/Nancy Drew/*.ini" --ini=Game.SavePath="Saved Games"
END
```

- **Each block has an id and runs once per volume.** The volume records the
  ids it has had, as databases record their migrations. A save folder
  restored from a backup, or copied from another Mac, gets whatever it's
  missing the next time an app opens it, whichever app built it.
- **It's safe by default:**
  1. the app copies the volume aside first;
  2. a failed step restores the copy, and the game isn't started;
  3. the person is told in plain words, and the failure is reported.
- **It changes only volumes.** The build owns the app, and these steps own
  the person's files. A path outside the block's volume is an error, so the
  app's own contents only ever change by rebuilding.
- **It's recorded like `LAUNCH`.** The planner takes the block out of the
  build's steps and the wrapp's settings carry it. It adds nothing to layer
  keys or caching.
- **The loading window shows it as a stage**, e.g. "Updating your saved
  games".
- **The name is a placeholder.** `BEFORE-LAUNCH` says when it runs.
  `MIGRATE` says what it's usually for, but is also Rails' word.

## Which instructions it allows

Each instruction, core or module, declares which phases it can run in:
build, before launch, or both. The checker enforces it inside the block.
That's the same kind of declaration as a path type's roles.

| Instruction | Before launch? | Why |
| --- | --- | --- |
| `COPY`, `MOVE`, `REMOVE`, `EDIT` | Yes | File changes the app can make itself, in plain Swift. |
| `RUN` (a program in an engine) | Later, when a game needs it | Possible, since the app runs Wine already, but slower, and it may need a display. It suits an old game's own save converter. |
| `ADD`, and `fetch` mounts | No | A launch must never need the internet. Anything a step needs is fetched by the build and kept in the app. |
| `FROM`, `USE`, `ARG`, `LAYER`, `EXPORT`, `COPY --from=<stage>` | No | They describe the build itself. Their effects (values, modules) are decided by the time the app runs. |
| Instructions that need an input (`installer.RUN`, `steam.INSTALL`, `wine.KEEP-DISCS`, `her-download.INSTALL`) | No | The disc or download isn't there at launch. |
| Other module instructions | If the module declares it | `wine.REGISTRY` could, but only where the registry is in a volume, under the rule above. |

## Modules

- **The modules available are the ones the app contains**: the final
  stage's modules. A ScummVM app can't `RUN` a Windows converter before
  launch, because Wine isn't in it. A bundle that needs that keeps Wine in
  its final stage, and ships it, so the cost is visible in the Wrappfile.
- **Paths and module instructions resolve as at build time**, through path
  types and the module's registration. A module's runtime facet
  (`RuntimeModule`) gains the ability to perform the operations it declared
  for this phase. Those declarations go in the shared WrappKit contract,
  beside the program registry.
- **Files from the bundle** (`COPY assets/new-defaults.ini …`) are copied
  into the app by the build, since the bundle isn't there at launch.

## Compiled to data, not code

There's no compiler on a player's Mac, so the block can't become Swift. It
doesn't need to: the planner already compiles it, with functions expanded,
`${…}` substituted, `IF`s decided and paths in their full form. The block
becomes a list of typed operations in the app's settings:

```swift
enum PrelaunchOperation: Codable {
    case move(from: String, to: String)            // full-form paths: wine:C:/users/…
    case remove(String)
    case copy(asset: String, to: String)           // a file the build copied into the app
    case editINI(file: String, settings: [String: String])
    case module(ModuleID, operation: String, arguments: [String: String])   // done by the module's runtime facet
}
```

The app knows those operations and nothing of Wrappfile syntax,
substitution, functions or module data. That is how the app already reads
everything else (`sc generate`'s Swift, the recorded launch). An app runs
the operations it was built with, using its own code, so the two can't
disagree.

## Where it comes in a launch

1. **Steps before launch**, against volumes no program is using. They can
   run behind the save warning, as module set-up does now
   (`GameLauncher.swift`, modules' `prepare`), since they don't depend on
   what the person picks there.
2. **Each module gets going, in start order**: Wine's desktop, then services
   such as Steam. Each waits for its own sign of readiness before the next
   starts, as today.
3. **The launcher starts the game.**

Why before the services:

- **A service may use the same files.** Steam Cloud syncs saves when Steam
  starts. A migration running at the same time would race it, and could
  leave saves half-changed or upload them mid-change.
- **A failure is simpler with nothing running.** The app restores the copy
  and doesn't start the game. A started service would have to be stopped
  first, and Steam takes a while to stop because it saves its sign-in.
- **Overlapping them saves little.** File operations take a moment; Steam's
  start is the slow part.

**The exception is `RUN`**, when it's allowed: a converter under Wine needs a
Wine session, and Wine's start is part of module preparation. So the module
that runs a step gets going first, but only that module, and services
still wait until the steps are done. That splits how modules start ("needed
by a step" before "services"), which is one reason to leave `RUN` out of
the first version.

## Rough phases

1. **The block and file operations.**
   - `BEFORE-LAUNCH … END` parsed and checked: allowed instructions, paths
     only in its volume, and its `--id` unique within the bundle.
   - Phases declared on instructions.
   - The planner compiles the block into operations, and the build records
     them.
   - The app runs them before modules prepare: copying the volume aside,
     restoring it on failure, and recording ids in the volume.
2. **`RUN` before launch, if a game needs it**, with the module that runs
   it starting first.

Verify with unit tests of the compiler and the runner (a volume in a
temporary folder), and an integration run updating a real app whose saves
need the change.

## Open questions

1. **Conditions inside the block.** A condition on a choice can be decided
   at build time. A condition on the Mac (`arch`, `macos`) is about the Mac
   that built the app, which may not be the one running it. The proposal is
   to forbid those inside the block until a game needs one, rather than add
   evaluation at launch.
2. **What "once" means.** Proposed: once per volume, recorded in the volume.
   That covers saves restored from a backup or copied from another Mac.
3. **Saves Steam Cloud holds.** If Steam downloads old-format saves after
   the steps have run, they arrive after the migration, and the volume's
   record says it's done. The migration could also cover what Steam brings
   down, or games whose saves Steam syncs could be barred from file
   migrations. It doesn't arise today, because a Steam-launched game's saves
   are in Steam's folders, not a volume.
4. **Steps before every launch**, not once, are a different thing, closer to
   a module's own set-up. Nothing needs one, so they're left out.
5. **The name**: `BEFORE-LAUNCH`, `MIGRATE`, or something else.
