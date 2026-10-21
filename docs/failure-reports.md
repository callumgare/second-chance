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

**The first failure anywhere sends nothing until it is asked.** Until
`promptShown` is set, `FailureReporter.report` returns
`ReportOutcome.askingHowDetailed`, and the error screen asks whether to send
a basic or a detailed report. The question makes the case that a detailed
report is usually what it takes to fix the problem. The answer sends this
report and becomes the setting, Basic or Detailed. The screen's way out (Quit,
Launch Directly, Start Over) stays hidden until then
(`HiddenUntilReportAnswered`). Leaving anyway sends the report basic on the
way out: `FailureReporter.wait`, which every exit path calls, sends any
unanswered first failure as basic before it waits. That covers Cmd-Q, a run
that ends with no error window, and the wrapp's start-up errors. Nothing is
recorded as answered then, so the next failure asks again. A crash has no
error screen, so an alert asks the same question at the next start, and the
crash is sent at the answer. Choosing a level in Settings counts as having
been asked.

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
- **Launches given up on.** A launch that seems stuck never exits to be
  reported, so quitting while the info window shows its possible-failure
  note (its Quit button, Cmd-Q, the Dock) reports it as `Starting the game`
  / `stuck`, with the hang's diagnostics bundle in a detailed report.
  `applicationShouldTerminate` asks `InfoWindowController.giveUpIfStuck`,
  which sends it through `GameLauncher.reportStuckLaunch`, shows it being
  sent or asks about it as the error window would, and quits again once
  it has gone or been declined. Launch Directly is not a give-up and quits
  without one.
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

**When Sentry handles crashes, `CrashMarker` installs no signal handler of
its own.** `FailureReporter.start` runs first, then `CrashMarker.arm()`,
which sees `FailureReporter.handlesCrashes` and stands aside. Sentry records
the crash, and at the next start `previousRunCrashed` logs the line
`CrashMarker` would have ("The previous run crashed …"), with the path of
macOS's `.ips`. When reporting is off (Debug, headless, test and
WrappPuppeteer runs, or no DSN), `CrashMarker` works as before.

Why: `CrashMarker`'s handler would almost never run. Sentry takes a real
crash (a bad memory access, a Swift trap) first, through a Mach exception
handler, and once it has recorded it puts back the signal handlers that were
there before Sentry started. So the signal that follows goes straight to the
default action, past `CrashMarker`. In crash tests with both installed,
`CrashMarker` wrote its line for none of the segfaults and traps, only for a
`kill -SEGV`, which raises no Mach exception. Every crash still ended
normally, with either arrangement.

### Testing a crash from a terminal in VS Code

A crashing process can sit in the kernel for hours, in `ps` state `UE`, and
survive `kill -9`. That isn't the crash handlers. A process started from a
VS Code terminal, or by an agent running inside VS Code, inherits VS Code's
Mach exception port, which belongs to VS Code's Crashpad handler. The kernel
sends the crash there and waits for an answer before the process can exit. A
crash from a translated process has been seen to crash that handler. Every
handler VS Code started after that crashed within a second of starting, and
from then on every crash in VS Code's process tree waited, a one-line C
segfault included, until VS Code was quit. A steady stream of
`chrome_crashpad_handler` reports in `~/Library/Logs/DiagnosticReports` is the
sign. Run crash tests from Terminal, or with `launchctl submit` or
`./sc in-gui-session`, which start the process outside VS Code. Players start
wrapps from the Finder, so they never inherit VS Code's handler.

`CrashMarker.install(in:)` comes later, once the process knows its log folder.
It reports the previous run's crash when `CrashMarker` caught it, and opens
the marker file.

The app's Debug menu (in a Debug build, or a Release one launched with ⌥ held)
has **Crash Now…**, and the wrapp's `--debug-options` dialog a **Crash Now**
button, for checking a crash end to end.

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

- with no DSN (see [The DSN](#the-dsn));
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

## The DSN

The DSN isn't in the source. The `Stamp Sentry DSN` build phase in both
targets (`WrappTemplate/stamp-sentry-dsn.sh`) reads `SENTRY_DSN` from the
repo's `.env`, which git ignores (`.env.example` lists what goes in it). It
writes the value into the built Info.plist as `SentryDSN`, where
`FailureReporter.bundledDSN` reads it. A build without one — a fork's, a
contributor's, CI's — sends nothing, rather than reporting into the project's
Sentry. A DSN isn't a secret: it can only send events, and every copy of the
app carries it. `.env` is kept out of git so that forks don't share it.

It is a script rather than an `.xcconfig` for two reasons: xcconfig reads the
`//` in a DSN as the start of a comment, and WrappTemplate's Info.plist is
generated, which takes no custom keys. The phase runs on every build, so
editing `.env` takes effect at the next build. `sc release` refuses to publish
a build whose app or WrappTemplate has no `SentryDSN`, and `--build-only` only
warns. `SECOND_CHANCE_SENTRY_DSN` overrides the built-in DSN at run time.

`SENTRY_ORG` and `SENTRY_PROJECT` in the same file tell `sc release` where to
upload debug symbols. It passes them to `sentry-cli` itself, with
`SENTRY_LOAD_DOTENV=0`, so the upload doesn't depend on `sentry-cli` finding
a config file of its own.

## Symbolication

A crash's stack is only addresses until Sentry has the build's dSYMs.
`sc release` uploads `Second Chance.app.dSYM` and `WrappTemplate.app.dSYM`
with `sentry-cli`, and keeps them in `build/release/dSYMs.zip`
([releasing.md](releasing.md)). Wrapps carry the version of the Second Chance
that built them, so one upload covers both. Sentry matches each event to its
symbols by the binaries' UUIDs, not by release name.

## The Sentry project

Set up once, by hand, in Sentry:

- **Platform:** `apple-macos`. Its DSN and the organisation and project slugs
  go in `.env` ([below](#the-dsn)).
- **Security & Privacy:** turn on *Prevent Storing of IP Addresses*, and keep
  the default data scrubbing.
- **Rate limits:** turn on spike protection, and set an alert for new issues.
- **Plan:** the free plan's error and attachment quotas are enough to start
  with. Detailed reports' zips count against the attachment quota.
