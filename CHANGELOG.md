# Changelog

All notable changes to Second Chance.

## 0.6.0 — 2026-10-23

### New

- Add support for games downloaded from the Her Interactive digital store, for both Windows and Mac downloads.
- Add crash reporting. If a game fails to build, something goes wrong while you play, or Second Chance itself crashes, it can now send a report so the problem can be fixed.
- Ask whether to send a report each time a game builds and launches successfully, so working games get noticed too, not just broken ones. You're only asked once, and can change your mind later in Settings.

### Improved

- Redesign the main window to walk you through building a game step by step, like a typical installer, with a sidebar showing your progress.
- Tell a slow launch from a stuck one more accurately, so you're less likely to be told a launch may have failed when it's actually still working, and more likely to be told when it really has gotten stuck.
- Show progress while Steam updates itself, and bring Steam's window forward when it needs your attention, such as signing in or asking you to quit a game playing elsewhere.
- Wait for a game's previous session to fully close before starting a new one, instead of showing a confusing warning after a silent wait.
- Give the launch and crash windows a more native look and feel, and make sure all the buttons fit properly on newer versions of macOS.
- Lighten the app's accent colours in dark mode so they're easier to read.
- Fix various accessibility issues, including for VoiceOver users, across both the main window and the game launch window.
- Ask you to quit a game yourself before offering to quit it for you, so you don't lose unsaved progress by accident.

### Fixed

- Offer to move Second Chance into your Applications folder if it's run from somewhere else to fix app translocation issues.
- Ask for disc 2 only once disc 1 has finished copying, with a button to eject disc 1 first, so a Mac with only one disc drive can be used for two-disc games.
- Fix some games not quitting their background processes properly, which could leave things running after you closed the game.
- Fix some Direct3D games going black when moving into or out of full screen on a separate desktop Space.
- Fix a game sometimes being reported as having failed when it actually quit normally.
- Fix the loading window's buttons being pushed off screen on newer versions of macOS.
- Fix a game's window sometimes being waited for even after the game had already quit, which could cause a long, pointless delay.
- Fix the "move to Applications" message being needlessly long.

<details>
<summary>Behind the scenes</summary>

- Added `sc lint` (SwiftLint plus markdownlint for the docs), run in CI and before every release, with `sc setup` checking the tools are installed.
- Fixed Swift 6 concurrency warnings across the app, Shared and the wrapp targets by marking pure value types and already-thread-safe classes `nonisolated`, and cleaned up several other compiler warnings (unused results, deprecated APIs, an Optional printed literally in a log line).
- Removed stale framework/library search paths left over from a deleted Wine engine cache, and skipped App Intents metadata extraction since no target uses it.
- Fixed `sc wrapp build`/`run` and `sc app run` running under `sc`'s own responsible process (causing spurious macOS permission prompts) by spawning with `POSIX_SPAWN_SETEXEC` instead of exec'ing.
- Added `sc test integration --vm <name>` to run integration tests inside a tart VM, for testing another macOS version without taking over the local screen; VM GPUs lack hardware OpenGL so Direct3D launches are reported as skipped rather than failed.
- Fixed `sc --on` using whichever `rsync` came first on each machine's PATH, which could silently drop the template's code signatures depending on the remote's rsync flavor; now pins `/usr/bin/rsync -aE` on both ends.
- Fixed `sc wrapp update` not copying the template's asset catalog, so an accent colour or icon change never reached an already-built wrapp.
- Fixed the test table showing a stuck "pending" row for Her downloads that only have a Mac installer.
- Fixed Her Interactive Windows installers unpacking into a `Disk1` subfolder that the build didn't look in, and made Cider-based Mac downloads keep the few DLLs Wine has no builtin for.
- Added `her-download` as a build source and test suite (`HerDownloadInstallIntegrationTests`) for testing Her Interactive downloads.
- Fixed a build failure before the first progress step inheriting the previous successful build's last-known stage in reports.
- Fixed integration test launches waiting for a game's window after the game process had already exited, and made the wrapp quit only after confirming Wine itself had actually stopped.
- Fixed a Wine error more than 1 second before a quit being wrongly blamed for that quit.
- Made each test launch use its own empty data folder instead of the player's real save/settings folder, so test runs can't pick up a player's local `Waverly.INI` window-mode setting.
- Added `sc app screenshot`, used to retake the README screenshots automatically by sizing the app's window, waiting for it to appear, and capturing it with its shadow.
- Rewrote the README for players, moving build/test/architecture documentation to a new CONTRIBUTING.md, and documented the Her Interactive download formats in docs/her-download.md.
- Fixed a build run from a corrupted copy of the app template failing slowly and confusingly; now checks the template's code signatures up front and fails immediately with a clear error.
- Made the source picker in the main window a real `List` again (for proper VoiceOver/keyboard support) while fixing the pixel-rounding bug that previously caused it to visually "nudge" rows on selection.

</details>

## 0.5.0 — 2026-10-21

### New

- Add crash and failure reporting. If a game fails to build, something goes wrong while you're playing, or Second Chance itself crashes, it can now send a report so the problem gets fixed. The first time this happens it asks how much detail you're comfortable including, and you can change your answer later in Settings.
- Full screen games now behave like other full screen apps on your Mac, so you can switch away to another app or Mission Control and back without losing full screen.

### Fixed

- Fixed The White Wolf of Icicle Creek quitting a few seconds after it starts on some Macs.
- Fixed Second Chance closing silently and without explanation when a game failed to start properly. It now tells you what went wrong.
- Fixed menus closing by themselves a couple of seconds after you open them while playing some games in full screen.
- Fixed your first click sometimes being ignored right after a game goes full screen.
- Fixed the cursor landing slightly off from where you click while playing full screen games on Macs with a notch.

<details>
<summary>Behind the scenes</summary>

- Rewrote the release notes generator's prompt so bullets lead with a short headline, stay to two sentences, drop technical details players don't care about, and avoid telltale AI writing habits (em dashes, "it's not X, it's Y", lists of three, words like "seamless" and "quietly").
- Sped up the release notes rewrite step from 2-3 minutes to about 30 seconds by running it with a faster model and lower reasoning effort, and made it stream its progress (what file it's reading, what it's writing) instead of sitting silently.
- Corrected the documented explanation for why crashed wrapps used to hang beyond kill -9: it wasn't two crash handlers conflicting, it was inherited Crashpad state from being launched inside VS Code. Clarified why the crash reporting SDK still has its own handler stand aside for Sentry.
- Moved the Sentry crash-reporting DSN and project identifiers out of source code and into a gitignored .env file, so forks and other contributors' builds no longer report crashes into this project's Sentry account. The release process now refuses to publish a build with no DSN configured.
- Documented how failure reports work: what each detail level includes, how data is redacted, and the chain of crash handlers involved. Release builds now upload debug symbols to Sentry automatically so crash reports can be matched back to source code.
- Fixed a bug where a crash from the previous run could be resent repeatedly in a loop instead of once, and trimmed a detailed report's process list down to just Wine and Second Chance's own processes instead of every process running on the Mac.
- Added the crash reporting SDK to the app and to each game's generated app, wired up so it stays off during development, testing and headless runs until a reporting key is configured.
- Added a way for a game's wrapper app to detect when a game quit before it actually started (rather than a clean exit from the player quitting), by watching for its first rendered frame and for quit requests reaching the game process directly.
- Fixed games that need a 4:3 display resolution quitting on Macs whose screen doesn't support one, by telling Wine to pretend the switch succeeded and scaling the game's picture to fit instead.
- Fixed the cursor lock in DirectDraw games taking about 5.6 seconds to engage after going full screen; it now takes effect within about 2 seconds by watching for the actual lock instead of waiting on a fixed delay.
- Reworked how the automated test suite captures and clicks through games: it now talks to lightweight in-process helpers built into each game's app over local sockets, instead of relying on screen recording and accessibility permissions, which previously had to be granted and made test runs flakier.
- Fixed the automated tests failing to capture ScummVM-based games on macOS 15 due to how those games report their compatibility version to the OS.
- Fixed the automated tests waiting out long timeouts instead of failing quickly and clearly when a game's window couldn't come to the front because the screen was locked.
- Fixed the automated tests failing to recognize a fullscreen Direct3D game's window as fullscreen, and improved their ability to click through games' intro and splash screens so test runs finish faster.
- Fixed `sc wrapp update` not copying one of the in-process test/diagnostic helpers into an existing game app, which meant test runs were sometimes exercising stale code.
- Changed system load logging so it only logs during a build or game run (and only while load is heavy, rather than constantly), making logs more useful for diagnosing slow performance without spamming them.

</details>

## 0.4.0 — 2026-10-20

### New

- Second Chance now updates itself when a new version comes out.

<details>
<summary>Behind the scenes</summary>

- `sc release` now signs the packaged app with the Sparkle key from the login keychain and publishes an `appcast.xml` alongside the zip on the GitHub release, so the app can find the update. It checks up front that the key in the keychain matches the one the app trusts, and stops before packaging if it doesn't.
- `sc release` now turns the changelog generated from commit messages into notes aimed at players: when Claude Code is installed it rewrites them into New / Improved / Fixed with the developer-only changes tucked into a collapsed "Behind the scenes" section, reading the git history where a commit message doesn't explain itself. Those notes go into the version's section of `CHANGELOG.md` — the copy that gets committed — and the release pauses there so they can be edited by hand. When it continues, it reads that section back and uses it for both the GitHub release and the app's update window. `--plain-notes`, a missing Claude Code, or a failed rewrite all fall back to the generated notes as they are.
- Ctrl-C at one of `sc`'s prompts now actually stops it. The prompt library's key reads blocked on stdin and ignored the cancelled task, so the first Ctrl-C printed "stopping" and hung until a second one killed the process outright, skipping cleanup — which is how `sc release` managed to leave a half-applied version bump behind. Key reads now poll and give up once the task is cancelled, and the prompt throws instead of acting on whatever option happened to be highlighted.

</details>

## 0.3.0 — 2026-10-20

### Bug Fixes

- **sc-cli:** Sc release takes back only its own changes when it stops
- **steam:** List owned games in release order, without "Nancy Drew: "
- **wrapp:** Don't hang when quit before the game has started
- **sc-cli:** Keep both integration suites' progress in sc's game table
- **wrapp:** Open Wine games fullscreen again, Steam-launched ones included
- **wrapp:** Judge the later Her games' exit by their own log, not their exit code
- **steam:** Explain what Steam's local network prompt is for
- **sc-cli:** Undo a failed release's changes
- **sc-cli:** Don't read an unparsed option group in release
- **sc-cli:** Start the app as its own responsible process in wrapp build
- **test:** WrappPuppeteer stops with its test, and ends the wrapp's whole Wine prefix
- **build:** Key the Wine prefix cache on the engine and drop stale prefixes
- **build:** Make copied game discs writable so wrapps can be deleted
- **wrapp:** Bring a slow-starting game to the front when its window appears
- **test:** Count the save warning confirmed once its button has gone
- **test:** Only count the save warning dismissed once it has closed
- **test:** Click Exit again where it was found when OCR loses it
- **build:** Keep working when every core is busy
- **test:** Keep a screenshot when the main menu never appears
- **build:** Retry an installer or patcher that found no display
- **wrapp:** Wait up to 3 minutes for Wine's desktop before a game too
- **build:** Wait up to 3 minutes for Wine's desktop before an installer
- **test:** Give a game's first window 30 s to come to the front
- **build:** Get the Castle Malloy and Blue Moon patchers to finish
- **test:** Never test a wrapp instance an earlier run left behind
- **build:** Wait for an installer's handed-off processes before checking it
- **build:** Find InstallShield 7+'s uninstall log where it keeps it
- **build:** Fail an install its installer never recorded finishing
- **build:** Unmount and report a failure while reading the discs
- **test:** Let processes a test starts write to os_log
- **logging:** Reset the crash handler by hand, since macOS ignores SA_RESETHAND for SIGILL
- **logging:** Log ScummVM not finding the game as an error
- **wrapp:** Say when the game never started, rather than that it exited
- **logging:** Tell an SSH session from the GUI one by launchd's session type
- **logging:** Leave debug chatter out of the summary's Wine output
- **logging:** Name an NSError by its domain and code in the summary
- **wrapp:** Don't report a game stopped by quitting as a failure
- Don't follow links out of the folder being measured
- **wrapp:** Measure linked game folders, and quieten ScummVM shutdown
- **build:** Remove the unused engine whole, so the wrapp still signs
- **build:** Say why a disc image won't mount, and where a save failed
- **sc:** Survive a closed terminal, and unblock signals before exec
- **build:** Catch incomplete installs and discs of the wrong game
- **wrapp:** Report the game's real exit status, and cut routine log noise
- **build:** Strip the unused engine from wrapps
- **wrapp:** Close the info window on the main thread
- **patches:** Run patch installers by their Windows path and check the exit code
- Make wrapp focus-when-started more reliable
- Sign with apple account cert
- **wrapp:** Start Wine's desktop before launching the game
- Test hang issue
- Arch selection
- Caching logic for wine and scummvm
- Don't show cancel error if build not started
- Log to console when run from terminal
- Use native os fullscreen for wine
- Ci tests

### Documentation

- Note the save-progress dialog that holds a hand-launched wrapp
- Move release instructions to docs/releasing.md
- Historical plan for Steam support
- **steam:** Note that sc wrapp build disclaims responsibility for the app
- **steam:** Steam's permission prompts only stall builds run under sc
- Note where InstallShield 7+ keeps its uninstall log
- Record the logging overhaul as a historical plan
- Add more info on wrapp build process
- Update docs after refactor

### Features

- **wrapp:** Offer to launch without Steam under the busy-Mac note too
- **wrapp:** Offer to launch without Steam when a launch through Steam fails
- **steam:** Bring Steam's sign-in window forward, and stop Steam on quit
- **wrapp:** Say whether Steam or the game is loading, and wait longer for Steam
- **sc-cli:** Sc release --build-only skips the tests
- **steam:** Sign in first, then offer only the games the account owns
- **sc-cli:** Sc release --build-only
- **sc-cli:** Commit and tag in release, and offer to publish
- **sc-cli:** Offer to replace an existing changelog section in release
- **sc-cli:** Sc clean steam-session and steam-client
- **steam:** Steam integration suite, and Steam on the welcome screen
- **steam:** Wrapps start Steam for games that need it
- **steam:** Build wrapps from Steam
- **steam:** Steam app data for every game on Steam, and its launch engine
- **steam:** Shared Steam sign-in and a driver for the Steam client
- **wrapp:** Warn on the loading window when the Mac is too busy
- **build:** Apply the wizard-style game patches by driving them with AutoIt
- **wine:** Log what was running when a Wine run times out
- **logging:** Keep log metadata and add a JSON-lines log
- **logging:** Record crashes and termination signals
- **wrapp:** Keep a log file per launch, and capture more bad starts
- **logging:** End failed builds and bad game launches with a summary
- **logging:** Open every log with a context header and run ID
- **wine:** Stream Wine runs and log how each one ends
- **wine:** Let Wine's err class through by default
- **logging:** Classify subprocess output and give log levels a meaning
- Replace control scripts with single cli tool
- **wrapp:** Capture diagnostics when a Wine game starts badly
- Apply all game patches
- Add setup for applying game patches
- Add export/import from log window
- Improve log window formatting

### Performance Improvements

- **wrapp:** Back off the desktop readiness checks as the wait grows

### Refactoring

- GamePuppeteer to WrappPuppeteer
- Use one system for test input injection
- Rename GameWrapper to WrappTemplate
- Use the name wrapp
- Extract headless CLI driver from InstallationViewModel
- Inject dependencies into build services
- Replace InstallationContext with unified WrappBuildInput
- Extract GameInstallerRunner and ISOMounter from install services
- Use swift-log for logging

