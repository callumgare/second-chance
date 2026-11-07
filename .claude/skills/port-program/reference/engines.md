# Engines: what runs what

Checked 2026-11-04. Second Chance has modules for **wine**, **dosbox** and
**scummvm** (`Modules/`); anything else is a new engine (SKILL.md, "Needs a
new engine").

## Why the order in SKILL.md

1. **ScummVM** first: a reimplementation needs no Windows, no codecs, no
   display-mode tricks and no Rosetta, runs natively on Apple Silicon, and
   plays every platform's data. When it says it supports a game, it's the
   best route even if Wine would also work.
2. **DOSBox** for DOS: native, configurable from a file, starts a program
   from `[autoexec]`.
3. **Wine** for Win32: the most programs, at the most cost — Rosetta, a
   prefix, graphics helpers. Two risks to know about:
   - **Rosetta is going away**: Apple says macOS 27 is the last with full
     Rosetta 2; macOS 28 keeps "a subset … aimed at older unmaintained
     gaming titles". Every x86_64 Wine depends on it.
   - **Win16 doesn't run under Rosetta 2** (LDT; WineHQ bug 59042), so 16-bit
     Windows programs and 16-bit `SETUP.EXE`s fail on Apple Silicon even
     though Wine 11's WoW64 supports them elsewhere.
4. Everything else is an emulator: more to set up, often a ROM or an OS a
   person must supply, but native and future-proof.

## Which engine, by platform

| Platform | First choice | Then | Needs |
| --- | --- | --- | --- |
| Data ScummVM recognises (SCUMM, SCI, Director, Her's engine…) | ScummVM (module) | — | Nothing |
| DOS, DOS extenders | DOSBox (module) | DOSBox-X for odd hardware | Nothing |
| Win32 (Win9x/XP era) | Wine (module) | DOSBox-X/86Box running Windows 9x | A 98 licence for the fallback |
| Win16 (Windows 3.x) | A 32-bit build of the same program, under Wine | DOSBox-X running Windows 3.1 (new engine) | A Windows 3.1 licence and install media |
| Flash projector | Ruffle (new engine), the SWF extracted | Wine | Nothing |
| Classic Mac 68k (System 6–7.6) | Basilisk II (the basilisk module) | Snow (compact Macs), QEMU q800, Mini vMac (System ≤ 7.5.5) | **An Apple ROM** and System software |
| Very early Mac (≤ System 6) | Advanced Mac Substitute / Executor 2000 (no ROM) | Mini vMac | AMS and Executor need nothing, but run few programs |
| Classic Mac PPC (Mac OS 7.5.2–9.0.4) | SheepShaver (new engine) | QEMU mac99 | **The "Mac OS ROM" file** and Mac OS |
| Mac OS 9.1–9.2.2, Mac OS X 10.0–10.5 PPC | QEMU `qemu-system-ppc -M mac99,via=pmu` | — | Mac OS install media; OpenBIOS is built in, no ROM |

A hybrid disc's Windows side under ScummVM or Wine beats its Mac side under
an emulator almost always: no ROM, no OS to install.

## The modules we have

| Module | Engine | Version (Modules/*/module.yaml) | Notes |
| --- | --- | --- | --- |
| wine | Sikarugir's Wine 10 build (x86_64) | `wine@10` | 32-bit programs through WoW64 under Rosetta; cnc-ddraw; `EmulateModeset` on. Direct3D through wined3d over OpenGL 4.1 (DX ≤ 9 is fine; 10/11 limited) |
| dosbox | DOSBox | see module | `LAUNCH C:/…` on DOSBox's C:, `--dosbox.overlay` volumes |
| scummvm | ScummVM 2026.4.0 (2026.3.0 kept for pinning) | see module | Installed with every data file ScummVM has; once the game runs, keep only what it needs with `SCUMMVM.KEEP-DATA <file>…` (`nancy.dat`; a Mac or Director game may need `classicmacfonts.dat`, `macgui.dat`). To see inside a game, its debugger console, driven through `sc puppet` (`reference/troubleshooting.md#scummvm`) |

Run the module's engines by hand for experiments:
`~/Library/Caches/SecondChance/engines/<prepared hash>/MacOS/scummvm`
(the hash is `prepared:` in the module; `./sc engine fetch <module>` if
it's missing), always with `HOME=<scratch dir>` so it neither reads nor
writes the user's settings.

## Emulators for a new engine

| Emulator | Licence | Apple Silicon | Headless set-up | Status |
| --- | --- | --- | --- | --- |
| **Basilisk II** (kanjitalk755/macemu) | GPL-2.0 | Native arm64, no JIT (fast enough for 68k) | `--config <prefs file>` or a VM folder holding `prefs`; keys `rom`, `disk`, `cdrom`, `screen`, `extfs` (a host folder as a volume). A disk listed in prefs boots | Active; builds on E-Maculation's forum |
| **SheepShaver** (same repo) | GPL-2.0 | Native arm64 builds, no JIT (slower); x86_64 under Rosetta has JIT | `~/.sheepshaver_prefs` scheme, same keys | Active. Mac OS ≤ 9.0.4, no 3D |
| **Snow** (twvd/snow) | MIT | Universal | CLI/workspace options to check | v1.6.0 2026-11-01; accurate, newer |
| **QEMU** q800 / mac99 | GPL-2.0 | Native (TCG) | All command line; `brew install qemu` | mac99 needs no ROM |
| **Mini vMac** | GPL-2.0 | x86_64 (Rosetta) | Options compiled in; `disk1.dsk` beside it auto-mounts | Old |
| **DOSBox-X** | GPL-2.0 | Native | `.conf` + `[autoexec]`; can boot Windows 3.1/9x | 2026.10.01; cask disabled (Gatekeeper): use its release zip |
| **DOSBox Staging** | GPL-2.0+ | Native, dynrec | `-conf` file, `-c … -exit` | 0.83.0; the better DOS default if the dosbox module ever changes |
| **86Box** | GPL-2.0 | Universal | A machine folder with `86box.cfg`; ROM set separate | Faithful, heavy |
| **Ruffle** | MIT/Apache | Native | `ruffle <swf>` | AS1/2 good, AS3 partial |

### ROMs and system software

The blocker for classic Mac emulation. Apple never licensed its ROMs or
older system software for redistribution (System 7.5.3 was once a free
download from Apple, but isn't licensed to be bundled). A module can't ship
them; a person would have to give their own, so the proposal must say how
the app asks for and checks them (a ROM's checksum identifies its model).
That's why a Windows or ScummVM route on a hybrid disc wins when it works.

The basilisk module settles this for 68k programs (docs/modules.md, "The
basilisk module's Mac"): System 7.5.3 is fetched by each Mac from archive.org
as part of the engine, and the ROM is the person's, asked for once and kept
(a Debug build downloads a development copy). A Quadra 650/800 ROM
(`F1ACAD13`) is the one it knows.

## Wine's renderers and helpers (for when wine is the route)

- **cnc-ddraw** (DirectDraw 1–7): what the wine module uses for DirectDraw
  games (`DO wine.cnc-ddraw`; `docs/wine-in-process-helpers.md`).
- **wined3d** (built in): Direct3D 1–9 over OpenGL 4.1. The default.
- **DXMT / D3DMetal / DXVK+MoltenVK**: D3D10–12; not in the wine module,
  and D3DMetal can't be redistributed. A program that needs them is out of
  reach for now: say so.
- **dgVoodoo2** needs D3D11 underneath: not a Mac route.
- **Glide** games need a Glide wrapper (nGlide/dgVoodoo): usually not a
  Mac route; look for a D3D or software renderer option in the game.
