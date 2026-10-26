# Polish notes: nine small fixes

A frozen record of a batch of quick notes about rough edges, what each turned
out to mean in the code, and what was done about it. It describes the code as
it was on 2026-10-26; see the docs it links for how things work now.

## The notes

1. "What's in a report?" in Settings should open from anywhere on its row,
   without the scrollbar flickering.
2. Show the log and debug options in the menu bar.
3. Say "Welcome _back_, Detective" to someone returning.
4. Selecting the text of a wrapp's alert worked, but copying it didn't.
5. Hide the window while the unit tests run, or at least keep it out of
   the front.
6. Vertically centre the wrapp's loading text when there is nothing below it.
7. When the game can't be identified, ask whether to choose another disc or
   carry on as "Other".
8. The log window didn't show multi-line entries.
9. Keep the UI responsive throughout a build.

## What each was, and what was done

### 1. The report disclosure

A plain `DisclosureGroup` in a `.formStyle(.grouped)` `Form`. On macOS only
its chevron and title take a click. The Settings window sizes itself to its
content (`.fixedSize(vertical:)`), but a moment after the content grows, so
the grouped form's scroll view briefly showed a scroller.

**Done:** the group is driven by its own `isExpanded` state, with a label that
fills the row and toggles it on a tap. The form hides its scroll indicators,
since the window always fits its content.

### 2. The log and debug options

The Debug menu (`DebugCommands`) held the log window and the testing
switches, but only appeared in a Debug build, or in a Release one launched
with ⌥ held. Otherwise the log was reachable only from the error screen.

Asked whether the log items alone should always be visible, the answer was
instead: _a setting that turns on a developer menu with all of them_.

**Done:**

- The menu is renamed **Developer**.
- **Show Developer menu** in Settings' new Advanced section shows it in any
  build. The setting is read through `@AppStorage`, so the menu appears as
  soon as it is switched on.
- The menu gains **Save Log…**.

### 3. Welcome back

Nothing recorded whether Second Chance had been opened before.
`ReportingPreferences.successReports` came closest, but it stays unset
whenever reporting is off. The decision was that _any earlier launch_ counts
as returning.

**Done:** `LaunchHistory` reads and sets a `hasLaunchedBefore` default once at
launch. This is skipped under test, in headless runs and for the README's
screenshot. Reading it once keeps the greeting from changing while the window
is open.

### 4. Copying an alert's text

The wrapp built its Edit menu (with ⌘C) only partway through `main()`. The
alerts it can show before then had selectable text but nothing to copy it
with:

- the damaged-app alerts
- the `--debug-options` dialog
- the previous run's crash prompt from `FailureReporter.start`

**Done:**

- `Shared/Views/EditMenu.swift` builds the Edit menu, now with Cut and Paste
  as well.
- It also puts up a stand-in menu for an alert that comes before the wrapp's
  own menu.
- The loading window's error text became selectable too.

### 5. The test host's window

`Second Chance.app` hosts the tests, and it opened its window and came to the
front for every run.

**Done:** under test (`TestHost.isRunning`), the app:

- takes the accessory activation policy before it finishes launching
- suppresses the window at launch
- turns off window restoration

### 6. The loading text

`InfoWindowView` copies NSAlert's layout: a 64 pt icon, then a text column
aligned to its top. `LoadingStage.detail` is nil while the game itself is
starting, which left that single line at the top of the icon's height.

**Done:** while loading with no detail and no progress bar, the text column
takes the icon's height and centres its content. Each other state keeps the
top alignment.

### 7. A game that isn't recognised

`GameDetector` returns `unknown`, `GameInfoProvider` turns that into
`GameInfo.unknownGame` ("Other"), and the build carried on to an interactive
installer without a word.

Asked where "choose another" should lead, the answer was _the same picker
again, plus a Cancel back to the home screen_.

**Done:** `WrappBuildInput.askAboutUnrecognisedGame` offers three choices:

- **Choose Another Disc / Download…:** the builder unmounts what it mounted,
  opens the source's own picker again and detects the new choice.
  `DiskWrappBuilder.resolveGame` loops over these steps itself.
  `HerDownloadWrappBuilder` instead throws a private `ChooseAnotherDownload`
  and catches it at the top, because another download may be the other
  format.
- **Install Anyway:** carries on as "Other".
- **Cancel:** throws `userCancelledBeforeStart`, which returns to the welcome
  screen.

A headless run never asks and carries on as before. Steam is unaffected,
because its game is chosen from a list.

### 8. Multi-line log entries

The log window is a SwiftUI `Table`, whose cells show a single line unless
told otherwise. The run's header, for one, is a single entry of several
lines.

**Done:** the cells take `lineLimit(nil)` and size vertically to fit. On
macOS 26 the table then grows each row to fit its entry.

### 9. A responsive UI

The app target's default actor isolation is `MainActor`, so every builder and
service runs on the main thread. Each `waitUntilExit()` and each big
`FileManager` call froze the window.

A Debug-only `MainThreadWatchdog` measured this first: it logs `[Hang]`
whenever the main thread doesn't answer within 0.25 s. A Stay Tuned for
Danger build logged six stalls:

| Stall | Cause |
| --- | --- |
| 4.8 s | Copying the template and the cached Wine prefix |
| 1.0 s | `codesign --verify` on the template |
| 0.9 s | Removing the unused engine (1.4 GB) |
| 0.4 s | `hdiutil attach` |
| 0.35 s | `xattr -cr` |
| 0.36 s | At start-up |

**Done:**

- `Process.output(of:_:)` runs a program on a background thread, reading
  stdout and stderr while it runs.
- `Blocking.run` does the same for any other blocking work.
- These now go through them:
  - hdiutil, codesign, cp, xattr, chmod, exiftool, unzip and `open`
  - the copies of the template, the prefix and AutoIt
  - removing the engine and temporary wrapps
  - the whole-installer read that detects a Her download
  - the patch snapshots

The same build then logged no stalls, and a two-disc Wine build only one, of
0.26 s, at launch. AGENTS.md now carries the rule that blocking work goes off
the main thread.

The full integration run found the Steam path still stalling, for up to
4.4 s at a time:

- `wineserver -k` before Steam's installer
- restoring and saving the cached Steam client (`SteamClientCache`)

Both went the same way. Two Steam games re-run afterwards logged no stalls.
One stall of about 0.3 s remains, reading a long MSI install log, and was
left alone.

## Verification

- Unit tests and lint after each item.
- On a test Mac (`<host>`):
  - the log window with the run's multi-line header
  - the Developer menu in the menu bar
  - "Welcome back" on a second launch
  - the loading window rendered offscreen with and without its detail line
  - headless builds with the watchdog
- The full integration suite, every game from every source, on `<host>`:
  the results are below.

## Integration results

The whole suite, `--source all`, ran in 90 minutes:

- **Disc:** all 33 games passed.
- **Steam:** the 11 games the test account owns passed. The other 22 were
  skipped, because the account doesn't own them.
- **Her download:** both downloads passed (Scarlet Hand for Windows, and
  Trail of the Twister for Mac).

Nothing failed, was overloaded or was locked. After the Steam stalls were
fixed, Message in a Haunted Mansion and Secrets Can Kill Remastered were
re-run from Steam and passed.
