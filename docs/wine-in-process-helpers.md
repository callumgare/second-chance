# Wine in-process helpers

Two things a wrapp does to the game's window need to happen _inside_ the Wine
process that owns it, because macOS only lets a process do them to its own
windows without the Accessibility permission — which a wrapp does not have:

| Helper | Source | What it does | Armed by | Off switch |
| --- | --- | --- | --- | --- |
| Native fullscreen | `WrappTemplate/InProcessHelpers/native_fullscreen.m` | Puts the game window into a real macOS fullscreen Space | `NATIVE_MACOS_FULLSCREEN_EXE` | `SECOND_CHANCE_NATIVE_FULLSCREEN=0` |
| Cursor lock | `WrappTemplate/InProcessHelpers/cursor_lock.m` | Gets cnc-ddraw to take hold of the mouse without swallowing the player's first click | `CURSOR_LOCK_EXE` | `SECOND_CHANCE_CURSOR_LOCK=0` |

## How they get into the game process

Both are compiled into one dylib, `Contents/Frameworks/in_process_helpers.dylib`,
by `WrappTemplate/setup-wine.sh` (an Xcode build phase of the WrappTemplate
target — add any new source to that phase's input files too, or edits to it
won't rebuild). `DYLD_INSERT_LIBRARIES` can't load them: wine-preloader reaches
its entry point before dyld runs initializers, so an inserted dylib is mapped
but its constructor never runs. Instead `patch-winemac.swift` gives Wine's Mac
driver, `winemac.so`, a weak dependency on the dylib. The header comment of
`native_fullscreen.m` has the details.

Every process that talks to the Mac driver loads `winemac.so` — `explorer.exe`
as well as the game — so each helper checks whether it is in the game before
doing anything. `WineEnvironment.runWindowsExecutableWithStart` sets
`NATIVE_MACOS_FULLSCREEN_EXE` and `CURSOR_LOCK_EXE` to the game's `.exe` name,
and a helper only arms when its process's executable has that name (Wine names
each child's loader copy after the `.exe` it runs). Leaving a variable unset is
what the off switches do.

Both log to os_log under subsystem `com.secondchance.gamewrapper` (categories
`NativeFullscreen` and `CursorLock`), and additionally append to the file named
by `IN_PROCESS_HELPERS_LOG` when it is set, which is the easier way to
watch one launch:

```bash
IN_PROCESS_HELPERS_LOG=/tmp/helpers.log open -n "built-apps/<game>.app"
```

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
