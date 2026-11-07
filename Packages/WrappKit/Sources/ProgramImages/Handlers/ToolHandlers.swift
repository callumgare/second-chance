//
//  ToolHandlers.swift
//  ProgramImages
//
//  What the outside tools read (ExternalTool.swift has how they're run):
//  7-Zip for archives, cabinets and disk images; unshield for InstallShield
//  cabinets; unar for StuffIt and Compact Pro; deark for the odd image
//  format and InstallShield 3's .Z; ffmpeg for a few early frames of a
//  video.

import Foundation

nonisolated struct ArchiveToolHandler: NodeHandler {
    let name = "7zz"

    func handles(_ identification: Identification) -> Bool {
        [.cab, .zip, .sevenZip, .rar, .gzip, .bzip2, .xz, .tar, .lzh, .arj, .chm, .szdd, .kwaj, .compressZ,
         .udif, .hfsPlus, .udf, .iso9660, .hfs, .applePartitionMap].contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let tool = crawl.tool("7zz", for: node), let file = crawl.materialise(node) else { return .handled }
        let isDisc = [.udif, .hfsPlus, .udf, .iso9660, .hfs, .applePartitionMap].contains(identification.kind)
        crawl.runTool(tool, arguments: { input, output in
            ["x", "-y", "-bd", "-bb0", "-pnone", "-o" + output.path, input.path]
        }, node: node, inputFile: file, timeout: isDisc ? crawl.options.discToolTimeout : nil)
        return .handled
    }
}

nonisolated struct InstallShieldHandler: NodeHandler {
    let name = "unshield"

    func handles(_ identification: Identification) -> Bool { identification.kind == .installShieldCab }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        // A set is read from its first cabinet (data1.cab), its header and
        // other parts beside it.
        let lower = node.name.lowercased()
        let stem = (lower as NSString).deletingPathExtension
        guard stem.hasSuffix("1") else {
            crawl.skip(node, "a later part of an InstallShield set, read with its first")
            return .handled
        }
        let base = String((node.name as NSString).deletingPathExtension.dropLast())
        let parts = [base + "1.hdr"] + (2...32).map { "\(base)\($0).cab" }
            + [base.uppercased() + "1.HDR"] + (2...32).map { "\(base.uppercased())\($0).CAB" }
        guard let tool = crawl.tool("unshield", for: node), let file = crawl.materialise(node, siblings: parts) else {
            return .handled
        }
        crawl.runTool(tool, arguments: { input, output in ["-d", output.path, "-j", "x", input.path] },
                      node: node, inputFile: file, timeout: crawl.options.discToolTimeout)
        return .handled
    }
}

nonisolated struct StuffItHandler: NodeHandler {
    let name = "unar"

    func handles(_ identification: Identification) -> Bool {
        [.stuffIt, .compactPro, .binHex, .macBinary].contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let tool = crawl.tool("unar", for: node), let file = crawl.materialise(node) else { return .handled }
        // Resource forks kept as forks, read back from their extended attributes.
        crawl.runTool(tool, arguments: { input, output in
            ["-q", "-f", "-D", "-nq", "-k", "fork", "-o", output.path, input.path]
        }, node: node, inputFile: file)
        return .handled
    }
}

nonisolated struct DearkHandler: NodeHandler {
    let name = "deark"

    func handles(_ identification: Identification) -> Bool {
        [.ilbm, .macPaint, .winHelp, .helpBitmap, .installShield3, .pcx, .pict, .tga, .bmp, .tiff, .gif]
            .contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let tool = crawl.tool("deark", for: node), let file = crawl.materialise(node) else { return .handled }
        var module: [String] = []
        if identification.kind == .macPaint { module = ["-m", "macpaint"] }
        if identification.kind == .installShield3 { module = ["-m", "is_z"] }
        crawl.runTool(tool, arguments: { input, output in
            ["-q", "-od", output.path, "-o", "out", "-maxfiles", "2000"] + module + [input.path]
        }, node: node, inputFile: file)
        return .handled
    }
}

nonisolated struct VideoHandler: NodeHandler {
    let name = "ffmpeg"

    /// Frames from the first 15 seconds: one every 2.5 s, the first at the
    /// start (a title card, a publisher's logo).
    static let seconds = 15
    static let interval = 2.5

    func handles(_ identification: Identification) -> Bool {
        [.smacker, .bink, .flic, .avi, .quickTime, .mpeg].contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard crawl.options.videoFrames else {
            crawl.skip(node, "video frames are turned off")
            return .handled
        }
        guard let tool = crawl.tool("ffmpeg", for: node), let file = crawl.materialise(node) else { return .handled }
        let frames = Int(Double(Self.seconds) / Self.interval)
        crawl.runTool(tool, arguments: { input, output in
            ["-nostdin", "-hide_banner", "-loglevel", "error", "-t", String(Self.seconds), "-i", input.path,
             // The first frame, then one every interval: a video shorter
             // than the interval still gives its first.
             "-vf", "select='eq(n\\,0)+gte(t-prev_selected_t\\,\(Self.interval))'", "-fps_mode", "passthrough",
             "-frames:v", String(frames + 1), "-f", "image2",
             output.appendingPathComponent("frame-%02d.png").path]
        }, node: node, inputFile: file, detail: "frame, via ffmpeg", childRoles: [.videoFrame])
        return .handled
    }
}
