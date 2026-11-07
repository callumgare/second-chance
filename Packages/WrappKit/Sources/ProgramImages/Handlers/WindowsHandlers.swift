//
//  WindowsHandlers.swift
//  ProgramImages
//
//  Windows programs (PE and NE): every icon group (each image of it, all
//  one family), loose icons, bitmaps, and images or archives kept in other
//  resources; what follows the last section (a self-extractor's archive,
//  an installer's data); and for an installer, its payload through the tool
//  that unpacks it without running it. UPX-packed programs are unpacked
//  first (`upx -d` on a copy). Also shortcuts (.lnk) and autorun.inf, which
//  say which program and icon matter, and MSIs' icons, bitmaps and
//  cabinets.

import Foundation
import WindowsFormats

nonisolated struct WindowsProgramHandler: NodeHandler {
    let name = "windows-program"

    func handles(_ identification: Identification) -> Bool {
        identification.kind == .peProgram || identification.kind == .neProgram
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let data = node.data() else { return .declined }
        let lowerName = node.name.lowercased()
        let installer = identification.installer
            ?? (lowerName.hasPrefix("setup") || lowerName.hasPrefix("install") || lowerName.hasPrefix("unins") ? "setup" : nil)
        var roles: Set<ImageRole> = []
        if installer != nil { roles.insert(.installerOwnIcon) }

        if identification.kind == .neProgram {
            guard let program = NEExecutable(data: data) else { return .declined }
            let resources = program.resources
            let hasIcon = Self.addResources(resources, node: node, roles: roles, crawl: crawl)
            crawl.notePrograms(path: node.matchPath, size: data.count, isInstaller: installer != nil, isGUI: true,
                               hasIcon: hasIcon)
            return .handled
        }

        guard let program = WindowsExecutable(data: data) else { return .declined }
        let hasIcon = Self.addResources(program.resources, node: node, roles: roles, crawl: crawl)
        crawl.notePrograms(path: node.matchPath, size: data.count, isInstaller: installer != nil,
                           isGUI: program.subsystem == 2 && !program.isDLL, hasIcon: hasIcon)

        // Packed: unpacked by upx, its resources then read again.
        if program.isUPXPacked, let upx = crawl.tool("upx", for: node), let file = crawl.materialise(node) {
            crawl.runTool(upx, arguments: { input, output in
                ["-d", "-q", "-o", output.appendingPathComponent(Crawl.safeName(node.name)).path, input.path]
            }, node: node, inputFile: file, detail: "unpacked by upx")
        }

        // An uninstaller carries the installer's code, not its payload.
        let isUninstaller = lowerName.hasPrefix("unins")
        switch isUninstaller ? "uninstaller" : installer {
        case "uninstaller":
            break
        case "inno":
            if let tool = crawl.tool("innoextract", for: node), let file = crawl.materialise(node, siblings: Self.innoParts(node)) {
                crawl.runTool(tool, arguments: { input, output in
                    ["--extract", "--silent", "--progress=off", "--color=off", "--output-dir", output.path, input.path]
                }, node: node, inputFile: file)
            }
        case "nsis":
            if let tool = crawl.tool("7zz", for: node), let file = crawl.materialise(node) {
                crawl.runTool(tool, arguments: { input, output in
                    ["x", "-y", "-bd", "-bb0", "-pnone", "-o" + output.path, input.path]
                }, node: node, inputFile: file, accept: { !$0.path.contains("/.rsrc/") })
            }
        case "wise", "setup-factory", "smart-install-maker", "ghost", "clickteam", "installaware", "gentee":
            if !Self.scanOverlay(program, data: data, node: node, crawl: crawl) {
                crawl.skip(node, "\(installer ?? "this") installers can't be unpacked without running them; "
                           + "point it at the installed program or the wrapp instead")
            }
        default:
            Self.scanOverlay(program, data: data, node: node, crawl: crawl)
        }
        return .handled
    }

    /// Inno Setup's external data files (`setup-1.bin` …) beside the setup.
    private static func innoParts(_ node: Node) -> [String] {
        let base = (node.name as NSString).deletingPathExtension
        return (0...9).map { "\(base)-\($0).bin" } + (0...9).map { "\(base)-\($0)a.bin" }
    }

    /// The icons, bitmaps and other resources of a program. True if it has
    /// an icon group.
    @discardableResult
    static func addResources(_ resources: [WindowsResource], node: Node, roles: Set<ImageRole>, crawl: Crawl) -> Bool {
        let icons = ProgramIcons(resources: resources)
        var groupedIcons: Set<Int> = []
        var iconIndex = 0
        for group in icons.groups {
            let groupLabel = "\(group.isCursor ? "RT_GROUP_CURSOR" : "RT_GROUP_ICON") \(group.name)"
            var groupRoles = roles.union(group.isCursor ? [.cursor] : [.icon])
            if !group.isCursor, iconIndex == 0 { groupRoles.insert(.firstIconGroup) }
            let source = group.isCursor ? nil : IconSource(path: node.matchPath, groupIndex: iconIndex, groupID: group.name.number)
            for (entry, data) in group.images {
                groupedIcons.insert(entry.id)
                guard var image = WindowsImageDecoder.decodeIconImage(data) else { continue }
                if image.bitDepth == 0 { image.bitDepth = entry.bitCount }
                crawl.addImage(image, node: node, steps: [Step(.resource, groupLabel)], roles: groupRoles,
                               familyKey: "\(node.id)/\(groupLabel)", iconSource: source)
            }
            if !group.isCursor { iconIndex += 1 }
        }
        for resource in resources {
            guard let data = resource.data, !data.isEmpty else { continue }
            let label = "\(ResourceType.displayName(resource.type)) \(resource.name)"
            switch resource.type {
            case .id(ResourceType.icon):
                // An icon no group names.
                guard let id = resource.name.number, !groupedIcons.contains(id),
                      let image = WindowsImageDecoder.decodeIconImage(data) else { continue }
                crawl.addImage(image, node: node, steps: [Step(.resource, label)], roles: roles.union([.icon]))
            case .id(ResourceType.bitmap):
                guard let image = WindowsImageDecoder.decodeBitmap(data) else { continue }
                crawl.addImage(image, node: node, steps: [Step(.resource, label)], roles: roles.union([.bitmapResource]))
            case .id(ResourceType.cursor), .id(ResourceType.groupIcon), .id(ResourceType.groupCursor),
                 .id(ResourceType.version), .id(ResourceType.string), .id(ResourceType.menu), .id(ResourceType.dialog),
                 .id(ResourceType.manifest), .id(ResourceType.font), .id(7), .id(9), .id(11):
                continue
            default:
                // RT_RCDATA, RT_HTML and a program's own types: an image, a
                // container (IExpress keeps its cabinet in RCDATA CABINET),
                // or images inside (a Delphi form's TImage).
                Embedded.handle(data, label: label, kind: .resource, node: node, roles: roles, crawl: crawl)
            }
        }
        return !icons.iconGroups.isEmpty
    }

    /// What follows the last section: an archive a self-extractor carries,
    /// or images. True if it found an archive.
    @discardableResult
    static func scanOverlay(_ program: WindowsExecutable, data: Data, node: Node, crawl: Crawl) -> Bool {
        guard let overlay = program.overlay, overlay.count >= 64,
              let bytes = data.bytes(in: overlay) else { return false }
        // An archive at, or near, the overlay's start.
        let magics: [(bytes: [UInt8], name: String)] = [
            ([0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0], "cab"), ([0x50, 0x4B, 0x03, 0x04], "zip"),
            ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], "7z"), ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], "rar"),
            ([0x49, 0x53, 0x63, 0x28], "installshield"), ([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1], "msi"),
        ]
        let window = bytes.prefix(4 << 20)
        var best: (offset: Int, name: String)?
        for magic in magics {
            if let range = window.range(of: Data(magic.bytes)) {
                let offset = range.lowerBound - bytes.startIndex
                if best == nil || offset < best?.offset ?? .max { best = (offset, magic.name) }
            }
        }
        if let best {
            let start = overlay.lowerBound + best.offset
            let child = crawl.makeNode(parent: node, step: Step(.overlay, "overlay @0x\(String(start, radix: 16)) (\(best.name))"),
                                       content: .source(data.dropFirst(start)))
            crawl.enqueue(child)
            return true
        }
        if crawl.options.carve {
            Carving.carve(bytes, label: "overlay", node: node, crawl: crawl)
        }
        return false
    }
}

/// Bytes found inside something (a resource, a stream): decoded if they're
/// an image, queued if they're a container, carved otherwise.
nonisolated enum Embedded {
    static func handle(_ data: Data, label: String, kind: Step.Kind, node: Node, roles: Set<ImageRole>, crawl: Crawl) {
        let images = ImageFileHandler.decodeKnown(data)
        if !images.isEmpty {
            for image in images {
                crawl.addImage(image, node: node, steps: [Step(kind, label)], roles: roles.union([.picture]))
            }
            return
        }
        var child = crawl.makeNode(parent: node, step: Step(kind, label), content: .bytes(data))
        child.roles = node.roles.union(roles)
        let identification = FileIdentifier.identify(child)
        switch identification.kind {
        case .unknown:
            if data.count >= 256, crawl.options.carve { Carving.carve(data, label: label, node: node, crawl: crawl) }
        default:
            crawl.enqueue(child)
        }
    }
}

nonisolated struct IconFileHandler: NodeHandler {
    let name = "icon-file"

    func handles(_ identification: Identification) -> Bool {
        [.ico, .cur, .ani].contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let data = node.data() else { return .declined }
        if identification.kind == .ani {
            // A RIFF list of icons: each 'icon' chunk an .ico.
            var offset = 12
            var index = 0
            while offset + 8 <= data.count, index < 256, let size = data.u32(at: offset + 4) {
                let chunk = data.bytes(in: offset..<(offset + 4)).map { String(decoding: $0, as: UTF8.self) }
                if chunk == "LIST" {
                    offset += 12
                    continue
                }
                if chunk == "icon", let icon = data.bytes(in: (offset + 8)..<(offset + 8 + size)), let file = ICOFile(data: icon) {
                    for image in file.images.compactMap({ WindowsImageDecoder.decodeIconImage($0.data) }) {
                        crawl.addImage(image, node: node, steps: [Step(.frame, "frame \(index)")], roles: [.cursor],
                                       familyKey: "\(node.id)/ani")
                    }
                    index += 1
                }
                offset += 8 + size + (size & 1)
            }
            return .handled
        }
        guard let file = ICOFile(data: data) else { return .declined }
        let role: ImageRole = file.isCursor ? .cursor : .icon
        for entry in file.images {
            guard var image = WindowsImageDecoder.decodeIconImage(entry.data) else { continue }
            if image.bitDepth == 0 { image.bitDepth = entry.bitCount }
            crawl.addImage(image, node: node, steps: [], roles: [role], familyKey: "\(node.id)/ico",
                           iconSource: IconSource(path: node.matchPath, groupIndex: 0, groupID: nil))
        }
        return .handled
    }
}

nonisolated struct ShellLinkHandler: NodeHandler {
    let name = "shortcut"

    func handles(_ identification: Identification) -> Bool { identification.kind == .shellLink }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let data = node.data(), let link = ShellLink(data: data) else { return .declined }
        let target = link.target ?? ""
        let targetName = target.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map { $0.lowercased() } ?? ""
        // Not the uninstaller, the manual or a web page.
        let ignored = ["unins", "uninst", "readme", "help", "manual", "setup", "register", "config"]
        if ignored.contains(where: targetName.hasPrefix) || targetName.hasSuffix(".url") || targetName.hasSuffix(".txt")
            || targetName.hasSuffix(".htm") || targetName.hasSuffix(".html") || targetName.hasSuffix(".pdf") {
            crawl.skip(node, "a shortcut to \(targetName), not the program")
            return .handled
        }
        if let icon = link.iconLocation {
            crawl.addHint(TargetHint(path: icon, role: .shortcutIcon, iconIndex: link.iconIndex,
                                     reason: "the icon of \(node.name)"))
        } else if !target.isEmpty {
            crawl.addHint(TargetHint(path: target, role: .shortcutIcon, iconIndex: link.iconIndex,
                                     reason: "the program \(node.name) opens"))
        }
        if !target.isEmpty, targetName.hasSuffix(".exe") {
            crawl.addHint(TargetHint(path: target, role: .mainProgramIcon, reason: "the program \(node.name) opens"))
        }
        return .handled
    }
}

nonisolated struct AutorunHandler: NodeHandler {
    let name = "autorun"

    func handles(_ identification: Identification) -> Bool { identification.kind == .autorunInf }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let data = node.data()?.prefix(64 << 10),
              let autorun = AutorunInf(text: String(data: data, encoding: .windowsCP1252) ?? "") else { return .declined }
        // Paths in it are from the disc's root: the folder autorun.inf is in.
        let base = Array(node.matchPath.dropLast())
        if let icon = autorun.icon {
            crawl.addHint(TargetHint(path: icon, role: .autorunIcon, iconIndex: autorun.iconIndex, relativeTo: base,
                                     reason: "autorun.inf's icon"))
        }
        return .handled
    }
}

nonisolated struct CompoundFileHandler: NodeHandler {
    let name = "msi"

    func handles(_ identification: Identification) -> Bool { identification.kind == .compoundFile }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let data = node.data(), let msi = MSIStreams(data: data) else { return .declined }
        for stream in msi.icons {
            var child = crawl.makeNode(parent: node, step: Step(.entry, "Icon table: " + stream.name.dropFirst(5)),
                                       content: .bytes(stream.data))
            child.roles.insert(.msiIcon)
            crawl.enqueue(child)
        }
        for stream in msi.binaries {
            Embedded.handle(stream.data, label: "Binary table: " + stream.name.dropFirst(7), kind: .entry, node: node,
                            roles: [.installerArt], crawl: crawl)
        }
        for stream in msi.cabinets {
            crawl.enqueue(crawl.makeNode(parent: node, step: Step(.entry, stream.name), content: .bytes(stream.data)))
        }
        // Other streams that are images (OLE documents keep pictures so).
        for stream in msi.streams where !stream.name.hasPrefix("!") && !stream.name.hasPrefix("Icon.")
            && !stream.name.hasPrefix("Binary.") && stream.data.prefix(4) != Data("MSCF".utf8) {
            let images = ImageFileHandler.decodeKnown(stream.data)
            for image in images {
                crawl.addImage(image, node: node, steps: [Step(.entry, stream.name)], roles: [.picture])
            }
        }
        return .handled
    }
}
