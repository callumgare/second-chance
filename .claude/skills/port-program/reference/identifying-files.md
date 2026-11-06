# Identifying what you've been given

Checked 2026-11-04. Start with `scripts/identify.py` (it reads, never runs);
this file is what to do with what it tells you, and the tools for the rest.

## Tools

What's installed on this Mac changes; `command -v <tool>` before relying on
one, and `brew install <formula>` what's missing (formulae are fine; since
2026-09-01 Homebrew disables *casks* that fail Gatekeeper, so apps such as
`wine-stable` or `dosbox-x-app` come from their GitHub releases instead).

| Tool | For | Install | Notes |
| --- | --- | --- | --- |
| `file` | First look: MZ/NE/PE/LE, ISO, HFS, StuffIt | built in | Weak on installer families |
| `identify.py` | All of the below in one report | `scripts/` | Add tells it misses |
| `7z`/`7zz` | ISO, UDF, CAB, MSI, NSIS, APM, DMG, HFS+, zip, rar, most SFX | `brew install sevenzip` | Not plain HFS. "data after the end of archive" on a hybrid disc is the HFS side |
| `innoextract` | Inno Setup (incl. GOG) | `brew install innoextract` | Inno ≤ 6.2.2; newer may fail |
| `unshield` | InstallShield 5–12 (`data1.cab` + `data1.hdr`) | `brew install unshield` | Not IS3 (`_SETUP.LIB`, `DATA.Z`) |
| `deark` | IS3 `DATA.Z` (`-m is_z`), PKLITE/LZEXE, MacBinary, BinHex, StuffIt, HFS (experimental), resource files | `brew install deark` | Many odd retro formats |
| `cabextract` | Microsoft CAB (Win9x, DirectX redists) | `brew install cabextract` | Not InstallShield cabs |
| `msitools` | `msiinfo suminfo`, `msiinfo tables/export`, `msiextract` | `brew install msitools` | Custom actions don't run |
| `unar`/`lsar` | StuffIt, Compact Pro, BinHex, MacBinary, AppleSingle, NSIS, LZH, ARJ | `brew install unar` | Keeps resource forks; no HFS images |
| `hfsutils` (`hmount`, `hls`, `hcopy`) | Plain HFS volumes, partitioned and hybrid discs, without mounting | `brew install hfsutils` | See below |
| `resource_dasm` | Resource forks, MacBinary/AppleSingle, 68k/PPC disassembly | build from github.com/fuzziqersoftware/resource_dasm | Best for 68k vs PPC questions |
| `DeRez` | Dump a resource fork (`DeRez -only cfrg App`) | built in (Xcode CLT) | Needs the fork on APFS/HFS+ or `..namedfork/rsrc` |
| `llvm-objdump -p` | PE imports | `brew install llvm` | PE only |
| `rabin2` | Imports, sections, NE/LE info | `brew install radare2` | |
| Detect It Easy (`diec`) | Packers, compilers, installer families, protection | `.pkg` from github.com/horsicq/DIE-engine releases | Best general detector |
| ProtectionScan | Copy protection in files *and disc images* | github.com/SabreTools/BinaryObjectScanner releases (osx-arm64) | MIT |
| `binwalk` | Archives buried in a blob (a stub + a CAB) | `brew install binwalk` | Noisy |
| `upx -d` | Unpack a UPX-packed exe to read its imports | `brew install upx` | UPX doesn't need unpacking to run |

## Executables: what kind

`MZ` at the start, then the 4 bytes at the offset stored at 0x3C:

| Header | Is | Route |
| --- | --- | --- |
| none | DOS | DOSBox. Strings `DOS/4G`, `PMODE/W`, `DOS32A`, `CWSDPMI`, `Phar Lap` mean a DOS extender — still DOSBox |
| `NE` | 16-bit Windows 3.x (or OS/2 1.x) | **Blocked on Apple Silicon**: Rosetta 2 refuses the LDT call Win16 needs (WineHQ bug 59042). Look for a 32-bit build of the same program first; otherwise DOSBox-X with Windows 3.1 (needs a Windows licence), which is a new engine |
| `LE`/`LX` | A DOS extender program (DOS/4GW) or a VxD/OS/2 program | DOSBox for a game |
| `PE\0\0` | Win32 (machine 0x14c) or Win64 (0x8664) | Wine. The imports say what it draws with: `ddraw` → DirectDraw (cnc-ddraw), `d3d8`/`d3d9` → Direct3D, `d3drm` → Retained Mode, `glide*` → Glide, `opengl32`, neither → GDI |

An exe importing **both** `ddraw.dll` and `d3d8`/`d3d9` usually draws with
Direct3D and uses DirectDraw only to list display modes (every Game Maker 7/8
game: Iji). Say `--wine.graphics=direct-3d` in its `LAUNCH`, and leave out
cnc-ddraw. Second Chance's own reading (`GameGraphicsAPI`) takes any
`ddraw.dll` import as DirectDraw, which is why the launch must say it.

A PE with almost no imports and `UPX0`/`UPX1` or odd sections is packed:
`upx -d` a copy to read its real imports. Armadillo hides its imports too
(the Big Fish games); the catalog then says what the game draws with.

## Installers

| Family | Tells | Unpack without running |
| --- | --- | --- |
| InstallShield 3 (often 16-bit) | `SETUP.EXE` + `_SETUP.LIB`, `_INST32I.EX_`, `_ISDEL.EXE`, `DATA.Z` | `deark -m is_z DATA.Z`; its 16-bit `SETUP.EXE` won't run under Rosetta |
| InstallShield 5–12 | `data1.cab` + `data1.hdr`, `ikernel.ex_`, `_setup.dll`, `layout.bin` | `unshield -d <out> x data1.cab` |
| InstallShield + MSI | `setup.exe` + `.msi` (+ `ISSetup.dll`) | `msiextract`, `7z x` |
| Wise | "WiseMain", "Wise Installation" | Run under Wine with `/s` |
| NSIS | "Nullsoft Install System" | `7z x` |
| Inno Setup | "Inno Setup Setup Data" | `innoextract` |
| MSI | OLE header `D0 CF 11 E0` | `msiinfo suminfo`, `msiextract` |
| CAB | `MSCF` | `cabextract` |
| A small `kernel32`+`user32`-only exe with a big overlay | A custom or obscure SFX/installer stub | `binwalk`, `7z l`, or run it under Wine and see what it writes |

Unpacking tells you what an installer installs and lets you check a
program runs before working on its installer. A bundle should still run the
real installer where it can (registry entries, fonts, shared DLLs it
registers), unless the program is known to need none of that.

## Copy protection

| Protection | Tells | Under Wine |
| --- | --- | --- |
| SafeDisc 1–4 | `00000001.TMP`, `CLCD16.DLL`, `CLCD32.DLL`, `CLOKSPL.EXE`, `DPLAYERX.DLL`, a `.ICD`, `secdrv.sys` | Fails: the driver can't load. Needs an unprotected edition (GOG/Steam) or the publisher's no-CD patch |
| SecuROM ≤ 7 | `CMS16.DLL`, `CMS_95.DLL`, `CMS32_95.DLL`; `.cms_t`/`.cms_d`/`.securom` sections | Fails, as above |
| StarForce | `protect.dll`, `protect.exe`, `sfdrv01.sys` | Fails |
| LaserLock | `LASERLOK` folder | Usually fails |
| A plain disc check | Looks for a volume label or a file on a CD-ROM drive | Fixable: the disc copied in as a CD-ROM drive with its label (`WINE.MOUNT --cdrom`, `WINE.KEEP-DISCS`) |

## Discs and classic Mac formats

- **macOS can't mount plain HFS** (gone since 10.15). Read it with
  hfsutils: `hmount <image> <n>` — `<n>` counts *HFS partitions*, starting
  at 1, not the partition map's entries (identify.py's numbers are the
  map's) — then `hls -laR`, `hcopy -m <mac path> <dest>` (MacBinary,
  keeping the resource fork) or `hcopy -r` (raw data fork), `humount`.
  Mac paths use `:` (`:Media:Ingenious`).
- **A hybrid disc** has an ISO 9660 side (`7z x` gets it; macOS mounts it)
  and an HFS side behind an Apple partition map. They're often the same
  program for Windows and Mac, sharing data files — each a route.
- **`hls -la` shows type/creator codes**: `APPL/xxxx` is an application;
  the creator says who made it. Common ones: `PJ93`/`PJ95`/`PJ97` Director
  3/5/6-7 projectors and `MD93`/`MD95` (`M!95`, `M*95` protected/compressed
  casts) their movies; `BINA/mdos` a DOS/Windows file on a Mac disc;
  `adrp` an alias.
- **68k, PPC or fat**: `CODE` resources and no `cfrg` → 68k; `cfrg` and a
  data fork starting `Joy!peff` → PowerPC; both → fat. Mach-O `ppc` in an
  `.app` → Mac OS X PPC (needs Mac OS X under QEMU). A `SIZE` resource
  gives its memory needs.
- **DiskCopy 4.2** (`.image`, `.dsk`): an 84-byte header then raw HFS
  (`dd bs=84 skip=1`); emulators read it directly.
- **For ScummVM, Mac files keep their resource forks**: ScummVM reads
  MacBinary, and its `devtools/dumper-companion.py` (`pip install machfs`)
  dumps a whole HFS disc into the form it expects (`dumper-companion.py iso
  <image> <out>`), punycoding names a Mac allowed and other systems don't.
  Copying only data forks loses what Mac Director titles need.

## What the program is made with

Often matters more than the platform: an engine reimplementation may run
the data on any platform's release.

| Tells | Made with | Look at |
| --- | --- | --- |
| `.dir`, `.dxr`, `.cst`, `.cxt`; a projector exe; `LINGO.INI`; `Xtras/` | Macromedia Director | ScummVM's director engine (`scummvm --detect`) |
| `RIFX`/`XFIR` at a file's start | A Director movie | as above |
| `000.LFL`, `*.LA0` | SCUMM | ScummVM |
| `RESOURCE.MAP`, `RESOURCE.000` | Sierra SCI | ScummVM |
| `.ciftree`, `.cif`, `.his` | Her Interactive's engine | ScummVM `nancy` |
| `.smk` / `.bik` | Smacker / Bink video | Ships its own DLL; no codec needed |
| `FWS`/`CWS` | Flash | Ruffle |
| `msvbvm*.dll`, `vb40032.dll` | Visual Basic | winetricks `vb*run` |
| `mfc4*.dll` | MFC | winetricks `mfc42` |
