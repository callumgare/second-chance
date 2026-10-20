# Wine in-process helpers

Some things done to the game's window need to happen _inside_ the Wine
process that owns it, because macOS only lets a process do them to its own
windows without the Accessibility (or Screen Recording) permission — which a
wrapp does not have:

| Helper | Source | What it does | Armed by | Off switch |
| --- | --- | --- | --- | --- |
| Native fullscreen | `WrappTemplate/InProcessHelpers/native_fullscreen.m` | Puts the game window into a real macOS fullscreen Space | `NATIVE_MACOS_FULLSCREEN_EXE` | `SECOND_CHANCE_NATIVE_FULLSCREEN=0` |
| Cursor lock | `WrappTemplate/InProcessHelpers/cursor_lock.m` | Gets cnc-ddraw to take hold of the mouse without swallowing the player's first click | `CURSOR_LOCK_EXE` | `SECOND_CHANCE_CURSOR_LOCK=0` |
| Puppet control | `WrappTemplate/InProcessHelpers/puppet_control.m` | Lets the integration tests' WrappPuppeteer capture and click the game window | `PUPPET_CONTROL_EXE`, set only when `SECOND_CHANCE_PUPPET_DIR` is | — (never armed for players) |

## How they get into the game process

All three are compiled into one dylib, `Contents/Frameworks/in_process_helpers.dylib`,
by `WrappTemplate/setup-wine.sh` (an Xcode build phase of the WrappTemplate
target — add any new source to that phase's input files too, or edits to it
won't rebuild). `DYLD_INSERT_LIBRARIES` can't load them: wine-preloader reaches
its entry point before dyld runs initializers, so an inserted dylib is mapped
but its constructor never runs. Instead `patch-winemac.swift` gives Wine's Mac
driver, `winemac.so`, a weak dependency on the dylib. The header comment of
`native_fullscreen.m` has the details.

Every process that talks to the Mac driver loads `winemac.so` — `explorer.exe`
as well as the game — so each helper checks whether it is in the game before
doing anything. `WineEnvironment.inProcessHelperVariables(gameExe:)` sets
`NATIVE_MACOS_FULLSCREEN_EXE` and `CURSOR_LOCK_EXE` to the game's `.exe` name,
and a helper only arms in the process running that `.exe`
(`InProcessHelpers/helper_common.h`). Wine 10 runs every Windows program
from the one `bin/wine` binary and rewrites the process's argv[0] to the
Windows path (`C:\…\Game.exe`, as `ps` shows it), so the helper reads argv[0]
back from the kernel and matches its last component. Older Wine started each
program through a copy of its loader named after the `.exe`, so the
executable's own name is matched as well. (Matching the executable alone is
why both helpers silently stopped arming when the bundled Wine moved to 10.)
Leaving a variable unset is what the off switches do.

A Wine program passes its environment on to the programs it starts, so the
variables reach the game from whichever process launches it.
`runWindowsExecutableWithStart` sets them on the `wine start` it runs the game
with. A game Steam launches (`-applaunch`, the `wine-steam` engine) is started
by the Steam client, which has the environment it was started with — not the
`-applaunch` call's — so the wrapp's `SteamClient` sets them on every Steam
process it runs. Steam's own processes have other names and never arm.

They log to os_log under subsystem `com.secondchance.gamewrapper` (categories
`NativeFullscreen`, `CursorLock` and `PuppetControl`), and additionally append to the file named
by `IN_PROCESS_HELPERS_LOG` when it is set, which is the easier way to
watch one launch:

```bash
IN_PROCESS_HELPERS_LOG=/tmp/helpers.log open -n "built-apps/<game>.app"
```

That step-by-step detail goes nowhere else. Only `os_log` and that file get
it. The few lines that say how a helper got on (armed; entering fullscreen
or staying windowed; the cursor locked or left alone) also go to stderr, as
`second-chance-helper[<helper>] <level>: <message>` (`helper_common.h`). Wine
passes stderr on to whatever started the game, so the lines reach the wrapp's
log through its own pipe or, for a game Steam launches, Steam's.
`InProcessHelperReport` (`Shared/Wine/`) watches them. The wrapp logs
`[Helpers] Native fullscreen armed`, `[Helpers] Cursor lock armed` and
`[Helpers] Puppet control armed` as each helper arms. If a helper it armed hasn't reported arming a minute after the
game's window appeared, it logs an error naming that helper. A helper that
fails to arm is otherwise silent: the game plays in a window, or swallows its
first click. The integration tests fail a Wine game whose log lacks either
`armed` line ([testing.md](testing.md)).

A cursor lock that gives up is reported but isn't an error. Only games that
draw through cnc-ddraw ever take the cursor; in a Direct3D game the helper
posts its middle clicks, sees no lock and leaves it.

## Native fullscreen

See the header comment of `native_fullscreen.m`: it waits for the window Wine
itself marks as fullscreen-capable to stop resizing, then calls
`-toggleFullScreen:` on it, as the green title-bar button would.

## Cursor lock

### The problem it solves

Second Chance runs the DirectDraw games through
[cnc-ddraw](https://github.com/FunkyFr3sh/cnc-ddraw), installed by
`WineManager` with `windowed=true` (native fullscreen then turns that window
into a fullscreen Space). In windowed mode cnc-ddraw only _locks_ the cursor —
hides the system cursor and confines it to the game's picture — once it sees a
mouse-button **release** inside the window, and it eats that release. Until
then:

- mouse-button-down messages are dropped, and
- its `GetCursorPos` hook gives the game a stale cursor position instead of the
  real one.

The Nancy Drew games read the buttons by polling `GetAsyncKeyState`, which
cnc-ddraw passes through, so the game _does_ see the first click — at the wrong
place. On a menu nothing happens, so the player's first click seems to do
nothing. On the Her Interactive logo, where any click skips, it "works", which
hides the problem. cnc-ddraw also unlocks whenever the app is deactivated, so
the same happens after Cmd-Tabbing back.

None of cnc-ddraw's settings avoid this while keeping native fullscreen:
`fullscreen=true` locks on activation but replaces the window with cnc-ddraw's
own borderless one, which native fullscreen then can't adopt, and `devmode=true`
never locks, leaving the cursor free to drift into the letterbox bars, reveal
the menu bar or Dock, or leave for another display.

### What it does

It waits until the game window is key, the app is active, the window's frame has
held still for a second and — when native fullscreen is armed — the window is
actually fullscreen. A lock taken before native fullscreen resizes the window
would confine the cursor to the old frame, and on a slow machine the window can
sit at its initial size for several seconds first, so a still frame alone isn't
enough. (If the window still isn't fullscreen after 20 seconds, it carries on
anyway: native fullscreen can give up and leave the window as it is.) Then it:

1. Checks whether the cursor is locked. Wine's Mac driver records both halves
   of cnc-ddraw's lock on `WineApplicationController` — `clippingCursor` and
   `clientWantsCursorHidden` — and runs in this same process, so they are read
   directly. The lock has to hold for two seconds to count: both flags are
   briefly true at startup, before cnc-ddraw first releases the cursor.
2. If not, posts a **middle** click to the game window, gives cnc-ddraw two
   seconds, and checks again — up to 15 clicks.

It runs again each time the app becomes active.

### Why a middle click

cnc-ddraw locks on any button's release, but while unlocked it drops the click
before the game sees it as a message, and the Nancy Drew games poll only the
left and right buttons. So a middle click locks the cursor without the game
noticing — in particular without skipping the publisher logo, which a left
click would.

The click is posted with `-[NSApp postEvent:]`, which goes through Wine's normal
event handling. Wine ignores a mouse event that isn't tied to one of its
windows, and an `NSEvent` made by `mouseEventWithType:` — the way to tie it to
the window — has button number 0, which Wine would deliver as a **left** click.
So the helper re-wraps that event's `CGEvent` with the middle button set, and
refuses to post anything that doesn't come out as button 2 on the game window.

### Checking it

The helper log should show the lock taking hold, normally on the first click:

```
pid=… cursor-lock | armed
pid=… cursor-lock | posted middle click 1
pid=… cursor-lock | cursor locked after 1 middle click(s)
```

To see cnc-ddraw's side, trace Wine's cursor calls with
`SECOND_CHANCE_WINEDEBUG=+event,+cursor`: a `macdrv_mouse_button … button 2`
press and release should be followed by `ShowCursor` taking the count below
zero and `macdrv_ClipCursor` to the game's picture — `(320,0)-(2240,1440)` for
a 4:3 game on a 2560×1440 display. Run with `SECOND_CHANCE_CURSOR_LOCK=0` for
comparison: then the same lock sequence appears only on the player's first real
click, and that click doesn't reach the game.

If a future game reads the middle button, it would see these clicks; it would
show up as that game reacting to something a few seconds after launch and on
every return to the app.

## Puppet control

The integration tests drive a wrapp with WrappPuppeteer
([testing.md](testing.md#wrapppuppeteer)): it finds the game's Exit button in
a capture of the game window and clicks it. Doing that from outside the game
needs Screen Recording and Accessibility. From inside it needs neither: a
process may capture its own windows (ScreenCaptureKit's current-process
content, macOS 14.4+) and post events to them (`-[NSApp postEvent:]`, as
cursor lock does). So this helper does the capturing and clicking, and
WrappPuppeteer asks it to over a Unix socket.

It arms only when WrappPuppeteer started the wrapp. WrappPuppeteer passes
`SECOND_CHANCE_PUPPET_DIR`, a private directory; when that is set,
`WineEnvironment.inProcessHelperVariables` sets `PUPPET_CONTROL_EXE` to the
game's `.exe`, and the helper in that process listens on
`$SECOND_CHANCE_PUPPET_DIR/game.sock`. A player's launch sets neither, so
nothing listens.

ScummVM games use it too, though nothing else here applies to them.
`scummvm` is an ordinary binary — ad-hoc signed, without hardened runtime — so
when the directory is set, `GameLauncher` starts it with
`DYLD_INSERT_LIBRARIES` naming the wrapp's own `in_process_helpers.dylib` and
`PUPPET_CONTROL_EXE=scummvm`; the other two helpers stay unarmed in it, their
variables unset. dyld kills a process whose inserted dylib is missing, so the
wrapp checks the file first and runs the game without puppet control if it
isn't there. ScummVM wrapps keep the dylib for this: `setup-wine.sh` leaves it
off `wine-files`, the list of what a ScummVM wrapp removes. If wrapps are ever
signed with hardened runtime, `scummvm` will need the
`com.apple.security.cs.allow-dyld-environment-variables` entitlement for this
to keep working.

One request per connection, one line each way, replies starting `ok` or
`error`. Coordinates are points in the game window with a top-left origin — a
capture's pixels divided by `scale` — so no screen geometry is involved.

| Request | Reply |
| --- | --- |
| `state` | `ok window=<n> size=<w>x<h> scale=<s> fullscreen=0\|1 key=0\|1 active=0\|1` |
| `capture <path>` | `ok <w>x<h>`, with a PNG of the game window at `<path>` |
| `click <x> <y>` | `ok`: a mouse move, then the left button held for 100 ms |
| `move <x> <y>` | `ok`: a mouse move alone (to park the game's drawn cursor) |

The wrapp answers for its own window the same way, on
`$SECOND_CHANCE_PUPPET_DIR/wrapp.sock` (`WrappTemplate/PuppetServer.swift`):
`info` replies `ok open=0|1 warning=0|1` for the info window and its save
warning, and `confirm` clicks **I Understand** where `InfoWindowView` reports
drawing it — `ok clicked` — or, if the warning is still up two seconds later,
does what the button does — `ok pressed`. (SwiftUI's accessibility tree,
which WrappPuppeteer used from outside, doesn't expose the button when read
in-process, so the view records the button's frame instead.)

The game window is the biggest visible window the process has. Two things
learned building it:

- **The click is held.** The Nancy Drew games poll the buttons
  (`GetAsyncKeyState`) rather than read click events, so a press and release
  posted together can fall between two polls and never be seen.
- **Listing windows is kept to a minimum.** ScreenCaptureKit has to list the
  process's windows before it can capture one, and that request queues in
  `replayd` behind every other capture on the Mac — for 8–16 s on a test Mac
  whose `systemstatusd` had been worn down ([testing.md](testing.md)). The
  helper keeps the window it found and lists again only when the window
  changes or a capture fails.

To watch it, set `IN_PROCESS_HELPERS_LOG`: each request and its reply is
logged as `pid=… puppet-control | <request> -> <reply>`. To drive it by hand,
start the wrapp with the variable and talk to the socket:

```bash
mkdir -m 700 /tmp/wp && SECOND_CHANCE_PUPPET_DIR=/tmp/wp "<wrapp>.app/Contents/MacOS/WrappTemplate" &
echo state | /usr/bin/nc -U /tmp/wp/game.sock
```
