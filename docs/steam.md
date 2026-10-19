# Steam

Steam-sourced wrapps run the real Steam client inside the wrapp's Wine
prefix: some games will only run with a signed-in Steam, and Steam's own
sign-in window (with QR sign-in) means Second Chance never handles a password.
The parts that drive it live in `Shared/Steam/`, compiled into the app, the
wrapp and WrappPuppeteer alike.

Steam builds and Steam wrapps work end to end, tested by
`sc test integration --source steam` ([testing.md](testing.md)).

**Steam's permission prompts, under `sc`.** At start-up Steam touches the
microphone (voice chat) and the local network (Remote Play / LAN discovery).
macOS attributes that to the responsible Mac app:

- **Second Chance or a wrapp** (an app bundle, with no usage description for
  either): macOS quietly declines, Steam carries on. This is what players get,
  and a build started from the app was checked to raise no prompt.
- **`sc`** (a bare command-line tool): macOS asks — "Allow 'sc' to find
  devices on local networks?", "'sc' would like to access the Microphone" —
  and **Steam hangs until both are answered**: on a test Mac a build's Steam
  sat for 20 minutes, then signed in in 66 s once they were. Rebuilding `sc`
  makes macOS ask again, as it's a new binary.

So for `sc wrapp build --from steam` and the Steam suite, answer them on the
Mac they run on (the microphone can be refused). Having `sc` disclaim
responsibility for the app it runs, so the app is the responsible process,
would end this.

## Building

`SteamWrappBuilder`, in order:

1. **Pick the game** (`WrappBuildInput.getSteamGame`, `STEAM_GAME_SLUG`) and,
   for a DRM-free one, how it launches (`getSteamLaunchMode`,
   `STEAM_LAUNCH_MODE`). The engine follows (`engineRouted`).
2. **Take the Steam lock**, or fail with `steamInUse` naming who has it.
3. **Make the wrapp and install the Steam client into it** — the template,
   the cached prefix, then Valve's `SteamSetup.exe /S` (downloaded once to
   `~/Library/Caches/SecondChance/`). Not `winetricks steam`: it installs
   Microsoft's core fonts first, which needs `cabextract`, which isn't
   bundled, and Steam doesn't need them under the bundled Wine. Then lay the
   cached updated client
   over it (`SteamClientCache`, `~/Library/Caches/SecondChance/steam-client`),
   so Steam's own update (most of a gigabyte) is downloaded once, not per
   build. The cache leaves out the account's sign-in, licences, settings and
   games.
4. **Sign in**: restore the shared session, queue the game's install, start
   Steam silently. With no session, or one Steam rejects, the GUI says to
   sign in in Steam's window (QR or password) and waits up to 30 minutes; a
   headless build fails with `steamSignInRequired` instead.
5. **Check ownership** (`steamGameNotOwned` otherwise), then **wait for the
   install**, showing Steam's phase — "Downloading 397 MB through Steam",
   "Checking the download", "Finishing the install".
6. **Stop Steam, save the session, and take the sign-in out of the wrapp.**
   The build runs Steam inside the wrapp's own prefix, so without this the
   finished `.app` would carry the account's token, and anyone given a copy
   could use the account. A wrapp gets the sign-in from the shared store when
   it runs, and on a Mac without one asks for it once.
7. **Configure.** A game that runs without Steam is moved out of
   `steamapps/common/` into `Program Files (x86)/Nancy Drew/`, and the Steam
   client is deleted; otherwise its exe stays in Steam's library and
   `AppSettings.plist` gets `SteamGameId`. `SteamLaunchMode` records the
   user's choice. Her Interactive's patches are not applied: Steam's build is
   current, and the patchers refuse it ([game-patches.md](game-patches.md)).

Steam is stopped on the failure path too, and the session saved if it signed
in, so a failed build neither leaves Steam running nor loses a refreshed
sign-in. `./sc wrapp build <slug> --from steam` runs the whole thing headless.

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
`GameInfoProvider` gets the faster path from then on.

## Running

A wrapp whose game needs Steam (`wine-steam`, `wine-steam-silent`) does it in
`WrappTemplate/WrappSteam.swift`, before the game starts:

1. **Take the Steam lock**, or tell the player which game has Steam open.
2. **End any Steam left over** from a run that was force-quit or crashed —
   it would still be running in this prefix, signed in.
3. **Restore the shared sign-in, start Steam silently, wait for it to sign
   in.** Without a sign-in, the loading window says to sign in in Steam's
   window, and waits for up to 30 minutes.
4. **Start the game.** `wine-steam` asks Steam to (`-applaunch`): no launcher
   of the wrapp's own to watch, so the game is found, and watched, by its exe;
   `wine-steam-silent` starts the exe itself, as a Wine game does. Startup
   diagnostics are timed from here, not from Steam's start.
5. **When the game ends, or the wrapp quits:** stop Steam, save the sign-in
   back to the store, take it out of the wrapp, release the lock. On quit this
   is cut short (10 s for Steam) to fit inside the wrapp's 15 s quit fallback.

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

## One wrapp on Steam at a time

Two wrapps signed in to the same account would knock each other off, and race
to save the session. `SteamActiveLock` is an `flock` on `active-wrapp.lock` in
the same directory, recording the holder's pid and bundle ID; the second
wrapp gets `.heldBy` and can say which game is using Steam. Being an `flock`,
it is released when the holding process exits, however it exits.

## Driving Steam

`SteamClient` (behind the `SteamClientDriving` protocol, the seam tests use)
runs `C:\Program Files (x86)\Steam\steam.exe` in the prefix:

- **`start(silent:)`** starts Wine's desktop first, as every Wine program does
  (AGENTS.md, "Wrapps start Wine's desktop before the game"). The bootstrapper
  exits **42** when it hands over to an updated client — not a failure.
- **Signed in or not** comes from Steam's logs, not its files:
  `logs/connection_log.txt` (`RecvMsgClientLogOnResponse() : … 'OK'`) and
  `logs/steamui_login.txt` (`SetLoginState: WaitingForCredentials`, with the
  reason, e.g. `Invalid Password` for a rejected token). Both logs keep earlier
  sessions, so the client only reads what was written since it started them.
- **Installing:** with Steam *not* running, `queueInstall` writes a minimal
  `steamapps/appmanifest_<id>.acf` (`appid`, `Universe`, `installdir`,
  `StateFlags` 1026); the next start installs it with no dialog.
- **Ownership must be checked first.** Steam says nothing at all about an app
  the account doesn't own — its manifest just sits there. `ownedAppIDs` reads
  the account's licences from `appcache/packageinfo.vdf`, which Steam writes a
  few seconds after signing in, so it waits for that file.
- **Progress is phases, not a percentage.** The manifest's `BytesDownloaded`
  stays 0 until the download is over, and the download folder's size is
  inflated by preallocation. `logs/content_log.txt` gives the total size and
  the phase (`Preallocating`, `Downloading`, `Verifying Staged`, `Committing`,
  then `Fully Installed`), which `installPhase` reports.
- **`shutdown(timeout:)`** runs `steam.exe -shutdown`, releases the desktop and
  waits for the prefix's Wine session to end. Steam usually goes in seconds but
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
