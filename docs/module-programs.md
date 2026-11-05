# Module programs

A module someone adds can bring a **program** that carries out its
instructions, as a shipped module's executor does compiled in. This is how
it's written, how a build runs it, and how it's imported.

## What a module with a program is

```yaml
id: "someone/gog"
release: 1
program: "bin/gog-module"     # a Mach-O in the module's folder: its executor
versions: [{ version: "1" }]
build:
  instructions:
    INSTALL:
      options: { into: { kind: value, role: location } }
      required: [into]
      arguments: { count: 1, roles: [input] }
```

- **Its id is namespaced**, `<namespace>/<name>`, and never a shipped
  module's: a shipped module wins over an added one with its id, which is
  left out with a warning in the log.
- **Its program is a Swift package** of two targets: a library holding the
  executor, a `ModuleExecutor` as every shipped executor is, and an
  executable of one line, which is all that makes it a program:

  ```swift
  // Sources/gog-module/main.swift
  import WrappModuleKit
  import GOGModule
  try await ModuleProgram.serve(GOGModule())
  ```

  The executor is written against `WrappModuleKit` alone, so the same code
  could be compiled in.
- **It's built for both kinds of Mac**, arm64 and x86_64
  (`swift build --arch arm64 --arch x86_64`): a build runs on either.
- **It's a release like any other module's**: its folder, the program
  included, is hashed into its release, and the program's hash is part of
  every step key it carries out, so a new build of the program means fresh
  layers.

What an added module still can't do: add a path type, run in the wrapp or
in WrappPuppeteer, be a source, or prepare an engine. Its program runs only
during a build.

## How a build runs it

`ExternalExecutor` (`Packages/WrappBuilder/Sources/WrappBuilder/Runner/`) is
the program as the runner sees it: a `ModuleExecutor`, so keys, layers,
checkpoints and events work as for any other.

- **The program starts when a step first needs it**, and runs until the
  build's end (`finish`), then is ended if it hasn't stopped within 10 s.
- **They talk JSON-RPC 2.0**, one message a line on the program's stdin and
  stdout (`RPCConnection`, in `WrappModuleKit`). Its stderr goes to the
  build's log, a line at a time.
- **`hello` agrees a protocol version** (`ModuleProtocol.version`). A program
  newer than this build's is refused, saying to update Second Chance.
- **The build asks the program** what `ModuleExecutor` has: `keyInputs`,
  `run`, `checkpoint`, `finish`, each with the step (`RemoteStep`: the step,
  its tree's path, and which of `--alive`, `--done` and `--asks` it names).
- **The program asks the build** what `StepContext` has: `tree`, `file`,
  `moduleFile`, `input`, `inputIfGiven`, `ask`, `runProgram`, `fetch`,
  `store`, `watch`, `programWrote`, `programExited` and `onSignal`, answered
  by the step it's carrying out; `emit` and `log` are notifications. A
  signal the program asked to hear of comes back as a `signal` notification.
  `ModuleProgram.serve` gives the executor a `StepContext` that makes these
  calls, so it can't tell it from the runner's own.
- **Errors are JSON-RPC error objects**: `-32000`, a recipe problem, which
  becomes `StepFailure.recipe` (and `WrappBuildError.buildRecipeProblem`);
  `-32001`, the step failed; `-32800`, cancelled (LSP's code). Cancelling is
  LSP's `$/cancelRequest` notification, either way.
- **A broken pipe never ends the build**: writing to a program that has
  gone fails as an error rather than raising SIGPIPE.

## The sandbox

A module's program runs under `sandbox-exec` (`ExternalExecutor.sandboxed`):
it reads what the person can, but reaches no network itself and writes only
to the temporary folder, where the build's trees and session stores are,
the cache stores (`~/Library/Caches/SecondChance/stores/`) and its own
module's global kept stores. What it needs from outside it asks the build
for (`input`, `fetch`, `runProgram`), which the build does outside the
sandbox. So it can't change the person's files directly, but it isn't
contained: `fetch` fetches any URL it names (so data could leave in one),
and `runProgram` runs a Wine program with the network, its mounts not yet
held to the host path rule. Importing a module is still agreeing to trust
it (decision 10 of the builders plan); the sandbox narrows what a mistake
in one can do.

- **The profile names real paths**: `/private/var/folders/…`, not the
  `/var/folders/…` `FileManager` gives, or every write in the tree is
  refused (`realPath`, as `URL.resolvingSymlinksInPath` takes `/private`
  off again).
- **Tried on macOS 15 and 26** (2026-11-05, the builders plan's sandbox
  spike): the fixture program's step, `hello`, a write in the temporary
  folder and a read anywhere work; a write to the home folder and a
  connection out are refused. `sandbox-exec` is deprecated, but on both.
- **`SECOND_CHANCE_MODULE_SANDBOX=0`** runs programs unsandboxed, for
  finding whether the sandbox is what stops one. A Mac with no
  `sandbox-exec` runs them unsandboxed too, and the log says so.

## Where added modules live

`~/Library/Application Support/SecondChance/modules/<namespace>/<name>/`
(`AddedModules.folder`), moved with `SECOND_CHANCE_APP_SUPPORT_DIR` under
test, so a test never loads the person's. `ModuleLoader(root:added:)` loads
them after the shipped ones, and Second Chance's builds give each that has a
program an `ExternalExecutor` (`AddedModules.executors`, through
`ModuleSteps.executors`). One that doesn't load is left out and logged,
rather than stopping every build.

## Importing one

```bash
./sc module import <folder>
```

`AddedModules.import` checks the module's `module.yaml` against the schema,
that its id is namespaced and no shipped module's, and that its program, if
it has one, is an executable built for arm64 and x86_64 (`lipo -archs`) that
answers `hello` at a protocol this build speaks; then copies it in,
replacing one of its id.

## Testing

`ModuleProgramTests` runs a fixture program, `wrapp-module-fixture`
(`Packages/WrappBuilder/Tests/ModuleFixture/`, built with the package's
tests), through the runner out of process: its step asks the build for its
input and emits through it, and a recipe problem in it is the build's; and
the sandbox lets `touch` write in the temporary folder but not the home
folder.
`AddedModulesTests` imports and loads added modules, and refuses one built
for one architecture.

## Not built yet

- The importer's signed copy and its cdhash, and quarantine after
  agreement (decision 10 of the builders plan); the app's import window.
- Holding `runProgram`'s mounts to the host path rule.
- A JSON Schema of the protocol, generated from its types, and the test
  comparing its calls with `StepContext`'s and `ModuleExecutor`'s.
- Running each portable shipped executor out of process in a unit test.
- Answers for an added module's questions when nobody's there
  (`--answer`, `SECOND_CHANCE_ANSWERS`).
