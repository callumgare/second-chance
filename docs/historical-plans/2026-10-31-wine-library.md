# Plan: one Wine library, and reading Windows files without ExifTool

## What happened

_Added after implementation. Everything below this section is the plan as
it was approved._

Both parts landed as planned, Part B first.

**Part B.**

- **Measured before deciding (B2).** The parity check ran over 35 discs and
  the Scarlet Hand Her download, and was a scratch command-line tool rather
  than the temporary test suite planned. The native `ProductName` and
  `Comments` matched ExifTool's on all 80 top-level programs, and the native
  MSI `Subject` matched on all 11 MSIs.
- **`Subject` stayed.** It decides Castle Malloy, a disc with no `setup.exe`.
  Leaving it out also broke Seven Ships and Waverly Academy. So `MSISummary`
  was written, not dropped.
- **A dead lookup surfaced.** `GameDetector` had asked ExifTool for
  `"Product Name"`, with a space, which never returned anything. The native
  reader finds `ProductName`, so a `setup.exe`'s product name now reaches
  detection for the first time. Simulated over every disc, it changes no
  result.
- **ExifTool's removal** went in as `refactor`, not `fix`.

**Part A.**

- **Gates.** Each gated phase passed the representative set. In the set, Haunted
  Carousel stood in for "a DirectDraw disc game", because Royal Tower and
  Scarlet Hand turned out to be ScummVM games. The by-hand checks that need
  someone at the test Mac's screen weren't done: the debug menu's buttons,
  quitting from the Dock, and reopening while closing.
- **Small changes from the plan:**
  - The launcher logs under its own category, `WineProcess`, so its lines
    stay apart from Wine's own output (`Wine`).
  - `WineServer.shutDown` gained a `stopPeriod` parameter, so the tests don't
    wait 5 s at each step.
  - The winetricks tests live in `WineRegistryTests`.
  - `SteamLockHolder.quit` did need the fix: the holder now stops the session
    in the wrapp's own prefix and in its copy in Caches, when there is one.

**The full suite found a regression that the gates missed.** In it, The
White Wolf of Icicle Creek's silent install installed Nancy Drew Central
instead of the game, then exited 1. The interactive retry then waited 48
minutes for clicks that never came.

- **Where it wasn't.** A bisect with headless `sc wrapp build` passed at every
  commit, and so did a run from a cached prefix. The failure only happened
  under `xcodebuild test`.
- **The cause.** The old `runWine` started Wine through `/bin/sh`, and macOS
  strips every `DYLD_*` variable when starting that protected binary. The
  plan's claim that the shell "adds nothing" was wrong in exactly this way.
  Started directly, Wine inherited the test host's injected libraries and
  framework paths, and with those loaded this one installer went another way.
- **The fix.** `Wine.environment` now leaves out every inherited `DYLD_*`
  variable (`fix(wine): keep the test host's DYLD_ variables out of Wine`).
  Players were never affected, since nothing sets these variables outside a
  test.
- **Also corrected along the way.** The installer arguments that had been
  escaped for the shell now have single backslashes. Doubled ones turned out
  to be harmless.

**Results.**

- **Real Mac, every source, before the `DYLD_` fix:** 45 passed, 1 failed
  (White Wolf, above) and 20 skipped. The skipped are Steam games the test's
  Steam account doesn't own. With the fix, White Wolf passed its integration
  test.
- **VMs, macOS 15 and 26, after the fix:** every disc and Her download
  built. Direct3D games were `skipped`, as a VM can't draw them. Of the
  rest, Sequoia passed all but Danger by Design and Kapu Cave, and Tahoe
  all but Secrets Can Kill and five DirectDraw games, each ending the same
  way: WrappPuppeteer found the game's Exit button but its clicks never
  quit the game. Secrets Can Kill is a ScummVM game, with no Wine in it,
  and each game that failed in one VM passed in the other and on the real
  Mac, so these are put down to clicking inside a VM, not to Wine.
- **Steam, on the morning after.** In the Sequoia run every Steam build
  failed: Steam stalled (`CSteamEngine::BMainLoop appears to have
  stalled`, then `fatal stalled cross-thread pipe`) and exited before it
  signed in. It did the same without a VM, without the `DYLD_` fix,
  with a fresh prefix and Steam client, and at the commit the real-Mac
  run had passed hours before, so it came from outside the code. It was
  left to be looked into separately, and Steam was left out of the Tahoe
  run.

This plan has two independent parts.
- **Part A**: the Wine library (phases 1–6).
- **Part B**: replacing ExifTool with native readers (phases B1–B4).

They touch different files and can land in either order. Part B is smaller and lower risk,
so it can go first. The only shared piece is `Blocking`, which moves to `Shared/` in phase 1;
Part B works with it in either place.

# Part A: one Wine library — `Wine`, one launcher, and facades for the registry, winetricks and the server

## Context

Second Chance starts Wine from about 25 call sites. They are spread across three
targets (the app, `WrappTemplate`, and `Shared/` for both) and go through five
different mechanisms:

- `WineEnvironment.runWine`, through a `/bin/sh` `export … exec` script
- `runExecutable`, `runWindowsExecutableWithStart`, `startDesktop` and `queryDisplayDevices` in `WineEnvironment`
- `WineUtilities`' `wineserver` helpers
- `WineManager`'s wrappers around all of the above
- a hand-built `Process` in `SteamClient.run`

Each of these decides for itself the environment, stdin, pipes, logging,
timeouts, what an exit code means, and whether it blocks a thread or is `async`.
Some results of that:

- **An exit code round trip.** `runWine` throws `executionFailed`,
  `WineManager.runWindowsExecutable` catches it and returns an `Int32`, and
  `GameInstallerRunner.runInstaller` throws `WineError.executionFailed` again.
- **Registry writes are raw argument lists.** A write is a ten-element
  `["reg", "add", …, "/f"]` array.
- **Different `wineserver` calls behave differently.** `wineserver -k`/`-k0`/`-w` run in about a dozen places, with
  different logging and waits. Steam polls `-k0` once a second instead of
  waiting on `-w`.
- **Bugs.**
  - `runExecutable("winecfg")` looks for `wine/bin/winecfg`, which doesn't exist, so the
    debug menu's Wine Config can't work.
  - `SteamLockHolder.quit` checks the wrapp's default prefix even when the wrapp runs from a copied one.
  - `WineManager.startWineServer` is dead code.
  - A missing Wine shows the person an error with developer instructions in it.

We reviewed [WineKit](https://github.com/divadretlaw/WineKit) and won't adopt it.
It is built for bottle-manager apps, and its process layer misses things we
depend on: `runWithoutCrashHandler`, swift-log, line-by-line output, timeouts,
the stall watchdog, ending the session on cancel, and `wineserver -w`. We do
borrow its *shape*: one value for "this Wine and this prefix", with
`registry`, `server` and `winetricks` facades on it.

**Outcome**:

- **One launcher.** Every Wine, wineserver and winetricks process starts in one place,
  `Shared/Wine/WineProcess.swift`.
- **Async-first.** There is one `async` API. Code on a plain thread calls it through one bridge.
- **Facades.** Call sites read `wine.run(…)`, `wine.start(…)`, `wine.output(of:)`,
  `wine.registry.set(_:for:in:)`, `winetricks.install(_:)` and `wine.server.shutDown(gracePeriod:)`.
- **Behaviour is unchanged**, except for the bugs above, which get their own `fix:` commits.

**Decisions made**:

- `WineEnvironment` is renamed to `Wine`.
- Every call site moves to the new API, including the wrapp's launch and quit paths and Steam.
- Each risky phase is gated on a representative set of integration runs on a test Mac,
  with the full suite once at the end.

---

## Design principles (and why they're the Swift way here)

1. **Async-first, with one bridge.** Every operation that waits on Wine is `async`.
   That gives cancellation through structured concurrency, which the build already relies on. The
   wrapp's GCD threads and `main()` call async code through one bridge, `Blocking.wait { … }`:
   - It is promoted from `WrappSteam`'s private `wait`/`waitThrowing` into `Shared/Blocking.swift`.
   - `Blocking.run`, which goes the other way, moves to the same file from `SecondChance/Utilities`.
   - The rule is documented on it: call it only from a thread that isn't part of Swift's
     concurrency pool, never from inside an `async` function. The work it waits on must not need the main actor.

   This replaces a pair of `run`/`runAndWait` signatures that would drift apart.
2. **Failures are errors.** A non-zero exit always throws
   `WineError.executionFailed(exitCode:)`. A caller that turns it into its own error catches that
   case, so there is no `exitCode: .returned` flag and no `Int32` round trip.
3. **Labels that read as English** (the API Design Guidelines):
   - `registry.set(.string("Y"), for: "EmulateModeset", in: .x11Driver)`
   - `server.waitUntilStopped(timeout:)`, which echoes `Process.waitUntilExit()`
   - `wine.output(of:)`, which echoes the existing `Process.output(of:)`
4. **Named values over raw strings.** `WineRegistry.Key` is a `RawRepresentable` struct,
   `ExpressibleByStringLiteral`, with static constants, like `Notification.Name`.
   `Winetricks.Verb` is an enum of the verbs we use, not WineKit's 1,267 generated ones.
5. **Callbacks, not `AsyncStream`, for output lines.** The game's line observers
   (diagnostics, the quit check, the helper report, launch activity) must see every line
   synchronously and in order on the pipe's reader queue, which is what `ProcessLineLogger` gives.
   An `AsyncStream` would need a consumer task and buffering policy for no gain.
6. **`Wine` is a value; the facades are views of it.** `wine.server` and `wine.registry`
   are cheap structs holding a copy of `wine`, as in WineKit. No singletons.

---

## The API when done

```swift
// Shared/Wine/Wine.swift (was WineEnvironment.swift; paths and environment only)
nonisolated public struct Wine: Sendable {
    public init(wrapp: URL, prefix: URL? = nil)      // was init(appPath:customPrefixDir:)
    let binDir: URL, prefix: URL, wineDir: URL, frameworksDir: URL
    var isBundled: Bool                              // false for a ScummVM wrapp
    public var variables: [String: String]           // was wineSpecificEnvironmentVariables()
    public var environment: [String: String]         // was environmentVariables(): ours over the parent's
    public var shellExports: String                  // `export K='v'` lines + PATH, for the debug shell and the log
    public var server: WineServer { WineServer(wine: self) }
    public var registry: WineRegistry { WineRegistry(wine: self) }
    public static let username = "crossover"         // was wineUsername
}
// Shared/Wine/Wine+WrappVariables.swift: the same statics, moved out of the core file:
// inProcessHelperVariables(gameExe:), wrappSessionVariables(), puppetDirectory(), defaultWineDebug

// Shared/Wine/WineCommand.swift: what to run, separate from how
public struct WineCommand: Sendable, Equatable {
    static func wine(_ arguments: [String]) -> Self                       // wine reg …, wine control, wine explorer.exe /desktop
    static func program(_ exe: String, _ arguments: [String] = []) -> Self // wine <exe> args
    static func start(_ exe: String, _ arguments: [String] = [],
                      unixPath: Bool = true, in directory: URL? = nil) -> Self  // wine start /wait [/unix] exe
    static func wineserver(_ arguments: [String]) -> Self
    static func script(_ script: URL, _ arguments: [String]) -> Self      // /bin/bash script, in Wine's environment
    var displayName: String                     // was WineEnvironment.displayName: "wine setup.exe"
    func commandLine(in wine: Wine) -> String   // was reproductionCommand / formatLaunchCommand
}

// Shared/Wine/WineProcess.swift: the ONE place a Process is built for Wine
public enum WineOutput: Sendable {
    case log(Logger = .wineOutput, onLine: (@Sendable (String) -> Void)? = nil)  // default
    case terminal     // inherit our stdio: the `wine` pass-through and the debug commands
    case discard
}
public enum OnTimeout: Sendable { case stopSession, stopProgram }  // stopSession = wineserver -k, as runWine does today

extension Wine {
    /// Wait for it, logging ▶/…/■ (SubprocessWatch). Throws `executionFailed`, `terminatedBySignal`,
    /// `timedOut`, `stalled` or `noDisplay`, or `CancellationError` (cancelling ends the session, as today).
    func run(_ command: WineCommand, environment: [String: String] = [:],
             timeout: TimeInterval? = nil, onTimeout: OnTimeout = .stopSession,
             watchdog: WineWatchdog? = nil, output: WineOutput = .log()) async throws
    /// Run it and return what it printed: captured to a temp file, never a pipe, because Wine's
    /// services hold pipes open. Lines still go through NoDisplaySignal. ▶/■ logged at .debug.
    func output(of command: WineCommand, timeout: TimeInterval? = nil,
                onTimeout: OnTimeout = .stopProgram) async throws -> String
    /// Don't wait: the game, Steam, the desktop.
    func start(_ command: WineCommand, environment: [String: String] = [:],
               output: WineOutput = .log()) throws -> WineProcess
}

/// @unchecked Sendable: wraps a Process (not Sendable), which is only touched through thread-safe calls.
public final class WineProcess: @unchecked Sendable {
    public var pid: Int32 { get }; public var isRunning: Bool { get }
    public let process: Process                       // escape hatch for GameMonitor, like TaggedProcess.process
    public func terminate(); public func kill()
    public func waitUntilExit(timeout: TimeInterval?) async -> SubprocessWatch.Outcome?   // nil on timeout
}

// Shared/Wine/WineRegistry.swift
public struct WineRegistry: Sendable {
    public struct Key: RawRepresentable, ExpressibleByStringLiteral, Sendable {
        static let x11Driver: Key = #"HKCU\Software\Wine\X11 Driver"#
        static let wineDrives: Key = #"HKLM\Software\Wine\Drives"#
        static let videoDeviceMap: Key = #"HKLM\HARDWARE\DEVICEMAP\VIDEO"#
    }
    public enum Value: Sendable { case string(String), dword(UInt32) }
    func set(_ value: Value, for name: String, in key: Key, timeout: TimeInterval = 600) async throws
    func importFile(atWindowsPath path: String, timeout: TimeInterval) async throws
    func values(in key: Key, timeout: TimeInterval) async throws -> String   // reg query; a timeout ends reg only
}

// SecondChance/Services/Winetricks.swift (the app only: winetricks ships in Second Chance.app)
struct Winetricks {
    enum Verb: String { case cncDdraw = "cnc_ddraw", isolateHome = "isolate_home" }
    init(wine: Wine, script: URL? = Bundle.main.url(forResource: "winetricks", withExtension: nil))
    func install(_ verb: Verb) async throws
}

// Shared/Wine/WineServer.swift (absorbs WineUtilities and Wine's server calls)
public struct WineServer: Sendable {   // without a bundled Wine: isRunning is false, the waits return true, the stops do nothing
    var isRunning: Bool { get async }                                         // -k0
    @discardableResult func stop() async -> Bool                              // -k
    func kill() async                                                         // -k9
    func waitUntilStopped(timeout: TimeInterval) async -> Bool                // -w, bounded
    func onStop(_ handler: @escaping @Sendable () -> Void) -> WineProcess?    // -w in the background; terminate() to cancel
    @discardableResult func shutDown(gracePeriod: TimeInterval = 5) async -> Bool  // -w → -k → -k9 (was waitTillWineserverStopped)
    func waitUntilProgramsExit(timeout: TimeInterval?, watchdog: WineWatchdog?) async throws  // -w as a logged, stall-watched run
}

// Shared/Blocking.swift (moved: Blocking.run from SecondChance/Utilities, and WrappSteam's wait)
nonisolated enum Blocking {
    static func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T        // sync work, from async code
    static func wait<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T  // async work, from a plain thread
}
```

Rules the code keeps:

- **What stays where.** `WineDesktop` keeps its behaviour, but `start` becomes `async`, using
  `Task.sleep` and `wine.registry.values(in:)`. `GameQuitCheck`, `InProcessHelperReport` and
  `GameGraphicsAPI` are untouched.
- **Shared code.** `ProcessLineLogger`, `SubprocessWatch`, `NoDisplaySignal`, `WineWatchdog`,
  today's `WineEnvironment.wait` (which becomes `WineProcess`'s internal wait) and
  `InheritedExceptionPorts` are reused as they are.
- **The launcher's guarantees.** It always:
  - starts the process with `runWithoutCrashHandler()`
  - sets stdin to `/dev/null`, except for `.terminal`
  - attaches `pid`/`program` metadata to every output line
  - waits for EOF for at most 5 s.
- **`binDir` stays internal.** A new SwiftLint rule, `wine_path_outside_library`, rejects `\.binDir\b`
  outside `Shared/Wine/`. The debug shell and the log's "run it by hand" lines use
  `wine.shellExports`/`commandLine(in:)` instead. `wine_without_crash_handler` stays.
- **Not covered.** `TaggedProcess` (ScummVM) and the `WrappPuppeteer` cleanup commands are
  not Wine-library users. The cleanup commands must stay raw argv for its
  signal handler's `posix_spawn`, so this plan leaves them alone.

---

## Phase 1: Rename to `Wine`, split the file, move `Blocking` (mechanical)

- **Rename the file and type.** `Shared/Wine/WineEnvironment.swift` becomes `Shared/Wine/Wine.swift`, and the type becomes `Wine`.
- **Rename the members:**

  | Was | Becomes |
  |---|---|
  | `init(appPath:customPrefixDir:)` | `init(wrapp:prefix:)` |
  | `prefixDir` | `prefix` |
  | `wineBinDir` | `binDir` |
  | `wineSpecificEnvironmentVariables()` | `variables` |
  | `environmentVariables()` | `environment` |
  | `wineUsername` | `username` |
- **Split the rest out:**
  - the wrapp-variable statics into `Wine+WrappVariables.swift`
  - `WineError` into `WineError.swift`
  - `WineWatchdog`/`WineWatchdogVerdict` into `WineWatchdog.swift`
- **Move the bridges.** Move `Blocking` from `SecondChance/Utilities/ProcessUtilities.swift` to
  `Shared/Blocking.swift`, and add `Blocking.wait`, lifted from `WrappSteam`'s private
  `wait`/`waitThrowing`. `WrappSteam` then calls the shared one.
- **Update every reference.** About 30 sites: `SteamClient`, `SteamLockHolder`,
  `SteamSessionStore`, `GameLauncher`, `main.swift`, `WrappBuildHelper`,
  `GameInstallerRunner`, `StartupDiagnostics`, and the tests. Check whether `Shared/`'s synchronized folder needs no `project.pbxproj` change for new files, and if
  WrappPuppeteer compiles `Shared/`, that `Blocking.swift` builds there.
- **No behaviour change.**

**Before**
```swift
let wine = WineEnvironment(appPath: config.appPath, customPrefixDir: config.winePrefix)
let wineEnvVars = wine.wineSpecificEnvironmentVariables()
let saves = prefix.appendingPathComponent("drive_c/users/\(WineEnvironment.wineUsername)")
let restored = try Self.waitThrowing { try await client.restoreLogin(from: store) }   // WrappSteam's private bridge
```
**After**
```swift
let wine = Wine(wrapp: config.appPath, prefix: config.winePrefix)
let wineEnvVars = wine.variables
let saves = prefix.appendingPathComponent("drive_c/users/\(Wine.username)")
let restored = try Blocking.wait { try await client.restoreLogin(from: store) }
```

Commit: `refactor(wine): rename WineEnvironment to Wine`

---

## Phase 2: The one launcher

- **New files.** Add `WineCommand.swift` and `WineProcess.swift`. Move `displayName`, `reproductionCommand`
  (which becomes `commandLine(in:)`) and the static `wait(for:timeout:watchdog:tick:)` into them.
- **Rebuild `run` on the launcher.** Today's `runWine` becomes `Wine.run`, with `start` and `output(of:)` beside it.
  `runWindowsExecutableWithStartAsync` and `runWindowsExecutableWithStart` become `.start(…)` commands.
- **Drop `/bin/sh`.** `process.environment` already carries exactly the same variables, so the
  script adds nothing.
  - It also breaks any argument containing `"`, `$` or a backtick.
  - Wine is started directly, with the same PID, since `sh` `exec`s anyway.
  - Installers now get stdin from `/dev/null` instead of inheriting it.
- **Move `WineDesktop` onto the launcher, and make it `async`.**
  - Its desktop becomes `wine.start(.wine(["explorer.exe", "/desktop"]))`.
  - Its checks become `wine.output(of: .wine(["reg", "query", …]), onTimeout: .stopProgram)`. A check
    must not stop the session, because that would kill the very desktop it is waiting for.
  - The back-off uses `Task.sleep`.
  - Its callers change:
    - `GameInstallerRunner.startDesktop` and `SteamClient.start` drop their `Task.detached` and just `await`.
    - `GameLauncher.prepareDesktop`, on the launcher's thread, uses `Blocking.wait`.
- **`output(of:)` logs quietly.** It logs its ▶/■ lines at `.debug`, since the desktop's checks would
  flood `.notice` during a two-minute wait. If `SubprocessWatch` can't take a level yet, add `level:`.
- **`WineManager` keeps its `runWine` wrappers** for one more phase, now delegating to `Wine.run`.

**Before** (`WineEnvironment.runWine`, which every installer runs through)
```swift
let shellScript = """
export WINEPREFIX="\(env["WINEPREFIX"] ?? "")"
export WINE="\(env["WINE"] ?? "")"
export DYLD_FALLBACK_LIBRARY_PATH="\(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "")"
…eight more exports…
exec "\(winePath.path)" \(quotedArguments)        // quotedArguments = arguments.map { "\"\($0)\"" }
"""
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sh")
process.arguments = ["-c", shellScript]
process.environment = env
```
**After** (inside `WineProcess.swift`, the only `Process()` for Wine)
```swift
let process = Process()
process.executableURL = command.executable(in: wine)    // bin/wine, bin/wineserver or /bin/bash
process.arguments = command.arguments
process.environment = wine.environment.merging(extra) { $1 }
process.currentDirectoryURL = command.directory
process.standardInput = output == .terminal ? FileHandle.standardInput : FileHandle.nullDevice
try process.runWithoutCrashHandler()
```

**Before** (`queryDisplayDevices`, 37 lines: temp file, handle, semaphore, terminate, read back)
```swift
let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("second-chance-display-query-\(UUID().uuidString).txt")
guard FileManager.default.createFile(atPath: outputURL.path, contents: nil), let output = try? FileHandle(forWritingTo: outputURL) else { … }
defer { … }
let process = Process()
process.executableURL = wineBinDir.appendingPathComponent("wine")
process.arguments = ["reg", "query", #"HKLM\HARDWARE\DEVICEMAP\VIDEO"#]
…
if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return .timedOut }
let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
if process.terminationStatus == 0 && text.contains(#"\Device\Video"#) { return .registered }
return .notYet(exitCode: process.terminationStatus)
```
**After** (in `WineDesktop`. It is spelled `wine.output(of: .wine(["reg", "query", …]))` until phase 3
adds `registry.values(in:)`.)
```swift
do {
    let values = try await wine.registry.values(in: .videoDeviceMap, timeout: timeout)
    return values.contains(#"\Device\Video"#) ? .registered : .notYet(exitCode: 0)
} catch WineError.executionFailed(let code) {
    return .notYet(exitCode: code)
} catch WineError.timedOut {
    return .timedOut
} catch {
    return .failedToRun("\(error)")
}
```

**Before** (`GameInstallerRunner.startDesktop`, hopping off the actor to call a blocking API)
```swift
let wine = WineEnvironment(appPath: wrappPath)
let logger = self.logger
return await Task.detached {
    WineDesktop.start(wine, logger: logger, outputLogger: wineOutputLogger)
}.value
```
**After**
```swift
await WineDesktop.start(Wine(wrapp: wrappPath), logger: logger, outputLogger: wineOutputLogger)
```

**Tests.** Add `SecondChanceTests/WineLauncherTests.swift`.
- **Fixture.** Pull `WineNoDisplayTests`' fake-wrapp helper out into a shared `FakeWine`
  test fixture, whose `bin/wine` and `bin/wineserver` are shell scripts that record their argv.
- **Cases:**
  - exit 0 passes, and exit 3 throws `executionFailed(3)`
  - a signal throws `terminatedBySignal`
  - a timeout with `.stopSession` runs `wineserver -k`, and with `.stopProgram` doesn't
  - `output(of:)` returns stdout and stderr, and a `nodrv_CreateWindow` line in captured
    output still throws `noDisplay`
  - an argument with `"$\`` reaches the script unchanged
  - cancelling the task stops the session
  - stdin is `/dev/null`
  - `Blocking.wait` returns a value and rethrows an error
- **Existing tests.** Move `InstallStallTests`' `wait` tests and `SubprocessWatchTests`'
  `displayName`/`reproductionCommand` tests to the new names. They're fast, so they belong in
  `sc test unit` with no `unitExclusions` change.
- **Gate.** Unit tests, `./sc lint`, then the representative integration set (Verification below).

Commit: `refactor(wine): start every Wine program through one launcher`

---

## Phase 3: `wine.registry`, `Winetricks`, and a slimmer `WineManager`

- **Add `WineRegistry.swift`.** `set` and `importFile` are built on `run`. `set` has a default timeout of
  600 s, the same timeout and reason as today. `values(in:)` is built on `output(of:)`.
- **Add `SecondChance/Services/Winetricks.swift`.** It runs through `wine.run(.script(…))`, so
  winetricks gets the line logging, a timeout and cancellation. Today it runs on a bare
  `TaggedProcess` in a `Task.detached` continuation. A failure throws the existing (and so far
  unused) `WineError.winetricksFailed(trick:)`.
- **Slim `WineManager`** down to the prefix: `createWinePrefix`, `mountDirectory`, the cache
  and `clearCache`.
  - Delete `runWine`, `runWindowsExecutable`, `runWindowsExecutableWithStart`,
    `runWineReturningExitCode`, `waitForWineToExit`, `startWineServer` (no callers) and
    `installWinetrick`.
  - `GameInstallerRunner` and `WrappBuildHelper.installSteamClient` use `Wine` directly.
  - `GameInstallerRunner` drops its `wineManager` dependency.
  - `DiskWrappBuilder`'s stray `WineManager.shared` property becomes an injected init parameter
    with a `.shared` default, the house pattern.
- **Fix:** the "Wine framework not found" `NSError`, which holds developer instructions,
  becomes `WineError.notBundled`, with an everyday `errorDescription` such as
  "This game's app is missing something it needs to run. Making the game's app again should fix it."
  The path goes to the log only.
- **No cache-key change.** The prefix is set up through new code but with the same steps.
  Run `./sc clean wine-prefixes` before this phase's integration runs, so a fresh prefix is built through the new path.

**Before** (`WineManager.createWinePrefix`)
```swift
try await runWine(
    at: wrappPath,
    executable: "wine",
    arguments: [
        "reg", "add", "HKEY_CURRENT_USER\\Software\\Wine\\X11 Driver",
        "/v", "EmulateModeset", "/t", "REG_SZ", "/d", "Y", "/f",
    ],
    timeout: 600
)
try await installWinetrick("cnc_ddraw", at: wrappPath)
…
try await installWinetrick("isolate_home", at: wrappPath)
```
**After**
```swift
let wine = Wine(wrapp: wrappPath)
let winetricks = Winetricks(wine: wine)
try await wine.registry.set(.string("Y"), for: "EmulateModeset", in: .x11Driver)
try await winetricks.install(.cncDdraw)
…
try await winetricks.install(.isolateHome)
```

**Before** (`WineManager.installWinetrick`, about 30 lines)
```swift
try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    Task.detached {
        let process = TaggedProcess(logger: logger)
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [winetricksPath, "--unattended", name]
        process.environment = wine.environmentVariables()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                continuation.resume(throwing: WineError.executionFailed(exitCode: process.terminationStatus))
                return
            }
            …
```
**After** (all of `Winetricks.install`)
```swift
func install(_ verb: Verb) async throws {
    guard let script else { throw WineError.winetricksNotFound }
    do {
        try await wine.run(.script(script, ["--unattended", verb.rawValue]), timeout: 600)
    } catch WineError.executionFailed {
        throw WineError.winetricksFailed(trick: verb.rawValue)
    }
    logger.notice("✓ Installed \(verb.rawValue)")
}
```

**Before** (`GameInstallerRunner.runInstaller`, where an exit code is thrown, caught, returned and thrown again, across three files)
```swift
let exitCode: Int32
if command.useStartCommand {
    exitCode = try await wineManager.runWindowsExecutableWithStart(
        at: wrappPath, exePath: command.exePath, arguments: command.arguments,
        timeout: timeout, watchdog: stallWatch)
} else {
    exitCode = try await wineManager.runWindowsExecutable(
        at: wrappPath, exePath: command.exePath, arguments: command.arguments,
        timeout: timeout, watchdog: stallWatch)
}
if exitCode != 0 {
    throw WineError.executionFailed(exitCode: exitCode)
}
```
**After**
```swift
let program: WineCommand = command.useStartCommand
    ? .start(command.exePath, command.arguments)
    : .program(command.exePath, command.arguments)
try await wine.run(program, timeout: timeout, watchdog: stallWatch)
```

**Before** (a patch, where a non-zero exit is the patch's own error)
```swift
let exitCode: Int32
do {
    exitCode = try await wineManager.runWindowsExecutable(
        at: wrappPath, exePath: winePath, arguments: arguments, timeout: Self.patchInstallerTimeout)
} catch WineError.timedOut {
    throw GamePatchError.timedOut(patch.id)
}
guard exitCode == 0 else { throw GamePatchError.installerFailed(id: patch.id, exitCode: exitCode) }
```
**After** (one `do`, every way it can fail mapped in one place)
```swift
do {
    try await wine.run(.program(winePath, arguments), timeout: Self.patchInstallerTimeout)
} catch WineError.executionFailed(let code) {
    throw GamePatchError.installerFailed(id: patch.id, exitCode: code)
} catch WineError.timedOut {
    throw GamePatchError.timedOut(patch.id)
}
```

**Before** (`WineManager.mountDirectory`, and `SteamClient.restoreLogin`)
```swift
try await runWine(at: wrappPath, executable: "wine", arguments: [
    "reg", "add", "HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives",
    "/v", "\(driveLetter):", "/t", "REG_SZ", "/d", driveType, "/f"
], timeout: 600)
…
try await wine.runWine(executable: "wine", arguments: ["reg", "import", SteamSessionStore.fragmentWindowsPath], timeout: 120)
```
**After**
```swift
try await wine.registry.set(.string(driveType), for: "\(driveLetter):", in: .wineDrives)
…
try await wine.registry.importFile(atWindowsPath: SteamSessionStore.fragmentWindowsPath, timeout: 120)
```

**Tests.**
- **`WineRegistryTests`.** Uses `FakeWine`. Checks that:
  - `set` produces exactly the `reg add … /t REG_SZ /d Y /f` and `REG_DWORD` argument lists
  - a `values(in:)` timeout leaves `wineserver` alone
- **`WinetricksTests`.** Checks that the verb is passed as `--unattended cnc_ddraw`, and that a non-zero exit becomes
  `winetricksFailed`.
- **Text test.** Checks that `notBundled`'s description avoids the words the house rule bans.
  Reuse `ErrorViewTests`' helper if it has one.
- **Gate.** `./sc clean wine-prefixes`, then the representative set. It covers a fresh
  prefix, disc mounting, a patch, the Her download's `/extract_all`, and Steam's `reg import`.

Commits:
- `refactor(wine): add wine.registry and Winetricks, and slim WineManager to the prefix`
- `fix(build): explain a game's app missing its Wine in everyday words`

---

## Phase 4: `wine.server` (replaces `WineUtilities` and every hand-run `wineserver`)

- **Add `WineServer.swift`.** It takes `waitTillWineserverStopped`, `waitForSessionEnd`,
  `onSessionEnd` and `killSession` from `WineUtilities`, and `isWineserverRunning`/`stopWineserver` from `Wine`.
  `WineUtilities.swift` is deleted.
- **Move every caller.**
  - The app's callers `await`.
  - The wrapp's GCD-thread callers use `Blocking.wait`:
    - `GameLauncher.performCleanup`/`waitForWineToEnd`
    - `main.swift`'s `waitForLastSession` and its forced-exit kill
    - `WrappSteam.init`
    - `SteamLockHolder.quit`
- **Fix:** `SteamClient.shutdown`'s 1 s `-k0` poll becomes `server.waitUntilStopped(timeout:)`,
  which waits on the signal rather than polling.
- **Fix:** `SteamLockHolder.quit` builds `Wine` with the prefix the wrapp actually runs from.
  - First confirm what `appURL` is and where the prefix can be found. The holder is
    created in `SteamWrappBuilder:115` and `GameLauncher:664`.
  - If it's only ever the default prefix in practice, record that and skip the fix.

**Before** (`GameInstallerRunner` ×2, `WrappBuildHelper` ×2, each with its own status logging)
```swift
let wine = WineEnvironment(appPath: wrappPath)
let status = await Blocking.run { wine.stopWineserver() }
if status != 0 {
    logger.warning("wineserver -k exited \(status)")
}
```
**After**
```swift
await Wine(wrapp: wrappPath).server.stop()   // logs a failed -k itself
```

**Before** (`SteamClient.shutdown`)
```swift
let stopped = await Task.detached {
    while Date().timeIntervalSince(start) < timeout {
        if !wine.isWineserverRunning() { return true }
        try? await Task.sleep(for: .seconds(1))
    }
    return false
}.value
…
wine.stopWineserver()
```
**After**
```swift
let stopped = await wine.server.waitUntilStopped(timeout: max(0, timeout - Date().timeIntervalSince(start)))
…
if !stopped { await wine.server.stop() }
```

**Before** (`GameLauncher.waitForWineToEnd`, and `main.swift`'s forced exit)
```swift
WineUtilities.waitTillWineserverStopped(at: config.appPath, customPrefixDir: config.winePrefix, gracefulTimeout: 30)
…
killWineBeforeForcedExit = { WineUtilities.killSession(wine) }
```
**After**
```swift
let wine = Wine(wrapp: config.appPath, prefix: config.winePrefix)
Blocking.wait { await wine.server.shutDown(gracePeriod: 30) }
…
killWineBeforeForcedExit = { Blocking.wait { await wine.server.kill() } }
```

**Before** (`main.swift` `waitForLastSession`, on a background queue)
```swift
guard wine.isWineserverRunning() else { return }
…
let waiter = WineUtilities.onSessionEnd(wine) { decide(.ended) }
if waiter == nil, !wine.isWineserverRunning() { decide(.ended) }
…
wine.stopWineserver()
if !WineUtilities.waitForSessionEnd(wine, timeout: 10) { … }
```
**After**
```swift
guard Blocking.wait({ await wine.server.isRunning }) else { return }
…
let waiter = wine.server.onStop { decide(.ended) }
if waiter == nil, !Blocking.wait({ await wine.server.isRunning }) { decide(.ended) }
…
let stopped = Blocking.wait { await wine.server.stop(); return await wine.server.waitUntilStopped(timeout: 10) }
if !stopped { … }
```

**Before** (`GameInstallerRunner.waitForInstallerProcesses`)
```swift
try await wineManager.runWine(at: wrappPath, executable: "wineserver", arguments: ["-w"], timeout: timeout, watchdog: watchdog)
```
**After**
```swift
try await Wine(wrapp: wrappPath).server.waitUntilProgramsExit(timeout: timeout, watchdog: watchdog)
```

**Tests.** Add `WineServerTests.swift`.
- **Fixture.** The fake `wineserver`'s `-w` waits while a marker file exists, `-k` removes that
  file, and every flag is recorded.
- **Cases:**
  - `shutDown(gracePeriod:)` escalates `-w` → `-k` → `-k9` only as far as needed
  - `waitUntilStopped` returns false at its timeout
  - `onStop` fires once, and not after its waiter is terminated
  - every call is a no-op without a bundled Wine (a ScummVM wrapp)
- **Gate.** The representative set, plus these quit-path checks by hand on the test Mac:
  - Quit a game from its menu: the wrapp exits within seconds and `wineserver` is gone.
  - Quit the wrapp from the Dock mid-game: same.
  - Reopen a wrapp while it is still closing: it shows `lastSessionClosing`, then starts.
  - Try "Stop it and continue".

Commits:
- `refactor(wine): run wineserver through wine.server`
- `fix(steam): wait for Steam's Wine session to end rather than polling it`
- `fix(steam): stop a left-over Wine session in the prefix the game's app uses`, if confirmed

---

## Phase 5: The wrapp and Steam start their programs through `wine.start`

- **`GameLauncher.launchWineProcess`** builds no pipes. `GameMonitor` keeps taking a `Process`
  (`game.process`) so the change stays contained.
- **`SteamClient.run`** goes through `wine.start`.
- **`getGameLaunchInfo`** stops building `…/wine/bin/wine` by hand. It gets its display string from
  `WineCommand.start(…).commandLine(in: wine)`.
- **One implementation of the "run it by hand" text.** `GameLauncher`'s "export commands for
  running Wine by hand" log and `launchWineShell`'s `.command` file both use `wine.shellExports`,
  so there's one implementation instead of three.
- **The `wine` pass-through and the debug menu** use `.terminal`, through `Blocking.wait`.
  `runExecutable` is deleted.
- **Fix:** Wine Config becomes `.wine(["winecfg"])`.
- **Add** the `wine_path_outside_library` SwiftLint rule.

**Before** (`GameLauncher.launchWineProcess`)
```swift
let outputPipe = Pipe()
let errorPipe = Pipe()
let process: Process
do {
    process = try wine.runWindowsExecutableWithStart(
        exePath: gameExeUnixPath, arguments: [], outputPipe: outputPipe, errorPipe: errorPipe)
} catch { … }
…
ProcessLineLogger.attach(to: outputPipe, logger: wineOutputLogger, level: .notice, onLine: observe)
ProcessLineLogger.attach(to: errorPipe, logger: wineOutputLogger, level: .warning, onLine: observe)
```
(Inside `runWindowsExecutableWithStart` the helper variables were merged in, and the working directory was set to the exe's folder.)

**After**
```swift
let exe = URL(fileURLWithPath: gameExeUnixPath)
let game: WineProcess
do {
    game = try wine.start(
        .start(exe.lastPathComponent, unixPath: false, in: exe.deletingLastPathComponent()),
        environment: Wine.inProcessHelperVariables(gameExe: exe),
        output: .log(wineOutputLogger, onLine: observe))
} catch { … }
```

**Before** (`SteamClient.run`, the only hand-built `wine` Process outside `WineEnvironment`)
```swift
let process = Process()
process.executableURL = wine.wineBinDir.appendingPathComponent("wine")
process.arguments = [Self.windowsExecutable] + arguments
var env = wine.environmentVariables()
if let gameExe { env.merge(WineEnvironment.inProcessHelperVariables(gameExe: gameExe)) { $1 } }
process.environment = env
process.standardInput = FileHandle.nullDevice
let output = Pipe()
let errors = Pipe()
…two ProcessLineLogger.attach calls…
try process.runWithoutCrashHandler()
```
**After**
```swift
_ = try wine.start(.program(Self.windowsExecutable, arguments),
                   environment: gameExe.map { Wine.inProcessHelperVariables(gameExe: $0) } ?? [:],
                   output: .log(outputLogger, onLine: onOutputLine))
```

**Before** (`main.swift`: the debug menu and the `wine` pass-through)
```swift
wine.runExecutable("wine", arguments: ["control"])
wine.runExecutable("winecfg")                       // bin/winecfg doesn't exist: always fails
…
let exitCode = wine.runExecutable("wine", arguments: wineArgs)
exit(exitCode)
```
**After**
```swift
func runInTerminal(_ command: WineCommand) -> Int32 {
    do {
        try Blocking.wait { try await wine.run(command, output: .terminal) }
        return 0
    } catch WineError.executionFailed(let code) {
        return code
    } catch {
        mainLogger.error("Couldn't run \(command.displayName): \(error)")
        return 1
    }
}
runInTerminal(.wine(["control"]))
runInTerminal(.wine(["winecfg"]))
…
exit(runInTerminal(.wine(wineArgs)))
```

**Gate.**
- The representative set, including the Steam game.
- By hand: the wrapp debug menu's Control Panel and Wine Config both open.
- `./sc wrapp wine <slug> -- --version` prints Wine's version.
- Save Log… still shows `pid` on Wine's lines.

Commits:
- `refactor(wrapp): start the game and Steam through wine.start`
- `fix(wrapp): open Wine's configuration from the debug menu`

---

## Phase 6: Docs and the historical plan

- **`AGENTS.md`.**
  - Update the `WineUtilities.waitTillWineserverStopped`, `WineEnvironment` and `WineManager`
    mentions under Gotchas.
  - Code Conventions gets two bullets:
    - "Every Wine program starts through `Wine.run`/`start`/`output(of:)`
      (`Shared/Wine/WineProcess.swift`); don't build a `Process` for Wine."
    - "Code on a plain thread calls async code through `Blocking.wait`."
  - Mention the new lint rule.
- **Docs.** Update `docs/logging.md` (`WineEnvironment.runWine`, §108–115), `docs/wrapp-build.md`
  (§220–282), `docs/wine-in-process-helpers.md`, `docs/failure-reports.md#child-processes`,
  `docs/game-patches.md:198` and `docs/releasing.md:28`.
- **Historical plan.** Add this plan as `docs/historical-plans/<implementation-date>-wine-library.md`,
  with its own `AGENTS.md` row. `DocsTableTests` checks both.
- **Final gate.** `./sc test unit`, `./sc lint`, and the full integration suite, covering every
  source and the VMs, as in Verification's **End** below.

Commit: `docs: describe the Wine library`

---

## Files at a glance

| New | Changed (representative) | Deleted |
|---|---|---|
| `Shared/Wine/Wine.swift` (renamed), `Wine+WrappVariables.swift`, `WineCommand.swift`, `WineProcess.swift`, `WineRegistry.swift`, `WineServer.swift`, `WineError.swift`, `WineWatchdog.swift`; `Shared/Blocking.swift` (moved); `SecondChance/Services/Winetricks.swift`; tests `WineLauncherTests`, `WineRegistryTests`, `WinetricksTests`, `WineServerTests`, fixture `FakeWine` | `WineDesktop.swift`, `WineManager.swift`, `GameInstallerRunner.swift`, `WrappBuildHelper.swift`, `DiskWrappBuilder.swift`, `SteamClient.swift`, `SteamLockHolder.swift`, `WrappSteam.swift`, `GameLauncher.swift`, `WrappTemplate/main.swift`, `ProcessUtilities.swift`, `TaggedProcess.swift` (comment), `.swiftlint.yml`, `InstallStallTests`, `SubprocessWatchTests`, `WineNoDisplayTests` | `Shared/Wine/WineUtilities.swift`; `WineManager`'s run wrappers and `startWineServer`; `runExecutable`; `WrappSteam`'s private `wait` |

## Verification

**Every phase**
- `./sc test unit`
- `./sc lint`
- Commit with a conventional message. `refactor` commits don't bump the version; the `fix:` commits do.

**The representative set** for phases 2–5. Build locally with `./sc test unit`, then run each on the test Mac
with `--skip-app-build`:
- **`secrets-can-kill-remastered`**: Direct3D, mode scaling, the desktop pre-start race
- **a DirectDraw disc game**: cnc-ddraw, cursor lock, disc mounting through `.wineDrives`, the
  silent→interactive retry. Pick one whose log shows `CURSOR_LOCK_EXE` armed.
- **`stay-tuned`**: ScummVM, where `wine.server` is a no-op without a bundled Wine
- **`scarlet-hand --source her-download`**: InstallShield `/extract_all`, answer file, `wineserver -w` with the stall watch
- **one Steam game (`--source steam`)**: `reg import`, `WineDesktop`, Steam start and shutdown.
  The `SteamClientSmokeTests` (`STEAM_SMOKE_*`) also cover start/shutdown.

**What to check in the logs**
- The ▶/■ lines and `pid` metadata are unchanged.
- There's one `[Desktop] Ready after …` line.
- No `[Hang]` lines.
- `wineserver` is gone after each wrapp quits (`pgrep wineserver` on the test Mac).

**End: the full suite, every source, on a real Mac and in VMs.** Run it once both parts have
landed, or at the end of whichever part lands last.

1. **Real Mac (the test Mac).** Every game, from every source:
   `./sc --on <host>:<path> test integration --source all --skip-app-build`.
   This is the only run that can test Direct3D games.
2. **VMs (Sequoia and Tahoe), on the test Mac.** Run these only after step 1 has finished. A VM loads
   the test Mac's CPU, which would push games in a real-Mac run into `overloaded`, and nothing else may
   launch wrapps during a test. **Don't touch the VMs or storage on the developer's own Mac**:
   they were in use for something else.
   1. **Check the test Mac's free disk space.** Each macOS image needs about 60 GB. If there isn't room
      for both, do one VM at a time: set it up, run, delete, then the next.
   2. **Set up tart on the test Mac** as before. If its Homebrew can't install the cirruslabs tap, get the
      GitHub release tarball into a folder of its own. Then clone `macos-sequoia-vanilla` as `sc-sequoia`
      (and `macos-tahoe-vanilla` as `sc-tahoe`), give each 4 CPUs and 8 GB, boot once headless, push
      an SSH key made for it with `ssh-copy-id`/`expect` (admin/admin), and stop it.
      sc installs Rosetta in the guest itself.
   3. **Run each VM:**
      `./sc --on <host>:<path> test integration --source all --vm sc-sequoia --skip-app-build`,
      then the same with `--vm sc-tahoe`. Set `TART_HOME`, `SC_VM_SSH_KEY` and the tart `PATH`
      for the run on the test Mac. If `--on` doesn't pass them through, wrap the command in
      `./sc --on <host>:<path> in-gui-session -- env … ./sc test integration …`.
   - **What a VM can test.** Builds, ScummVM games, DirectDraw games (in software rendering) and
     the Wine start-up and quit paths, on macOS versions the test Mac doesn't run.
   - **What it can't.** Direct3D games come back `skipped`, since a VM has no hardware OpenGL.
     That is expected, not a failure; step 1 covers them.
   - **Steam games in a VM** need the shared Steam sign-in copied into the guest. First check whether
     `--vm` does that by itself, and ask before copying the sign-in in by hand. Delete it from the
     guest afterwards.
   - **Old wrapps.** Any in `built-apps/` from before QuitWatch need `--refresh-wrapp template`.
3. **Clean up the test Mac.** Remove everything VM-related:
   - each VM (`tart delete sc-sequoia`, `tart delete sc-tahoe`)
   - tart's cached images (`tart prune`, or `rm -rf ~/.tart`)
   - tart's own folder
   - the SSH key made for the VMs
   - any Steam sign-in copied into a guest goes with its VM

**Reading the results.** Compare each run's results table with the last full run before the
refactor. Any game whose result changed, other than VM-`skipped` Direct3D games, is looked at
before the work is called done.

---

# Part B: read Windows files natively, and stop bundling ExifTool

## Context

Game detection uses ExifTool, a 36 MB Perl program bundled in `Second Chance.app` and run
through `#!/usr/bin/env perl`, for exactly three values:

- **`ProductName`** from a `setup.exe`'s or a Her installer's version resource
  (`GameDetector.detectGame(fromDisk:)` and `detectGame(fromHerInstaller:)`)
- **`ProductName` and `Comments`** from an installer's version resource, to tell InstallShield
  from Inno Setup (`GameInstallerRunner.detectInstallerType`)
- **`Subject`** from an `.msi`'s summary information (`detectGame(fromDisk:)`)

That costs us in four ways:
- **Size.** It's 36 MB of the download.
- **Perl.** It depends on the system's Perl, which Apple has said since macOS 10.15 may be removed
  from a future macOS.
- **Speed.** Each value is a separate process taking up to a second or two.
- **A latent bug.** `ExiftoolService.getFileProperties` matches output lines to properties by
  position, but `-s3` prints nothing for a missing tag. So an installer without a `ProductName`
  has its `Comments` filed as the `ProductName`. Today that's harmless, because the two are joined
  before they're searched, but it is a trap.

Its tests mostly skip, since their fixtures don't exist, and one hardcodes a `/Users/…` path.

**Why not adopt WindowsFileKit** (WineKit's Windows-file package)? It has a VS_VERSIONINFO
reader, but:
- **No MSI.** It can't read an MSI, which is an OLE compound file, not a PE.
- **Order assumption.** It assumes `StringFileInfo` comes before `VarFileInfo`, which the format
  doesn't require, so it could miss `ProductName` in exactly the installers we read.
- **Silent defaults.** Throughout, a short read becomes `?? 0` instead of a failure.
- **Duplication.** We'd use about a tenth of it, alongside the PE reader we already have
  (`WindowsExecutable` in `GameGraphicsAPI.swift`, which is bounds-checked and has no
  dependencies). It also has the same single-maintainer and EUPL concerns as WineKit.

**What we'll do instead.** Extend our own reader, using WindowsFileKit and Microsoft's format
docs as the reference for the layouts.

**Outcome**:
- **Native readers.** `WindowsExecutable` becomes a value that reads both an exe's imports and its
  version strings, and a small `MSISummary` reads an MSI's subject.
- **ExifTool goes away.** `ExiftoolService`, its tests, its build phase and the 36 MB with them.
- **Tests that run.** Detection gains unit tests that run without real installers.

---

## The API when done

```swift
// Shared/Windows/WindowsExecutable.swift (moved out of GameGraphicsAPI.swift; the wrapp still needs imports)
nonisolated public struct WindowsExecutable: Sendable {
    public init?(contentsOf url: URL)   // memory-mapped, not copied; nil if it isn't a PE image
    public init?(data: Data)
    public var importedDLLs: Set<String> { get }        // what importedDLLs(at:) returned
    public var versionStrings: [String: String] { get } // "ProductName", "Comments", "CompanyName", …
}

// SecondChance/Services/MSISummary.swift (the app only: only detection reads MSIs)
nonisolated struct MSISummary: Sendable {
    init?(contentsOf url: URL)           // nil if it isn't an OLE compound file with summary information
    let subject: String?                 // PIDSI_SUBJECT (3)
}
```

How `versionStrings` reads the file:
- **Find the resource.** It goes through the resource data directory (index 2) to `RT_VERSION`
  (16), taking the first name, then the first language, then the data entry.
- **Parse the nodes.** `VS_VERSIONINFO` is parsed as a generic tree, where each node is
  `wLength`, `wValueLength`, `wType`, a NUL-ended UTF-16 key, 32-bit padding, the value and then
  the children. That makes `StringFileInfo` and `VarFileInfo` found in either order.
- **Pick a table.** It takes the `StringTable` for US English (`0409…`) if there is one, otherwise
  the first.
- **Text values.** A text value's `wValueLength` counts UTF-16 units rather than bytes. The value
  is read up to its NUL within the node's bounds.
- **Bounds.** Every read is bounds-checked, as `importedDLLs` already is, and nothing defaults silently.

`MSISummary` follows MS-CFB and MS-OLEPS:
- the header
- the FAT and DIFAT sectors
- the directory, to find the `\u{5}SummaryInformation` stream
- the mini stream, since that stream is under 4 KB
- the property set, taking property 3 as a `VT_LPSTR` in the set's code page, which
  `CFStringConvertWindowsCodepageToEncoding` converts

Loops are capped, so a damaged file ends the read rather than spinning.

---

## Phase B1: `WindowsExecutable` reads version strings

- **Move `WindowsExecutable`** from `Shared/Wine/GameGraphicsAPI.swift` into
  `Shared/Windows/WindowsExecutable.swift`.
- **Turn it into a struct** that maps the file once, where today it copies the whole file into
  `[UInt8]`, and add `versionStrings`.
- **`GameGraphicsAPI`** reads `WindowsExecutable(contentsOf:)?.importedDLLs`.

**Before** (`GameGraphicsAPI`)
```swift
guard let imports = WindowsExecutable.importedDLLs(at: url) else { self = .unknown; return }
```
**After**
```swift
guard let imports = WindowsExecutable(contentsOf: url)?.importedDLLs else { self = .unknown; return }
```

**Tests.** `WindowsExecutableTests`, using a small in-test builder (`TestPE`) that writes a
minimal PE image with an import table and a `.rsrc` version resource. Cases:
- `ProductName` and `Comments` come back
- `VarFileInfo` before `StringFileInfo` still finds them
- with two string tables, US English wins
- a missing `Comments` is absent, not someone else's value
- a truncated resource gives nil or empty, never a crash
- the existing `GameGraphicsAPITests` import cases still pass

Also one real-file check that skips when its file is absent: a Windows `.exe` from the bundled
Wine (`lib/wine/i386-windows/`), which carries Wine's own version info. Confirm one does while implementing.

Commit: `refactor(detect): read a Windows program's version info natively`

---

## Phase B2: decide on, then read, an MSI's subject

- **Measure first.** A temporary, opt-in `WindowsMetadataParityTests` suite, added to
  `TestRunner.unitExclusions` while it exists. It needs real installers, so it stays out of the
  unit run, but it opens no windows and runs no Wine, so it can run on this Mac.
  - For every `installers/<slug>/disk-*.iso` (mounted through the existing `ISOMounter`) and
    every Her download present, it prints ExifTool's `ProductName`/`Comments`/`Subject` beside
    the native values.
  - It also shows whether detection still finds the right game with the `Subject` left out.
- **If `Subject` is ever the signal that decides a game**, implement `MSISummary`, with
  `MSISummaryTests` on a minimal compound-file fixture built in-test and one real `.msi` when present.
- **If it never is**, drop the `Subject` lookup instead, and record the measurement in the
  historical plan.

**Before** (`GameDetector.detectGame(fromDisk:)`)
```swift
if let msiFile = contents.first(where: { $0.pathExtension.lowercased() == "msi" }) {
    if let subject = try? await getFileInfo(msiFile, property: "Subject") {
```
**After**
```swift
if let msiFile = contents.first(where: { $0.pathExtension.lowercased() == "msi" }) {
    if let subject = await Blocking.run({ MSISummary(contentsOf: msiFile)?.subject }) {
```

Commit: `refactor(detect): read an MSI's subject natively`, or `refactor(detect): stop reading an MSI's subject`

---

## Phase B3: detection reads natively

- **`GameDetector`** and **`GameInstallerRunner.detectInstallerType`** use `WindowsExecutable`
  and `MSISummary`.
- **Drop the `exiftool:` parameters** from their initialisers and from any tests that pass them.
- **Run the parity suite** over every installer present. Every value must match ExifTool's,
  except where ExifTool's was the misattributed `Comments`.

**Before** (`GameDetector`)
```swift
/// Extract metadata from a file using exiftool
private func getFileInfo(_ filePath: URL, property: String) async throws -> String? {
    let exiftool = self.exiftool
    return try await Blocking.run { try exiftool.getFileProperty(filePath.path, property: property) }
}
…
if let productName = try? await getFileInfo(setupExe, property: "Product Name") {
```
**After**
```swift
/// A Windows program's version strings (empty when it has none, or isn't one).
/// Maps the file, so off the main thread.
private func versionStrings(of file: URL) async -> [String: String] {
    await Blocking.run { WindowsExecutable(contentsOf: file)?.versionStrings ?? [:] }
}
…
if let productName = await versionStrings(of: setupExe)["ProductName"] {
```

**Before** (`GameInstallerRunner.detectInstallerType`)
```swift
do {
    let exiftool = self.exiftool
    let metadata = try await Blocking.run { try exiftool.getFileProperties(installerPath, properties: ["ProductName", "Comments"]) }
    logger.notice("🔍 Installer metadata: \(metadata)")
    let combined = (metadata["ProductName"] ?? "") + " " + (metadata["Comments"] ?? "")
    …
} catch {
    logger.warning("⚠️ Failed to detect installer type via exiftool: \(error)")
}
```
**After**
```swift
let strings = await Blocking.run { WindowsExecutable(contentsOf: url)?.versionStrings ?? [:] }
logger.notice("🔍 Installer version info: ProductName=\(strings["ProductName"] ?? "–"), Comments=\(strings["Comments"] ?? "–")")
let combined = [strings["ProductName"], strings["Comments"]].compactMap { $0 }.joined(separator: " ").lowercased()
if combined.contains("installshield") { return .installShield }
if combined.contains("inno setup") { return .innoSetup }
```

**Gate.** `./sc test unit`, then the parity suite, then the representative integration set from
Part A's Verification. It exercises disc detection, Her-download detection and the
InstallShield/Inno split.

Commit: `refactor(detect): recognise games without ExifTool`

---

## Phase B4: stop bundling ExifTool

Delete or update each of these:
- **Code.** Delete `SecondChance/Services/ExiftoolService.swift`,
  `SecondChanceTests/ExiftoolServiceTests.swift`, and the parity suite from B2.
- **The build.** Delete the "Download And Copy Exiftool Files" build phase in `project.pbxproj`
  and `WrappTemplate/setup-exiftool.sh`.
- **The `sc` tool.** Remove `ExiftoolServiceTests`/`ExiftoolServiceIntegrationTests` from
  `TestRunner.unitExclusions`, and change `Test.swift`'s "Every suite except the integration and
  exiftool ones" text.
- **Docs.** Remove the mentions in `README.md:234` (credits), `CONTRIBUTING.md:54`,
  `docs/testing.md:99–100` and `docs/dev-cli.md:199`.
- **Add** a short "How a game is recognised" note to `docs/wrapp-build.md`, naming
  `WindowsExecutable` and `MSISummary`.
- **Check** the built app no longer has `Contents/Resources/exiftool`, and the release build
  still signs and notarises.

**Release notes.** `refactor` won't put "a 36 MB smaller download" in the release notes. If you
want players told, make this commit a `fix:` or `feat:`; that's your call at commit time.

Commit: `refactor(build): stop bundling ExifTool`

---

## Part B files at a glance

| New | Changed | Deleted |
|---|---|---|
| `Shared/Windows/WindowsExecutable.swift` (moved and extended), `SecondChance/Services/MSISummary.swift` (if B2 keeps it); tests `WindowsExecutableTests`, `MSISummaryTests` | `GameGraphicsAPI.swift`, `GameDetector.swift`, `GameInstallerRunner.swift`, `project.pbxproj`, `Tools/sc` `TestRunner.swift`/`Test.swift`, `README.md`, `CONTRIBUTING.md`, `docs/testing.md`, `docs/dev-cli.md`, `docs/wrapp-build.md` | `ExiftoolService.swift`, `ExiftoolServiceTests.swift`, `WrappTemplate/setup-exiftool.sh`, the build phase |

Part B is recorded with Part A in the historical plan, or in its own
`docs/historical-plans/<date>-native-windows-file-readers.md` if it lands separately.
