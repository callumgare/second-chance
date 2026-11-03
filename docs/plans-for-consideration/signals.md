# Signals

Proposed 2026-11-03. **Not planned yet: build it when a program needs it.**
That will be when a game needs a program running beside it that no module
provides as a service (a helper, a licence server, a patched launcher), or
when a launch's progress needs judging by something other than its window
appearing.

It builds on work proposed with it, which isn't built yet either:

- `SERVICE` taking a program, where only a module's service programs can be
  services, as each knows when it's ready (`steam://client`, ready once
  signed in);
- `LAUNCH`;
- values read through namespaces in `${…}`, with functions;
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
  | `--process-has-window[=<pid>]` | the process has a window on screen |
  | `--output` with `--contains` or `--matches` | the program writes such a line to its output |
  | `--exits[=<code>]` | the program exits (with that code) |
  | `--<module>.<watch>` | a module's own, such as `--steam.signed-in` |

  `--contains` takes the text literally and `--matches` a regex. A `${…}`
  inside `--matches` is escaped, so a path's characters match themselves.
- **`--all` or `--any` is required with more than one `WATCH`**, so how the
  watches combine is always written. With one, neither is needed.
- **A signal reads the program it's used with through `${program.…}`**:
  `path`, `dir` and `name`, known when planning, and `pid`, known only at
  launch. The step using the signal provides `program`; nothing else does.
  An option that's about a program defaults to it: `--process-has-window`
  alone means `--process-has-window=${program.pid}`.
- **Launch-time values are filled in by the wrapp.** The planner substitutes
  everything known when planning, and records the rest as data the wrapp's
  watcher fills in when the program starts. A function can't be given one
  (functions run only when planning), and a build step can't use one.
- **Signals are defined in a Wrappfile, globally, or in a module**, and
  named like functions: `steam.signed-in`, `self.ready` in the module's own
  files. A local signal can't share a name with a module the stage uses.
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
    case processHasWindow(pid: LaunchValue)             // filled in when the program starts
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
   - Parsed and checked: watch options, `--all`/`--any`, `program` only
     where provided, and no launch-time value given to a function or used in
     a build step.
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
3. **Signals in steps before launch**, if those are built
   ([before-launch-steps.md](before-launch-steps.md)): a migration could wait
   on a converter's signal. Nothing needs it.
