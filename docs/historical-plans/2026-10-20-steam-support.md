# Steam support: Steam-sourced wrapps with one shared sign-in

*Implemented 2026-10-19/20. A frozen record of the plan as carried out, with
what each phase found and the decisions that changed on the way. For how
Steam works now, read [docs/steam.md](../steam.md).*

## Goal

Build a wrapp from a game in the user's Steam library, and run games whose
DRM needs Steam, using the **real Steam client inside Wine** — not steamcmd
or DepotDownloader — because:

- the DRM games need a signed-in Steam to run anyway;
- Steam's own sign-in window offers QR sign-in, so Second Chance never
  handles a password.

**The key requirement:** the user signs in to Steam once, not once per wrapp,
whether building or running.

**Design:** each wrapp keeps its own Steam install (self-contained, and a
wrapp's Wine never touches another's); the sign-in lives in one shared
session store, copied into a wrapp's prefix before Steam starts and back
after it quits.

## Prerequisites

- **Wine 10.** Steam's bootstrapper exits during its first update on the
  previously bundled Wine 9 (CrossOver 24), and runs on Sikarugir's Wine 10.
  The upgrade landed first, validated by the disk integration suite on a
  fresh prefix.
- **The Debug prefix cache was keyed `"dev"` whatever the Wine version**, so
  after the upgrade, Debug builds reused a prefix Wine 9 had made until
  someone cleared it; the first all-pass Wine 10 run was, in fact, on that old
  prefix. The key now carries the bundled engine's version, and caching a
  prefix removes the others. Done first because the cached "prefix + Steam"
  the plan wanted would have inherited the bug.

## Phase 0: spike — what a sign-in is made of

By hand, in prefixes from `sc wrapp build … --debug skip-installer` plus
`SteamSetup.exe /S`: wrapp A, signed in with "Remember me"; B, A cloned after
Steam's self-update but before sign-in; C–G, B plus subsets of A's files.
Signed in or not was read from `logs/connection_log.txt`
(`RecvMsgClientLogOnResponse() … 'OK'`, `[Logged On`) and
`logs/steamui_login.txt` (`SetLoginState: WaitingForCredentials`).

| Prefix | Copied from A | Result |
| --- | --- | --- |
| C | `config/loginusers.vdf`, `config/config.vdf`, `AppData/Local/Steam/local.vdf`, `AutoLoginUser` | signed in |
| D | `local.vdf` + `AutoLoginUser` | asked for credentials |
| E | D + `loginusers.vdf` | token rejected (`Invalid Password`) |
| F | all four, again | signed in |
| G | all four, into a prefix with a different `MachineGuid` | signed in |

So the set is exactly those four; reusing the token neither burns nor
rotates it; and it isn't tied to the prefix, so a new prefix (after a Second
Chance update) keeps the sign-in. Also found:

- A rejected restore makes Steam rewrite `local.vdf` without the token — so
  a run that didn't sign in must never be saved back.
- `steam.exe -shutdown` usually exits in 2–5 s, once left a web helper
  running for minutes — so shutdown needs a time limit, then `wineserver -k`.
- **Installing:** a minimal `appmanifest_<id>.acf` (`appid`, `Universe`,
  `installdir`, `StateFlags` 1026) written while Steam isn't running makes
  the next start install the game with no dialog.
- **No live progress:** the manifest's `BytesDownloaded` stays 0 until the
  end; `content_log.txt` gives the total and the phase; the download folder's
  size is inflated by preallocation. Progress shows the phase, not a
  percentage.
- **Ownership:** an app the account doesn't own just sits; Steam logs
  nothing. Ownership comes from `appcache/packageinfo.vdf`, so the VDF parser
  needed Steam's binary format too.
- App IDs, install folders and executables came from Steam's app info.

## Phases 1–4, as built

1. **Shared pieces (`Shared/Steam/`):** a text and binary KeyValues parser;
   Steam's app/package caches and manifests; reading sign-in and install
   phase from Steam's logs; `SteamSessionStore` (the four-item set, newest
   wins, `flock`, never logs contents, refuses to save a run that didn't sign
   in); `SteamActiveLock` (one Steam at a time, released when the holder
   dies); `SteamClient` behind `SteamClientDriving`. A real-Steam smoke test
   drove it end to end.
2. **Game data:** `GameInfo` gained each game's Steam app ID, install folder
   and exe — 30 of the 33 games — and `steamEngine(launchMode:)`.
3. **Builder:** `SteamWrappBuilder` — pick the game (`STEAM_GAME_SLUG`), take
   the lock, make the wrapp and install Steam, sign in (the shared session, or
   the user in Steam's window; headless fails fast), check ownership, install,
   stop Steam and save the session, then configure. `sc wrapp build --from
   steam`, Sign Out of Steam, `sc clean steam-session`.
4. **Runtime (`WrappTemplate/WrappSteam.swift`):** take the lock, end a Steam
   left by a crashed run, restore the sign-in, start Steam, wait for it to
   sign in (asking the player when needed), start the game, and on exit or
   quit stop Steam, save the sign-in and take it out of the wrapp.

## What changed from the plan

- **The sign-in is taken out of every wrapp.** The build runs Steam inside
  the wrapp's own prefix, so the finished app would have carried the
  account's token; it's stripped after saving, and a wrapp gets it from the
  store at run time.
- **Valve's `SteamSetup.exe /S`, not `winetricks steam`,** which installs
  Microsoft's core fonts first and needs `cabextract`, not bundled.
- **The Steam client cache keeps the Steam Service with the client:** a
  cached client over the installer's older service raised a "Steam Service
  Error" dialog, which took focus from the game.
- **Games ScummVM runs from disc always run in ScummVM from Steam,** with no
  launch choice. The plan offered "via Steam" for them (Steam's `Game.exe`
  under Wine); tested, the game ignored the mouse — its cursor stayed put
  while clicks landed elsewhere.
- **Everything that needs Steam is launched by Steam (`-applaunch`).** The
  plan started the exe directly for `.yesLaunchWhenSteamRunning` games; Blue
  Moon's Steam release then ran with no window, while through `-applaunch` it
  was up in a second. Blackmoor Manor, Waverly Academy and Water's Edge pass
  the same way.
- **Her Interactive's patches don't apply to Steam builds:** Shadow Ranch's
  patcher refuses Steam's build ("This program cannot update the installed
  version…") and waited out its timeout.
- **Steam's macOS permission prompts.** Steam touches the microphone and the
  local network at start-up and waits on any prompt that raises. An app
  bundle with no usage descriptions gets none — what players see — but `sc`,
  a bare CLI, did, and a build's Steam waited 20 minutes. `sc wrapp build` now
  starts the app as its own responsible process.
- **The launcher holds Steam from the moment it starts,** not after sign-in:
  a wrapp quit mid-sign-in had left its Steam running.

## Testing (Phase 5)

- Unit suites with synthetic data (real Steam caches carry account IDs), and
  a fake-client builder test.
- `SteamInstallIntegrationTests` and `sc test integration --source
  disk|steam|all`: builds each requested game from Steam, headless with the
  saved sign-in, launch-tests it, checks no sign-in shipped, and skips a game
  the account doesn't own. It passed for one game on each route: ScummVM,
  direct under Wine with Steam removed, and through Steam.
- Found on the way, in the test tooling: WrappPuppeteer outlived a stopped
  run (it now watches the test's pid), and its Wine backstop `pkill -f wine`
  no longer matched Wine 10's process names (it now runs the wrapp's own
  `wineserver -k`).

## Not done

- **A dedicated Steam test account and scripted sign-in** (a Steam Guard code
  from the account's `shared_secret`, typed by WrappPuppeteer) for when the
  saved session expires. The suite uses the saved sign-in and disables itself
  without one.
- **DRM classification** for the 21 games on Steam whose `steamDRM` isn't
  known: they launch through Steam, which works whatever it is; knowing would
  let the DRM-free ones offer the faster direct launch.
- Steam IDs for the games the build account doesn't own were taken from
  Steam's public app info, not tested.
