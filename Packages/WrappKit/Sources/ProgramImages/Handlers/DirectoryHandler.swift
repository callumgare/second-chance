//
//  DirectoryHandler.swift
//  ProgramImages
//
//  A folder on the Mac — the input, or what a tool unpacked — walked whole:
//  each file becomes a node whose step is its path inside the folder. Links
//  aren't followed (a Wine prefix's `dosdevices/z:` is `/`), folders the
//  filter skips aren't walked, and a file's resource fork and Finder info
//  come with it, from its extended attributes or from an AppleDouble `._`
//  file beside it.

import ClassicMacFormats
import Darwin
import Foundation

nonisolated struct DirectoryHandler: NodeHandler {
    let name = "folder"

    func handles(_ identification: Identification) -> Bool { identification.kind == .directory }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard case .hostDirectory(let url) = node.content else { return .declined }
        // The input's own files are files; a tool's output's are entries of what it unpacked.
        crawl.enqueue(Self.children(of: url, parent: node, crawl: crawl, detail: nil, stepKind: .file))
        return .handled
    }

    /// Every file under `root`, as nodes under `parent`.
    static func children(of root: URL, parent: Node, crawl: Crawl, detail: String?, stepKind: Step.Kind = .entry,
                         accept: (URL) -> Bool = { _ in true }) -> [Node] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [])
        else { return [] }
        let rootPath = root.resolvingSymlinksInPath().path
        var files: [(url: URL, relative: String)] = []
        var names: Set<String> = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            let relative = String((resolvedParent + "/" + url.lastPathComponent).dropFirst(rootPath.count + 1))
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if case .skip(let reason) = crawl.filter.verdict(for: relative + "/") {
                    walker.skipDescendants()
                    crawl.skip(nil, reason, name: Step.display(parent.chain + [Step(stepKind, relative + "/")]))
                }
                continue
            }
            guard values.isRegularFile == true, accept(url) else { continue }
            files.append((url, relative))
            names.insert(relative)
        }
        files.sort { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }

        var nodes: [Node] = []
        for file in files {
            let name = file.url.lastPathComponent
            let directory = file.url.deletingLastPathComponent()
            let prefix = String(file.relative.dropLast(name.count))
            // An AppleDouble file whose data file is here goes with it.
            if name.hasPrefix("._"), names.contains(prefix + String(name.dropFirst(2))) { continue }
            var node = crawl.makeNode(parent: parent, step: Step(stepKind, file.relative, detail: detail),
                                      content: .hostFile(file.url))
            node.mac = macMetadata(for: file.url, appleDouble: names.contains(prefix + "._" + name)
                                   ? directory.appendingPathComponent("._" + name) : nil)
            node.siblings = { sibling in
                let url = directory.appendingPathComponent(sibling)
                return FileManager.default.fileExists(atPath: url.path) ? .hostFile(url) : nil
            }
            nodes.append(node)
        }
        return nodes
    }

    /// A file's resource fork and Finder info: from its own extended
    /// attributes (a file unpacked by unar keeps them), or an AppleDouble file.
    static func macMetadata(for url: URL, appleDouble: URL?) -> MacMetadata? {
        var fork = extendedAttribute("com.apple.ResourceFork", of: url)
        var finderInfo = extendedAttribute("com.apple.FinderInfo", of: url)
        if let appleDouble, let data = try? Data(contentsOf: appleDouble),
           let decoded = AppleSingle.decode(data) {
            fork = fork ?? decoded.resourceFork
            if finderInfo == nil, !decoded.type.isEmpty {
                return MacMetadata(type: decoded.type, creator: decoded.creator, finderFlags: decoded.finderFlags,
                                   resourceFork: fork)
            }
        }
        guard fork != nil || finderInfo != nil else { return nil }
        finderInfo = finderInfo ?? Data(count: 32)
        return MacMetadata(type: finderInfo?.osType(at: 0) ?? "", creator: finderInfo?.osType(at: 4) ?? "",
                           finderFlags: finderInfo?.be16(at: 8) ?? 0, resourceFork: fork)
    }

    static func extendedAttribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 256 << 20 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }
}
