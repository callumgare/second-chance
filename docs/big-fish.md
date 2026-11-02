# Big Fish Games

Big Fish Games sells 30 of the Nancy Drew games, as downloads its own app, the
**Game Manager**, installs. The Big Fish source builds a wrapp from a game the
person owns there: the Game Manager runs in the build's Wine prefix, they sign
in in its own window, pick one of their games, and it downloads, installs and
activates it.

## What Big Fish ships

- **The Game Manager** (version 4.0.1.5 when this was written) comes from
  `bfginstaller35.exe` on Big Fish's CDN, the same file for everyone (a game's
  "free trial" download from the website is a small stub that fetches it). It
  installs into `C:\Program Files (x86)\bfgclient` (about 730 MB) and is a
  Chromium (CEF) app: its whole window is one web page, from
  `C:\ProgramData\Big Fish\Game Manager\resources`.
- **A game** is identified by its SKU, `F<product>T1L<language>`: `F2435T1L1` is
  product 2435 (The White Wolf of Icicle Creek) for Windows (`T1`) in English
  (`L1`); `L2` is German and `L4` French. The catalog keeps each game's product
  number (`GameInfo.bigFishProduct`), so any language's edition maps to it
  (`BigFishSKU`, `GameInfoProvider.game(forBigFish:)`).
- The Game Manager downloads a game's installer (Big Fish's own NSIS wrapping
  tool) and a split 7z archive into `C:\BigFishCache\GameManager\GameDB\<SKU>`,
  and installs it into `C:\Program Files (x86)\Nancy Drew - <Title>`. The folder
  holds:
  - the game itself, its `.exe` wrapped in **Armadillo**, a 2000s DRM wrapper;
  - Big Fish's DRM launcher, also Armadillo-wrapped, with a random name
    (`rvlrkpp.exe`, `wqxgxgg.exe`): what the Game Manager runs to activate and
    start the game;
  - `bfgstate.xml`, which names the SKU, the launcher (`executablePath`) and,
    for a trial, its length;
  - `LaunchGame.bfg`, the message Big Fish's own Play shortcut sends.

  Its installer also runs Microsoft's DirectX web setup, which isn't needed.
- **Activation**: after installing, the Game Manager runs the launcher to
  activate the game for this computer (DRM1, against
  `activation.bigfishgames.com`). A trial's 60 minutes are kept in the prefix.

## The build

`BigFishWrappBuilder` (`SecondChance/Builders/`), step by step:

1. **The game named up front**, if any: `BIG_FISH_GAME_SLUG`, which a headless
   run must set. `BIG_FISH_TRIAL=1` builds that game's free trial instead (its
   English edition), with no sign-in and no library: it is for the
   integration tests, which can then try every game Big Fish sells. A trial
   wrapp records `BigFishTrial` in its settings.
2. **The Game Manager is installed** in a fresh wrapp's prefix
   (`BigFishWrappPreparer`). `bfginstaller35.exe` is downloaded once into
   `~/Library/Caches/SecondChance/` over https; as it's always the current
   version it can't be checked against a hash, so it is only checked for
   being a Windows program of about the right size. Its `/S` isn't silent: it
   relaunches itself for administrator rights, and the relaunch stops on its
   licence page. `big-fish-game-manager-setup.au3` (in the app's Resources)
   clicks whichever of its buttons is live (`I Agree`, then `Next`, `Install`,
   `Finish` or `Close` if a build of it shows them) until `bfgclient.exe` is
   there and the wizard has gone. The installer starts the Game Manager as it
   finishes; only one runs in a prefix (a second hands over to the first and
   exits, so its DevTools port never answers), so the session is ended there.
   AutoIt and the installer are staged under `C:\second-chance-big-fish` and
   removed after.
3. **It starts** with its DevTools port (`BigFishGameManager.start`).
4. **Sign-in.** Already signed in is fine. Otherwise, from the app, the
   Game Manager's sign-in form is opened and its window brought forward, the
   progress screen tells the person to sign in there, and the build looks
   every 2 s for up to 30 minutes, failing if the Game Manager quits. The
   person's password never passes through Second Chance. A headless build
   can't ask anyone, so it fails (`bigFishSignInRequired`) unless it's the
   test harness's: `BIG_FISH_TEST_SIGN_IN=1` with `BIG_FISH_EMAIL` and
   `BIG_FISH_PASSWORD` fills in and sends the Game Manager's own form
   (`signInForTesting`).
5. **The game.** The account's library (`ownedGames`) is matched to the
   catalog by product number, so every language edition is a choice of its
   own, labelled with its language when it isn't English; they're offered in
   the order the games came out, and the build publishes
   `.bigFishGamesOwned`. A game named up front takes its English edition if
   the account has it, else any edition it has.
6. **Download, install, activate.** `downloadNewGame` with
   `downloadFullVersion` false for a trial; then the game's state is read every
   2 s for up to 4 hours. Downloading and installing show their progress; the
   wait after installing, and a ready state before the game's folder has its
   `bfgstate.xml`, is activation ("Unlocking the game"). A failed state fails
   the build as a download, install or activation failure, and so does the
   Game Manager quitting. Meanwhile `big-fish-directx-cancel.au3` cancels
   Microsoft's DirectX web setup, which each game's installer starts and would
   otherwise sit on its licence page.
7. **Sign out**, and wait until the page says so: the wrapp mustn't carry the
   person's sign-in, and an owned, activated game plays signed out. (Not for
   a trial, which never signed in.) Then the Game Manager is shut down.
8. **Configure.** The game's program is the one in its folder the catalog
   knows by name (its Steam release's `.exe`, or the disc's), or else the only
   one that isn't Big Fish's. The wrapp records `BigFishLaunchFile` (the
   folder's `LaunchGame.bfg`, from the root of C:) and `BigFishSKU`, and keeps
   the Game Manager: its `bfgprocess.exe` and `bfggameservices.exe` start the
   game. A game ScummVM runs (Haunted Mansion, Royal Tower) is a ScummVM wrapp
   of the installed folder, as from Steam: no launch file, and the Game
   Manager and its download cache are taken out. No official Her Interactive
   patch applies to a Big Fish copy (`GamePatch.Edition.matches`).

A failure anywhere shuts the Game Manager down and removes the half-made
wrapp. `BigFishWrappBuilderTests` drives all of this with a fake Game Manager
and a fake preparer.

## Testing

`BigFishWrappBuilderTests` runs the whole build against a fake Game Manager in
the unit run. Real builds come from `sc`:

```bash
./sc wrapp build white-wolf --from big-fish                    # the full game, as the test account
./sc wrapp build white-wolf --from big-fish --big-fish-trial   # its free trial, signed out
./sc test integration --source big-fish [<slug>…]              # owned games
./sc test integration --source big-fish-trial [<slug>…]        # every game's free trial
```

**The test account.** A headless build has nobody to sign in, so the full
game signs in with the account in the repo's `.env`, `BIG_FISH_EMAIL` and
`BIG_FISH_PASSWORD` (`.env.example`). `sc wrapp build` reads them and hands
them to the app with `BIG_FISH_TEST_SIGN_IN=1`; `sc test integration` passes
them to the test host as `TEST_RUNNER_BIG_FISH_EMAIL` and `_PASSWORD`, and
only when the owned suite runs, and `IntegrationTestInput` sets
`BIG_FISH_TEST_SIGN_IN` for its builds. Neither is ever printed. Without them
`--from big-fish` refuses to start (unless `--big-fish-trial`), and the owned
suite skips itself and says why.

The two suites, in `BigFishInstallIntegrationTests.swift`, go through
`IntegrationGameRun` like the others and reserve disk as a Steam build does,
since the download's size isn't known beforehand:

- **Big Fish install — per game (owned)** (`BigFishOwnedInstallIntegrationTests`,
  `--source big-fish`) builds each game Big Fish sells that the account owns,
  one at a time, build and launch together (`IntegrationStages.bigFish`):
  each build signs the one account in and out. The first build's
  `.bigFishGamesOwned` event tells the suite which games the account owns,
  and the rest of the run skips the others without building, as the Steam
  suite does. It checks the build's log has the sign-in, the library and the
  installed game in it; that the wrapp records `GameSource` `big-fish`, the
  game's `BigFishSKU` and, for a Wine game, a `BigFishLaunchFile` that is
  there; and that **no sign-in shipped**: the account's address (as it is,
  lower-cased, URL-encoded or UTF-16) is in none of the prefix's registry
  files nor anything up to 32 MB under `drive_c/BigFishCache`,
  `drive_c/ProgramData/Big Fish` or `drive_c/users`.
- **Big Fish install — per game (trial)** (`BigFishTrialInstallIntegrationTests`,
  `--source big-fish-trial`) builds every game's free trial, signed out, side
  by side with other builds. Each build's prefix is new, so each trial has
  its full 60 minutes; the launch only goes as far as the menu, which the
  wrapp reaches by pressing the Game Manager's Play Now. It checks the
  wrapp records `BigFishTrial` and the English edition's SKU.

Both download the Game Manager's installer once, before the first build
(`IntegrationStages.bigFishInstaller`), so builds side by side don't each
fetch it and race to save it. `sc clean downloads` deletes it with the rest
of `~/Library/Caches/SecondChance`'s downloads.

## Armadillo under Rosetta

Every Armadillo-wrapped program crashed at once under Wine on Apple silicon,
with `virtual_setup_exception stack overflow … addr 0x7ffe4800`. Two things
Rosetta 2 does differently from an Intel CPU running Windows cause it. Both are
fixed in Wine's 32-bit `ntdll.dll`, which the build patches as it bundles the
engine (`setup-wine.sh` → `WrappTemplate/RosettaFaultFix/`, the patcher in
`Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/RosettaFaultFix.swift`).

1. **An `fs:` access with the `0x67` address-size prefix** (16-bit addressing in
   32-bit code). Armadillo removes each of its exception handlers with
   `pop dword fs:[0000]` encoded that way (`64 67 8F 06 00 00`). Rosetta raises
   an access violation for it instead of running it. Armadillo's handler then
   skips over it two bytes at a time, as if it were a fault it caused on
   purpose, so the handler record stays linked; its stack slot is reused, and
   the next deliberate fault calls whatever is there (0x7FFE4800) until the
   stack runs out. Rosetta runs the instruction correctly when it's
   single-stepped, which is how it was found.
2. **The Windows 9x check.** Armadillo's runtime tells Windows 9x from NT by the
   high byte of the code segment selector: 0 on NT (`cs` 0x1B, or 0x23 for a
   32-bit program on 64-bit Windows). Wine on macOS runs 32-bit code in an LDT
   segment, `cs` 0x0107, so Armadillo takes the 9x path and probes for the
   SoftICE debugger with `int 68h`, which faults (Wine reports a read of
   0xFFFFFFFF), and Armadillo gives up with "Access violation at 0x00EEC5D8".
   The selector can't change: Rosetta only runs 32-bit code in such a segment,
   and Wine's Windows version setting doesn't affect it. Without SoftICE,
   `int 68h` does nothing, and that's what the fix makes it do (`int 41h`, the
   other 9x debugger probe, likewise).

The patch replaces `KiUserExceptionDispatcher`'s first two instructions with a
jump to code placed in the unused end of `.text`'s last file page. That code
(`fault_fix.c`) looks at the faulting instruction: for those two cases it does
what Windows would have done and resumes the thread with `NtContinue`; for
anything else it carries on into Wine's dispatcher, so no other program
notices. It runs in every 32-bit Wine program, before vectored and frame-based
handlers alike, which covers Armadillo's second process (it runs the game as a
child under its own debugger) as well as the Game Manager's launcher. The code
is compiled once with MinGW and committed as bytes (`regenerate.sh` rebuilds
them and checks they need no relocations). The patcher refuses an `ntdll.dll`
whose dispatcher doesn't start as expected, so a Wine upgrade that changes it
fails the build rather than shipping unpatched.

Red herrings, for whoever looks next:

- Wine logs "Setting debug registers is not supported under Rosetta, faking
  success" hundreds of times. Armadillo only writes DR7 = 0x155 with DR0–3 = 0
  (an anti-debugger trick); faking it is harmless.
- Wine under Rosetta pushes a single-stepped `call`'s return address 4 bytes
  too low. It only matters to tools that trace with the trap flag; Armadillo's
  own `iret` single-step trick isn't a `call` and works.
