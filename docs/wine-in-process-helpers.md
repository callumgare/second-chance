# Wine in-process helpers

Some things done to the game's window need to happen _inside_ the Wine
process that owns it, because macOS only lets a process do them to its own
windows without the Accessibility (or Screen Recording) permission — which a
wrapp does not have:

| Helper | Source | What it does | Armed by | Off switch |
| --- | --- | --- | --- | --- |
| Native fullscreen | `Packages/Modules/wine/InProcessHelpers/native_fullscreen.m` | Puts the game window into a real macOS fullscreen Space | `NATIVE_MACOS_FULLSCREEN_EXE`, unless the launch says `--wine.window=windowed` ([below](#when-the-launch-says)) | `SECOND_CHANCE_NATIVE_FULLSCREEN=0` |
| Display below the notch | `Packages/Modules/wine/InProcessHelpers/display_below_notch.m` | On a display with a notch, shows Wine only the part below it, so a game in a fullscreen Space gets mouse positions that match its picture | `NATIVE_FULLSCREEN_BELOW_NOTCH=1`, in every Wine process of a wrapp | `SECOND_CHANCE_NATIVE_FULLSCREEN=0` |
| Cursor lock | `Packages/Modules/wine/InProcessHelpers/cursor_lock.m` | Gets cnc-ddraw to take hold of the mouse without swallowing the player's first click | `CURSOR_LOCK_EXE`, when the launch asks for it (`--wine.cursor-lock`, [below](#which-games-get-it)) | `SECOND_CHANCE_CURSOR_LOCK=0` |
| Mode scaling | `Packages/Modules/wine/InProcessHelpers/emulated_mode_scaling.m` | Scales a Direct3D game's picture up to the display when Wine is emulating the display mode the game switched to | `EMULATED_MODE_SCALING_EXE`, unless the game draws through cnc-ddraw ([below](#mode-scaling)) | `SECOND_CHANCE_MODE_SCALING=0` |
| Quit watch | `Packages/Modules/wine/InProcessHelpers/quit_watch.m` | Tells the wrapp when the game first put a frame on screen and whether anything asked it to quit, so a game that quits before it has started reads as a failure | `QUIT_WATCH_EXE`, for every Wine game ([below](#quit-watch)) | — (it only reports) |
| Cocoa start wait | `Packages/Modules/wine/InProcessHelpers/cocoa_start_wait.m` | Lets each Wine program's Mac driver wait for its main thread to start Cocoa beyond Wine's 5 s, which a fully loaded Mac runs out, leaving the program with no display driver for good | Nothing: every Wine process ([below](#cocoa-start-wait)) | `SECOND_CHANCE_COCOA_START_WAIT=0` |
| Hidden windows | `Packages/Modules/wine/InProcessHelpers/hidden_windows.m` | Keeps Big Fish's Game Manager's windows and Dock icon off the screen, but while the person signs in | `HIDDEN_WINDOWS_EXE`, set on the Game Manager; `*` for everything it runs during a build ([below](#hidden-windows)) | — |
| Puppet control | `Packages/Modules/wine/InProcessHelpers/puppet_control.m` | Lets the integration tests' WrappPuppeteer capture and click the game window | `PUPPET_CONTROL_EXE`, set only when `SECOND_CHANCE_PUPPET_DIR` is | — (never armed for players) |
| Virtual pointer | `Packages/Modules/wine/InProcessHelpers/virtual_pointer.m` | Shows the game (Wine, or ScummVM) a pointer that goes where it's put, in a login where the Mac's can't be moved (a test session), so puppet control's clicks land | As puppet control is, and only once a warp is seen not to move the pointer ([below](#virtual-pointer)) | — (never armed for players) |

## How they get into the game process

Their source is the wine module's, kept in its package beside `WineKit`
(`Packages/Modules/wine/`, [modules.md](modules.md#executors)). All of them
are compiled into one dylib, `Contents/Frameworks/in_process_helpers.dylib`,
by `Packages/Modules/wine/build-in-process-helpers.sh` (an Xcode build phase of the
WrappTemplate target — add any new source to that phase's input files too, or
edits to it won't rebuild), so every wrapp's launcher carries it, and the
launcher's revision hashes their source. `DYLD_INSERT_LIBRARIES` can't load them: wine-preloader reaches
its entry point before dyld runs initializers, so an inserted dylib is mapped
but its constructor never runs. Instead preparing Wine (`WineBuild.prepare`,
[modules.md](modules.md#engine-packages)) gives Wine's Mac driver,
`winemac.so`, a weak dependency on the dylib (`MachOPatch`). The header
comment of `native_fullscreen.m` has the details.

Every process that talks to the Mac driver loads `winemac.so` — `explorer.exe`
as well as the game — so each helper checks whether it is in the game before
doing anything. `Wine.inProcessHelperVariables(gameExe:launch:)` sets
`NATIVE_MACOS_FULLSCREEN_EXE`, `CURSOR_LOCK_EXE` and
`EMULATED_MODE_SCALING_EXE` to the game's `.exe` name,
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
`GameLauncher` sets them on the `wine start` it runs the game with
(`wine.start`). A game Steam launches (`-applaunch`, the `wine-steam` engine) is started
by the Steam client, which has the environment it was started with — not the
`-applaunch` call's — so the wrapp's `SteamClient` sets them on every Steam
process it runs. Steam's own processes have other names and never arm.

A game Big Fish owns is started by its DRM service, `bfggameservices.exe`
(`bfgprocess.exe` only hands it the game's `.bfg`), and a Windows service
has the environment `services.exe` started with: the session's first
program's, not the `bfgprocess` call's. So for an owned Big Fish game every
Wine program the wrapp starts carries the variables (`Wine.sessionVariables`,
`BigFishRuntime.sessionVariables`), whichever starts the session. (Writing
them into the prefix's registry environment doesn't reach a service: Wine's
`services.exe` passes its own environment on rather than building one from
the registry.) Nor does the game have any output of the wrapp's to write
its helpers' reports to, so they also append each line to the file
`SECOND_CHANCE_HELPER_REPORTS` names, which the wrapp reads as it would the
game's output (`HelperReportFile`). A Big Fish free trial is started by the
Game Manager's Play Now instead, which passes its environment on as any
program does.

They log to os_log under subsystem `com.secondchance.gamewrapper` (categories
`NativeFullscreen`, `CursorLock`, `EmulatedMode` and `PuppetControl`), and
additionally append to the file named
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
`InProcessHelperReport` (`Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/`) watches them. The wrapp logs
`[Helpers] Native fullscreen armed`, `[Helpers] Cursor lock armed`,
`[Helpers] Mode scaling armed` and `[Helpers] Puppet control armed` as each
helper arms. If a helper it armed hasn't reported arming a minute after the
game's window appeared, it logs an error naming that helper. A helper that
fails to arm is otherwise silent: the game plays in a window, or swallows its
first click, or draws into a corner of the screen. The integration tests fail
a Wine game whose log lacks the `armed` line of a helper it should have armed
([testing.md](testing.md)).

A cursor lock that gives up is reported but isn't an error. Only games that
draw through cnc-ddraw ever take the cursor, and the wrapp doesn't arm it in a
game it knows draws with Direct3D; in one it couldn't tell about, the helper
posts its middle clicks, sees no lock and leaves it.

## Native fullscreen

It waits for the game's window to stop resizing, then calls
`-toggleFullScreen:` on it, as the green title-bar button would. The game's
window is one of two kinds:

- **A window Wine lets go fullscreen.** Wine's `adjustFullScreenBehavior:`
  marks resizable, parentless windows as fullscreen-capable. cnc-ddraw's
  window is one.
- **A borderless window covering the screen.** This is how a Direct3D game
  draws in fullscreen mode (Ghost of Thornton Hall, for one). Left to Wine,
  such a window gets no Space: Wine raises it above the menu bar and the
  Dock instead. The helper takes one over only once Direct3D draws into it,
  which it detects by Wine having given the window an OpenGL or Metal view.
  A cnc-ddraw game's window can start out the size of the screen for a
  second or two before cnc-ddraw shrinks it, and cnc-ddraw attaches its
  OpenGL view only after that.

Wine decides which windows may go fullscreen from the game's Win32 window
style, and it decides again whenever the window's style or state changes,
which happens when the game loses and regains focus. A Space given to a
borderless window would last only until the player first switched away. So
for the window it takes over, the helper replaces five of Wine's own
`WineWindow` methods at run time (`replaceOwnMethod`, in `helper_common.h`,
which every helper replaces Wine's methods through: a method the Wine class
only inherits is first given to that class as its own, so replacing it never
changes `NSWindow`'s, and every other window's, along with it):

| Wine method | What it does for that window instead |
| --- | --- |
| `adjustFullScreenBehavior:` | Always grants fullscreen. Never takes the window out of its Space. |
| `minimumLevelForActive:` | Keeps the normal window level, not the raised level Wine gives a window covering the screen. |
| `doOrderOut` | Leaves the window, and its Space, in place while the app is inactive. Wine hides a fullscreen window by closing it, which would end the Space. |
| `windowWillStartLiveResize:`, `windowDidEndLiveResize:` | Do nothing while a window covering the screen moves into or out of its Space. A window Wine lets go fullscreen keeps Wine's: it really is resized, and cnc-ddraw rescales its picture and the mouse when told the resize has ended. |

AppKit counts that move as a live resize, and Wine passes a live resize
on to the game as `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`, as though the
player had started dragging the window's edge. On Windows a fullscreen
Direct3D game never gets them. Warnings at Waverly Academy and Shadow at
the Water's Edge, from Steam, stopped drawing for good more often than not
when their frame timer's tick landed between the two, leaving the Space
black. The window is the size of the screen before and after the move, so
the game misses nothing.

Every other window keeps Wine's behaviour. The helper checks these methods
exist before replacing them. If Wine has changed and they don't, it reports
a warning and gives fullscreen only to the windows Wine already allows.

The helper keeps watching after the first entry. A window whose Space Wine
closed while the app was active goes back into one when it is shown again.
A window the player took out of fullscreen themselves is left windowed.

The header comment of `native_fullscreen.m` has the details.

### When the launch says

A Wine launch can override native fullscreen with `--wine.window`
([wrappfile.md](wrappfile.md#the-launch-volumes-and-app)), for a program
the wrapp gets wrong:

- **`--wine.window=windowed`** leaves native fullscreen unarmed
  (`RecordedLaunch.keepsWindowed`), so the program stays in its window,
  whatever it asks for.
- **`--wine.window=fullscreen`** arms it as usual and also sets
  `NATIVE_MACOS_FULLSCREEN_FORCE=1` (`RecordedLaunch.forcesFullscreen`), to
  make the window fullscreen whether or not the program asks. The helper
  doesn't read it yet, so for now it does what leaving the option out does.
- **Left out**, native fullscreen works as above, as it always has. What's
  planned is for the helper to see when the program asks for fullscreen
  itself, with the option kept for a program it misjudges.

ScummVM and DOSBox games are always fullscreen; the option is the wine
module's. What window WrappPuppeteer expects a game to end up in is its
bundle's test's to say ([testing.md](testing.md#scenarios)).

### On a display with a notch

A fullscreen Space on a display with a notch leaves out the strip the notch
sits in. On a 1512×982 display the game's window is 1512×945. Wine tells the
game its window has shrunk, but a Direct3D game keeps drawing for the whole
display. Direct3D squeezes that picture into the window, and mouse positions
aren't adjusted to match. Measured on Secrets Can Kill Remastered, the
game's cursor sat 12 points above the real one near the top of the screen and
37 points above it near the bottom, enough to miss a button. (cnc-ddraw
games aren't affected, because cnc-ddraw scales mouse positions itself.)

`display_below_notch.m` makes Wine see a display that ends at the notch, by
using the display's own below-notch mode (1512×945 there), which macOS offers
for apps to run below the notch. The game then starts with a desktop the size
of the Space, and its picture and the mouse agree. In every Wine process of
the wrapp, for Wine's Mac driver (`winemac.so`) only:

| What Wine calls | What it gets |
| --- | --- |
| `-[NSScreen frame]`, `-visibleFrame` | The screen without the strip. Wine builds its displays from these, and converts window and cursor positions with them. |
| `CGDisplayCopyDisplayMode` | The below-notch mode. Wine sizes the Win32 desktop from the current mode. |
| `CGDisplaySetDisplayMode` with the below-notch mode | Nothing happens, so Wine "restoring the original mode" never switches your display. |
| `CGEventGetLocation`, `CGWarpMouseCursorPosition` | Positions shifted by the strip's height, since these count from the true top of the display. |

The first is a method replacement that checks its caller is `winemac.so`. The
others replace `winemac.so`'s imported addresses (its `__got` entries), so the
rest of the process, AppKit included, sees the display as it is.

It has to act in `explorer.exe` too, not only in the game: in Wine 10 the
desktop process registers the displays, and the game takes them from there.
So rather than naming the game's `.exe`, it is armed by
`NATIVE_FULLSCREEN_BELOW_NOTCH=1`. The wrapp sets that on itself at start-up
(`Wine.wrappSessionVariables`), and every Wine process it starts
inherits it. Second Chance's own installer runs never have it.

It does nothing unless the main display is a built-in one with a below-notch
mode, and it stops adjusting anything if that display's mode changes while
the game runs. The game's process logs `showing Wine the display below the
notch` when it applies.

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

### Which games get it

Only the DirectDraw games draw through cnc-ddraw. The Direct3D ones (the later
games — Crystal Skull, Thornton Hall, Castle Malloy and Alibi in Ashes among
them — and Secrets Can Kill Remastered) never go near it, and in those
the helper's middle clicks did harm: one arriving while the player has a menu
open from the menu bar closes it, and with nothing ever locking the cursor the
helper kept clicking for its full 15 tries — again on every return to the app.

So the wrapp arms it only when the game's launch asks for it,
`LAUNCH --wine.cursor-lock`, recorded in its settings
([wrappfile.md](wrappfile.md#the-launch-volumes-and-app)), and every Nancy
Drew DirectDraw game's launches do. Planning refuses a target that sets
cnc-ddraw up (`DO wine.cnc-ddraw`) and whose launch doesn't ask, since its
first click would be swallowed. A launch recorded before the option
(`RecordedLaunch.format` nil or 1, `choosesItsHelpers` false) keeps the old
inference: the lock is armed where cnc-ddraw may be drawing, as the launch
declares (`--wine.graphics=direct-draw`, `direct-3d` or `unknown`). A wrapp
built before launches were recorded is judged as before:
`GameGraphicsAPI`
(`Packages/WrappKit/Sources/WindowsFormats/`) reads the DLLs the game's `.exe` imports, from its PE import
directory: `ddraw.dll` means DirectDraw; `d3d8.dll` or `d3d9.dll` without it
means Direct3D, and cursor lock stays unarmed. Every game checked fell cleanly
on one side, the Steam copies too: Steam's DRM wrapper leaves the imports
readable (Ghost of Thornton Hall's adds `steam_api.dll` beside `d3d9.dll`).

Big Fish's copies don't: Armadillo packs the `.exe`, leaving it importing
neither ([big-fish.md](big-fish.md)). For an `.exe` like that, or one that
can't be read, the game catalog says instead: every Wine game in it has
`graphics`, from what its disc and Steam `.exe`s import (a test checks none is
missing). Without that, a Big Fish Direct3D game got the cursor lock's 15
middle clicks in its first minute, and WrappPuppeteer waited for them to end
before clicking past a splash screen. Only a game the catalog doesn't know,
whose `.exe` says nothing, arms it as before. The wrapp's log says which it
found, and why the lock isn't armed: `[Helpers] Thornton.exe draws with
Direct3D, as its launch says, and cursor lock isn't armed: its launch doesn't
ask for it` (or, for an older launch, `it doesn't draw through cnc-ddraw`).

### What it does

It waits until the game window is key, the app is active and its frame is
final. With native fullscreen armed, that's once the window has finished
moving into its fullscreen Space, which AppKit announces
(`NSWindowDidEnterFullScreenNotification`, watched by `native_fullscreen.m`).
A lock taken before then would confine the cursor to the old frame, and on a
slow machine the window can sit at its initial size for several seconds before
native fullscreen moves it, so a frame that has stopped changing isn't enough.
Without native fullscreen, or if the window still isn't in a Space after 20
seconds (native fullscreen can give up and leave the window as it is), the
sign is the frame holding still for a second. Then it:

1. Checks whether the cursor is locked. Wine's Mac driver records both halves
   of cnc-ddraw's lock on `WineApplicationController` — `clippingCursor` and
   `clientWantsCursorHidden` — and runs in this same process, so they are read
   directly. Found this way, before any click, the lock has to hold for two
   seconds to count: both flags are briefly true at startup, before cnc-ddraw
   first releases the cursor.
2. If not, posts a **middle** click to the game window and keeps checking.
   Clicks are only posted while the cursor is free, so cnc-ddraw had already
   let go of it, and a lock that appears after the click is the click's: it
   counts at once. With no lock two seconds after a click, it clicks again,
   up to 15 clicks.

cnc-ddraw normally locks within a quarter of a second of the click, so the
lock is done moments after the window reaches its Space. (It used to wait a
second for the frame to hold still even in a Space, sleep two seconds after
each click, and ask every lock to hold for two more: over five seconds after
fullscreen, which a DirectDraw game's first click — a player's or the
integration test's — had to wait for.)

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

The integration test checks it on every game that may draw through cnc-ddraw:
WrappPuppeteer waits for the cursor lock to finish, notes whether the game
holds the cursor, and makes its first click. If the cursor was free before that
click and held after it, the click is what cnc-ddraw locked on — so it
swallowed it — and the run fails with "The game's first click was swallowed".
A Direct3D game has no cnc-ddraw to swallow anything, and isn't checked
([testing.md](testing.md#wrapppuppeteer)).

The helper log should show the lock taking hold, normally on the first click:

```text
pid=… cursor-lock | armed
pid=… cursor-lock | window is in its fullscreen Space
pid=… cursor-lock | posted middle click 1
pid=… cursor-lock | cursor locked after 1 middle click(s), 0.25s after the last
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

## Mode scaling

### The problem it solves

Old games switch the display to the mode they were made for, and quit when
the switch fails. The White Wolf of Icicle Creek asks for 800×600 and exits
(cleanly, exit 0, a few seconds after its window appears) when Wine answers
`DISP_CHANGE_BADMODE`, which it does whenever the Mac display has no mode of
that size: Wine only offers modes the display really has, and a MacBook's
built-in display has no 4:3 modes at all. On a monitor that does have the mode
the switch works, but really switches the monitor.

So the prefix has Wine's `EmulateModeset` on (the wine module's
`Modules/wine/stages/prefix`, whose `WINE.REGISTRY` step sets it as the prefix is made; Wine 10 reads it from `HKCU\Software\Wine\X11 Driver` whatever
the driver). win32u then says yes to any common mode without touching the
display, and maps the game's windows up to the display's real size, at the
same scale on both axes: on a 1512×945 display the game's 800×600 window
becomes a 1260×945 view, centred in a Mac window covering the display. Mouse
positions go back down the same way.

### What it does

Wine 10's Mac driver doesn't scale what Direct3D draws. wined3d presents its
800×600 frame into the window's OpenGL surface, which Wine sizes to the
1260×945 view, so without help the frame lands in the view's bottom-left
corner. (winex11 renders into an offscreen drawable of the game's size and
blits it up; winemac has nothing like it.) In the game's process the helper:

- replaces `-[WineOpenGLContext wine_updateBackingSize:]`, Wine's own Retina
  mode hook, which does nothing with Retina mode off. It gives the OpenGL
  surface the game's size, the view's size divided by Wine's scale, as the CGL
  surface backing size, and macOS stretches it to fill the view. Wine's scale is
  the display's size over the emulated mode's, the smaller of the two axes. The
  mode comes from `NtUserEnumDisplaySettings`, called from the thread Wine makes
  the context current on, as Wine's drivers call win32u. It's a plain export of
  win32u.so, unlike the version-specific `NtUserCall*` codes, and like every
  Unix-side export it uses the normal calling convention, not `ms_abi`. The
  display's size is what Wine sees (`wineMainDisplaySize`, below the notch when
  [that helper](#on-a-display-with-a-notch) is on).
- leaves a borderless Wine window where Wine put it, replacing
  `-[WineWindow constrainFrameRect:toScreen:]`. Wine maps a window up to the
  whole display only if it exactly covers the emulated screen, and a game
  creates its window at the mode's size before switching: an 800×600 window at
  (0,0) of a larger display, which AppKit pushes below the menu bar. The game
  keeps that position, and after the switch its window starts a point or more
  below the emulated screen's top, so Wine scales it as an ordinary window that
  covers neither the display nor the menu bar, and native fullscreen never
  adopts it.
- paints Wine's window surface black outside the OpenGL view, wrapping
  `-[WineContentView setColorImage:]`. The bars beside a picture of another
  shape are the Mac window's own surface, which nothing draws into and which
  Wine fills with AppKit's light grey window background. That surface covers
  only the mode's screen scaled up (x 0–1920 for 800×600 on a 2560×1440
  display), not the whole display, so beyond it, in the right-hand bar, the
  Mac window's own background shows. The helper makes that black too, both
  when the image arrives and after `-[WineWindow checkTransparency]`, which
  sets an opaque window's background back to AppKit's colour. A window with a
  title bar gets the same while a picture is being scaled: White Wolf's
  window has been seen with one, still covering the display, and its right
  bar white. What gives it one is unknown; it isn't the title bar macOS shows
  over a fullscreen window while the cursor rests at the top of the screen,
  which leaves the bars black without this
  ([the cursor and the title bar](testing.md#the-cursor-and-the-title-bar)).
  (An ordinary titled window's OpenGL view fills it, so it has no bars to
  paint.)

- keeps the game's mode and window while the game is in the background.
  When a fullscreen Direct3D game loses focus, wined3d puts the desktop mode
  back and minimizes the game's window, as Windows does. A window in a
  fullscreen Space can't be minimized, so Wine restores it at once, and its
  Mac driver gives the restored window the Mac window's frame
  (`macdrv_ShowWindow`), which is in the display's points rather than the
  emulated mode's. The game's 800×600 window became 1512×945 in an 800×600
  world. Restoring the window also made it active again inside Wine, so when
  the player really came back nothing put it right, and the game reset its
  device while the desktop mode was still set. White Wolf came back from
  Cmd-Tab with its picture half a screen up and black below. Neither step does
  anything for the real display while the mode is emulated, so while the
  game's app is in the background the helper answers a request to restore the
  desktop's mode, and one to minimize a window, as done without doing them. It
  swaps `NtUserChangeDisplaySettings` and `NtUserShowWindow` in win32u.so's
  syscall table (its `__DATA,__data`), which is how the game's Windows side
  reaches them. The game hears it has lost focus through its message queue,
  after the app has, and a quick Cmd-Tab brings the app back before the game
  has handled it. So the helper keeps doing this until the game asks for its
  own mode again, as wined3d does when it handles the return, not until the
  app is back in front. The wrapp's log says `keeping the game's display mode and
  window while it's in the background` the first time it does. The
  integration test's [switch away and back](testing.md#switching-away-and-back)
  covers the slow case only: a quick switch there didn't reproduce the
  timing, even without the fix, so the quick case was checked by hand.

Once Wine's window covers the display, [native fullscreen](#native-fullscreen)
puts it into a Space as for any other Direct3D game. The Space is the size the
window already is, so nothing is resized. Nothing happens in a game that never
switches modes: the mode then matches the display and the scale is 1.

### Which games get it

`EmulateModeset` is on for the whole prefix, but the helper arms only in a
game that may draw with Direct3D (`GameGraphicsAPI.mayUseDirect3D`). A game
that draws through cnc-ddraw never switches the real display, since cnc-ddraw
runs windowed. `SECOND_CHANCE_MODE_SCALING=0` (`--debug no-mode-scaling`)
leaves the helper unarmed but `EmulateModeset` on, so the frame lands in the
corner again, for comparison.

### Checking it

The wrapp's log names the scale each time the surface changes size:

```text
[Helpers] Mode scaling armed (armed in Game.exe)
[Helpers] Mode scaling: scaling Direct3D's 800x600 picture up to 1260x945
[Helpers] Native fullscreen: entering native fullscreen: '…' 1512x945 (a window covering the screen)
```

A first line for a smaller size (`508x381 … up to 800x600`) is normal: it's
the moment between the switch and Wine resizing the window. To see Wine's
side, `SECOND_CHANCE_WINEDEBUG=+system` shows the game's
`NtUserChangeDisplaySettings` request (`trace_devmode … dmPelsWidth=800
dmPelsHeight=600`) with no `returned -2` after it, and `+macdrv` shows the
game window's rects: `client (126,0)-(1386,945), visible (0,0)-(1512,945)` on
a 1512×945 display.

A build's Wine sessions on a 120 Hz display (a MacBook Pro's) log
`NtUserChangeDisplaySettings … returned -2` and `explorer:initialize_display_settings
Failed to initialize registry display settings` once each time explorer.exe
starts. That isn't a game failing: explorer asks to record the current mode,
at 120 Hz, and every emulated mode is 60 Hz, so the request matches none of
them. win32u has already recorded the mode itself. A game's launch logs the
same refusal as Wine's desktop starts, before the game's window appears, as
`Changing (null) display settings returned -2`; a game refused its own mode
names the display instead (`Changing L"\\.\DISPLAY1" …`), which is how
[quit watch](#quit-watch)'s check tells the two apart.

## Quit watch

### The problem it solves

A game that can't run often just quits: The White Wolf of Icicle Creek, refused
its display mode, exited 0 two seconds after its window appeared, with nothing
on screen and no message. Wine games return all sorts of exit codes when the
player quits, so the code can't tell the two apart, and the wrapp logged
`Game ended, exiting cleanly` and closed. The player saw the game vanish.

### What it does

In the game's process the helper prints one line (in [the report
format](#how-they-get-into-the-game-process)) when each of these first happens:

- `first frame on screen`, from `-[WineOpenGLContext flushBuffer]`. Wine's Mac
  driver draws Direct3D through an OpenGL context, and a frame reaches the
  screen only when the game presents one: `wglSwapBuffers` ends there. Wine's
  own painting of a new window goes through the window's surface image
  instead, so the first call is the game's.
- `quit requested`, from `-[WineApplicationController applicationShouldTerminate:]`,
  which ⌘Q in the game, Quit from its Dock menu and a logout all reach. These go
  to the game's process, not the wrapp, so the wrapp can't see them itself.

The wrapp (`GameQuitCheck`, in `Packages/SecondChanceKit/Sources/SecondChanceKit/Wine/`) reads those lines and Wine's
`err:` lines from the game's output. When the game exits it judges the exit a
failure if nothing asked the game to quit and the game:

- quit before its window appeared, and before any frame (a frame means a
  window the wrapp missed);
- draws with Direct3D, and quit before its first frame;
- quit within 1 s of a Wine error that isn't one of the routine ones every
  launch logs (`Modules/wine/routine-errors.yaml`: Vulkan, wow64, HID devices,
  NTLM and Kerberos, the desktop's `(null)` mode refusal, and for a game
  started through Steam, the COM lookups and graphics probe Steam does as it
  starts).

Asked to quit means the wrapp quitting (⌘Q on its window, a `SIGTERM`, which is
how the tests stop it), the helper's `quit requested`, or macOS announcing a
logout or shutdown. A game killed by a signal is reported as that already.

A failure is logged as an error, with the Wine errors behind it, and the
wrapp shows its error window, saying why when the Wine error is one it knows
(`GameQuitCheck.knownCause`: a refused display mode, an unhandled exception, a
DLL that won't load). The wrapp then exits 1, or with the game's own code if
that wasn't 0. The game's exit is noticed the moment it happens (a
`DispatchSource` process source in `GameMonitor`), so the time since the last
Wine error is exact.

### Which games get it

Every Wine game. Only a Direct3D game's first frame counts, though: cnc-ddraw
presents on a timer whether the game has drawn anything or not, so a DirectDraw
game, or one whose graphics `GameGraphicsAPI` can't tell, is judged by its
window and Wine's errors alone. ScummVM games aren't checked.

### Checking it

```text
[Helpers] Quit watch armed (armed in Game.exe)
[Helpers] Quit watch: first frame on screen
```

A game that quits unexpectedly logs, after the usual `■ Game exited …` line:

```text
■ That was no quit: nothing asked the game to quit, and it quit before it drew anything. The game asked for a display mode this Mac doesn't have, and quit when it couldn't have it.
    Wine: 0130:err:system:NtUserChangeDisplaySettings Changing L"\\.\DISPLAY1" display settings returned -2.
```

A healthy launch that gets reported this way has met a Wine error that's
routine after all: the line it names belongs in `Modules/wine/routine-errors.yaml`
(or `Modules/steam/`'s, for a line only Steam's launches log), then `sc
generate`, which compiles them into the wrapp (`GameQuitCheck+RoutineErrors.swift`).

## Cocoa start wait

### The problem it solves

Every Wine program that talks to the Mac driver — `explorer.exe`, Wine's
services, the game — starts it in `macdrv_start_cocoa_app` (Wine's
`dlls/winemac.drv/cocoa_main.m`): it asks the main thread to become a Cocoa
app, handing it a pointer to a struct on its own stack, and waits 5 seconds
for it. With every core busy, under Rosetta, the main thread hasn't always
got there by then — seen with nine games starting at once and busy loops on
top. The driver then gives up ("Failed to start Cocoa app main loop"), so
the program has no display driver for good: the game never shows a window,
sitting there using CPU, or explorer's desktop never comes up and the game
is told "The explorer process failed to start". When the main thread does
get to the request, it reads the struct from a stack frame long gone and
crashes (`-[__NSMallocBlock__ lock]: unrecognized selector`). Nothing
recovers once the load goes.

### What it does

It replaces `-[NSConditionLock lockWhenCondition:beforeDate:]`, and for the
one call that is that wait — from `winemac.so`, for condition 1,
`COCOA_APP_RUNNING` — waits up to 10 minutes instead, as long as a build
waits for Wine's desktop. Every other call goes straight to the original. A
start that took longer than 5 s logs
`second-chance-helper[CocoaStart] warning: the main thread took …s to start
Cocoa, past Wine's 5s limit`, the cases that would have failed before.

It isn't armed per game: it runs in every Wine process, the build's
installers included, as all of them start the driver the same way.

### If it happens anyway

The wrapp watches the game's output for the driver giving up, or for
`nodrv_CreateWindow` (`NoDisplaySignal`, which a build also retries on).
Either means the game can never show a window, so the wrapp reports it,
stops the launch and opens the game again by itself, passing
`--after-no-display`; a copy started that way shows an error instead
(`noDisplayExplanation`) if it happens again.

## Hidden windows

Big Fish's Game Manager is driven through its page
([big-fish.md](big-fish.md)), and the person should only see it to sign in,
as Steam's `-silent` keeps Steam out of sight. The Game Manager has no such
option, so `BigFishGameManager` starts it with `HIDDEN_WINDOWS_EXE` set
(`Wine.hiddenWindowsVariables`). During a build it is `*`: a Wine program
passes its environment on to the programs it starts, so every program the
Game Manager runs is hidden too — the game's installer, and Microsoft's
DirectX setup, which a script cancels unseen. The Game Manager's own
installer, which an AutoIt script clicks through, runs with it set to `*`
too, and a file to show it that is never made. When a wrapp starts a trial
through it, it is `bfgclient.exe`, as the game is one of those programs. In
each process it arms in, the helper:

- keeps windows off the screen: AppKit puts a window there through
  `-[NSWindow orderWindow:relativeTo:]`, which every `orderFront:` comes down
  to and which Wine's Mac driver calls for each window the program shows.
  While hidden, a window ordered in is remembered instead, so none flashes up;
- keeps the Dock icon away: Wine gives a program its Dock icon, and makes it
  active, in `-[WineApplicationController transformProcessToForeground:]`,
  which does nothing while hidden.

It shows them, as Wine would have, while the file `HIDDEN_WINDOWS_SHOW_FILE`
names exists, looking four times a second, and hides them again (an
accessory app: no Dock icon) once it's gone. `showSignIn` creates it and
`hideWindow`, which the build calls once the person has signed in, removes
it. It lives in the temporary folder, so it never ships in a wrapp. The
helper logs `second-chance-helper[HiddenWindows] notice: armed in
bfgclient.exe (pid …)`, then `windows shown` and `windows hidden` as the sign-in
comes and goes.

## Puppet control

The integration tests drive a wrapp with WrappPuppeteer
([testing.md](testing.md#wrapppuppeteer)): it finds the game's Exit button in
a capture of the game window and clicks it. Doing that from outside the game
needs Screen Recording and Accessibility. From inside it needs neither: a
process may capture its own windows (ScreenCaptureKit's current-process
content, macOS 14.4+) and post events to them (`-[NSApp postEvent:]`, as
cursor lock does). So this helper does the capturing and clicking, and
WrappPuppeteer asks it to over a Unix socket. It checks for the 14.4 API by
asking ScreenCaptureKit for it, not with `@available`. ScummVM is linked
against the macOS 10.14 SDK, so macOS runs it in compatibility mode and tells
it an older version than its own, and on macOS 15 `@available` refused to
capture in every ScummVM wrapp.

It arms only when WrappPuppeteer started the wrapp. WrappPuppeteer passes
`SECOND_CHANCE_PUPPET_DIR`, a private directory; when that is set,
`Wine.inProcessHelperVariables` sets `PUPPET_CONTROL_EXE` to the
game's `.exe`, and the helper in that process listens on
`$SECOND_CHANCE_PUPPET_DIR/game-<pid>.sock`, named by its own PID. A player's
launch sets neither, so nothing listens.

Each process has a socket of its own because a game can run as two processes
with the same `.exe`: an Armadillo-wrapped game from Big Fish starts a second
copy under its own debugger, and that copy has the window
([big-fish.md](big-fish.md)). Both load the helper. When they shared one path,
whichever started last took it, and the Secrets Can Kill Remastered trial's
debugger, which has no window, started six seconds after the game: every
request got `error no game window`. WrappPuppeteer works out which process has
the game's window before its first request, and talks to that one's socket.

The sockets are also how WrappPuppeteer finds the game at all. It waits for a
`game-<pid>.sock` whose process is alive to appear in its directory, then for a
window of any process serving one there (`ProcessSockets`). It doesn't look the
game up by name: most Nancy Drew games are `Game.exe`, and another started
meanwhile, by a person or another wrapp in the same login, would have passed
for it. A game whose process is running but never serves a socket fails the
run with "puppet control never armed".

ScummVM games use it too, though nothing else here applies to them.
`scummvm` is an ordinary binary — ad-hoc signed, without hardened runtime — so
when the directory is set, `GameLauncher` starts it with
`DYLD_INSERT_LIBRARIES` naming the wrapp's own `in_process_helpers.dylib` and
`PUPPET_CONTROL_EXE=scummvm`; the other two helpers stay unarmed in it, their
variables unset. dyld kills a process whose inserted dylib is missing, so the
wrapp checks the file first and runs the game without puppet control if it
isn't there. ScummVM wrapps keep the dylib for this: it is the launcher's, not
Wine's, so taking Wine out of a ScummVM wrapp leaves it. If wrapps are ever
signed with hardened runtime, `scummvm` will need the
`com.apple.security.cs.allow-dyld-environment-variables` entitlement for this
to keep working.

One request per connection: a line in, a reply out (one line, but for
`windows`), starting `ok` or `error`. Connections are served at once, each on a
thread of its own, so a capture that takes seconds holds up no click. Coordinates
are points in the game window with a top-left origin — a capture's pixels divided
by `scale` — so no screen geometry is involved. Options are `name=value` words
after the arguments. `PUPPET_CONTROL_EXE=*` arms it in every process that loads
it (an installer, a launcher and the game each get a socket), as
`HIDDEN_WINDOWS_EXE=*` does for hidden windows.

A capture has to show what the screen shows, or clicks aimed by it miss. On
macOS 15 they didn't always. The move into a fullscreen Space left a Direct3D
game's OpenGL surface at a size from partway through it: 2485×1399 in a
2560×1440 window. On screen macOS scales the surface up to fill the window,
by the same 3% both ways, so the picture is where it should be, but a capture
of the window takes the surface as it is,
in the bottom-left corner with the rest transparent. The game's Exit button
was then 63 points left of where the capture put it, and the test's clicks
missed it until something resized the surface, such as the player moving the
mouse. So a capture whose opaque part is smaller than the window and anchored
bottom-left is scaled up to fill it, as the screen does (`undersizedSurface`).
macOS 26 doesn't leave the surface undersized.

| Request | Reply |
| --- | --- |
| `hello` | `ok version=2 pid=<n> exe=<name> commands=<list>`: older helpers in built wrapps answer `error unknown request`, which says they're version 1 |
| `state` | `ok window=<n> size=<w>x<h> scale=<s> fullscreen=0\|1 native=0\|1 key=0\|1 active=0\|1 onspace=0\|1 cursor=held\|free cursorlock=off\|waiting\|locked\|not-locked` — `fullscreen` for a macOS fullscreen Space (`native`) or a borderless window exactly covering the screen, as Direct3D games draw; `onspace` whether the window is on the Space on screen; `cursor` whether cnc-ddraw holds the mouse now, and `cursorlock` how the [cursor lock](#cursor-lock) got on (`off` where it isn't armed, as in ScummVM) |
| `windows` | `ok <n> windows`, then a line each: `id=<n> frame=<x>,<y>,<w>,<h> level=<n> visible=0\|1 key=0\|1 main=0\|1 kind=game\|panel\|other title=<percent-encoded>`, the frame from the screen's top left; `game` is the window the other requests act on |
| `capture <path> [region=<x>,<y>,<w>,<h>] [scale=<s>]` | `ok <w>x<h>`, with a PNG of the game window at `<path>`: a part of it (in points) for `region`, and at `scale` pixels a point rather than the window's own |
| `click <x> <y> [button=left\|right] [count=1-3] [hold=<ms>]` | `ok`: a mouse move, 150 ms for the game to see it, then the button held for 100 ms (or `hold`), `count` times |
| `move <x> <y>` | `ok`: a mouse move alone (to park the game's drawn cursor) |
| `down <x> <y>`, `up <x> <y>` `[button=]` | `ok`: a press, or a release, alone |
| `drag <x> <y> <x2> <y2> [steps=<n>] [hold=<ms>]` | `ok`: a press at the start, `steps` moves (10) along the line with the button down, a release at the end |
| `key <name>[+<mod>…] [hold=<ms>]` | `ok`: modifiers down, the key down, held 60 ms, up, modifiers up, each with its own virtual keycode (US layout), which is what Wine and SDL read. Names: `a`–`z`, `0`–`9`, punctuation, `return`, `escape`, `tab`, `space`, `delete`, the arrows `left` `right` `up` `down`, `f1`–`f12`, `home`, `end`, `pageup`, `pagedown`; modifiers `cmd`, `shift`, `opt`, `ctrl` |
| `type <text>` | `ok`: each character as its key, with shift where it needs it, 40 ms apart; the text percent-encoded (`Hi%20there`) |
| `focus` | `ok`: the app made active and the game window key |
| `quit` | `ok`: the app is asked to quit as its Quit menu item (Wine's ⌘⌥Q) does, with `-[NSApplication terminate:]`, not waited for, since a hang would be inside it |
| `yield <pid>` | `ok`: the game's app hands activation to that app, which may then make itself active: WrappPuppeteer switching away from the game, as Cmd-Tab would, since macOS 14 only lets the active app hand activation on |

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

- **The click is slow, like a hand's.** The Nancy Drew games poll the mouse
  (`GetAsyncKeyState`, `GetCursorPos`) a frame at a time rather than read
  click events. A press and release posted together can fall between two
  polls and never be seen, and a press arriving with the cursor, before the
  game has highlighted the button under it, is ignored: the Exit click took
  four tries until the cursor was given 150 ms to arrive first.
- **Each capture lists the process's windows afresh.** ScreenCaptureKit has
  to list them before it can capture one. A window kept from an earlier
  listing can stop capturing with nothing to say so — once the window has
  moved into its fullscreen Space, or after a Direct3D game skips its intro
  (Crystal Skull's) — where one listed again captures at once. On a Mac whose
  `systemstatusd` has been worn down, listing queues in `replayd` for 8–16 s
  ([testing.md](testing.md)); so does every capture there, and a reboot is
  the fix.
- **A capture that goes unanswered gets a second one alongside it.** Now and
  then ScreenCaptureKit never answers a screenshot request, though it
  answers the same request a moment earlier or later in a fraction of a
  second. Nothing announces it: logging AppKit's window, Space and screen
  notifications around captures, the run whose capture was lost saw the same
  events in the same order as the eight that weren't. So after 2 s without an
  answer the helper lists the windows again and asks for a second
  screenshot, without giving up the first; whichever brings a picture back
  first is the reply, and an error only counts once neither is outstanding.
  On a slow Mac the first can still win, so the 2 s only decides when the
  spare request starts. A request gives up after 30 s.
- **Nothing is captured until the window is in its fullscreen Space.** A
  capture around the move — during it, or even one finished just before it
  begins — can come back refused as though Screen Recording were denied, and
  leave the window out of the process's capturable windows for good (Castle
  Malloy's and Crystal Skull's tests each failed so, every capture for five
  minutes). So `capture` replies `error the game window isn't in its
  fullscreen Space yet` until native fullscreen is done with the window: it
  has moved it, and AppKit has said the move finished
  (`NSWindowDidEnterFullScreenNotification`, which `native_fullscreen.m`
  watches for every helper — `helper_common.h`), or it gave up, or it isn't
  armed. `state` likewise says `native=0` until the move has finished, so
  WrappPuppeteer starts on the game once it's there.

Keys and mouse buttons are posted as clicks are, so they need nothing more. Posted
keys reach a Wine game (SkiFree turns at the arrows and restarts at F2) and ScummVM
(Ctrl-F5 opens its menu), in a test session too. A Direct3D Nancy Drew game
ignored Escape at its desk and in its case file, which may only mean it doesn't
use the key there.

To watch it, set `IN_PROCESS_HELPERS_LOG`: each request and its reply is
logged as `pid=… puppet-control | <request> -> <reply>`. To drive it by hand,
start the wrapp with the variable and talk to the socket:

```bash
mkdir -m 700 /tmp/wp && SECOND_CHANCE_PUPPET_DIR=/tmp/wp "<wrapp>.app/Contents/MacOS/WrappTemplate" &
echo state | /usr/bin/nc -U /tmp/wp/game-<pid>.sock   # the game process's PID
```

## Virtual pointer

**In a test session the Mac's pointer can't be moved by a program.** A test
session ([dev-cli.md](dev-cli.md#test-sessions)) is a login made through
Screen Sharing, running in the background on a virtual display. There the
pointer stays where Screen Sharing's viewer last put it — (10,10) when it
never has, as with the keep-alive — and `CGWarpMouseCursorPosition`, though it
reports success, puts it back there whatever it was asked for;
`CGDisplayMoveCursorToPoint` and posted HID moves don't move it either. Only a
pointer event over Screen Sharing does. On a console the same calls move it.

Wine reads the real pointer for `GetCursorPos` (`+[NSEvent mouseLocation]`,
in `macdrv_get_cursor_position`), and a game that holds the cursor —
cnc-ddraw's [lock](#cursor-lock) — warps it to where the game's cursor should
be and reads it straight back. So in a test session a click puppet control
posted on old-clock's Exit button reached Wine at the button
(`button 0 pressed at (1160,1272)` in a `WINEDEBUG=+cursor` trace), but the
game, reading `pointer at (10,10)`, put its cursor in the picture's top-left
corner (`warped to 320,9`) and took every click there. Every click-driven
test of a Wine game failed in test sessions; keys, which don't involve the
pointer, worked. ScummVM 2026.3 took a click's position from its event, so
its clicks landed; 2026.4 warps the pointer and then reads it (SDL, through
`+[NSEvent mouseLocation]`), and its clicks on Stay Tuned's Exit button did
nothing in a test session though they quit it on a console.

`virtual_pointer.m` keeps a pointer of its own for the game where the real
one is stuck. It arms where puppet control does, and acts only once a warp,
on the game's first use of the pointer, is seen not to move it — one point
across and back, which nobody sees on a console — so a console run uses the
real pointer as before. In a Wine process:

- it wraps `winemac.so`'s imports of `CGWarpMouseCursorPosition` and
  `CGEventGetLocation` (on top of [the notch
  helper](#on-a-display-with-a-notch)'s wrappers, when those are in;
  `helper_common.h`), and `+[NSEvent mouseLocation]` for calls from
  `winemac.so`;
- a warp moves its pointer (and still goes through), and so does a move or
  click puppet control posted, which puppet control marks with
  `kPuppetEventTag` in the event's user data — the one field
  `-[NSApplication postEvent:atStart:]` keeps (it renumbers events);
- every other mouse event is given its pointer as its position: the window
  server's, the moves AppKit makes up when the app is activated (as a click
  activates it), which even carry the game's own process id, and cursor
  lock's middle clicks, which aim at the real pointer. Any of them would
  otherwise drag the game's cursor back to the corner.

In ScummVM, which loads the dylib through `DYLD_INSERT_LIBRARIES`
([above](#puppet-control)), it redirects scummvm's own imports of
`CGWarpMouseCursorPosition` and `CGDisplayMoveCursorToPoint` — found by name
through its indirect symbol table, as scummvm binds the old way, through lazy
pointers that hold a stub until the first call — and `+[NSEvent
mouseLocation]` for calls from scummvm. SDL reads no event's location
through `CGEventGetLocation`, so puppet control tells it where each event it
posts points instead (`virtualPointerNotePuppetMove`).

It says `second-chance-helper[PuppetControl] notice: the pointer can't be moved
in this login (it stays at 10,10); showing the game one that can` when it acts.
Swapping a new `in_process_helpers.dylib` into a wrapp by hand, remove the old
file first: written over in place, its cached code signature no longer
matches, and dyld kills scummvm, which inserts it, at launch.
