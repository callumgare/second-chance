# Steam

Steam-sourced wrapps run the real Steam client inside the wrapp's Wine
prefix: some games will only run with a signed-in Steam, and Steam's own
sign-in window (with QR sign-in) means Second Chance never handles a password.
The parts that drive it live in `Packages/SecondChanceKit/Sources/SecondChanceKit/Steam/`,
part of the shared package the app, the wrapp and WrappPuppeteer all use.

Steam builds and Steam wrapps work end to end, tested by
`sc test integration --source steam` ([testing.md](testing.md)).

**Steam's permission prompts, under `sc`.** At start-up Steam touches the
microphone (voice chat) and the local network (Remote Play / LAN discovery).
macOS attributes that to the responsible Mac app:

- **Second Chance or a wrapp** (an app bundle): with no microphone usage
  description, macOS quietly declines the microphone and Steam carries on.
  The local network can still raise "Allow 'Second Chance' to find devices
  on local networks?". macOS fixes that title, but the text under it is the
  app's `NSLocalNetworkUsageDescription` (`INFOPLIST_KEY_…` in the app and
  WrappTemplate build settings), which says it is for Steam, why Steam wants
  it, and that Don't Allow is fine. Don't add a microphone description: with
  one, macOS would ask about the microphone instead of declining it.
- **`sc`** (a bare command-line tool): macOS asks — "Allow 'sc' to find
  devices on local networks?", "'sc' would like to access the Microphone" —
  and **Steam hangs until both are answered**: on a test Mac a build's Steam
  sat for 20 minutes, then signed in in 66 s once they were. Rebuilding `sc`
  makes macOS ask again, as it's a new binary.

So `sc wrapp build` starts the app as its own responsible process
(`Proc.stream(…, disclaimResponsibility: true)`, using the private
`responsibility_spawnattrs_setdisclaim`): the app answers for itself and
macOS asks nothing. Checked with a freshly rebuilt `sc`, which used to
prompt again every time. `sc wrapp run`, `sc wrapp wine` and `sc app run`
replace `sc` with the program they start (`Proc.exec`), and do the same
there: `posix_spawn` with `POSIX_SPAWN_SETEXEC` is an exec that takes the
disclaim attribute, where a plain `execv` kept the program `sc` to macOS. A
Steam wrapp run that way waited on "'sc' would like to access the
Microphone". Anything else that runs the app under `sc` without either — or
the test host under xcodebuild — can still meet the prompts; answer them
(the microphone can be refused).

## Building

`SteamWrappBuilder`, in order:

1. **Take the Steam lock.** While a game has it, ask what to do about it
   (`WrappBuildInput.askAboutSteamInUse`, below); a headless build fails
   with `steamInUse`, naming the game.
2. **Make the wrapp and install the Steam client into it** — the template,
   the cached prefix, then Valve's `SteamSetup.exe /S` (downloaded once to
   `~/Library/Caches/SecondChance/`). Not `winetricks steam`: it installs
   Microsoft's core fonts first, which needs `cabextract`, which isn't
   bundled, and Steam doesn't need them under the bundled Wine. Then lay the
   cached updated client
   over it (`SteamClientCache`, `~/Library/Caches/SecondChance/steam-client`),
   so Steam's own update (most of a gigabyte) is downloaded once, not per
   build. The cache leaves out the account's sign-in, licences, settings and
   games.
3. **Sign in**: restore the shared session and start Steam silently. With no
   session, or one Steam rejects, the GUI brings Steam's window to the front
   once Steam has asked for a sign-in and the window is up (as a wrapp does;
   see [Running](#running)), only then says to sign in there (QR or
   password), and waits up to 30 minutes. ⌘C and ⌘V work in it: the build
   has ⌘ act as Ctrl for `steam.exe` and `steamwebhelper.exe` alone
   (`WineRegistry.letCommandActAsControl`), as Wine otherwise keeps ⌘ for
   its own Mac menu and a Windows program knows only Ctrl. A headless build fails
   with `steamSignInRequired` instead. A Steam that exits first — missing
   from eight checks two seconds apart, since it restarts itself after an
   update — is started once more, and exiting again fails the build with
   `steamExited`. A first start that crashed part-way through its update
   otherwise sat out the whole 20-minute wait for a Steam that was gone.
   Until it signs in or asks, the progress line says what Steam is doing —
   "Starting Steam", "Updating Steam", "Connecting to Steam". What Steam is
   doing comes from `SteamSignInWatch`, which a wrapp uses too (see
   [Running](#running)): each check returns what has happened since the
   last (a new start-up stage, a request to sign in, signed in, exited,
   stuck), and the build acts on it with its own deadlines and restart.
   The watch logs each of those as `[Sign-in]` lines, and while nothing
   changes, a line a minute saying what Steam is doing and how long ago its
   logs last changed, so a log shows how far a stalled Steam got.

   **A Steam that goes quiet while signing in** is handled by
   `SteamStallPolicy`, which a wrapp follows too (see [Running](#running)),
   from what the watch sees of Steam's logs. Any write to any of them counts
   as activity, an update's progress included:

   - **Quiet for 2 minutes** (`SteamSignInWatch.quietLimit`, halved; every
     time here is tripled while the Mac is heavily loaded,
     `LoadingStage.heavyLoadFactor`), before it has signed in or asked for
     credentials: a notice says signing in is taking longer than usual, and
     counts down to Steam being started again. A write takes it back.
   - **Quiet for 4 minutes**: stuck. Steam is stopped and started again by
     itself, with the progress line saying so. Once one sat for 20 minutes
     having written nothing since it found its files up to date, when the
     next game's Steam, with the same sign-in, signed in within a minute.
   - **Stuck again**: Steam is left running, and the notice offers **Sign
     In Again** (`SteamSignInNotice.stuck`). It goes if Steam signs in or
     asks for credentials by itself. Taking it up signs out of Steam (as
     *Sign Out of Steam* does), takes the sign-in out of the prefix
     (`SteamSessionStore.strip`), and starts Steam again, which then asks
     for a sign-in. The build hears the button through
     `WrappBuildInput.takeSteamSignInAfreshRequest`.
   - **Stuck after that**, or a second time in a headless build, which has
     nobody to offer it to, fails with `steamStoppedResponding`, as does a
     Steam that keeps writing but neither signs in nor asks within 20
     minutes. Its error screen's **Try Again** signs out of Steam first, in
     case the saved sign-in is what it's stuck on, and says so. Nobody
     signing in to Steam's window within the 30 minutes is
     `steamSignInTimedOut`, whose Try Again just starts again.

   The notices' words are `SteamSignInNotice`'s, so the build's progress
   screen and a wrapp's loading window say the same.

4. **Pick the game from the ones the account owns** (`ownedAppIDs`), so
   nobody is offered a game Steam won't install. From the app,
   `WrappBuildInput.chooseSteamGame` lists only those (`steamNoGamesOwned`
   when there are none), asking in Second Chance's main window, in place of
   the progress, which comes to the front as the person has just been in
   Steam's window (`WrappBuildViewModel.ask`); for a DRM-free one it then asks how it launches
   (`getSteamLaunchMode`, `STEAM_LAUNCH_MODE`), and the engine follows
   (`engineRouted`). Steam only installs a queued game when it starts, so the
   build then stops Steam — saving the session but leaving it in the prefix —
   queues the install and starts Steam again, which signs straight back in.
   A game named up front (`STEAM_GAME_SLUG`: headless builds and the
   integration tests) is read before anything else, queued before Steam's
   first start, and checked against the licences here instead
   (`steamGameNotOwned`), so it needs no restart.
5. **Wait for the install**, showing Steam's phase — "Downloading 397 MB
   through Steam", "Checking the download", "Finishing the install" — and,
   while it downloads, how far it has got: the progress bar fills, with
   "1.2 GB of 2.4 GB, about 3 minutes left" under it (`SteamDownloadMeter`,
   below). A download that gets nowhere for a minute says so on the
   progress screen (check the internet; Steam carries on by itself once it
   can), and one that gets nowhere for 30 minutes fails the build with
   `steamDownloadStalled`. A Steam that exits meanwhile, missing from eight
   checks in a row as during the sign-in, fails the build with
   `steamExitedWhileInstalling` rather than leaving it to wait out the
   four-hour limit.
6. **Stop Steam, save the session, and take the sign-in out of the wrapp.**
   The build runs Steam inside the wrapp's own prefix, so without this the
   finished `.app` would carry the account's token, and anyone given a copy
   could use the account. A wrapp gets the sign-in from the shared store when
   it runs, and on a Mac without one asks for it once. Then release the
   Steam lock: nothing after this uses Steam, and a wrapp opened while the
   build saves itself would otherwise find Steam taken by the build.
7. **Configure.** A game that runs without Steam is moved out of
   `steamapps/common/` into `Program Files (x86)/Nancy Drew/`, and the Steam
   client is deleted; otherwise its exe stays in Steam's library and
   `AppSettings.plist` gets `SteamGameId`. `SteamLaunchMode` records the
   user's choice. Her Interactive's patches are not applied: Steam's build is
   current, and the patchers refuse it ([game-patches.md](game-patches.md)).

Steam is stopped on the failure path too, and the session saved if it signed
in, so a failed build neither leaves Steam running nor loses a refreshed
sign-in. Quitting Second Chance mid-build stops it as well: each build
registers its running Steam with `RunningSteam`, and the app waits for it to
shut down (10 s, then by force) before deleting the temporary wrapp it runs
from. Otherwise quitting with Steam's sign-in window open left that window,
and Steam's whole Wine session, running. `./sc wrapp build <slug> --from
steam` runs the whole thing headless.

## Which games, and how they launch

`GameInfo` carries each game's Steam app ID, install folder (under
`steamapps/common/`) and Windows executable, taken from Steam's app info.
30 of the 33 games are on Steam; the original Secrets Can Kill and Stay Tuned
for Danger aren't (Steam's Secrets Can Kill is the Remastered edition), and
Ransom of the Seven Ships (31980) is no longer sold but still installs for
those who own it.

The engine a Steam wrapp uses (`GameInfo.steamEngine(launchMode:)`):

| Game | Choice offered | Engine | Starts by |
| --- | --- | --- | --- |
| one ScummVM runs from disc, any `steamDRM` | none | `.scummvm` | ScummVM on Steam's files; Steam is removed from the wrapp |
| `.yesLaunchViaSteamOnly`, `.yesLaunchWhenSteamRunning`, or not worked out (`nil`) | none | `.wineSteam` | `steam.exe -applaunch <id>` |
| `.no` | "via Steam" | `.wineSteam` | as above |
| `.no` | "directly" | `.wine` | the exe; Steam is removed from the wrapp |

**Everything that needs Steam is launched by Steam** (`-applaunch`), which
works whatever the DRM. The other way — Steam `-silent`, then the wrapp
starting the exe itself (`.wineSteamSilent`, still understood by the wrapp) —
left Blue Moon's Steam release running with no window for minutes, though
its `steamDRM` says it only needs Steam running; through `-applaunch` its
window was up in a second.

**The ScummVM games always run in ScummVM**, so they get no launch choice
and no Steam Cloud saves. Their Steam release is the Windows exe, and run
under Wine it ignores the mouse — its cursor stays put while clicks land
elsewhere — while ScummVM reads only the data and so doesn't care about the
exe's DRM.

The choice (`offersSteamLaunchChoice`) is put to the user without naming
engines: launching directly is quicker and more reliable, launching via Steam
keeps Steam Cloud saves. A game whose DRM is worked out and set in
its bundle's `drm` ([program-bundles.md](program-bundles.md)) gets the faster path from then on.

## Running

A wrapp whose game needs Steam (`wine-steam`, `wine-steam-silent`) does it in
`WrappTemplate/WrappSteam.swift`, before the game starts:

1. **Take the Steam lock.** While another game has it, ask the player what
   to do about it (`GameLauncher.takeSteam`, below). Choosing not to quit it
   ends the launch without a failure report. `WrappSteam` is then given the
   lock, and gives it up when it finishes.
2. **End any Steam left over** from a run that was force-quit or crashed —
   it would still be running in this prefix, signed in.
3. **Restore the shared sign-in, start Steam silently, wait for it to sign
   in.** This happens behind the save warning, so Steam is usually signed in
   by the time the player has read it; only the game waits for **I
   Understand**. Without a sign-in, the loading window says to sign in in
   Steam's window, and waits for as long as Steam keeps running — there is
   no time limit, and a Steam that exits ends the wait
   (`WrappSteam.Failure.exited`). It follows Steam with the build's
   `SteamSignInWatch`, checking every second and whether Steam is still
   running every five, and logging the same `[Sign-in]` lines. Steam going
   quiet is handled by the same `SteamStallPolicy` as a build's, its notices
   in the loading window in place of the stage's own slow and
   possible-failure notes. Stuck after signing in afresh, the launch fails
   with "Steam got stuck signing in" (`WrappSteam.Failure.stuck`). Steam's sign-in window is brought
   to the front as soon as Steam asks (`SteamSignInWindow`): Steam may have
   spent minutes installing and updating itself first, and the player has
   likely gone to another app meanwhile. A build from the app does the same.
   It finds the window as the largest on screen owned by `steam.exe` or
   `steamwebhelper.exe`. Only one Steam runs at a time, so that window is
   this Steam's. It activates that process the way the wrapp brings a game
   forward. Since macOS 14 that is cooperative, so it can be refused when
   neither the wrapp nor the app is the active one, which shows as a warning
   in the log.
4. **Start the game.** `wine-steam` asks Steam to (`-applaunch`): no launcher
   of the wrapp's own to watch, so the game is found, and watched, by its exe;
   `wine-steam-silent` starts the exe itself, as a Wine game does. Startup
   diagnostics are timed from here, not from Steam's start.

   **Steam plays one game per account at a time.** If the account is
   already playing on another computer, Steam's launch stops at its
   `KickingOtherSession` step and asks whether to stop the game there, and
   the game only starts once the player answers. While it waits for the
   game, the wrapp reads Steam's `logs/console_log.txt` every couple of
   seconds for the step its launch is waiting on (`SteamLogs.launchPrompt`;
   Steam logs `LaunchApp waiting for user response to <step>`). On that one it
   logs `SteamLogs.playingElsewhereMarker` as an error, switches the loading
   window to "Your Steam account is playing on another computer"
   (`LoadingStage.steamPlayingElsewhere`, no clock), and brings Steam's
   window forward. The integration test fails with that reason instead of a
   timeout. The step's name comes from Steam's client (`SteamUI.dll`),
   not from a launch seen to stop there.
5. **When the game ends, or the wrapp quits:** stop Steam, save the sign-in
   back to the store, take it out of the wrapp, release the lock. On quit this
   is cut short (10 s for Steam) to fit inside the wrapp's 15 s quit fallback.

The loading window names each step (`WrappSteam.Status`, shown as a
`LoadingStage`): "Starting Steam…"; "Updating Steam…", with a progress bar,
while the bootstrapper updates the client (`SteamLogs.bootstrapPhase`);
"Connecting to Steam…" once the client is signing in
(`SteamLogs.isConnecting`) — those three from `SteamStartupWatch`
(`Shared`), which a build's sign-in wait follows too; the sign-in prompt if it needs one; then "Steam
is starting *Title*…". Each has its own clock for the "taking longer than
usual" note and the possible-launch-failure warning, set from launches timed
on a loaded Mac and described in [wrapp-launch.md](wrapp-launch.md): a
stalled update is one with no new progress line for 30 s, and Steam's own
programs' CPU and log writing never count as progress, as Steam does both
when idle. Waiting for the player to sign in, or to answer any other
question in Steam's window, has no clock. The warning leaves the spinner up,
since the launch may still succeed; a launch that has definitely failed
shows the error instead.

Any launch step Steam waits on, apart from the ones it passes through by
itself (`SteamLogs.routineLaunchPrompts`: `ShowInterstitials`,
`CreatingProcess`), counts as a question for the player once it has lasted
a few seconds: the loading window says Steam is waiting for them
(`.steamWaitingForPlayer`) and Steam's window comes forward. `ShowInterstitials`
is routine but not always quick: it usually takes 1–3 s, and has taken 30 s
with nothing else stirring, which is why Steam starting the game gets 45 s
without a sign before it counts as stalled.

**A DRM-free game the user chose to launch via Steam can fall back to
launching directly.** Both the possible-launch-failure warning and the error
offer **Start Without Steam** (starting the game without Steam) when `AppSettings.plist` has
`SteamLaunchMode` = `steam` (`GameConfig.canLaunchWithoutSteam`). On a
heavily loaded Mac the busy-Mac note replaces the warning, but the offer
still appears under it once the warning would have; a game with
DRM never had the choice, has no `SteamLaunchMode`, and isn't offered it.
Picking it quits the wrapp the usual way — Steam stopped, the sign-in saved,
the Wine session ended — and then opens a new instance with
`--launch-without-steam`, which runs as engine `wine` on the exe still in
Steam's library (`GameConfig.withoutSteam()`), without the save warning the
player has just seen. It is for that launch only: the next one goes through
Steam again. Saves are the same folder either way; only the Steam Cloud sync
is skipped.

A wrapp moved to a Mac without the store asks for the sign-in once and
creates the store there. A wrapp that's killed outright (SIGKILL, a test
harness timing out) can't stop Steam; the next launch cleans it up (step 2).

## One sign-in for every wrapp

Each wrapp has its own Steam install, so wrapps stay self-contained. The
*sign-in* is shared: `SteamSessionStore` keeps it in
`~/Library/Application Support/SecondChance/Steam/session/` (mode 0700),
copies it into a wrapp's prefix before its Steam starts, and copies it back
after Steam quits.

A remembered sign-in is exactly these, found by trying subsets of them in a
Steam that had never signed in:

| What | Where, in the prefix |
| --- | --- |
| The remembered accounts | `drive_c/Program Files (x86)/Steam/config/loginusers.vdf` |
| Steam's config (the token is rejected without it) | `drive_c/Program Files (x86)/Steam/config/config.vdf` |
| The token (a JWT, valid for months) | `drive_c/users/crossover/AppData/Local/Steam/local.vdf` |
| Which account to sign in as | `HKCU\Software\Valve\Steam\AutoLoginUser` |

The registry value is stored as a `.reg` fragment and imported with
`wine reg import` (`SteamClient.restoreLogin`); on the way back it is read
straight out of the prefix's `user.reg`, which is why capturing waits until
Wine has stopped and written it out.

The token is not tied to the prefix: the same copy signs in again and again,
and in a prefix with a different `MachineGuid`. So a new prefix — after a
Second Chance update, say — keeps the sign-in.

Rules the store follows, each from something seen to go wrong:

- **Only a run that signed in is saved.** When Steam rejects a token it
  rewrites `local.vdf` without one; saving that would sign every wrapp out.
  `capture(from:signedIn:)` refuses unless the caller says Steam signed in.
- **The newer session wins.** If another wrapp saved a session since this one
  restored (by `local.vdf`'s modification time), this one's is dropped.
- **Restores and saves take a lock** (`session.lock`, an `flock`), and a save
  is built beside the old session and swapped in, so a failure leaves the old
  one whole.
- **Nothing logs file contents.**

Signing out — Second Chance's *Sign Out of Steam*, or `sc clean
steam-session` — deletes the store; every Steam wrapp then asks for a
sign-in once. The menu item is there only while the store holds a sign-in
(`StoreSignIns`, which looks again each time a menu opens or Second Chance
comes to the front, since builds and wrapps save and drop it). `sc clean steam-client` drops the cached Steam client.

## One wrapp on Steam at a time

Two wrapps signed in to the same account would knock each other off, and race
to save the session. `SteamActiveLock` is an `flock` on `active-wrapp.lock` in
the same directory, recording the holder's pid and bundle ID (a build
records `SteamLockHolder.buildBundleID` instead). Being an `flock`,
it is released when the holding process exits, however it exits. The file is
opened close-on-exec, so Wine and Steam, started from the holder, never
carry the lock on after it.

A second taker gets `.heldBy(SteamLockHolder)`. A build and a wrapp both wait
for it through `SteamActiveLock.take`, which asks what to do each time it is
held and acts on the answer, so each only decides what being left without it
means: a cancel or a failure for a build, a quiet end to a wrapp's launch.
`SteamLockHolder.name` is
the holding wrapp's name as the person knows it (its game's title, from the
running app), found only while the pid in the record is still an app with
that bundle ID. `ask` shows the choice a build and a wrapp both offer, as an
alert in a wrapp; a build asks the same `prompt` as a page of Second Chance's
window (`BuildQuestion`):

- **Try Again**, the default. The alert asks them to save their game and
  quit it themselves, then click this.
- **Quit It Without Saving**, the fallback, last, for a game that won't
  quit; the alert says that anything not saved in it will be lost, and the
  button is marked as losing work: `hasDestructiveAction` on the alert (the
  only warning style macOS 26 lets an alert button take; it ignores a red
  title), and a red title on the error screen and the build's page, where SwiftUI's
  `role: .destructive` alone draws no colour on a push button. `quit` asks the
  wrapp to quit as Cmd-Q would, which stops its Steam and saves the sign-in
  back. A wrapp still running 40 s later gets SIGTERM, which it treats as a
  quit, ending itself 15 s on. 20 s after that it gets SIGKILL. A wrapp that
  didn't quit itself leaves its Wine session (the game, Steam signed in)
  behind, so `quit` then stops that with `wineserver -k`. The waits end as
  soon as the process exits (`waitForExit`, a kqueue process source).
- **Cancel**. For a build this is a cancel before it started, so the app
  goes back to the welcome screen with nothing reported.

A build holding the lock is never offered to be quit: the person can only
wait for it, and try again.

A build that still fails with `steamInUse(SteamLockHolder)`, because the game
didn't quit, ends on the error screen. That screen keeps the same order: the
message asks them to save and quit the game themselves, **Try Again** is the
default button (`retrySteamBuild`), and below the message the same fallback
offers **Quit It Without Saving** with its warning (`SteamHolderFallback`,
`quitSteamHolderAndRetry`), which tries again once the game has gone.

Game names in these alerts and screens are in curly quotes
(`SteamLockHolder.quoted`), as macOS quotes app names in its own alerts,
since a title's own dashes and colons otherwise run into the sentence.

## Driving Steam

`SteamClient` (behind the `SteamClientDriving` protocol, the seam tests use)
runs `C:\Program Files (x86)\Steam\steam.exe` in the prefix:

- **`start(silent:)`** starts Wine's desktop first, as every Wine program does
  ([wrapp-launch.md](wrapp-launch.md#wines-desktop)). The bootstrapper
  exits **42** when it hands over to an updated client — not a failure.
- **Signed in or not** comes from Steam's logs, not its files:
  `logs/connection_log.txt` (`RecvMsgClientLogOnResponse() : … 'OK'`) and
  `logs/steamui_login.txt` (`SetLoginState: WaitingForCredentials`, with the
  reason, e.g. `Invalid Password` for a rejected token). Both logs keep earlier
  sessions, so the client only reads what was written since it started them.
- **Updating itself** comes from `logs/bootstrap_log.txt`
  (`SteamLogs.bootstrapPhase`): a start with nothing to update logs only
  `Verifying installation...` and `Verification complete`. One that updates
  — because Valve has released a newer client (`Checking for update on
  startup`, then `Downloaded new manifest: … version N, installed version
  M`), or because a file failed the size check — logs a `Downloading update
  (X of Y KB)...` line about four times a second, `Download complete.`,
  `Installing update...`, `Extracting package...`, `Installing update...`
  again and `Update complete, launching Steam...`, after which the restarted
  bootstrapper checks its files again. The cached client a build lays in
  (`SteamClientCache`) is the version of the day it was cached, so a wrapp
  whose Steam Valve has since updated downloads that update on its next
  start: about 100 MB, seconds on a fast connection.
  A couple of minutes after the client starts, a `Background update loop`
  checks for a newer client and may download one to install at the next
  start; that isn't this start's update, so it's ignored.
- **Connecting** comes from the connection log's state, in every line
  (`[Logged Off, …]`, `[Connecting, …]`, `[Logged On, …]`): from
  `LogOn() called` to `Logged On` takes a couple of seconds online.
- **The launch's steps** come from `logs/console_log.txt`
  (`LaunchApp changed task to <step>`, `SteamLogs.launchStep`): each new one
  is the launch getting somewhere, and the steps it waits at are
  `SteamLogs.launchPrompt`.
- **Installing:** with Steam *not* running, `queueInstall` writes a minimal
  `steamapps/appmanifest_<id>.acf` (`appid`, `Universe`, `installdir`,
  `StateFlags` 1026); the next start installs it with no dialog.
- **Ownership must be checked first.** Steam says nothing at all about an app
  the account doesn't own — its manifest just sits there. `ownedAppIDs` reads
  the account's licences from `appcache/packageinfo.vdf`, which Steam writes a
  few seconds after signing in, so it waits for that file.
- **Steam doesn't say how far its download has got.** The manifest's
  `BytesDownloaded` stays 0 until the download is over.
  `logs/content_log.txt` gives the total size (`update started : download
  0/<bytes>`), the phase (`Preallocating`, `Downloading`, `Staging`,
  `Verifying Staged`, `Committing`, then `Fully Installed`), which
  `installPhase` reports, and `Current download rate: <n> Mbps` only once a
  minute. The download folder is no help either: preallocation gives its
  files real blocks, not sparse ones, so `du` jumps to nearly the whole size
  in the first second (1.9 of 2.4 GB) and then barely moves.
- **So the download is measured by Wine's network traffic.**
  `SteamDownloadMeter` reads `nettop -P -L 1 -x -J bytes_in` (no permission
  needed, a few hundredths of a second) every couple of seconds and sums
  the bytes received by Wine's processes — `wine`, `wineserver` and the
  Windows programs nettop names by their exe — from the moment the
  download starts. Only the sum means anything: a connection's count sits
  with `wineserver` in one sample and with the program using it in the
  next. A process that exits takes its count with it, so only growth
  counts. Measured on a 2.4 GB download (Ghost of Thornton Hall), the sum
  grew a steady 47 MB every 3 s, matching Steam's own 122 Mbps, and ended
  about 1 % over Steam's figure, which is Steam's other traffic; the bar
  stops at 99 % for that reason. It counts any other Wine program on the
  Mac that downloads at the same time, which only one Steam at a time
  makes unlikely. Without `nettop`, the build shows the phase alone.
- **`shutdown(timeout:)`** runs `steam.exe -shutdown`, releases the desktop and
  waits for the prefix's Wine session to end. It sends `-shutdown` only while
  `steam.exe` is running: with no Steam to tell, it starts a Wine session of
  its own, whose errors as the wrapp is deleted beneath it ended up in the
  failure summary. Steam usually goes in seconds but
  has been seen to leave a web helper running for minutes, so after the
  timeout it stops the wineserver.

**Steam writes its logs with Windows line endings.** In Swift `"\r\n"` is a
single `Character`, so `split(separator: "\n")` never splits them; split with
`whereSeparator: \.isNewline`.

## Steam's file formats

`VDF.swift` reads Valve's KeyValues: the text form (manifests,
`loginusers.vdf`; keys are case-insensitive) and the binary form of the caches
in `appcache/` — `appinfo.vdf` (formats 27–29; 29 keeps keys in a string table
at the end of the file) and `packageinfo.vdf`. `SteamCaches` builds on it:
owned app IDs, and each app's name, install folder and launch executables.

## Testing

The unit suites (`SteamVDFTests`, `SteamSessionTests`) use synthetic data —
real Steam caches and manifests carry the account's IDs and don't belong in
the repo.

`SteamClientSmokeTests` drives a real Steam: restore a saved sign-in into a
wrapp whose Steam has never signed in, install a game, quit, save the session.
It is off unless pointed at a wrapp, and needs a Steam account that owns the
game:

```bash
TEST_RUNNER_STEAM_SMOKE_WRAPP=<wrapp with Steam installed, signed out> \
TEST_RUNNER_STEAM_SMOKE_STORE=<a scratch session store> \
TEST_RUNNER_STEAM_SMOKE_SEED_PREFIX=<a signed-in prefix to seed the store from> \
./sc test unit
```

`TEST_RUNNER_STEAM_SMOKE_APP=<app ID>:<install dir>` picks the game (default:
Message in a Haunted Mansion, about 400 MB). A wrapp to point it at:
`./sc wrapp build <slug> --debug skip-installer`, then run `SteamSetup.exe /S`
in it with `./sc wrapp wine <slug> -- <path to SteamSetup.exe> /S`.
