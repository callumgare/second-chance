# Wine versions

Which Wine each program runs on, how to move one to another, and the faults
we've met in Wine along the way, with the versions each affects and the
first that fixes it. Read it before moving a program, or the Nancy Drew games
as a whole, to a newer Wine. How Wine is fetched, prepared and patched is
[modules.md](modules.md#engine-packages); how a Wine program is started is
[wrapp-build.md](wrapp-build.md#running-wine).

## What we have

The wine module (`Modules/wine/module.yaml`) offers three versions, each
fetched from its maker and prepared on the Mac that builds:

| Version | What it is | Used by |
| ------- | ---------- | ------- |
| `10.0_8` | Sikarugir's Wine 10.0 (CrossOver-family, msync) | The Nancy Drew games Wine runs, from every source (Big Fish's module is `wine@10`); Bioscopia, Webmaster, Icy Tower, Iji |
| `11.0_1` | WineHQ's stable 11.0, as Gcenx builds it for macOS | Nothing yet |
| `11.21` | WineHQ's development 11.21, as Gcenx builds it | SkiFree, Laser Tank |

A bundle names the Wine it wants in its `FROM --module=wine@<version>
prefix`; a module built on Wine names it the same way (`depends-on`, and its
own stages' `FROM`), so Big Fish's games take the Big Fish module's Wine, not
their bundle's. A wrapp keeps the Wine it was built with, until it's updated.

## Moving a program to another Wine

1. Check the table below for faults the program is known to hit, and the
   Wine that fixes or brings each.
2. Change its `FROM` (or the module's), raise a module's `release:` if it's a
   module's, and run its integration test on the new Wine: for a whole
   source, every game it builds (`sc test integration --source <source>`).
   A fault that's random (the WMI deadlock below hit one launch in five)
   needs many launches before it can be called gone.
3. A program that breaks stays where it was, pinned with a comment saying
   why and what would let it move.
4. Patches a Wrappfile applies (`WINE.PATCH`) each say which Wine they were
   made for, and fail on one whose code they don't recognise
   ([modules.md](modules.md#the-wine-modules-patches)). An update that moves a
   wrapp to another Wine (the wine module's `stages/update`) lays the new Wine
   in without them.

## Known faults

| Fault | Affects | Fixed in | What we do |
| ----- | ------- | -------- | ---------- |
| [WMI deadlock](#wmi-deadlock) | 9.3 to 10.4, our 10.0_8 | 10.5 (11.0 stable) | Nothing yet: Big Fish trials hang at random |
| [Big Fish's programs crash](#big-fishs-programs-crash-on-wine-11) | 11.21 (11.0 not tried) | Not fixed | Big Fish stays on 10.0_8 |
| [Iji crashes at start](#iji-crashes-on-wine-11) | 11.6 onwards | Not fixed | Iji stays on 10.0_8 |
| [DirectMusic's slow stop](#directmusics-slow-stop) | 10.0 | 11.2 | `WINE.PATCH skip-synth-playout` (Iji) |
| [Allegro's exit hang](#allegros-exit-hang) | Every Wine so far | Not fixed | `WINE.PATCH keep-thread-handles` (Icy Tower) |
| [Steam's bootstrapper](#steams-bootstrapper) | Kegworks' Wine 9 (CX24) | 10.0_8 | Steam runs on 10.0_8 |
| [Armadillo under Rosetta](#armadillo-under-rosetta) | Every Wine (Rosetta's) | Not Wine's to fix | The prepared 32-bit `ntdll` is patched |
| [Direct3D not scaled](#direct3d-not-scaled-in-an-emulated-mode) | 10's Mac driver | Not checked | The wrapp's mode scaling helper |
| [Cocoa's 5 s start](#cocoas-5-s-start) | Every Wine | Not fixed | The Cocoa start wait helper |

### WMI deadlock

Wine's WMI (`dlls/wbemprox`) gave each table a lock in 9.3 ("wbemprox:
Protect tables with a critical section") and held it from `grab_table` to
`release_table`: for as long as a query's results were open, not just while
they were filled in. Two threads of one program querying the same class
could then deadlock, where Windows never blocks. Wine 10.5 took the lock away
("wbemprox: Get rid of the per-table lock", b93bee1a, [Wine bug
56859](https://bugs.winehq.org/show_bug.cgi?id=56859), an installer that
hung the same way).

Big Fish's DRM did it while starting a free trial, on about one launch in
five (2026-11-13 and -14). Its sign: Wine CPU drops to nothing a minute or
so in, and the log has

```text
err:sync:RtlpWaitForCriticalSection section … "…/dlls/wbemprox/builtin.c: table.cs" wait timed out in thread …, blocked by …
```

after which the DRM's launcher and `gmActivator` exit without starting the
game, leaving the Game Manager waiting. A bought game's launch, which has no
`gmActivator`, hasn't been seen to hit it.

### Big Fish's programs crash on Wine 11

Tried 2026-11-14 with the Big Fish module on 11.21: the Game Manager
(`bfgclient.exe`, a Chromium app) crashed seconds after it started, every
time, with

```text
err:seh:call_seh_handlers invalid frame 0000000004E5F484 (0000000103292000-000000010338FD20)
err:seh:NtRaiseException Exception frame is not in stack limits => unable to dispatch exception.
```

just after its GPU set-up failed: Wine checked a 32-bit stack frame against
the 64-bit stack's limits. Starting it with `--disable-gpu
--disable-gpu-compositing` got its page up, but the DRM it started then
crashed the same way, and with `virtual_setup_exception stack overflow …
addr 0x7bf9e9ea`, in ntdll's own range. The Rosetta patch to the 32-bit
`ntdll` was in place, as on 10.0_8. Not yet known: whether 11.0 behaves the
same, which change in 11 brought it, and whether the patch's hand-over to
Wine's dispatcher (`NtContinue`) is part of it. Moving Big Fish to Wine 11
would fix the WMI deadlock, so it starts there.

### Iji crashes on Wine 11

Every Wine 11 from 11.6 crashes Iji at start, with a stack overflow in its
exception handlers; 11.0 runs it, but loads it for minutes (the slow stop
below). So Iji stays on 10.0_8 with the patch
([modules.md](modules.md#the-wine-modules-patches)).

### DirectMusic's slow stop

Wine 10's synthesiser sink (`dlls/dmsynth/synthsink.c`) waits, as it stops,
until everything written has played, about 1.5 s each time; a Game Maker 7
game stops one per sound, and Iji sat on its loading screen for six minutes.
Wine 11.2 rewrote the sink to wait only for its write latency. Until a
program that needs it can move, `skip-synth-playout`
([modules.md](modules.md#the-wine-modules-patches)).

### Allegro's exit hang

Not a fault of one version: Allegro 4 waits on a thread handle that msvcrt's
`_endthread` has already closed, as on Windows, and on Wine the freed value
can be handed to something else first, so the game hangs as it exits (Icy
Tower, about 3 exits in 11 on macOS 26). `keep-thread-handles`
([modules.md](modules.md#the-wine-modules-patches)) keeps the handle open.
A Wine update of the wrapp drops the patch.

### Steam's bootstrapper

On Kegworks' Wine 9 (`WS12WineCX24.0.7`, what wrapps had before 10.0_8),
Steam's 32-bit bootstrapper exited during its first update. On 10.0_8 it
updates to the 64-bit client and signs in ([steam.md](steam.md)).

### Armadillo under Rosetta

Rosetta 2, not Wine: it faults on an `fs:` access with the `0x67` prefix,
and Wine on macOS runs 32-bit code in a segment Armadillo takes for Windows
9x. The patch to the prepared 32-bit `ntdll` deals with both, on every Wine
version the module prepares; it refuses an `ntdll` whose exception
dispatcher starts otherwise, so a Wine that changes it fails to prepare
rather than shipping unpatched
([big-fish.md](big-fish.md#armadillo-under-rosetta)).

### Direct3D not scaled in an emulated mode

With `EmulateModeset` on (a 4:3 mode on a display that lacks it), Wine 10's
Mac driver scales a program's windows but not what Direct3D draws in them.
The wrapp's mode scaling helper does
([wine-in-process-helpers.md](wine-in-process-helpers.md#mode-scaling)).
Not checked on Wine 11.

### Cocoa's 5 s start

Wine gives a program's main thread 5 s to start Cocoa, which a fully loaded
Mac runs out, leaving the program with no display driver for good. The Cocoa
start wait helper lets it wait longer
([wine-in-process-helpers.md](wine-in-process-helpers.md#cocoa-start-wait)).
