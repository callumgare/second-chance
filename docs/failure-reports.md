# Failure reports

When a build or a game fails, or Second Chance or a wrapp crashes, a report
goes to [Sentry](https://sentry.io), at the detail the person chose. This is
how the developer hears about failures nobody files an issue for, and how
often each one happens.

The code is in `Shared/Reporting/`: `FailureReporter` is the only file that
imports Sentry. `Shared/Views/FailureReportCallout.swift` and
`CrashReportPrompt.swift` are the UI.

## Levels

One setting covers Second Chance and every wrapp (`ReportingPreferences`). It
is a JSON file, `~/Library/Application Support/SecondChance/failure-reporting.json`,
because each wrapp is its own bundle with its own `UserDefaults`. It is read
afresh at each failure, so a change made in Second Chance reaches wrapps that
are already running.

| Setting | A failure | A crash, at the next start |
| ------- | --------- | -------------------------- |
| **Basic** (the default) | Sent basic | Sent basic |
| **Detailed** | Sent detailed | Sent detailed |
| **Manual** | The error screen offers Send Detailed / Send Basic / Don't Send | An alert offers the same |

The first failure anywhere also asks how detailed reports should be from now
on, and sets `promptShown` so it is only asked once. After a failure the
basic report has already gone, so the question sits under it on the error
screen. Choosing Detailed sends this failure again as a detailed report. For a
crash nothing has gone yet, so an alert asks first and the crash is sent at
the answer. Choosing a level in Settings counts as having been asked.

What each report contains:

| | Basic | Detailed |
| --- | :---: | :---: |
| Version and build, macOS version, CPU architecture, Mac model | ✓ | ✓ |
| `process` (`app` / `wrapp`), game slug, source, engine (tags) | ✓ | ✓ |
| What failed, how (`kind`) and the stage: our own fixed words | ✓ | ✓ |
| A crash's stack trace | ✓ | ✓ |
| The `FailureSummary` block (as the event's `summary` extra) | | ✓ |
| `failure-report.zip`: the log, and the diagnostics bundle if there is one | | ✓ |
| A comment and an email address, if the person adds them | ✓ | ✓ |

**A basic report never contains message text**, because messages and
associated values can hold paths. The kind of a thrown error is
`ErrorChain.identifier`: its type and case (`WrappBuildError.installIncomplete`,
`NSCocoaErrorDomain 513`), with underlying errors in the `caused_by` tag. For a
game run it is how the run ended: `quit-unexpectedly`, `never-started`,
`killed-by-signal`, `exit-code` or `no-window`, with `exit_code`, `signal` and
`diagnostics` tags.

Grouping is `[process, what, kind, stage]`. The game is a tag rather than part
of the fingerprint, so one Wine problem across many games is one Sentry issue,
and that issue can still be filtered by game.

## What leaves the Mac

Every event, ours or the SDK's, passes through `scrub` in `beforeSend`:

- it clears the server name, the request and the module list;
- it keeps only the user's random installation ID;
- for a basic report, it cuts Sentry's contexts down to the allow-list in
  `ReportScrubber.basicContextKeys` and drops extras and breadcrumbs;
- it runs every remaining string through `ReportRedactor`.

`ReportRedactor` replaces:

- the home folder (as a path, a `file://` URL and percent-encoded) with `~`;
- any other `/Users/<name>` with `/Users/<user>`;
- the user's short and full names, and the Steam account and persona names
  from the saved sign-in, with `<user>`;
- the computer's names with `<computer>`;
- SteamID64s with `<steam-id>`.

The zip's files go through the same redactor (`ReportBundle`), and a file
that isn't UTF-8 is left out rather than sent unchecked.

The SDK runs with everything but crash and failure capture off: no sessions,
tracing, hang tracking, MetricKit, breadcrumbs or network capture
(`FailureReporter.start`). Nothing is sent unless something fails.

## Where failures are reported

Everything goes through `FailureReporter.report(_:)`, which reads the setting
and returns a `ReportOutcome` for the error screen. `FailureReportModel` holds
that outcome for `FailureReportCallout`.

- **Build failures.** `WrappBuildViewModel.runBuild`'s catch reports them,
  because it still has the thrown error, the detected game and the source.
  The bus's `.failed` event isn't reported: it fires for the same failure.
  Cancelling reports nothing.
- **Game runs.** `GameLauncher.handleGameTermination` reports a run that
  ended badly, the same runs that log a failure summary. `reportSteamFailure`
  reports Steam failing to start. The error window tracks the report through
  `InfoWindowController.showError(…, report:sending:)`.
- **A wrapp's own start-up errors.** The `exit(1)` paths in `main.swift` use
  `reportAndWait`.
- **Crashes.** The SDK records a crash and finds it at the next start.
  `beforeSend` holds back any event that isn't tagged `report_detail`, meaning
  the SDK made it itself. `previousRunCrashed` then sends it again, tagged, on
  the main queue, after asking if it has to.
  A detailed crash report from a wrapp carries the log of the launch that
  crashed (`setRunLogs`). The app keeps no per-run log, so its crash reports
  carry none.

A new failure that someone sees should get a report too: build a
`FailureReport` with fixed words for `what` and an identifier for `kind`.

A process on its way out waits for reports under way: `FailureReporter.wait`
in the wrapp's exit and quit paths and in the app's `finishTerminating`. A
detailed report waits for its diagnostics bundle to finish
(`StartupDiagnostics.bundleWhenComplete`). That wait is bounded by the
capture's own command timeouts.

## Crash handlers

`FailureReporter.start` runs straight after `AppLogging.bootstrap` and
before `CrashMarker.install`. `CrashMarker`'s signal handler keeps the
action that was installed before it, which is Sentry's, and restores it
before re-raising. So the chain is CrashMarker → Sentry → default, and macOS
still writes its `.ips`. Debug Settings in the app, and the wrapp's
`--debug-options` dialog, have a **Crash Now** button for checking that chain.

## Linking

The static `Sentry` product is linked into Second Chance and WrappTemplate.
**It must stay static in WrappTemplate**: a wrapp's `Contents/Frameworks` is
replaced by the engine's (`setupWineFramework`), and the wrapp is only ad-hoc
signed on the outer bundle. `check-output-collisions.sh` fails the build if
Sentry is linked dynamically.

Xcode still embeds an empty 52 KB `Sentry.framework` that only carries
Sentry's privacy manifest. Nothing links against it, so losing it is harmless.

WrappPuppeteer compiles `Shared/` but doesn't link Sentry. Everything that
touches the SDK is therefore inside `#if FAILURE_REPORTING`, which only the
SecondChance and WrappTemplate targets define
(`SWIFT_ACTIVE_COMPILATION_CONDITIONS`).

## When it's off

`FailureReporter.disabledReason` keeps reporting off:

- with no DSN (`FailureReporter.releaseDSN`, or `SECOND_CHANCE_SENTRY_DSN`);
- in a Debug build;
- in a headless build (`NON_INTERACTIVE`), which covers the integration tests;
- in a wrapp WrappPuppeteer drives (`SECOND_CHANCE_PUPPET_DIR`);
- under XCTest.

`SECOND_CHANCE_REPORTING=1` or `0` overrides all of these except the DSN.
Through `sc` it is `--debug reporting`.

To try reporting from a Debug build:

```fish
SECOND_CHANCE_SENTRY_DSN=<a test project's DSN> ./sc app run --debug reporting
```

Debug builds report to the `development` environment, so they don't mix
with players' reports.

## Symbolication

A crash's stack is only addresses until Sentry has the build's dSYMs.
`sc release` uploads `Second Chance.app.dSYM` and `WrappTemplate.app.dSYM`
with `sentry-cli`, and keeps them in `build/release/dSYMs.zip`
([releasing.md](releasing.md)). Wrapps carry the version of the Second Chance
that built them, so one upload covers both. Sentry matches each event to its
symbols by the binaries' UUIDs, not by release name.

## The Sentry project

Set up once, by hand, in Sentry:

- **Platform:** `apple-macos`. Its DSN goes in `FailureReporter.releaseDSN`.
  Its organisation and project slugs go in `.sentryclirc`.
- **Security & Privacy:** turn on *Prevent Storing of IP Addresses*, and keep
  the default data scrubbing.
- **Rate limits:** turn on spike protection, and set an alert for new issues.
- **Plan:** the free plan's error and attachment quotas are enough to start
  with. Detailed reports' zips count against the attachment quota.
