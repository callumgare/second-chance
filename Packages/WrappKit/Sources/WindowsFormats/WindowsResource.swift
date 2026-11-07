//
//  WindowsResource.swift
//  WindowsFormats
//
//  A resource in a Windows program, 32-bit (PE) or 16-bit (NE): its type, its
//  name, and its bytes. Both formats keep icons and bitmaps the same way, so
//  what is made from them (an icon group's .ico, a bitmap's .bmp) is shared.
//  The layouts are Microsoft's "Resource File Formats" and the ICO format
//  ("Icons", Win32 SDK, 1995).

import Foundation

/// A resource's type or name: a number, or a string.
nonisolated public enum ResourceName: Hashable, Sendable, CustomStringConvertible {
    case id(Int)
    case name(String)

    public var description: String {
        switch self {
        case .id(let id): String(id)
        case .name(let name): name
        }
    }

    public var number: Int? {
        if case .id(let id) = self { return id }
        return nil
    }
}

/// The standard resource types, by number.
nonisolated public enum ResourceType {
    public static let cursor = 1
    public static let bitmap = 2
    public static let icon = 3
    public static let menu = 4
    public static let dialog = 5
    public static let string = 6
    public static let font = 8
    public static let rcData = 10
    public static let groupCursor = 12
    public static let groupIcon = 14
    public static let version = 16
    public static let html = 23
    public static let manifest = 24

    /// RT_ICON's name, "RT_GROUP_ICON" and the like, for a standard type;
    /// the number or name itself otherwise.
    public static func displayName(_ type: ResourceName) -> String {
        guard let id = type.number else { return type.description }
        let names = [1: "RT_CURSOR", 2: "RT_BITMAP", 3: "RT_ICON", 4: "RT_MENU", 5: "RT_DIALOG", 6: "RT_STRING",
                     7: "RT_FONTDIR", 8: "RT_FONT", 9: "RT_ACCELERATOR", 10: "RT_RCDATA", 11: "RT_MESSAGETABLE",
                     12: "RT_GROUP_CURSOR", 14: "RT_GROUP_ICON", 16: "RT_VERSION", 17: "RT_DLGINCLUDE",
                     19: "RT_PLUGPLAY", 20: "RT_VXD", 21: "RT_ANICURSOR", 22: "RT_ANIICON", 23: "RT_HTML",
                     24: "RT_MANIFEST"]
        return names[id] ?? String(id)
    }
}

/// One resource, as the program holds it.
nonisolated public struct WindowsResource: Sendable {
    public let type: ResourceName
    public let name: ResourceName
    /// The language, for a PE resource; 0 for an NE one, which has none.
    public let language: Int
    /// Nil when the directory points outside the file, as a packed
    /// program's (UPX's) compressed resources do.
    public let data: Data?

    public init(type: ResourceName, name: ResourceName, language: Int, data: Data?) {
        self.type = type
        self.name = name
        self.language = language
        self.data = data
    }
}

/// An icon (or cursor) group: the directory RT_GROUP_ICON holds, naming the
/// RT_ICON resources that are its images at each size and depth.
nonisolated public struct IconGroup: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// 0 means 256.
        public let width: Int
        public let height: Int
        public let colorCount: Int
        public let planes: Int
        public let bitCount: Int
        public let byteCount: Int
        /// The RT_ICON (or RT_CURSOR) resource's number.
        public let id: Int

        public init(width: Int, height: Int, colorCount: Int, planes: Int, bitCount: Int, byteCount: Int, id: Int) {
            self.width = width
            self.height = height
            self.colorCount = colorCount
            self.planes = planes
            self.bitCount = bitCount
            self.byteCount = byteCount
            self.id = id
        }
    }

    public let isCursor: Bool
    public let entries: [Entry]

    /// Nil if `data` isn't a group directory. A cursor group's entries are
    /// laid out differently (two 16-bit sizes, the height doubled).
    public init?(data: Data) {
        guard data.u16(at: 0) == 0, let type = data.u16(at: 2), type == 1 || type == 2,
              let count = data.u16(at: 4), count > 0, count <= 256 else { return nil }
        isCursor = type == 2
        var entries: [Entry] = []
        for index in 0..<count {
            let entry = 6 + index * 14
            guard let planes = data.u16(at: entry + 4), let bitCount = data.u16(at: entry + 6),
                  let byteCount = data.u32(at: entry + 8), let id = data.u16(at: entry + 12) else { break }
            if type == 2 {
                guard let width = data.u16(at: entry), let height = data.u16(at: entry + 2) else { break }
                entries.append(Entry(width: width, height: height / 2, colorCount: 0, planes: planes,
                                     bitCount: bitCount, byteCount: byteCount, id: id))
            } else {
                guard let width = data.u8(at: entry), let height = data.u8(at: entry + 1),
                      let colors = data.u8(at: entry + 2) else { break }
                entries.append(Entry(width: width, height: height, colorCount: colors, planes: planes,
                                     bitCount: bitCount, byteCount: byteCount, id: id))
            }
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }
}

/// An .ico or .cur file: a directory of images, each a DIB (an icon's
/// bitmap, its height doubled for the AND mask) or a PNG.
nonisolated public struct ICOFile: Sendable {
    public struct Image: Sendable {
        /// From the directory; 0 means 256. The image's own header is the
        /// truth when they differ.
        public let width: Int
        public let height: Int
        public let bitCount: Int
        public let data: Data
    }

    public let isCursor: Bool
    public let images: [Image]

    /// Nil if `data` isn't an icon or cursor file.
    public init?(data: Data) {
        guard data.u16(at: 0) == 0, let type = data.u16(at: 2), type == 1 || type == 2,
              let count = data.u16(at: 4), count > 0, count <= 256 else { return nil }
        isCursor = type == 2
        var images: [Image] = []
        for index in 0..<count {
            let entry = 6 + index * 16
            guard let width = data.u8(at: entry), let height = data.u8(at: entry + 1),
                  let bitCount = data.u16(at: entry + 6), let size = data.u32(at: entry + 8),
                  let offset = data.u32(at: entry + 12), size > 0, offset >= 6,
                  offset + size <= data.count else { continue }
            let start = data.startIndex + offset
            images.append(Image(width: width, height: height, bitCount: type == 2 ? 0 : bitCount,
                                data: data[start..<start + size]))
        }
        guard !images.isEmpty else { return nil }
        self.images = images
    }

    /// An .ico file holding `images`, each with its group entry, as Windows
    /// would write the group out.
    public static func build(_ images: [(entry: IconGroup.Entry, data: Data)]) -> Data {
        var file = Data()
        file.appendLE16(0)
        file.appendLE16(1)
        file.appendLE16(images.count)
        var offset = 6 + 16 * images.count
        for (entry, data) in images {
            file.append(UInt8(truncatingIfNeeded: entry.width))
            file.append(UInt8(truncatingIfNeeded: entry.height))
            file.append(UInt8(truncatingIfNeeded: entry.colorCount))
            file.append(0)
            file.appendLE16(entry.planes)
            file.appendLE16(entry.bitCount)
            file.appendLE32(data.count)
            file.appendLE32(offset)
            offset += data.count
        }
        for (_, data) in images { file.append(data) }
        return file
    }
}

/// A device-independent bitmap's header, as an RT_BITMAP, an icon's image or
/// a .bmp holds it.
nonisolated public struct DIBHeader: Sendable, Equatable {
    public let headerSize: Int
    public let width: Int
    /// Positive: rows run bottom up. For an icon's image, doubled.
    public let height: Int
    public let bitCount: Int
    public let compression: Int
    public let colorsUsed: Int

    public init?(data: Data) {
        guard let size = data.u32(at: 0) else { return nil }
        if size == 12 {  // BITMAPCOREHEADER (OS/2 1.x, Windows 2)
            guard let width = data.u16(at: 4), let height = data.u16(at: 6), let bitCount = data.u16(at: 10)
            else { return nil }
            self.headerSize = 12
            self.width = width
            self.height = height
            self.bitCount = bitCount
            compression = 0
            colorsUsed = 0
        } else {
            guard size >= 40, size <= 256, let width = data.u32(at: 4), let rawHeight = data.u32(at: 8),
                  let bitCount = data.u16(at: 14), let compression = data.u32(at: 16),
                  let colorsUsed = data.u32(at: 32) else { return nil }
            headerSize = size
            self.width = Int(Int32(truncatingIfNeeded: width))
            height = Int(Int32(truncatingIfNeeded: rawHeight))
            self.bitCount = bitCount
            self.compression = compression
            self.colorsUsed = colorsUsed
        }
        guard width > 0, width <= 16384, height != 0, abs(height) <= 32768,
              [1, 2, 4, 8, 16, 24, 32].contains(bitCount) else { return nil }
    }

    /// How many palette entries follow the header.
    public var paletteCount: Int {
        guard bitCount <= 8 else { return 0 }
        return colorsUsed > 0 && colorsUsed <= 1 << bitCount ? colorsUsed : 1 << bitCount
    }

    /// Bytes per palette entry: 3 for a core header, 4 otherwise.
    public var paletteEntrySize: Int { headerSize == 12 ? 3 : 4 }

    /// Where the pixels start, from the header's start: after it, its
    /// palette and, for BI_BITFIELDS in a 40-byte header, three masks.
    public var pixelOffset: Int {
        headerSize + paletteCount * paletteEntrySize + (compression == 3 && headerSize == 40 ? 12 : 0)
    }

    /// A .bmp file of `dib` (a header, palette and pixels, as RT_BITMAP has
    /// them): a 14-byte file header in front.
    public static func bmpFile(_ dib: Data) -> Data? {
        guard let header = DIBHeader(data: dib) else { return nil }
        var file = Data([0x42, 0x4D])
        file.appendLE32(14 + dib.count)
        file.appendLE32(0)
        file.appendLE32(14 + header.pixelOffset)
        file.append(dib)
        return file
    }
}

extension Data {
    nonisolated mutating func appendLE16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    nonisolated mutating func appendLE32(_ value: Int) {
        appendLE16(value & 0xFFFF)
        appendLE16(value >> 16)
    }

    /// The bytes in `range`, counted from zero, if all of them are there.
    nonisolated public func bytes(in range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= count, !range.isEmpty || range.lowerBound <= count
        else { return nil }
        return self[(startIndex + range.lowerBound)..<(startIndex + range.upperBound)]
    }
}
