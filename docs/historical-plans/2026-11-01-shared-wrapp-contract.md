# Sharing more between the app, the wrapp and WrappPuppeteer

## What happened

_Written after implementation. The plan was a review of the code Second
Chance, the wrapps and WrappPuppeteer each had their own copy of, done once
the shared code had become a local package
([2026-11-01-shared-package.md](2026-11-01-shared-package.md)); this records
what it found and what was done._

The three programs agree on a lot without sharing the code that says so: what
a wrapp's `AppSettings.plist` holds, what each engine means, where things are
inside a wrapp, which processes are Wine's, and how to wait for Steam. Each
was written two or three times, and some copies had drifted.

## What was done

1. **The game database became a package of its own** (`Packages/GameCatalog`).
   `sc` used to compile the app's `GameInfo.swift` and
   `GameInfoProvider.swift` through symlinks; the wrapp and WrappPuppeteer
   couldn't use them at all. It is a separate package, not a module of
   `SecondChanceKit`, because `sc` depending on `SecondChanceKit` made SwiftPM
   fetch swift-log and Sentry, most of a gigabyte, for a CLI that uses
   neither.
2. **One engine type.** The wrapp compared its engine as strings
   (`hasPrefix("wine-steam")`) and WrappPuppeteer had an enum of its own, in
   which `.wine` meant every Wine engine, Steam's included. Both use
   `GameInfo.GameEngine` now, asking it `runsInWine`, `needsSteam` and
   `launchedBySteam`; WrappPuppeteer's checks became properties of `Wrapp` so
   a straight swap couldn't quietly narrow `.wine`.
3. **`WrappSettings`, `WrappLayout` and `Wine.drives`.** The plist is a
   `Codable` type with the keys wrapps always had, so existing wrapps still
   read. The paths inside a wrapp are one type; what is inside a prefix is
   asked of the `Wine` running it, since a wrapp that can't write its own
   prefix runs in a copy. Drive letters, made in three places, are one API,
   which documents what A: is for. Items 1–3 went in as one commit, since
   the settings type needs the layout.
4. **`ProcessList`.** Nine places ran and parsed `ps`, with three ideas of
   which processes are Wine's (`contains("wine") || contains(".exe")`,
   `.exe` or `wineserver`, and `SystemLoad.isWine`). There is one listing and
   one test now. A diagnostics bundle's `processes.txt` is still `ps`'s own
   output, since it is for people to read and carries memory use.
5. **Steam.** The sign-in wait and the wait for the lock were each written
   in the build and the wrapp. They differ for good reasons — the build is
   async, has deadlines and restarts Steam once; the wrapp is synchronous,
   waits for as long as the player does and can be cancelled — so what is
   shared is what Steam did (`SteamSignInWatch`, checked once per pass of
   each side's own loop) and the asking while the lock is held
   (`SteamActiveLock.take`), not the loops.

## Left as it was

- The failure-report level wording, in the wrapp's alert and the app's
  settings: a few strings.
- `ScummVMService`, which nothing calls: dead code to delete, not share.
- A shared finder for a Wine program's window on screen: only the install
  stall watch needs one.
