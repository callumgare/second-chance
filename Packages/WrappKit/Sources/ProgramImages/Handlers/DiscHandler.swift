//
//  DiscHandler.swift
//  ProgramImages
//
//  Disc and disk images, read natively and never mounted: ISO 9660 (with
//  Joliet), raw 2352-byte-sector images, Apple partition maps, classic HFS
//  volumes and Disk Copy 4.2 images. A hybrid disc has both an ISO 9660
//  side and an HFS one (behind a partition map, or at 1024 bytes beside the
//  ISO's descriptors at 32 KB), and both are read. What isn't read natively
//  (HFS+, UDF, UDIF .dmg) goes to 7-Zip.

import ClassicMacFormats
import Foundation

nonisolated struct DiscHandler: NodeHandler {
    let name = "disc"

    func handles(_ identification: Identification) -> Bool {
        [.iso9660, .rawCD, .applePartitionMap, .hfs, .diskCopy42].contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard var opened = node.byteSource() else { return .declined }
        if identification.kind == .rawCD {
            guard let raw = RawSectorSource(opened) else { return .declined }
            opened = raw
        }
        if identification.kind == .diskCopy42 {
            guard let volume = DiskCopy42.volume(in: opened) else { return .declined }
            opened = volume
        }
        let source = opened
        var found = false
        // The Mac side.
        if let map = ApplePartitionMap(source: source) {
            for (index, partition) in map.partitions.enumerated() where partition.type == "Apple_HFS" {
                let slice = ByteSlice(source, offset: partition.offset, count: partition.length)
                let label = "partition \(index + 1) \(partition.name.isEmpty ? partition.type : partition.name)"
                found = expandHFS(slice, label: label, node: node, crawl: crawl) || found
            }
        } else if source.read(1024..<1026) == Data("BD".utf8) {
            found = expandHFS(source, label: nil, node: node, crawl: crawl) || found
        }
        // The Windows (ISO 9660) side.
        if let iso = ISO9660(source: source) {
            found = true
            let entries = iso.entries(limit: crawl.options.maxNodes)
            let files = entries.filter { !$0.isDirectory && !$0.isAssociated }
            let byPath = Dictionary(files.map { ($0.path.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            let forks = Dictionary(entries.filter(\.isAssociated).map { ($0.path.lowercased(), $0) },
                                   uniquingKeysWith: { first, _ in first })
            var children: [Node] = []
            for entry in files {
                var child = crawl.makeNode(parent: node, step: Step(.entry, entry.path),
                                           content: .source(ByteSlice(source, offset: entry.offset, count: entry.length)))
                if let fork = forks[entry.path.lowercased()], fork.length > 0, fork.length < 64 << 20 {
                    child.mac = MacMetadata(type: "", creator: "", finderFlags: 0, resourceFork: iso.read(fork).map { Data($0) })
                }
                let folder = (entry.path as NSString).deletingLastPathComponent
                child.siblings = { name in
                    let path = (folder.isEmpty ? name : folder + "/" + name).lowercased()
                    return byPath[path].map { .source(ByteSlice(source, offset: $0.offset, count: $0.length)) }
                }
                children.append(child)
            }
            crawl.enqueue(children)
        }
        if !found {
            if source.read(1024..<1026) == Data("H+".utf8) {
                return .declined  // HFS+ inside: 7-Zip's.
            }
            crawl.skip(node, "no file system here could be read")
        }
        return .handled
    }

    /// Every file of an HFS volume, with its resource fork and Finder info.
    private func expandHFS(_ source: any ByteSource, label: String?, node: Node, crawl: Crawl) -> Bool {
        if HFSVolume.isHFSPlusWrapper(source) {
            crawl.skip(node, "an HFS+ volume in an HFS wrapper; 7-Zip reads it", name: label)
            return false
        }
        guard let volume = HFSVolume(source: source) else { return false }
        let volumeNode = crawl.makeNode(parent: node, step: Step(.volume, label.map { "\($0): \(volume.name)" } ?? volume.name),
                                        content: .bytes(Data()), containerDepth: node.depth)
        crawl.announce(volumeNode, kind: "hfs-volume")
        var children: [Node] = []
        let entries = volume.entries(limit: crawl.options.maxNodes)
        // An alias to an application at the volume's root is how a disc
        // shows which program to open: the application of that name is the
        // main one.
        for entry in entries where entry.path.count == 1 && entry.type == "adrp" && entry.finderFlags & 0x8000 != 0 {
            crawl.addHint(TargetHint(path: "/" + entry.name.replacingOccurrences(of: "/", with: ":"), role: .mainProgramIcon,
                                     reason: "the application the disc's alias opens"))
        }
        for entry in entries where !entry.isDirectory {
            let path = entry.path.map { $0.replacingOccurrences(of: "/", with: ":") }.joined(separator: "/")
            let content: Node.Content
            if let range = volume.contiguousRange(of: entry, resource: false) {
                content = .source(ByteSlice(source, offset: range.lowerBound, count: range.count))
            } else {
                content = .lazy(size: entry.dataLength) { volume.dataFork(of: entry) }
            }
            var child = crawl.makeNode(parent: volumeNode, step: Step(.entry, path), content: content,
                                       containerDepth: node.depth + 1)
            let fork = entry.resourceLength > 0 && entry.resourceLength < 64 << 20 ? volume.resourceFork(of: entry) : nil
            child.mac = MacMetadata(type: entry.type, creator: entry.creator, finderFlags: entry.finderFlags,
                                    resourceFork: fork, isVolumeRoot: entry.path.count == 1)
            children.append(child)
        }
        crawl.enqueue(children)
        return true
    }
}
