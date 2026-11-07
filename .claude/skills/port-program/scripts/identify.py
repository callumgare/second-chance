#!/usr/bin/env python3
"""Say what a program, installer, archive or disc image is, and what to run next.

  identify.py <file or folder>…        a report for each
  identify.py --json <file>            the same, as JSON

For a file: its size and sha256, `file`'s view, then what its bytes say:

  - an MZ executable: DOS, a DOS extender (LE/LX: DOS/4GW, PMODE…), 16-bit Windows
    (NE) or 32/64-bit Windows (PE), with a PE's machine, subsystem, the DLLs it
    imports (and so what it draws and plays sound with), its version strings,
    and the installer or packer it is (Inno, NSIS, InstallShield, Wise, MSI
    wrapper, 7-Zip SFX, WinZip SFX, Setup Factory…), and copy protection markers
    (SafeDisc, SecuROM, StarForce, Armadillo, Themida, ASProtect, UPX…);
  - a disc image: ISO 9660 (with its volume name, and Joliet), an Apple
    partition map, HFS or HFS+ volumes (a classic Mac or hybrid disc), UDF;
  - classic Mac formats: MacBinary, BinHex, StuffIt, Disk Copy 4.2, a resource
    fork, a 68k or PowerPC application;
  - archives and other containers: zip, 7z, rar, cab, MSI/OLE, InstallShield cab.

For a folder: the files that matter (setups, executables, autorun.inf,
InstallShield's data1.hdr, .msi, …), each identified.

Only the standard library; run with python3 -I. It reads files, never runs them.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

READ = 8 * 1024 * 1024  # how much of a big file to scan for markers

INSTALLERS = [
    (rb"Inno Setup Setup Data", "Inno Setup", "innoextract -l <file>; innoextract -e -d <out> <file> (brew install innoextract)"),
    (rb"Inno Setup", "Inno Setup (probably)", "innoextract -l <file>"),
    (rb"Nullsoft Install System|NullsoftInst", "NSIS", "7z x <file> -o<out> (7-Zip unpacks most NSIS installers)"),
    (rb"InstallShield", "InstallShield", "Look for data1.hdr/data1.cab beside it or inside it (7z x); unshield -d <out> x data1.cab. 16-bit IS3 setups need _setup.lib/_inst32i.ex_ handling"),
    (rb"Wise Installation|WISE_SETUP|WiseMain", "Wise Installer", "Run under Wine with /s; or extract with E_WISE / wunpack"),
    (rb"7zS.sfx|7-Zip SFX|;!@Install@!UTF-8!", "7-Zip self-extractor", "7z x <file> -o<out>"),
    (rb"WinZip Self-Extractor|WinZip\(R\) Self-Extractor", "WinZip self-extractor", "unzip <file> or 7z x <file>"),
    (rb"Setup Factory", "Setup Factory", "Run under Wine (silent: /S); 7z sometimes lists it"),
    (rb"Smart Install Maker", "Smart Install Maker", "Run under Wine"),
    (rb"Ghost Installer", "Ghost Installer", "Run under Wine"),
    (rb"Clickteam Install Creator|Install Creator", "Clickteam Install Creator", "Run under Wine"),
    (rb"InstallAware", "InstallAware", "Run under Wine; /s"),
    (rb"(?i)gentee installer|ginstall\.dll", "Gentee/CreateInstall", "Run under Wine (CreateInstall: /S may be silent; unverified)"),
    (rb"msiexec|\.msi\x00", "MSI bootstrapper (maybe)", "Look for a .msi beside or inside it (7z x)"),
    (rb"Rar!\x1a\x07", "RAR self-extractor", "7z x <file> or unar <file>"),
]

PROTECTION = [
    (rb"BoG_ \*90\.0&!!  Yy>|\.icd\x00|SafeDisc|stxt774|stxt371", "SafeDisc"),
    (rb"\.securom|SecuROM|\.cms_t|\.cms_d", "SecuROM"),
    (rb"StarForce|protect\.dll|\.sforce", "StarForce"),
    (rb"Armadillo|\.pdata\x00\x00\x00\x00ArmAccess", "Armadillo"),
    (rb"\.themida|Themida|WinLicense", "Themida/WinLicense"),
    (rb"\.aspack|ASPack", "ASPack"),
    (rb"ASProtect|\.aspr", "ASProtect"),
    (rb"UPX0\x00|UPX!", "UPX (packed; `upx -d` unpacks)"),
    (rb"LaserLok|LaserLock", "LaserLock"),
    (rb"CD-Cops|CDCOPS", "CD-Cops"),
    (rb"\.ldr\x00|tages", "TAGES (maybe)"),
    (rb"PECompact|PEC2", "PECompact"),
    (rb"GameGuard", "GameGuard"),
]

DOS_EXTENDERS = [
    (rb"DOS/4G", "DOS/4GW"), (rb"PMODE/W", "PMODE/W"), (rb"CWSDPMI|go32", "DJGPP (CWSDPMI)"),
    (rb"DOS32A|DOS/32A", "DOS/32A"), (rb"Phar Lap|TNT DOS-Extender", "Phar Lap"), (rb"WDOSX", "WDOSX"),
    (rb"Causeway", "CauseWay"), (rb"EOS ", "EOS (maybe)"), (rb"Rational Systems", "DOS/16M"),
]

# What a Windows program's imports say about it.
IMPORT_HINTS = {
    "ddraw.dll": "DirectDraw (Second Chance: --wine.graphics=direct-draw; cnc-ddraw)",
    "d3d8.dll": "Direct3D 8 (--wine.graphics=direct-3d)",
    "d3d9.dll": "Direct3D 9 (--wine.graphics=direct-3d)",
    "d3dim.dll": "Direct3D immediate mode (DX5-7)",
    "d3d11.dll": "Direct3D 11 (needs a modern Wine/D3DMetal path; out of reach of OpenGL wined3d on macOS?)",
    "d3d10.dll": "Direct3D 10", "d3d12.dll": "Direct3D 12 (D3DMetal/GPTK only)",
    "opengl32.dll": "OpenGL", "glide2x.dll": "3dfx Glide (needs a Glide wrapper: nGlide/dgVoodoo)",
    "glide3x.dll": "3dfx Glide", "dinput.dll": "DirectInput", "dinput8.dll": "DirectInput 8",
    "dsound.dll": "DirectSound", "dplayx.dll": "DirectPlay (winetricks directplay)",
    "dmusic.dll": "DirectMusic", "winmm.dll": "WinMM (MCI: CD audio, MIDI, AVI)",
    "quartz.dll": "DirectShow (videos: winetricks quartz/lavfilters?)",
    "msvfw32.dll": "Video for Windows (AVI; Indeo/Cinepak codecs?)",
    "qtmlclient.dll": "QuickTime for Windows", "smackw32.dll": "Smacker video", "binkw32.dll": "Bink video",
    "mss32.dll": "Miles Sound System", "ir50_32.dll": "Indeo 5",
    "mfc42.dll": "MFC 4.2 (winetricks mfc42)", "msvbvm60.dll": "Visual Basic 6 runtime (winetricks vb6run)",
    "vb40032.dll": "Visual Basic 4 runtime", "msvbvm50.dll": "Visual Basic 5 runtime (vb5run)",
    "msvcp60.dll": "MSVC 6 C++", "mscoree.dll": ".NET (winetricks dotnet*; or Wine Mono)",
    "director": "Macromedia Director", "dirapi.dll": "Macromedia Director (ScummVM's director engine may run it)",
    "iml32.dll": "Director projector", "proj.dll": "Director projector",
    "flash.ocx": "Flash ActiveX", "steam_api.dll": "Steamworks", "gdi32.dll": "GDI",
}

# A Director projector's Xtras (.x32 in its Xtras folder) that need something
# installed beside it under Wine. ScummVM needs none of them.
DIRECTOR_XTRAS = {
    "qt3asset.x32": "QuickTime for Windows 3+ installed (QT3Asset; the game may check quickTimeVersion()): "
                    "prefer the disc's own QuickTime installer; Apple's 7.6 (winetricks quicktime76) fails to "
                    "initialise under Wine 10 (Bioscopia, 2026-11)",
}

PE_MACHINES = {0x14C: "i386 (32-bit)", 0x8664: "x86-64 (64-bit)", 0x1C0: "ARM", 0xAA64: "ARM64", 0x200: "Itanium"}
PE_SUBSYSTEMS = {1: "native", 2: "Windows GUI", 3: "Windows console", 5: "OS/2", 7: "POSIX", 9: "Windows CE"}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_cmd(path: Path) -> str:
    try:
        return subprocess.run(["file", "-b", str(path)], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return "?"


def utf16_strings(data: bytes, keys: list[str]) -> dict:
    """Version-info strings, found as UTF-16LE key\\0\\0value."""
    out = {}
    for k in keys:
        m = re.search(k.encode("utf-16-le") + rb"\x00\x00(?:\x00\x00)?((?:[^\x00]\x00){1,120})", data)
        if m:
            out[k] = m.group(1).decode("utf-16-le", "replace").strip()
    return out


def pe_info(data: bytes, pe: int) -> dict:
    info: dict = {}
    machine, nsec, _, _, _, optsize, chars = struct.unpack_from("<HHIIIHH", data, pe + 4)
    info["machine"] = PE_MACHINES.get(machine, hex(machine))
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    is64 = magic == 0x20B
    info["subsystem"] = PE_SUBSYSTEMS.get(struct.unpack_from("<H", data, opt + 68)[0], "?")
    info["dll"] = bool(chars & 0x2000)
    sections = []
    sec = opt + optsize
    for i in range(nsec):
        name, vsize, va, rsize, rptr = struct.unpack_from("<8sIIII", data, sec + i * 40)
        sections.append((name.rstrip(b"\x00").decode("latin-1"), va, vsize, rptr, rsize))
    info["sections"] = [s[0] for s in sections]

    def rva(r: int) -> int | None:
        for _, va, vsize, rptr, rsize in sections:
            if va <= r < va + max(vsize, rsize):
                return r - va + rptr
        return None

    dd = opt + (112 if is64 else 96)
    imp_rva = struct.unpack_from("<I", data, dd + 8)[0]
    dlls = []
    off = rva(imp_rva) if imp_rva else None
    while off is not None and off + 20 <= len(data):
        name_rva = struct.unpack_from("<I", data, off + 12)[0]
        if name_rva == 0:
            break
        n = rva(name_rva)
        if n is None or n >= len(data):
            break
        dlls.append(data[n:data.index(b"\x00", n)].decode("latin-1").lower())
        off += 20
        if len(dlls) > 200:
            break
    info["imports"] = dlls
    info["import hints"] = sorted({IMPORT_HINTS[d] for d in dlls if d in IMPORT_HINTS})
    if "ddraw.dll" in dlls and {"d3d8.dll", "d3d9.dll"} & set(dlls):
        info["graphics"] = ("imports DirectDraw and Direct3D: it draws with Direct3D (DirectDraw for display modes, "
                            "as Game Maker 7/8 games do) unless shown otherwise — --wine.graphics=direct-3d, no cnc-ddraw. "
                            "Second Chance's own reading of the exe (GameGraphicsAPI) would say direct-draw, so the launch must say it")
    if not dlls and len(sections) <= 3:
        info["note"] = "few or no imports: packed or protected (its real imports are hidden)"
    return info


def mz_info(data: bytes) -> dict:
    info: dict = {}
    lfanew = struct.unpack_from("<I", data, 0x3C)[0] if len(data) > 0x40 else 0
    sig = data[lfanew:lfanew + 4] if 0 < lfanew < len(data) - 4 else b""
    if sig == b"PE\x00\x00":
        info["kind"] = "Windows PE"
        try:
            info.update(pe_info(data, lfanew))
        except (struct.error, ValueError, IndexError) as e:
            info["pe error"] = str(e)
    elif sig[:2] == b"NE":
        info["kind"] = "16-bit Windows (NE): Win 3.x — Wine runs Win16 only in a 32-bit-capable (WoW64) Wine; check it does"
        target = data[lfanew + 0x36] if lfanew + 0x36 < len(data) else 0
        info["ne target os"] = {1: "OS/2", 2: "Windows", 3: "European DOS 4", 4: "Windows 386"}.get(target, target)
    elif sig[:2] in (b"LE", b"LX"):
        info["kind"] = f"{sig[:2].decode()} executable: a DOS extender program (DOS/4GW…) or a VxD/OS/2 program — DOSBox"
    else:
        info["kind"] = "DOS (MZ) program — DOSBox"
    ext = [n for pat, n in DOS_EXTENDERS if re.search(pat, data)]
    if ext:
        info["dos extender"] = ext
    return info


def iso_info(f, size: int) -> dict:
    info: dict = {}
    f.seek(0)
    head = f.read(0x10000)
    if head[0:2] == b"ER" or head[0x200:0x202] == b"PM":
        info["apple partition map"] = True
        parts = []
        blk = struct.unpack_from(">H", head, 2)[0] or 512
        for i in range(1, 64):
            o = i * blk
            if head[o:o + 2] != b"PM":
                break
            start, count = struct.unpack_from(">II", head, o + 8)
            name = head[o + 16:o + 48].split(b"\x00")[0].decode("mac_roman")
            ptype = head[o + 48:o + 80].split(b"\x00")[0].decode("mac_roman")
            parts.append({"n": i, "name": name, "type": ptype, "start": start * blk, "bytes": count * blk})
        info["partitions"] = parts
        for p in parts:
            if p["type"] == "Apple_HFS":
                f.seek(p["start"] + 1024)
                mdb = f.read(512)
                info.setdefault("hfs volumes", []).append(hfs_mdb(mdb) | {"partition": p["n"]})
    f.seek(1024)
    mdb = f.read(512)
    if mdb[:2] in (b"BD", b"H+", b"HX"):
        info.setdefault("hfs volumes", []).append(hfs_mdb(mdb) | {"partition": 0})
    f.seek(0x8000)
    vd = f.read(0x800 * 8)
    if vd[1:6] == b"CD001":
        info["iso9660 volume"] = vd[40:72].decode("latin-1").strip()
        info["iso9660 created"] = vd[813:829].decode("latin-1")
        for i in range(8):
            d = vd[i * 0x800:(i + 1) * 0x800]
            if d[0] == 2 and d[88:91] in (b"%/@", b"%/C", b"%/E"):
                info["joliet"] = True
    if b"NSR02" in vd or b"NSR03" in vd or b"BEA01" in vd:
        info["udf"] = True
    if "hfs volumes" in info and "iso9660 volume" in info:
        info["note"] = "hybrid disc: a Windows (ISO 9660) side and a classic Mac (HFS) side — each may hold a different program"
    if "hfs volumes" in info:
        info["hfs tools"] = ("macOS can't mount HFS (standard) since 10.15: use hfsutils (hmount <img> <partition>; hls -laR; "
                             "hcopy -m for MacBinary keeping resource forks), or `hfs` from the machfs python package")
    return info


def hfs_mdb(mdb: bytes) -> dict:
    if mdb[:2] == b"BD":
        n = mdb[36]
        return {"fs": "HFS (classic Mac OS)", "name": mdb[37:37 + n].decode("mac_roman")}
    return {"fs": "HFS+" if mdb[:2] == b"H+" else "HFSX"}


def mac_info(path: Path, data: bytes) -> dict:
    info: dict = {}
    if len(data) > 128 and data[0] == 0 and 1 <= data[1] <= 63 and data[74] == 0 and data[82] == 0:
        n = data[1]
        info["macbinary"] = {"name": data[2:2 + n].decode("mac_roman", "replace"),
                             "type": data[65:69].decode("mac_roman", "replace"),
                             "creator": data[69:73].decode("mac_roman", "replace"),
                             "data fork": struct.unpack_from(">I", data, 83)[0],
                             "resource fork": struct.unpack_from(">I", data, 87)[0]}
    if data.startswith(b"(This file must be converted with BinHex"):
        info["binhex"] = "BinHex 4.0: unar / lsar"
    if data[:4] in (b"SIT!", b"StuffIt") or data[:8] == b"StuffIt " or b"StuffIt (c)1997" in data[:200]:
        info["stuffit"] = "StuffIt archive: unar / lsar (brew install unar)"
    if len(data) > 84 and data[82:84] == b"\x01\x00" and data[0] < 64:
        info["diskcopy 4.2"] = f"maybe a Disk Copy 4.2 image named {data[1:1 + data[0]].decode('mac_roman', 'replace')!r}"
    rsrc = Path(str(path) + "/..namedfork/rsrc")
    try:
        r = rsrc.read_bytes() if rsrc.exists() else b""
    except OSError:
        r = b""
    if r:
        info["resource fork bytes"] = len(r)
        types = resource_types(r)
        if types:
            info["resource types"] = types
            if "cfrg" in types and "CODE" in types:
                info["mac app"] = "fat: 68k and PowerPC"
            elif "cfrg" in types:
                info["mac app"] = "PowerPC (SheepShaver/QEMU with Mac OS 8.6-9)"
            elif "CODE" in types:
                info["mac app"] = "68k (Basilisk II, or Mini vMac for System 6/7 era)"
    try:
        fi = subprocess.run(["xattr", "-px", "com.apple.FinderInfo", str(path)], capture_output=True, text=True).stdout
        raw = bytes.fromhex(fi.replace(" ", "").replace("\n", ""))
        if raw[:8].strip(b"\x00"):
            info["finder type/creator"] = f"{raw[0:4].decode('mac_roman')}/{raw[4:8].decode('mac_roman')}"
    except (OSError, ValueError):
        pass
    return info


def resource_types(r: bytes) -> list[str]:
    try:
        _, map_off, _, _ = struct.unpack_from(">IIII", r, 0)
        tlist = map_off + struct.unpack_from(">H", r, map_off + 24)[0]
        n = struct.unpack_from(">H", r, tlist)[0] + 1
        return [r[tlist + 2 + i * 8:tlist + 6 + i * 8].decode("mac_roman") for i in range(n)]
    except (struct.error, IndexError):
        return []


def container(data: bytes) -> str | None:
    sigs = [(b"PK\x03\x04", "zip"), (b"7z\xbc\xaf\x27\x1c", "7z"), (b"Rar!\x1a\x07", "rar"), (b"MSCF", "Microsoft CAB (cabextract)"),
            (b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1", "OLE compound file: an MSI (msiinfo suminfo / msiextract) or other OLE doc"),
            (b"ISc(", "InstallShield cabinet (unshield)"), (b"\x13\x5d\x65\x8c", "InstallShield 3 .Z archive (unshield can't; isxunpack/i3comp)"),
            (b"koly", "DMG trailer?"), (b"\x1f\x8b", "gzip"), (b"BZh", "bzip2"), (b"\xfd7zXZ", "xz"),
            (b"FWS", "Flash SWF"), (b"CWS", "Flash SWF (compressed)"), (b"RIFX", "Director movie (big-endian)"),
            (b"XFIR", "Director movie (little-endian)"), (b"SMK2", "Smacker video"), (b"BIK", "Bink video")]
    for s, name in sigs:
        if data.startswith(s):
            return name
    return None


def identify_file(path: Path) -> dict:
    size = path.stat().st_size
    rep: dict = {"path": str(path), "size": size, "file": file_cmd(path)}
    if size < 2 * 1024 * 1024 * 1024:
        rep["sha256"] = sha256(path)
    with path.open("rb") as f:
        data = f.read(READ)
        if size > READ:  # installers keep their markers near the end too
            f.seek(max(size - READ, READ))
            tail = f.read(READ)
        else:
            tail = b""
        if size >= 0x8800 or data[:2] in (b"ER",):
            iso = iso_info(f, size)
            if iso:
                rep["disc"] = iso
    scan = data + tail
    c = container(data)
    if c:
        rep["container"] = c
    if data[:2] == b"MZ":
        rep["executable"] = mz_info(data)
        inst = [(n, how) for pat, n, how in INSTALLERS if re.search(pat, scan)]
        if inst:
            rep["installer"] = [n for n, _ in inst]
            rep["unpack with"] = inst[0][1]
        prot = sorted({n for pat, n in PROTECTION if re.search(pat, scan)})
        if prot:
            rep["protection markers"] = prot
        v = utf16_strings(scan, ["ProductName", "CompanyName", "FileDescription", "FileVersion", "ProductVersion", "OriginalFilename", "LegalCopyright"])
        if v:
            rep["version info"] = v
        if b"PK\x03\x04" in data[0x400:] and "installer" not in rep:
            rep["note"] = "contains a zip: maybe a self-extracting archive (7z x / unzip)"
    mac = mac_info(path, data)
    if mac:
        rep["mac"] = mac
    return rep


INTERESTING = re.compile(r"(?i)(setup|install|autorun|\.(exe|com|bat|msi|cab|hdr|inf|ini|iss|ins|z|lib|pak|dat|smk|bik|dir|dxr|cxt|mov|toast|img|dsk|image|sit|hqx|bin)$)")


def identify_dir(root: Path) -> dict:
    files = [p for p in root.rglob("*") if p.is_file()]
    rep: dict = {"path": str(root), "files": len(files), "bytes": sum(p.stat().st_size for p in files)}
    exts: dict = {}
    for p in files:
        exts[p.suffix.lower()] = exts.get(p.suffix.lower(), 0) + 1
    rep["extensions"] = dict(sorted(exts.items(), key=lambda kv: -kv[1])[:20])
    auto = next((p for p in files if p.name.lower() == "autorun.inf"), None)
    if auto:
        rep["autorun.inf"] = auto.read_text(errors="replace")[:1000]
    xtras = sorted({p.name for p in files if p.suffix.lower() == ".x32"})
    if xtras:
        rep["director xtras"] = xtras
        needs = [note for name, note in DIRECTOR_XTRAS.items() if name in {x.lower() for x in xtras}]
        if needs:
            rep["director xtras need"] = needs
    picks = [p for p in files if INTERESTING.search(p.name) and p.stat().st_size > 0]
    picks.sort(key=lambda p: (len(p.relative_to(root).parts), -p.stat().st_size))
    rep["identified"] = []
    for p in picks[:25]:
        r = identify_file(p)
        r["path"] = str(p.relative_to(root))
        rep["identified"].append({k: v for k, v in r.items() if k != "sha256"})
    return rep


def main(argv: list[str]) -> None:
    as_json = "--json" in argv
    paths = [a for a in argv if a != "--json"]
    if not paths:
        sys.exit(__doc__)
    for a in paths:
        p = Path(a)
        rep = identify_dir(p) if p.is_dir() else identify_file(p)
        if as_json:
            print(json.dumps(rep, indent=1))
        else:
            print(json.dumps(rep, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
