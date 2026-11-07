//
//  WindowsExecutable+Resources.swift
//  WindowsFormats
//
//  Every resource in a PE program — its icons, bitmaps, cursors and the
//  data it keeps (RT_RCDATA and its own types) — and what follows its last
//  section (an installer's or self-extractor's payload). The resource
//  directory is three levels, type → name → language, each named entries
//  first, then numbered ones in order, which is also the order Windows takes
//  a program's own icon from: its first icon group.

import Foundation

nonisolated extension WindowsExecutable {
    /// Every resource, in directory order. Capped, as a damaged directory
    /// can claim any number.
    public var resources: [WindowsResource] {
        guard let rva = directory(2), let root = fileOffset(ofRVA: rva) else { return [] }
        var resources: [WindowsResource] = []
        for type in resourceEntries(at: root, root: root) where type.isDirectory {
            let typeName = resourceName(type, root: root)
            for name in resourceEntries(at: root + type.offset, root: root) where name.isDirectory {
                let nameName = resourceName(name, root: root)
                for language in resourceEntries(at: root + name.offset, root: root) where !language.isDirectory {
                    guard resources.count < 50_000 else { return resources }
                    let entry = root + language.offset
                    var data: Data?
                    if let dataRVA = bytes.u32(at: entry), let size = bytes.u32(at: entry + 4),
                       let start = fileOffset(ofRVA: dataRVA) {
                        data = bytes.bytes(in: start..<(start + size))
                    }
                    resources.append(WindowsResource(type: typeName, name: nameName, language: language.id ?? 0,
                                                     data: data))
                }
            }
        }
        return resources
    }

    /// A named entry's name: a 16-bit length and that many UTF-16 units.
    private func resourceName(_ entry: ResourceEntry, root: Int) -> ResourceName {
        if let id = entry.id { return .id(id) }
        guard let offset = entry.nameOffset, let length = bytes.u16(at: root + offset) else { return .name("?") }
        let units = (0..<min(length, 256)).compactMap { bytes.u16(at: root + offset + 2 + $0 * 2) }
        return .name(String(decoding: units.map(UInt16.init), as: UTF16.self))
    }

    /// Where the file goes on past its last section: an installer's data, a
    /// self-extractor's archive, a game's packed resources. Nil when nothing
    /// follows, or only the signature (its certificate table, which the
    /// security directory says is at the end).
    public var overlay: Range<Int>? {
        let end = sections.map { $0.rawOffset + $0.rawSize }.max() ?? 0
        var last = bytes.count
        // The certificate table's "RVA" is a file offset.
        if directoryCount > 4, let certificates = bytes.u32(at: directories + 4 * 8), certificates >= end,
           certificates < last {
            last = certificates
        }
        guard end > 0, end < last else { return nil }
        return end..<last
    }

    /// Packed by UPX, which leaves only the first icon group readable;
    /// `upx -d` unpacks it without running it.
    public var isUPXPacked: Bool {
        if sectionNames.contains(where: { $0.hasPrefix("UPX") }) { return true }
        // "UPX!" in the headers, where UPX puts its own.
        let head = bytes.prefix(0x400)
        return head.range(of: Data("UPX!".utf8)) != nil
    }

    /// The program's subsystem: 2 for a Windows program, 3 for a console one.
    public var subsystem: Int? {
        guard let pe = bytes.u32(at: 0x3C) else { return nil }
        return bytes.u16(at: pe + 24 + 68)
    }

    /// Whether the image is a DLL rather than a program.
    public var isDLL: Bool {
        guard let pe = bytes.u32(at: 0x3C), let characteristics = bytes.u16(at: pe + 22) else { return false }
        return characteristics & 0x2000 != 0
    }
}

/// The icon groups of a program, PE or NE, each with its images: what
/// `ExtractIcon` would draw from. The first is the program's own icon.
nonisolated public struct ProgramIcons: Sendable {
    public struct Group: Sendable {
        public let name: ResourceName
        public let isCursor: Bool
        /// Each image with its group entry, in the group's order; an image
        /// whose resource is missing or unreadable is left out.
        public let images: [(entry: IconGroup.Entry, data: Data)]

        /// An .ico (or, for a cursor, an .ico of the cursor's images) of the group.
        public var icoFile: Data { ICOFile.build(images) }
    }

    public let groups: [Group]

    /// From a program's resources: each RT_GROUP_ICON (and RT_GROUP_CURSOR)
    /// with the RT_ICON (RT_CURSOR) images it names. A cursor image starts
    /// with its hot spot, which is dropped.
    public init(resources: [WindowsResource]) {
        var icons: [Int: Data] = [:]
        var cursors: [Int: Data] = [:]
        for resource in resources {
            guard let id = resource.name.number, let data = resource.data else { continue }
            if resource.type == .id(ResourceType.icon), icons[id] == nil { icons[id] = data }
            if resource.type == .id(ResourceType.cursor), cursors[id] == nil, data.count > 4 {
                cursors[id] = data.dropFirst(4)
            }
        }
        var groups: [Group] = []
        var seen: Set<ResourceName> = []
        for resource in resources {
            let isIcon = resource.type == .id(ResourceType.groupIcon)
            guard isIcon || resource.type == .id(ResourceType.groupCursor), !seen.contains(resource.name),
                  let data = resource.data, let group = IconGroup(data: data) else { continue }
            seen.insert(resource.name)
            let images = group.entries.compactMap { entry -> (entry: IconGroup.Entry, data: Data)? in
                guard let image = (isIcon ? icons : cursors)[entry.id] else { return nil }
                return (entry, image)
            }
            groups.append(Group(name: resource.name, isCursor: !isIcon, images: images))
        }
        self.groups = groups
    }

    /// The icon groups alone, cursors left out: index 0 is the program's icon.
    public var iconGroups: [Group] { groups.filter { !$0.isCursor } }

    /// The group a shortcut's icon index names: a non-negative index counts
    /// icon groups, a negative one is a resource number.
    public func group(forIconIndex index: Int) -> Group? {
        if index >= 0 { return iconGroups.indices.contains(index) ? iconGroups[index] : nil }
        return iconGroups.first { $0.name == .id(-index) }
    }
}
