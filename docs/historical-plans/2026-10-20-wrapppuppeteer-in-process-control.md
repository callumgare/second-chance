# WrappPuppeteer without permissions: drive the game from inside its process

*Implemented 2026-10-20. A frozen record of the plan as carried out, with
what each phase found and the decisions that changed on the way. For how it
works now, read
[docs/wine-in-process-helpers.md](../wine-in-process-helpers.md#puppet-control)
and the WrappPuppeteer section of [docs/testing.md](../testing.md).*

## Goal

WrappPuppeteer needed **Screen Recording** and **Accessibility** only because
it acted on another app's windows from outside: it captured the game's window
with `screencapture`, found and pressed the info window's button through the
Accessibility API, read fullscreen state through it, and clicked with
`CGEvent`s. macOS lets a process do all of that to **its own** windows with no
permission at all. So move the capturing and clicking into the wrapp and the
game process, and have WrappPuppeteer ask for them over a local socket.

What that removed:

- the permission gate, exit codes 3–5, and the re-grant steps in
  `docs/testing.md`;
- the need for each test Mac to grant WrappPuppeteer those permissions;
- WrappPuppeteer's use of `/usr/sbin/screencapture`, which turned out to
  slowly wear down the test Mac (see *systemstatusd* below).

## What the prototypes established

- **A process with neither permission can capture and click its own window.**
  A standalone app reporting `CGPreflightScreenCaptureAccess() == false` and
  `AXIsProcessTrusted() == false` clicked its own button with
  `-[NSApp postEvent:]` (the action ran) and captured its own window with
  `SCShareableContent.getCurrentProcessShareableContent` +
  `SCScreenshotManager.captureImage` (macOS 14.4+); OCR read the capture.
- **It works inside both engines' game processes.** A prototype helper
  (Unix socket; `state`, `capture <path>`, `click <x> <y>`), with the game
  launched as its own LaunchAgent so it inherited no grants:

  | | Wine (Last Train) | ScummVM (Secrets Can Kill) |
  |---|---|---|
  | Got in by | rebuilt `in_process_helpers.dylib` in a wrapp copy | `DYLD_INSERT_LIBRARIES` on `scummvm` |
  | Permissions inside | neither | neither |
  | Capture | 2560×1440, OCR read the whole menu | 2560×1440, OCR read the whole menu |
  | Click Exit from inside | game quit 1 s later | game quit 2 s later |
  | Click point vs WrappPuppeteer's | (1159, 1277) vs (1159, 1278) | (1162, 1188), identical |

- **Wine accepts the posted click** as long as the `NSEvent` is tied to the
  game window (`mouseEventWithType:…windowNumber:`), as `cursor_lock.m`
  already relied on. ScummVM's SDL event loop accepts it too.
- **In-process clicks don't need the game to be frontmost.** `scummvm` was
  never the active app and its click still worked, so the test checks
  frontmost/fullscreen itself rather than relying on a click failing.
- **`scummvm` can take an injected dylib.** It's ad-hoc signed without
  hardened runtime, so `DYLD_INSERT_LIBRARIES` is honoured. (Wine can't use
  that route — wine-preloader runs before dyld initialisers — which is why its
  helpers ride on `winemac.so`.)
- **Captures are fast once settled:** ~30–250 ms in-process, against ~1 s per
  `screencapture` run.

### systemstatusd: why captures stalled on the test Mac

The prototypes' first captures stalled 8–16 s on the test Mac (macOS 26.2)
but not on a macOS 15.6 Mac. A `sample` of `replayd` during a stall had its
`com.apple.systemstatus.publisher.internalqueue` blocked in synchronous XPC to
`systemstatusd`, the daemon behind the menu-bar privacy indicators, in ~96% of
samples; `systemstatusd` spent seconds of CPU per update. It had run 13.6 days,
used 392 min of CPU and held 39 MB (fresh: ~10 MB). After a reboot (SIP blocks
restarting it any other way):

- each run of `/usr/sbin/screencapture` left ~2 KB in it and made every later
  update dearer — CPU per 50 runs 0.56 s → 1.07 s over 500 runs;
- 300 short-lived processes capturing in-process left it flat (0.28 s per 50);
- after the 500 `screencapture` runs, those in-process processes cost 1.24 s
  per 50 — the build-up slows every app's captures.

WrappPuppeteer ran `screencapture` for every Exit-finding attempt, so two
weeks of integration tests wore it down. Moving off `screencapture` removes
that source; `docs/testing.md` has how to spot it.

## Design as built

WrappPuppeteer creates a private directory (`/tmp/wrapp-puppeteer-<pid>`,
mode 0700 — short enough for a socket path) and launches the wrapp with
`SECOND_CHANCE_PUPPET_DIR` naming it. Nothing listens unless that variable is
set, and nothing a player runs sets it.

- **`wrapp.sock`** — `WrappTemplate/PuppetServer.swift`, for the wrapp's own
  info window: `info` and `confirm`.
- **`game.sock`** — `WrappTemplate/InProcessHelpers/puppet_control.m`, inside
  the game process: `state`, `capture <path>`, `click <x> <y>`,
  `move <x> <y>`, in window points with a top-left origin.

The helper reaches the game through `in_process_helpers.dylib` for Wine (armed
by `PUPPET_CONTROL_EXE`, which `WineEnvironment.inProcessHelperVariables`
sets only when the directory is), and through `DYLD_INSERT_LIBRARIES` on
`scummvm` (`GameLauncher`). Steam-launched games get it the same way as other
Wine games.

WrappPuppeteer's `Core/InProcessControl.swift` is the client; the scenario and
`InfoWindow` use it, and the permission gate, `Accessibility`, `CGEvent`
input, `screencapture -l` and exit codes 3–5 are gone. Diagnostics on failure
capture the game window through the game; a full-screen screenshot is added
only if a Screen Recording grant happens to exist.

## Phases as carried out

1. **Game helper (Wine)** — `puppet_control.m`, built into the dylib (with
   ScreenCaptureKit weak-linked, since the dylib targets macOS 11) and known to
   `InProcessHelperReport` as `PuppetControl`. Found: **the click must be
   held.** The games poll the buttons (`GetAsyncKeyState`), so a press and
   release posted together was never seen; the helper holds the button 100 ms.
2. **ScummVM injection** — found two bugs on the way. ScummVM wrapps didn't
   have the dylib: it was on `wine-files`, the list of what a ScummVM wrapp
   removes, so `setup-wine.sh` now leaves it off. And dyld kills a process
   whose inserted dylib is missing — the game died with SIGABRT — so
   `GameLauncher` checks the file first and runs the game without puppet
   control if it's absent. Fixing the list also exposed that the engine lists
   reached the template one build late (the Resources phase copies them before
   the setup scripts regenerate them); each script now copies its fresh list
   into the bundle.
3. **Wrapp socket** — the plan was to find **I Understand** through the
   window's accessibility tree, in-process. SwiftUI didn't expose the button
   that way, so `InfoWindowView` records the button's frame (in a coordinate
   space on its root, which fills the hosting view; `.global` put the click at
   the window's bottom edge) and `confirm` clicks there, falling back to the
   button's action if the warning is still up after two seconds. A click on a
   window that isn't key only brings it forward, so `confirm` makes it key
   first.
4. **WrappPuppeteer on the sockets** — integration passed for both disk games
   at once, but Last Train needed four Exit clicks where it had needed one.
   **A press arriving with the cursor, before the game had highlighted the
   button under it, was ignored**; the helper now moves the cursor, waits
   150 ms, then presses, and Last Train quits on the first click again. The
   Steam game then failed: **Ghost of Thornton Hall covers the screen with a
   borderless Direct3D window** rather than entering a fullscreen Space, which
   the old bounds check counted and the helper's `state` didn't. `fullscreen`
   now means either, with `native` saying which.
5. **Docs** — `docs/wine-in-process-helpers.md` (the puppet control section),
   `docs/testing.md` (no permissions, diagnostics, the systemstatusd note),
   `AGENTS.md`.

Final integration on the test Mac: `secrets-can-kill`, `blue-moon` (disk) and
`thornton-hall` (Steam) pass with WrappPuppeteer holding no grants.

## Decisions

1. **The `key` command was dropped.** WrappPuppeteer sent no keys (its only
   `pressReturn` call was commented out), so the helper has no key request.
2. **WrappPuppeteer is still launched through LaunchServices.** The plan
   recommended a plain child of the test. With no permissions involved either
   way, the existing, proven route stayed; only its comments and the
   permission handling around it changed.
3. **Full-screen diagnostics are optional** — taken only when a grant exists.
4. **One Steam game in the integration check** — `thornton-hall`, which is
   what caught the borderless-window case.

## Risks carried forward

- **Clicks no longer prove a player could reach the game.** Something
  invisible in front of it, or the game on another Space, wouldn't stop an
  in-process click. The explicit frontmost/fullscreen checks cover the cases
  seen so far.
- **A control channel in shipped wrapps**, gated by an environment variable
  only WrappPuppeteer sets and a 0700 directory.
- **Hardened runtime would block the ScummVM route.** If wrapps are ever
  signed with it, `scummvm` needs
  `com.apple.security.cs.allow-dyld-environment-variables`, or the helper has
  to be linked in instead.
