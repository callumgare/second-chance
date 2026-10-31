# Shared code as a local Swift package

## What happened

_Written after implementation. There was no written plan beforehand: the
approach was agreed in conversation, and this records it and what turned up
while doing it._

`Shared/` used to be a synchronized folder that Xcode added to three targets
(Second Chance, WrappTemplate and WrappPuppeteer), so each compiled its own
copy of every file into its own module. Nothing marked where the shared code
ended, and the Sentry code was hidden from WrappPuppeteer with
`#if FAILURE_REPORTING`, a condition only two of the targets defined.

It is now a local Swift package (`Shared/Package.swift`), which is Apple's
recommended way for two apps in one repo to share code. Its library products
are linked by the targets that need them. The alternatives were a framework
target, which a wrapp couldn't use: a dynamic one would be deleted with
`Contents/Frameworks`, and WrappTemplate builds for Intel only. The other
alternative was to keep the folder as it was.

## Decisions

- **Two modules, split at Sentry.** `SecondChanceKit` has everything
  WrappPuppeteer may use. `SecondChanceReporting` has `Shared/Reporting/` and
  the two report views, and is the only module that depends on Sentry.
  WrappPuppeteer doesn't link it, so `FAILURE_REPORTING` and its `#if`s are
  gone.
- **The core never imports reporting.** Only two places in the core module
  used reporting:
  - `CrashMarker.arm()` asked `FailureReporter.handlesCrashes`. Now
    `FailureReporter.start` sets `CrashMarker.sentryHandlesCrashes`, which
    keeps every call site unchanged. Making `arm` take a parameter would have
    had to go through `install(in:)` as well.
  - `NewerRelease` used `FailureReporter.isDebugBuild`. That moved to
    `RunContext.isDebugBuild`, and `FailureReporter.isDebugBuild` forwards to
    it.

  `ProgramExitError` moved into the core, since `WineError` conforms to it.
- **`public` only where asked.** Declarations were made public where the
  compiler reported a use across the module boundary, not wholesale. The
  memberwise initializers apps use became explicit `public init`s. A
  default argument that refers to an internal declaration had to be made
  public too (`SteamSessionStore.defaultRoot`, `SystemLoadMonitor.busyInterval`,
  `ReportingPreferences.defaultDirectory`, `SteamLockHolder.Patience()`).
- **The package matches the targets' Swift settings.** These are Swift 5
  mode, `MainActor` default isolation, the features that
  `SWIFT_APPROACHABLE_CONCURRENCY` turns on, and `MemberImportVisibility`.
  It also needed `BareSlashRegexLiterals`: Xcode allows `/regex/` literals by
  default, but SwiftPM doesn't, and `LogFormatter` uses them.
- **Tests stayed where they were.** `SecondChanceTests` reaches the package
  with `@testable import SecondChanceKit` / `SecondChanceReporting`, which
  works because Xcode builds the package with testing enabled in Debug. Moving
  the shared code's tests into the package, so `swift test` runs them on their
  own, is left for later.
- **Static linking is checked.** `check-output-collisions.sh` now fails the
  build if either module ends up as a dynamic framework in the wrapp, as it
  already did for swift-log and Sentry.
