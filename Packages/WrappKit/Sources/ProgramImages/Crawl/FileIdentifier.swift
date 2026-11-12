//
//  FileIdentifier.swift
//  ProgramImages
//
//  What a file is, from its bytes first and its name only to break a tie:
//  the signature tables of the porting skill's identify.py, ported. Only the
//  head and tail are read (and a program's overlay), never the whole file,
//  so a crawl over a disc doesn't read every byte to name each file.

import ClassicMacFormats
import Foundation
import WindowsFormats

nonisolated public enum FileKind: String, Codable, Sendable {
    case directory
    case peProgram = "pe", neProgram = "ne", dosProgram = "dos", extendedProgram = "le"
    case ico, cur, ani, icns, png, jpeg, gif, bmp, tiff, tga, pict, pcx, ilbm, macPaint = "macpaint", winHelp = "hlp"
    /// A WinHelp file's bitmaps (SHG, MRB).
    case helpBitmap = "shg"
    case shellLink = "lnk", autorunInf = "autorun-inf"
    case compoundFile = "ole"
    case iso9660 = "iso", rawCD = "raw-cd", applePartitionMap = "apm", hfs, hfsPlus = "hfs-plus"
    case diskCopy42 = "diskcopy42", udif = "dmg", udf
    case macBinary = "macbinary", appleSingle = "applesingle", binHex = "binhex", stuffIt = "stuffit"
    case compactPro = "compactpro", resourceFork = "rsrc"
    case zip, sevenZip = "7z", rar, cab, installShieldCab = "installshield-cab", installShield3 = "installshield3-z"
    case installShieldHeader = "installshield-hdr"
    case gzip, bzip2, xz, tar, lzh, arj, chm, szdd, kwaj, compressZ = "compress-z"
    case smacker, bink, flic, avi, quickTime = "quicktime", mpeg
    case director, flash = "swf", herCIF = "her-cif", herAVF = "her-avf"
    case unknown
}

/// What the identifier found: the kind, and for a Windows program the
/// installer it is (Inno Setup, NSIS…), if any.
nonisolated public struct Identification: Sendable {
    public var kind: FileKind
    public var installer: String?
    public var detail: String?
}

nonisolated enum FileIdentifier {
    /// Installer markers in a program's bytes (identify.py's INSTALLERS),
    /// in order of trust.
    static let installerMarkers: [(marker: String, family: String)] = [
        ("Inno Setup Setup Data", "inno"),
        ("Nullsoft Install System", "nsis"),
        ("NullsoftInst", "nsis"),
        ("Wise Installation", "wise"),
        ("WISE_SETUP", "wise"),
        ("WiseMain", "wise"),
        (";!@Install@!UTF-8!", "7z-sfx"),
        ("7zS.sfx", "7z-sfx"),
        ("7-Zip SFX", "7z-sfx"),
        ("WinZip Self-Extractor", "winzip-sfx"),
        ("Setup Factory", "setup-factory"),
        ("Smart Install Maker", "smart-install-maker"),
        ("Ghost Installer", "ghost"),
        ("Clickteam Install Creator", "clickteam"),
        ("InstallAware", "installaware"),
        ("ginstall.dll", "gentee"),
        ("Inno Setup", "inno"),
        ("InstallShield", "installshield"),
    ]

    static func identify(_ node: Node) -> Identification {
        if case .hostDirectory = node.content { return Identification(kind: .directory) }
        guard let source = node.byteSource(), source.count > 0 else { return Identification(kind: .unknown) }
        let head = source.read(0..<min(source.count, 65_536)) ?? Data()
        let lowerName = node.name.lowercased()
        let ext = (lowerName as NSString).pathExtension

        // A classic Mac file says what it is.
        if let type = node.mac?.type {
            if type == "PICT" { return Identification(kind: .pict) }
            if type == "PNTG" { return Identification(kind: .macPaint) }
        }

        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + bytes.count && head.dropFirst(offset).prefix(bytes.count).elementsEqual(bytes)
        }
        func starts(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }

        if starts("MZ") { return identifyMZ(node, head: head, source: source) }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return Identification(kind: .png) }
        if starts([0xFF, 0xD8, 0xFF]) { return Identification(kind: .jpeg) }
        if starts("GIF8") { return Identification(kind: .gif) }
        if starts("BM"), head.u32(at: 14).map({ [12, 40, 52, 56, 108, 124].contains($0) }) == true {
            return Identification(kind: .bmp)
        }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return Identification(kind: .tiff) }
        if starts("icns") { return Identification(kind: .icns) }
        if starts([0, 0, 1, 0]), ext == "ico" || ICOFile(data: head) != nil, ext != "cur" { return Identification(kind: .ico) }
        if starts([0, 0, 2, 0]), ext == "cur" || ext == "ico" { return Identification(kind: .cur) }
        if starts("RIFF"), starts("ACON", at: 8) { return Identification(kind: .ani) }
        if starts("RIFF"), starts("AVI ", at: 8) { return Identification(kind: .avi) }
        if starts("RIFX") || starts("XFIR") || (starts("RIFF") && (starts("MV93", at: 8) || starts("APPL", at: 8))) {
            return Identification(kind: .director)
        }
        if starts("FORM"), starts("ILBM", at: 8) || starts("PBM ", at: 8) { return Identification(kind: .ilbm) }
        if starts([0x4C, 0, 0, 0, 0x01, 0x14, 0x02, 0]) { return Identification(kind: .shellLink) }
        if lowerName == "autorun.inf" { return Identification(kind: .autorunInf) }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) { return Identification(kind: .compoundFile) }
        if starts("MSCF") { return Identification(kind: .cab) }
        if starts("ISc(") {
            return Identification(kind: lowerName.hasSuffix(".hdr") ? .installShieldHeader : .installShieldCab)
        }
        if starts([0x13, 0x5D, 0x65, 0x8C]) { return Identification(kind: .installShield3) }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) { return Identification(kind: .zip) }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return Identification(kind: .sevenZip) }
        if starts("Rar!") { return Identification(kind: .rar) }
        if starts([0x1F, 0x8B]) { return Identification(kind: .gzip) }
        if starts("BZh") { return Identification(kind: .bzip2) }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return Identification(kind: .xz) }
        if starts([0x1F, 0x9D]) { return Identification(kind: .compressZ) }
        if starts("ustar", at: 257) { return Identification(kind: .tar) }
        if starts("-lh", at: 2) || starts("-lz", at: 2) { return Identification(kind: .lzh) }
        if starts([0x60, 0xEA]), ext == "arj" || head.count > 40 { return Identification(kind: .arj) }
        if starts("ITSF") { return Identification(kind: .chm) }
        if starts([0x53, 0x5A, 0x44, 0x44, 0x88, 0xF0, 0x27, 0x33]) { return Identification(kind: .szdd) }
        if starts([0x4B, 0x57, 0x41, 0x4A, 0x88, 0xF0, 0x27, 0xD1]) { return Identification(kind: .kwaj) }
        if starts([0x3F, 0x5F, 0x03, 0x00]) { return Identification(kind: .winHelp) }
        if starts("lP") || starts("lp"), ["shg", "mrb", ""].contains(ext) { return Identification(kind: .helpBitmap) }
        if starts("SMK2") || starts("SMK4") { return Identification(kind: .smacker) }
        if starts("BIK") || starts("KB2") { return Identification(kind: .bink) }
        if let magic = head.u16(at: 4), magic == 0xAF11 || magic == 0xAF12, ["fli", "flc", "flx"].contains(ext) {
            return Identification(kind: .flic)
        }
        if ["moov", "mdat", "ftyp", "wide", "free", "skip", "pnot"].contains(where: { starts($0, at: 4) }),
           ["mov", "qt", "mp4", "m4v", "moov", ""].contains(ext) || starts("ftyp", at: 4) || starts("moov", at: 4) {
            return Identification(kind: .quickTime)
        }
        if starts([0, 0, 1, 0xBA]) || starts([0, 0, 1, 0xB3]) { return Identification(kind: .mpeg) }
        if starts("FWS") || starts("CWS") || starts("ZWS") { return Identification(kind: .flash) }
        if starts("CIF TREE") || starts("CIF FILE") { return Identification(kind: .herCIF) }
        if starts("AVF WayneSikes") || starts("AVF HerInter") { return Identification(kind: .herAVF) }
        if starts("StuffIt (c)1997") || starts("SIT!") || starts("StuffIt") || (starts("rLau", at: 10) && starts("SIT", at: 0)) {
            return Identification(kind: .stuffIt)
        }
        if BinHex.looksLike(head.prefix(4096)) { return Identification(kind: .binHex) }
        if let magic = head.be32(at: 0), magic == AppleSingle.singleMagic || magic == AppleSingle.doubleMagic {
            return Identification(kind: .appleSingle)
        }
        if PCXDecoder.looksLike(head), ext == "pcx" || ext == "pcc" || head.count >= 128 && head.u8(at: 64) == 0 {
            return Identification(kind: .pcx)
        }
        if ext == "tga", head.count > 18 { return Identification(kind: .tga) }

        // Disc images: a raw CD's sync, a partition map, HFS at 1024, ISO
        // 9660 at 32 KB, a Disk Copy 4.2 header, a UDIF trailer.
        if starts([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]) {
            return Identification(kind: .rawCD)
        }
        if starts("ER"), source.read(512..<514) == Data("PM".utf8) || source.read(2048..<2050) == Data("PM".utf8) {
            return Identification(kind: .applePartitionMap)
        }
        if let signature = source.read(1024..<1026) {
            if signature == Data("BD".utf8), HFSVolume(source: source) != nil {
                return Identification(kind: ISO9660.looksLike(source) ? .iso9660 : .hfs)
            }
            if signature == Data("H+".utf8) || signature == Data("HX".utf8) { return Identification(kind: .hfsPlus) }
        }
        if ISO9660.looksLike(source) { return Identification(kind: .iso9660) }
        if source.read(0x8001..<0x8006) == Data("BEA01".utf8) { return Identification(kind: .udf) }
        if DiskCopy42.volume(in: source) != nil { return Identification(kind: .diskCopy42) }
        if source.count > 512, source.read((source.count - 512)..<(source.count - 508)) == Data("koly".utf8) {
            return Identification(kind: .udif)
        }
        // MacBinary has no magic before III: every field that must be zero
        // is checked, and the forks' lengths against the whole file.
        if head.first == 0, head.count >= 128, source.count <= 256 << 20, head.be8(at: 74) == 0, head.be8(at: 82) == 0,
           let data = node.data(), MacBinary.decode(data) != nil {
            return Identification(kind: .macBinary)
        }
        if ResourceFork(data: head) != nil, ext == "rsrc" || head.count == source.count {
            return Identification(kind: .resourceFork)
        }
        if ext == "pct" || ext == "pict" { return Identification(kind: .pict) }
        return Identification(kind: .unknown)
    }

    /// An MZ program: Windows (PE, NE), a DOS extender's (LE, LX) or plain
    /// DOS. A PE is checked for installer markers in its head, tail and
    /// overlay start, and its version strings.
    private static func identifyMZ(_ node: Node, head: Data, source: any ByteSource) -> Identification {
        guard let header = head.u32(at: 0x3C), let signature = source.read(header..<(header + 4)) else {
            return Identification(kind: .dosProgram)
        }
        if signature.prefix(2) == Data("NE".utf8) { return Identification(kind: .neProgram) }
        if signature.prefix(2) == Data("LE".utf8) || signature.prefix(2) == Data("LX".utf8) {
            return Identification(kind: .extendedProgram)
        }
        guard signature == Data([0x50, 0x45, 0, 0]), let data = node.data(), let program = WindowsExecutable(data: data) else {
            return Identification(kind: .dosProgram)
        }
        var regions = [data.prefix(2 << 20), data.suffix(1 << 20)]
        if let overlay = program.overlay { regions.append(data.dropFirst(overlay.lowerBound).prefix(1 << 16)) }
        let version = program.versionStrings
        let versionText = [version["Comments"], version["ProductName"], version["CompanyName"],
                           version["FileDescription"], version["InternalName"]].compactMap { $0 }.joined(separator: " ")
        regions.append(Data(versionText.utf8))
        for (marker, family) in installerMarkers {
            let needle = Data(marker.utf8)
            if regions.contains(where: { $0.range(of: needle) != nil }) {
                return Identification(kind: .peProgram, installer: family, detail: version["ProductName"])
            }
        }
        return Identification(kind: .peProgram, installer: nil, detail: version["ProductName"])
    }
}
