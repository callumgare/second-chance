# Signals

> **Post-implementation note (2026-11-05, Claude for Callum):** the first
> phase's syntax and watcher are built, for builds, by the builders-into-modules
> plan: `SIGNAL`/`WATCH`, planned to data, a step's `--alive`/`--done`/`--asks`,
> `WATCH --grows` and `--wine.busy`, `EMIT --on`, and `${program.…}` known
> only as a step runs (not when planning, as below: `INSTALLER.RUN` chooses its
> installer as it runs). Still to build here: `SERVICE --ready`, `LAUNCH`'s
> events, and the wrapp's watcher ([wrappfile.md](../wrappfile.md#signals)).

Proposed 2026-11-03. **Not planned yet: build it when a program needs it.**
That will be when a game needs a program running beside it that no module
provides as a service (a helper, a licence server, a patched launcher), or
when a launch's progress needs judging by something other than its window
appearing.

It builds on work proposed with it, which isn't built yet either:

- `LAUNCH`, whose program's path type says which engine starts it;
- values read through namespaces in `${…}` (`${input.…}`, `${const.…}`),
  all known when planning;
- path types (`wine:C:/…`).

If that work changes before this is taken up, this plan changes with it.

## Why

A service has to be ready before the game starts: Steam signed in, or the
game's DRM finds nothing. Today each module knows how to tell, in Swift.
Letting a Wrappfile start any program as a service needs a way for the
Wrappfile to say what "ready" looks like, much as Docker's `HEALTHCHECK`
does for a container. Docker's check is one command run on a timer, though,
and what tells a Wine program is ready is usually something seen: a log
line, a file, a window, a process.

The same idea covers more than readiness. A launch's "started", "failed"
and "quit cleanly" are what the loading window and the quit watch work out
today, in Swift, the same way for every game.

## `SERVICE`

A program running beside the game while someone plays (a service) is
behaviour a reader should see on its own line, not in a flag on `LAUNCH`.
The work this builds on leaves it out, because nothing needs one yet (the
only one would be Steam running beside a game it doesn't start, which is no
longer built) and a service has to say when it's ready, which is what
signals are for. So it's designed here:

```text
SERVICE [--name=<id>] [--ready=<signal>] [--env NAME=<value>]… <program> [<argument>…]
SERVICE --remove <program or name>
```

- **It takes a program, as `LAUNCH` and `RUN` do**, under the same path
  type rules. Services start before the launch in the order written, and
  stop after it in the reverse order.
- **Each waits until it's ready before the next starts**: until its
  `--ready` signal, or, for a program a module registers as a service
  program (`steam://client`, ready once signed in), the module's own
  readiness check, which `--ready` can still override. A program with
  neither is an error, saying nothing would tell when it was ready.
- **Wine's desktop isn't a service.** It's how the wine module gets going
  (`WineDesktop`), and comes before any service.
- **Services build up and are inherited through `FROM`.** Unlike `LAUNCH`,
  later ones don't replace earlier ones.
- **`SERVICE --remove` takes one off**, named by its `--name` or its program
  in either form; removing one the stage doesn't have is an error.
- **A module taken out of the stage takes its services with it**:
  `STEAM.REMOVE` drops a `SERVICE steam://client`.
- **A launch's `--fallback` runs with the same services.**
- **It's recorded with the launch**, not a step, so it changes no layer
  key. `--env` on a service is refused for a secret input, as on `LAUNCH`.

## The shape

A signal is a named block of watches, defined once and used by name:

```dockerfile
SIGNAL helper-ready --all
  WATCH --process-has-window
  WATCH --log="${program.dir}/helper.log" --matches="Listening on"
END

SERVICE --ready=helper-ready "C:/Helper/helper.exe"
```

- **`WATCH` lines say what to look for.** Each is one kind of watch, written
  as its option:

  | Watch | Fires when |
  | --- | --- |
  | `--log=<path>` with `--contains="…"` or `--matches="…"` | a line written after the program started has the text, or matches the regex |
  | `--file=<path>` | the file exists |
  | `--process=<name>` | a process of that name is running |
  | `--process-has-window[=<name>]` | the program's process (or one of that name) has a window on screen |
  | `--output` with `--contains` or `--matches` | the program writes such a line to its output |
  | `--exits[=<code>]` | the program exits (with that code) |
  | `--<module>.<watch>` | a module's own, such as `--steam.signed-in` |

  `--contains` takes the text literally and `--matches` a regex. A `${…}`
  inside `--matches` is escaped, so a path's characters match themselves.
- **`--all` or `--any` is required with more than one `WATCH`**, so how the
  watches combine is always written. With one, neither is needed.
- **A signal reads the program it's used with through `${program.…}`**:
  `path`, `dir` and `name`, all known when planning. The step using the
  signal provides `program`; nothing else does. A watch that's about a
  process means the program's own unless told otherwise: the wrapp's
  watcher knows which process it started, so no pid is needed in the
  Wrappfile.
- **Signals are defined in a Wrappfile, globally, or in a module**, and
  named like functions: `steam.signed-in`, `self.ready` in the module's own
  files. A local signal wins over a module of the same name, with a
  warning, as a local function does.
  One defined and never used is a warning.
- **A signal's block is a scope** for `INPUT`, `CONST` and `VAR`, as a
  function's is.
- **There are no timeouts.** A signal that never comes is a launch that
  shows no sign of progress, which the loading window already notices and
  says, and which the build's stall watch notices for a build.

## Where signals are used

1. **`SERVICE --ready=<signal>`**, the reason to build this. A module's
   service programs keep their own readiness, which `--ready` can still
   override.
2. **`LAUNCH`'s events**, later: `--started=`, `--failed=` and
   `--quit-cleanly=` in place of the loading window's and the quit watch's
   generic judgement, for a game that needs its own. A game whose window
   comes up long after its splash's, say, or one that quits with exit code 1
   as normal.

   The Nancy Drew games from Ghost of Thornton Hall on are the second kind:
   they exit non-zero, and a line Her's engine writes to `Debug.LOG` says
   whether they quit cleanly. The work this builds on gives the wine module
   launch options for exactly that case, `--wine.clean-exit-log` and
   `--wine.clean-exit-line`, which those games' bundles write. With signals
   they become one:

   ```dockerfile
   SIGNAL nancy-drew-good-exit
     WATCH --log="C:/users/crossover/Documents/*/Debug.LOG" --contains="ExitInstance(), good exit..."
   END

   LAUNCH --quit-cleanly=nancy-drew-good-exit … "${const.install-dir}/Thornton.exe"
   ```

   The signal belongs in the nancy-drew module, as `nancy-drew.good-exit`,
   built from its `clean-exit-log.yaml`, and the two wine options go.
3. **A build step waiting for one**, perhaps: `RUN --done=<signal>` for an
   installer that never exits on its own, which AutoIt closes today.

## Signals and layer keys

A signal's definition isn't a step, so defining or changing one changes no
key. A build step that uses one has the signal written into its description
in full, its watches expanded, not only its name. So changing a signal
rebuilds what it changes at build time, and nothing else. A `SERVICE` or
`LAUNCH` is recorded with the launch, not hashed.

## Compiled to data

As with the rest of a launch, the wrapp never reads Wrappfile syntax. The
planner records each signal used at launch as data:

```swift
enum Watch: Codable {
    case log(path: String, pattern: LinePattern)        // full-form path; literal or regex
    case file(path: String)
    case process(name: String)
    case processHasWindow(name: String?)                // nil: the program's own process
    case output(pattern: LinePattern)
    case exits(code: Int32?)
    case module(ModuleID, watch: String, arguments: [String: String])
}

struct Signal: Codable {
    let combine: Combine                                // .all or .any
    let watches: [Watch]
}
```

The wrapp's watcher runs them with what it uses today: the log tails behind
the loading window's signs of progress, `ProcessList`, and the window checks.

## Rough phases

1. **`SIGNAL`, `WATCH` and `SERVICE --ready`.**
   - Parsed and checked: watch options, `--all`/`--any`, and `program` only
     where provided.
   - Planned into recorded signals, and the wrapp waiting on a service's
     signal.
   - Steam's readiness re-expressed as `steam.signed-in`, and Steam's
     service program using it, to prove the module path.
2. **`LAUNCH`'s events**, when a game needs one.
3. **Build steps waiting on a signal**, when an installer needs one.

Verify with unit tests of the parser, checker and planner, tests of the
watcher against a fake program writing a log, and an integration run of a
game with a service only signals can start.

## Open questions

1. **The names.** `SIGNAL` and `WATCH`, or `EVENT` and `WHEN`? Docker's
   `HEALTHCHECK` is a different thing (a command on a timer), so its name
   would mislead.
2. **Signals with their own inputs.** A module's signal might want a
   parameter (`steam.signed-in --account=…`). Proposed: a signal's `INPUT`s
   are given as options where it's used (`--ready=helper-ready,port=8080`
   reads badly; `READY helper-ready --port=8080` on its own line after the
   step reads better). Leave it out until one needs it.
3. **Values known only at launch**, such as the pid of a process the
   program starts. Nothing needs one yet.
4. **Signals in steps before launch**, if those are built
   ([before-launch-steps.md](before-launch-steps.md)): a migration could wait
   on a converter's signal. Nothing needs it.
