# Changelog

All notable changes to Second Chance.

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

