# Plan: failure reporting through Sentry

## Context

When a build or a game launch fails, Second Chance currently shows **Save Logs**
and an "Open an issue on GitHub" link (`Shared/Views/BugReportCallout.swift`).
Only the few users who file an issue are ever heard from, and we can't see how
often each failure happens or to which game. This plan adds Sentry so that
failures and crashes reach us automatically, at a level of detail each user
picks.

**What the user asked for:**
- **Default: Basic.** Every failure is reported automatically with almost no
  detail: app version, the game, and what failed.
- **First-failure prompt.** The first time a failure happens, whether in Second
  Chance or in a wrapp, ask whether to send detailed reports from now on.
- **A setting with three levels:**
  - **Detailed:** anonymised logs and diagnostics are attached.
  - **Basic:** only the minimum.
  - **Manual:** each failure asks "Send detailed / Send basic / Don't send".
- Both Second Chance and wrapps report, sharing one setting.
- Real crashes are reported on the next launch.
- Logs are attached only to detailed reports.

## Design

### Report levels and what each sends

| | Basic | Detailed |
|---|---|---|
| App version and build, macOS version, CPU arch, Rosetta yes/no | ✓ | ✓ |
| Process (`app` / `wrapp`), game slug, source (disk / her-download / steam), engine | ✓ | ✓ |
| Failure kind (error type plus case name only, e.g. `WrappBuildError.installIncomplete`, or quit/diagnostics reason, exit code, signal), stage (`LogContext`) | ✓ | ✓ |
| Crash stack trace (symbolicated via dSYMs) | ✓ | ✓ |
| `FailureSummary.render` text, `ErrorChain.describe`, breadcrumbs (recent log lines) | | ✓ redacted |
| Attachment: zip of the log export, newest diagnostics bundle and the user's comment | | ✓ redacted, size-capped |
| Optional email or comment (only if the user types one) | | ✓ |

**Basic must never include message text.** A `localizedDescription` can contain
paths. So basic reports use a new `ErrorChain.identifier(_:)`, which returns
only the type and the enum case label (taken through `Mirror`, without
associated values).

### Settings storage, shared between the app and every wrapp

- Wrapps are separate bundles, so `UserDefaults` won't do. The setting lives in
  a small JSON file at `~/Library/Application Support/SecondChance/failure-reporting.json`:
  `{ level: detailed|basic|manual, promptShown: Bool }`.
- New `Shared/Reporting/ReportingPreferences.swift` reads and writes it
  atomically. A missing file means `basic` with `promptShown = false`.
- It is read fresh at each failure rather than cached, so a change made in
  Second Chance applies to wrapps that are already running.

### SDK set-up (`Shared/Reporting/FailureReporter.swift`)

`FailureReporter.start(process:)` is called right after `AppLogging.bootstrap`
in `SecondChanceApp.init` and in WrappTemplate's `main()`.

**Not started at all when any of these hold:**
- a Debug build, unless `SECOND_CHANCE_REPORTING=1` (same pattern as
  `SECOND_CHANCE_UPDATES` in `SecondChance/Services/AppUpdater.swift:45`);
- `SECOND_CHANCE_REPORTING=0`;
- `NON_INTERACTIVE` is set, which covers headless builds and integration tests;
- `SECOND_CHANCE_PUPPET_DIR` is set, i.e. WrappPuppeteer is driving the wrapp;
- running under XCTest or Swift Testing.

**SDK options:**
- DSN is a constant in Shared, not a secret.
- `environment`: `production` or `development`.
- `releaseName`: `second-chance@<CFBundleShortVersionString>+<CFBundleVersion>`.
  Wrapps share the app's version (both are rewritten by `ProjectVersion`).
- `sendDefaultPii = false`.
- Turned off: `enableAutoSessionTracking`, tracing (`tracesSampleRate` nil),
  app-hang tracking, MetricKit, network breadcrumbs and swizzling. We report
  failures only, not usage telemetry.
- Automatic breadcrumbs are off; our own are added only for detailed reports.
- `beforeSend` runs `ReportScrubber` on every event:
  - clears `serverName` and `user` (keeps Sentry's random installation ID so
    "users affected" still works);
  - reduces device and OS contexts to an allow-list (model family, OS version,
    arch);
  - redacts every string field and debug-image `code_file` path.

**Redaction (`Shared/Reporting/ReportRedactor.swift`)** replaces:
- the home directory, as a path and in its `file://` and percent-encoded forms;
- `NSUserName()` and `NSFullUserName()`;
- the computer name (`Host.current().localizedName`);
- the Steam account name if one is known (check `docs/steam.md` and `Shared/Steam/`
  for where the sign-in name surfaces in logs).

**Crash-handler coexistence.**
- `CrashMarker` currently resets the signal to `SIG_DFL` and re-raises
  (`Shared/Logging/CrashMarker.swift:68-85`), which would skip Sentry's own
  signal handler.
- Change `CrashMarker.install` to save the previous `sigaction` for each signal,
  and have the handler restore *that* before `raise`. Install it **after**
  `FailureReporter.start` so the chain is CrashMarker → Sentry → default, and
  the `.ips` is still written.
- Remove the comment about `SA_RESETHAND` for SIGILL/SIGTRAP only if the new
  behaviour no longer needs it. Restoring the previous handler still avoids the
  loop, as long as Sentry's handler re-raises with the default action in place.

### Dependency and build

- **Package.** Add `https://github.com/getsentry/sentry-cocoa` (`upToNextMajor`
  from the current 9.x) to `project.pbxproj`. Link the **static** `Sentry`
  product into SecondChance and WrappTemplate.
- **Static linking in WrappTemplate is required.** `setupWineFramework` deletes
  `Contents/Frameworks`, and wrapps are only ad-hoc signed on the outer bundle.
- **Arch check.** Confirm the prebuilt xcframework has a macOS `x86_64` slice.
  If it doesn't, use the source-built `SentrySPM` product.
- **Build check.** Extend `WrappTemplate/check-output-collisions.sh` with the
  same three checks it runs for `Logging.framework`, now for `Sentry.framework`.
- **Membership list.** New WrappTemplate-only files go on its
  `membershipExceptions` list. `Shared/Reporting/` files are picked up
  automatically through the `Shared` folder.

### Where failures are reported

All reports go through one API:

```swift
FailureReporter.report(Failure(kind:, stage:, game:, source:, engine:, error:, summary:, attachments:))
```

It reads the setting and returns a `ReportOutcome`: sent with this event ID,
awaiting choice, or not sent. The UI then shows either "Report sent (ID …)" or
the Manual choice.

**Second Chance**
- `WrappBuildViewModel.runBuild`'s catch (`SecondChance/ViewModels/WrappBuildViewModel.swift:182-196`)
  is the single reporting point. It has the raw `Error`, `detectedGame`,
  `selectedWrappSource` and the stage. Cancellation is skipped. The bus
  `.failed` path is not reported, since it fires for the same failure.
- Keep the outcome on the ViewModel so `ErrorView`
  (`SecondChance/Views/WrappBuildProgressView.swift:171-208`) can show it.
- `CLIBuilder` doesn't report, because reporting is disabled under
  `NON_INTERACTIVE`.

**Wrapp**
- `GameLauncher.handleGameTermination` when the run ended badly
  (`WrappTemplate/GameLauncher.swift:250-258`), with `GameQuitCheck.Failure`,
  exit code, signal and the diagnostics bundle.
- `reportSteamFailure` (`GameLauncher.swift:515-529`).
- The `main.swift` configuration and mount failures that `exit(1)`
  (`main.swift:405-441`, `:664-670`, `:730-734`). Call `SentrySDK.flush(timeout:)`
  before the exit.
- **Diagnostics bundles finish asynchronously** after the summary is logged.
  Add a completion signal to `StartupDiagnostics` (e.g. an async
  `waitForBundle()` resumed where it logs "bundle complete", `StartupDiagnostics.swift:239`).
  The detailed report waits on that rather than a fixed delay. The upper bound
  is the capture's own process timeouts.

**Grouping.** `fingerprint = [process, failure kind, stage]`. Game slug, engine
and source are **tags**, so one Wine problem across many games stays one
issue, and Sentry can still filter by game.

### Detailed attachments (`Shared/Reporting/ReportBundle.swift`)

- Factor the formatting out of `LogExporter.export(to:)` (`Shared/LogExporter.swift:21-39`)
  into `LogExporter.render() -> String`, which `export` then writes. Reuse it here.
- Zip into a temp directory: the redacted log text, a redacted copy of the
  newest diagnostics bundle (when the failure has one) and `comment.txt`.
- Cap at about 15 MB compressed: drop `sample-*` files first, then trim the log
  head. Sentry's per-request limit is 40 MB compressed.
- Send with `SentryAttachment(path:)` on the event's scope.
- For crashes, Sentry can't attach scope files. The next launch sends the
  crash, and in detailed mode follows it with an event (same fingerprint)
  carrying the previous run's log from `RotatingLogFile`'s
  `~/Library/Logs/SecondChance/<slug>/launch-*.log`, or the app's mirror if
  there is one.

### UI

**`BugReportCallout` becomes `FailureReportCallout(outcome:)`, used everywhere it is used today:**
- `ErrorView`;
- the wrapp info window's error phase (`WrappTemplate/Views/InfoWindowView.swift:283-304`);
- the "Possible Launch Failure" note (`:213-231`) shows the callout but sends
  nothing until the launch actually fails.

It shows one of three things:
- **Sent:** "A basic/detailed report was sent (ID `ab12cd34`)". It also has an
  **Add details…** button, which opens a comment field and an optional email
  and sends them with `SentrySDK.capture(feedback:)` and `associatedEventId`.
- **Manual:** three buttons, **Send detailed report / Send basic report / Don't
  send**.
- **Not sent / disabled:** the existing GitHub text.

The GitHub link stays in all three. Its URL is now pre-filled
(`issues/new?title=…&body=…`) with the version, game, failure kind and the
report ID.

**First-failure prompt (`Shared/Views/ReportingPromptView.swift`, shown once
when `promptShown == false`):**
- Shown in Second Chance or a wrapp, after the basic report has gone. It explains
  what was just sent and what a detailed report adds.
- Choices: **Send detailed reports**, **Keep basic reports**, **Ask me each time**.
- Choosing detailed also sends a detailed report for *this* failure.
- It sets `promptShown`. It is shown as a sheet over the error screen, not a
  separate window.

**Settings in Second Chance:**
- The app has no Settings scene yet (only `DebugSettingsView`, which isn't
  persisted). Add a `Settings { }` scene with a "Failure Reports" section: a
  three-way picker with a short line explaining each option, and a "What's
  sent?" disclosure that mirrors the table above.
- The menu-bar Settings… item comes with the scene.

**Wrapp menu:** an **About Failure Reports…** item that says the setting lives
in Second Chance and shows the current level.

**Manual mode for crashes:**
- Sentry sends a cached crash on start, so the choice is made before start.
- `CrashMarker.reportPrevious` already knows before the SDK starts that the
  previous run crashed. When the level is Manual and a crash marker is present,
  show the three-way choice first, then start Sentry with a `beforeSend` that
  for this session drops the crash or strips it to basic.
- In a wrapp, this happens before the game launches.

### Release and symbolication (`Tools/sc`)

- `sc setup` checks for `sentry-cli`. The auth token is read from the login
  keychain (generic password `sentry-auth-token`), following the Sparkle key
  pattern in `docs/updates.md`.
- `sc release` (`Tools/sc/Sources/SCKit/Commands/Release.swift`, after the
  build checks around :263 and before the appcast):
  - zips `Second Chance.app.dSYM` and `WrappTemplate.app.dSYM` into
    `build/release/dSYMs.zip`;
  - runs `sentry-cli debug-files upload` with them.
  - Skipped under `--dry-run` and `--build-only`. A failed upload stops the
    release before publish, the same as a signing failure.

### Sentry project settings (one-off, done by hand and written into the doc)

- Platform `apple-macos`.
- **Prevent storing IP addresses** turned on.
- Default data scrubbing kept on.
- Spike protection and an alert on new issues.
- The free Developer plan (5k errors/month) is enough to start. Note the
  attachment quota.

### Docs

- **New `docs/failure-reports.md`:** levels, what each sends, storage file,
  switches (`SECOND_CHANCE_REPORTING`), where the reporting points are, the
  CrashMarker chaining, dSYM upload, Sentry project settings. Add its row to
  `AGENTS.md`'s doc table (`DocsTableTests` enforces this).
- **`AGENTS.md`:** a Gotchas bullet that Sentry must stay statically linked in
  WrappTemplate, that reporting is off in Debug/headless/puppet runs, and that
  new user-facing failures should go through `FailureReporter.report`. Add
  `SECOND_CHANCE_REPORTING` to the debug-switch list.
- **Other docs to update:**
  - `docs/logging.md`: the CrashMarker change and that redaction exists for
    reports;
  - `docs/releasing.md`: the dSYM step and the token;
  - `docs/dev-cli.md`: add `--debug reporting` if added to `sc`;
  - `README.md`: a short privacy section saying what is sent by default and
    how to change it.
- When done, copy this plan to `docs/historical-plans/<date>-failure-reporting.md`
  with its own row.

## Phases (commit each and carry on)

1. **SDK and plumbing.**
   - Package and static linking in both targets, the x86_64 slice check,
     collision-script checks.
   - `FailureReporter.start` with the disable rules and `ReportScrubber`.
   - CrashMarker chaining.
   - A `--debug-options` "Crash now" entry in the wrapp and a Debug-only menu
     item in the app, to trigger a crash on purpose.
2. **Preferences and the basic report path:** `ReportingPreferences`,
   `ErrorChain.identifier`, `FailureReporter.report`, the app's build-failure
   hook and the wrapp's hooks.
3. **Detailed reports:** `LogExporter.render`, `ReportRedactor`,
   `ReportBundle`, the `StartupDiagnostics` completion signal.
4. **UI:** `FailureReportCallout`, first-failure prompt, Manual choice, feedback
   comment, Settings scene, wrapp menu item, pre-filled GitHub URL.
5. **Crashes on next launch,** including the Manual-mode choice before
   `SentrySDK.start`.
6. **`sc release` dSYM upload, `sc setup` check, docs.**

## Verification

- **Unit tests** (`./sc test unit`), new suites in `SecondChanceTests/`:
  - `ReportRedactorTests`: home path, file URL, percent-encoded path, user
    name, full name, computer name.
  - `ErrorChainIdentifierTests`: enum with associated values → case label
    only; `NSError` → domain and code.
  - `ReportingPreferencesTests`: missing file → basic and not prompted;
    round-trip; corrupt file → defaults.
  - `ReportScrubberTests`: build a `Sentry.Event` with a server name, user,
    paths and full contexts. Assert that a basic event keeps only the
    allow-listed fields and that a detailed one has its paths redacted.
  - `FailureReporterGatingTests`: each disable rule (`NON_INTERACTIVE`, puppet
    dir, Debug without the override).
  - `ReportBundleTests`: size cap drops `sample-*` first.
- **Build:** `./sc app build`. The collision script passes. `otool -L` on
  WrappTemplate shows no `Sentry.framework`. `lipo -info` on the WrappTemplate
  binary is still `x86_64`.
- **End-to-end against a `development` Sentry environment**, with
  `SECOND_CHANCE_REPORTING=1` on a Debug build:
  1. Force a build failure with `--debug skip-installer` plus a bad installer
     so `installIncomplete` fires. Check the basic event appears with tags and
     fingerprint and no message text, and that the first-failure prompt shows.
     Choose Detailed and confirm the second event has the zip and no
     `/Users/<name>`. Unzip it and grep for the user name.
  2. Switch to Manual in Settings, fail again and check the three buttons. Each
     one sends a detailed report, a basic report or nothing.
  3. In a wrapp, use `SECOND_CHANCE_DIAG_SLOW_SECONDS=1` to force a diagnostics
     bundle on a game that then fails. Check the detailed report waits for
     "bundle complete" and includes it.
  4. "Crash now" in the wrapp. Check the `.ips` still appears in
     DiagnosticReports, the crash marker line is logged on the next launch and
     the Sentry crash arrives symbolicated, after uploading the Debug dSYM by
     hand. Repeat in Manual mode and check the pre-start choice appears.
- **Integration (on the test Mac, one game):**
  `./sc test integration <game-slug>` still passes, and no events appear in
  Sentry (reporting is off under `NON_INTERACTIVE` and the puppet).
- **Release:** `./sc release --dry-run` names the dSYM step.
  `./sc release --build-only` skips the upload.

## How the implementation differed

Written when the work was done, to record where it departed from the plan
above:

- **The first-failure question is inline, not a sheet.** It sits under the
  report on the error screen (`FailureReportCallout`), which works the same in
  the app's window and a wrapp's self-sizing info window.
- **A crash isn't decided before Sentry starts.** `beforeSend` holds back the
  SDK's event for the previous run's crash. Once the process can show an alert
  and knows where its logs are, it sends the event again at the right detail,
  asking first when the setting says to or on the first failure
  (`CrashReportPrompt`). That needed no UI before the SDK starts, and the same
  path attaches the crashed launch's log to a detailed report.
- **Detailed reports carry no breadcrumbs.** The zipped log covers it.
- **The org and project slugs live in `.sentryclirc`**, and the DSN in
  `FailureReporter.releaseDSN`. Both are left for whoever creates the Sentry
  project to fill in. *(Post-implementation, 2026-10-21, Claude at Callum's
  request: both moved into a gitignored `.env`, whose DSN a build phase writes
  into the built Info.plist — docs/failure-reports.md#the-dsn.)*
- **`sc` gained `--debug reporting`** for trying it from a Debug build.
