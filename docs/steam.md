# Steam

Steam-sourced wrapps run the real Steam client inside the wrapp's Wine
prefix: some games will only run with a signed-in Steam, and Steam's own
sign-in window (with QR sign-in) means Second Chance never handles a password.
The parts that drive it live in `Shared/Steam/`, compiled into the app, the
wrapp and WrappPuppeteer alike.

**The building blocks below are in place; the Steam builder and the wrapp's
Steam launch path that use them are not yet** — `SteamWrappBuilder` still
throws `steamNotFullyImplemented` (see AGENTS.md, "Things Currently In Flux").

## One sign-in for every wrapp

Each wrapp has its own Steam install, so wrapps stay self-contained. The
*sign-in* is shared: `SteamSessionStore` keeps it in
`~/Library/Application Support/SecondChance/Steam/session/` (mode 0700),
copies it into a wrapp's prefix before its Steam starts, and copies it back
after Steam quits.

A remembered sign-in is exactly these, found by trying subsets of them in a
Steam that had never signed in:

| What | Where, in the prefix |
|---|---|
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
