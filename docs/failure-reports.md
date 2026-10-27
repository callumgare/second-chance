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
been asked. Where nobody is there to answer (a headless build, a wrapp
WrappPuppeteer drives, a test: `FailureReporter.canAsk`), which happens only
when `SECOND_CHANCE_REPORTING=1` forces reporting on, no alert is shown and a
crash goes at the setting's level, Manual sending nothing.

What each report contains:

| | Basic | Detailed |
| --- | :---: | :---: |
| Version and build, macOS version, CPU architecture, Mac model | ✓ | ✓ |
| `process` (`app` / `wrapp`), game slug, source, engine (tags) | ✓ | ✓ |
| `translocated`, `memory` and `memory_pressure` (tags, below) | ✓ | ✓ |
| What failed, how (`kind`) and the stage: our own fixed words | ✓ | ✓ |
| A crash's stack trace | ✓ | ✓ |
| The `FailureSummary` block (as the event's `summary` extra) | | ✓ |
| `failure-report.zip`: the log, and the diagnostics bundle if there is one | | ✓ |
| In the zip, for a crash: macOS's crash report (the `.ips`) | | ✓ |
| In the zip, for a failure: screenshots of the process's own windows | | ✓ |
| A comment and an email address, if the person adds them | ✓ | ✓ |

**A basic report never contains message text**, because messages and
associated values can hold paths. The kind of a thrown error is
`ErrorChain.identifier`: its type and case (`WrappBuildError.installIncomplete`,
`NSCocoaErrorDomain 513`), with underlying errors in the `caused_by` tag, and
for an error that says how a program ended (`ProgramExitError`: a Wine
program's `WineError.executionFailed` or `.terminatedBySignal`) its
`exit_code` or `signal` tag, so a basic report still tells a program that
couldn't be run at all (126) from one that failed. For a
game run it is how the run ended: `quit-unexpectedly`, `never-started`,
`killed-by-signal`, `exit-code` or `no-window`, with `exit_code`, `signal` and
`diagnostics` tags.

Every event says how detailed it is in the `report_detail` tag (`basic` or
`detailed`), so `report_detail:detailed` in Sentry's search finds the ones
with a zip. A crash sent at the next start also has `crash:previous-run`.

Three tags are there for crashes nobody can explain yet, to see what they
have in common. `translocated` is `yes` when macOS ran the app from a
translocated copy (`AppTranslocation`, and [Moving to
Applications](updates.md#moving-to-applications)). `memory` is the Mac's RAM.
`memory_pressure` is the worst memory pressure the Mac has reported during
the run: `normal`, `warning` or `critical`. Each is set on the scope, which
the SDK stores with a crash, so a crash's report shows them as they were
when it crashed.

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

The zip's text files go through the same redactor (`ReportBundle`), and a
text file that isn't UTF-8 is left out rather than sent unchecked.

The screenshots are the one thing a redactor can't check, so
`WindowScreenshots` decides what is in them. They are of the process's own
windows only: ScreenCaptureKit's current-process content, which needs no
Screen Recording permission. An open or save panel is left out, since it
shows the person's folders and files, and so is the log window, whose lines
name them. Nothing else Second Chance or a wrapp shows is personal. A wrapp's
game draws in Wine's process, not the wrapp's, so a wrapp's screenshots show
its loading and error windows, not the game. The windows are listed on the
main thread, which a wrapp on its way out may be blocking while it waits for
the report, so `capture` gives up after 5 s and the report goes without them.

The SDK runs with everything but crash and failure capture off: no sessions,
tracing, hang tracking, MetricKit, breadcrumbs or network capture
(`FailureReporter.start`). Nothing is sent unless something fails, or the
person has turned on [success reports](#success-reports).

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
  A detailed crash report carries the log of the run that crashed
  (`setRunLogs`: a wrapp's launch logs, the app's run logs) and macOS's own
  crash report, the `.ips` in `~/Library/Logs/DiagnosticReports`
  (`CrashMarker.crashReport`), redacted. The `.ips` has the stack of every
  thread, which matters when the SDK's own capture comes out short: one
  crash came in with a single frame on the crashed thread.

A new failure that someone sees should get a report too: build a
`FailureReport` with fixed words for `what` and an identifier for `kind`.

A process on its way out waits for reports under way: `FailureReporter.wait`
in the wrapp's exit and quit paths and in the app's `finishTerminating`. A
detailed report waits for its diagnostics bundle to finish
(`StartupDiagnostics.bundleWhenComplete`). That wait is bounded by the
capture's own command timeouts.

## Success reports

Failure reports say what breaks, but not how often things work, so they
can't say which games are known to work. Success reports count every build
and every game launch, and how each ended, for people who said yes. They are
Sentry [Application Metrics](https://docs.sentry.io/platforms/apple/metrics/),
sent by the SDK `FailureReporter` started (`Shared/Reporting/SuccessReporter.swift`),
so they are off wherever failure reports are ([When it's off](#when-its-off)).

**The question is asked once, after the first build that worked**, before
the folder picker (`WrappBuildInput.askAboutSuccessReports`, called from
`WrappBuildHelper.finalize`). The main window shows it in place of the
build's progress (`WrappBuildViewModel.successReportsQuestion`), and the
build waits for the answer. Neither button is the default, and no key
picks one. A yes gets a thank-you page before the build goes on. The answer is
`successReports` in `ReportingPreferences`, nil until asked, so a file saved
before it existed reads as not asked. It isn't asked in a headless run or
one that can't report, and Settings changes it after that. A wrapp's
Failure Reports… menu item shows it.

Two counters, each with `game`, `source`, `engine` and `outcome`:

| Metric | Counted in | `outcome` |
| ------ | ---------- | --------- |
| `build` | `WrappBuildViewModel.performBuild` | `ok`, or the failure's `ErrorChain.identifier`. A cancelled build isn't counted |
| `launch` | `GameLauncher.handleGameTermination`, `reportStuckLaunch` | `ok`, or the failure report's kind: `quit-unexpectedly`, `never-started`, `killed-by-signal`, `exit-code`, `no-window`, `stuck` |

A launch is `ok` when the game ended cleanly, by the same test that decides
whether a failure is reported, or when the player quit the wrapp while the
game was running with its window up. Each launch is counted once. A wrapp
reads its source from `GameSource` in `AppSettings.plist`; one built before
that was written says `unknown`.

`beforeSendMetric` (`SuccessReporter.scrub`) drops a metric when the answer
is no longer yes, and cuts the rest down to `SuccessReporter.allowedAttributes`.
The SDK adds the scope's tags, the installation ID and the Mac's details
before that hook runs, so a success report leaves with which game and how it
went, the Second Chance release and environment, and the macOS version:
nothing that says whose Mac it was.

**What isn't counted:** anything before the question has been answered.
Someone whose first build fails is never asked, so that failure exists
only as a failure report, and nothing is held over to send if they say yes
later. To see which games work, read success rates (`outcome:ok` over all of
a game's `launch` or `build`) in Sentry's Metrics explorer, grouped by
`game` and `source`. Read them alongside the failure issues, not instead of
them.

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

### Child processes

**Start Wine with `runWithoutCrashHandler()`, never a bare `run()`**
(`Shared/ChildProcess.swift`). A child inherits its parent's task exception
ports, so with reporting on, a child's bad memory accesses are sent to
Sentry's Mach exception handler inside Second Chance or the wrapp, rather than
becoming a signal in the child. Windows programs fault on purpose all the
time, and Wine turns each fault into a Windows exception through that signal.
Sentry answers one fault on each of its two handler threads. It files each as
a crash of ours, puts back our own ports and replies, and then neither thread
is left listening. From the child's third fault on, the faulting thread waits
in the kernel for an answer that never comes.

The sign is a Wine program that sits at 0% CPU with nothing in its output,
alongside a Sentry crash report for Second Chance or a wrapp that never
crashed: an `EXC_BAD_ACCESS`, often at address 0, from code at a `0x2…`
address (Wine's code, translated by Rosetta), with no process name. That is
how White Wolf's silent install hung for 30 minutes in a Release build.
Debug, headless and test runs never showed it, because reporting is off in
all of them; `SECOND_CHANCE_REPORTING=1` with a `SECOND_CHANCE_SENTRY_DSN`
that goes nowhere turns it on without sending anything, which is how it was
reproduced
([the investigation](historical-plans/2026-10-26-sentry-exception-ports.md)).

`runWithoutCrashHandler()` clears our exception ports, starts the child, and
puts them back, all under a lock. The child, and anything it starts, keeps
the default ports, so its faults reach Wine. A crash on another of our threads
in that moment still reaches Sentry's signal handler; only its Mach handler
misses it. `WineEnvironment`, `WineUtilities`, `SteamClient`, `WineManager`
and `TaggedProcess` (winetricks, ScummVM) start their processes this way. A
SwiftLint rule (`wine_without_crash_handler`) rejects a bare `run()` in
`Shared/Wine/` and `Shared/Steam/`, and `ChildProcessTests` checks that a
child started this way faults normally while one started with `run()`
hangs.

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

The app's Debug menu ([docs/logging.md](logging.md#where-each-log-lives) says when it
shows) has **Crash Now…**, and the wrapp's `--debug-options` dialog a **Crash Now**
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
  the default data scrubbing. Add `game` to *Safe Fields*. The default
  scrubbing hides any value containing "secret", so without that the
  Secrets Can Kill games' slugs reach a [success report](#success-reports)
  as `[Filtered]`. A slug is one of ours, never anything personal.
- **Rate limits:** turn on spike protection, and set an alert for new issues.
- **Plan:** the free plan's error and attachment quotas are enough to start
  with. Detailed reports' zips count against the attachment quota.
