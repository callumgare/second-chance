//
//  Extractor.swift
//  ProgramImages
//
//  The crawl: from the input, each node is filtered by its path, identified
//  by its bytes, and handed to the handlers that know its kind, which find
//  images in it and nodes inside it, until nothing is left or a limit is
//  reached. Images are decoded to RGBA, deduped by their pixels (keeping
//  every place each was found), written as PNGs, and at the end grouped into
//  families and ranked (Ranking.swift). Synchronous and single-threaded, so
//  the order (and the output) is the same every run; `extract` runs it off
//  the calling thread.

import ClassicMacFormats
import Foundation
import Logging
import ProcessKit
import WindowsFormats
import WrappFormat

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.ProgramImages")

nonisolated public struct ExtractionOptions: Sendable {
    /// Where `<sha256>.png` and records.jsonl go.
    public var outputDirectory: URL
    /// Where tools unpack to; a fresh folder in the temporary directory if nil.
    public var workDirectory: URL?
    public var maxDepth = 8
    /// The most bytes tools may write in all; nil for max(4 × the input, 2 GB).
    public var byteBudget: Int?
    /// The most a tool may write for each byte it read.
    public var maxExpansionRatio = 200
    public var maxNodes = 100_000
    public var maxImages = 20_000
    public var toolTimeout: TimeInterval = 120
    /// For a whole disc or volume handed to a tool.
    public var discToolTimeout: TimeInterval = 600
    /// Run the outside tools at all.
    public var useTools = true
    /// Look for images by their signatures in what isn't otherwise read.
    public var carve = true
    /// Take frames from videos.
    public var videoFrames = true
    /// The filter table; the shipped one if nil.
    public var filter: PathFilter?
    /// Tools, by name; found on PATH and in Homebrew's folders if nil.
    public var tools: [String: ExternalTool]?

    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }
}

nonisolated public struct ExtractionSummary: Sendable {
    public let records: [ImageRecord]
    public let nodes: Int
    public let skipped: Int
    public let recordsFile: URL
}

nonisolated public enum ProgramImageExtractor {
    /// Crawl `input` (a file or folder: an installer, a disc image, an
    /// installed program, a wrapp) for every image, off the calling thread.
    /// `events` is called for each event, on the crawl's thread.
    public static func extract(_ input: URL, options: ExtractionOptions,
                               events: @escaping @Sendable (ExtractionEvent) -> Void) async throws -> ExtractionSummary {
        try await Blocking.run { try extractSynchronously(input, options: options, events: events) }
    }

    /// The same, on this thread.
    public static func extractSynchronously(_ input: URL, options: ExtractionOptions,
                                            events: @escaping @Sendable (ExtractionEvent) -> Void) throws -> ExtractionSummary {
        let crawl = try Crawl(input: input, options: options, events: events)
        defer { crawl.cleanUp() }
        return try crawl.run()
    }
}

/// A hint at which file is the program, or where its icon is, matched
/// against images' paths once the crawl is done.
nonisolated struct TargetHint: Sendable {
    /// Lower-cased path components, the drive letter dropped.
    let components: [String]
    let role: ImageRole
    /// Which icon group: nil for the first; see `ProgramIcons.group(forIconIndex:)`.
    let iconIndex: Int?
    let reason: String

    init(path: String, role: ImageRole, iconIndex: Int? = nil, relativeTo base: [String] = [], reason: String) {
        var parts = path.replacingOccurrences(of: "\\", with: "/").lowercased().split(separator: "/").map(String.init)
        if let first = parts.first, first.count == 2, first.hasSuffix(":") { parts.removeFirst() }
        parts.removeAll { $0 == "." }
        components = path.contains(":") || path.hasPrefix("/") || path.hasPrefix("\\") ? parts : base + parts
        self.role = role
        self.iconIndex = iconIndex
        self.reason = reason
    }

    func matches(_ path: [String]) -> Bool {
        guard !components.isEmpty, path.count >= components.count else { return false }
        return Array(path.suffix(components.count)) == components
    }
}

/// An image's tie to the program or file it came from, for matching hints.
nonisolated struct IconSource: Sendable, Hashable {
    let path: [String]
    /// The icon group's index among the program's icon groups (0 for an
    /// icon file), and its resource number, if it has one.
    let groupIndex: Int
    let groupID: Int?
}

/// One distinct image while the crawl runs.
nonisolated final class FoundImage: @unchecked Sendable {
    let sha256: String
    let image: RGBAImage
    var chains: [[Step]] = []
    var sources = 0
    var roles: Set<ImageRole> = []
    var iconSources: Set<IconSource> = []
    var familyKeys: Set<String> = []
    let order: Int

    init(sha256: String, image: RGBAImage, order: Int) {
        self.sha256 = sha256
        self.image = image
        self.order = order
    }
}

nonisolated enum HandlerOutcome {
    case handled
    case declined
}

nonisolated protocol NodeHandler: Sendable {
    var name: String { get }
    func handles(_ identification: Identification) -> Bool
    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome
}

nonisolated final class Crawl: @unchecked Sendable {
    let input: URL
    let options: ExtractionOptions
    let filter: PathFilter
    let tools: [String: ExternalTool]
    let workDirectory: URL
    private let ownsWorkDirectory: Bool
    private let emit: @Sendable (ExtractionEvent) -> Void
    private let handlers: [any NodeHandler]

    private var queue: [Node] = []
    private var nextID = 0
    private(set) var nodesSeen = 0
    private(set) var skipped = 0
    private(set) var bytesExtracted = 0
    let byteBudget: Int
    private(set) var images: [String: FoundImage] = [:]
    private var imageOrder = 0
    private(set) var hints: [TargetHint] = []
    /// Programs seen, for guessing the main one when nothing says.
    private(set) var programs: [(path: [String], size: Int, isInstaller: Bool, isGUI: Bool, hasIcon: Bool)] = []
    private var lastProgress = Date.distantPast
    private let started = Date()
    private var missingToolsReported: Set<String> = []

    init(input: URL, options: ExtractionOptions, events: @escaping @Sendable (ExtractionEvent) -> Void) throws {
        self.input = input
        self.options = options
        emit = events
        filter = try options.filter ?? PathFilter()
        tools = options.useTools ? (options.tools ?? ExternalTool.findAll()) : [:]
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        if let work = options.workDirectory {
            workDirectory = work
            ownsWorkDirectory = false
        } else {
            workDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("icon-extract-\(UUID().uuidString)", isDirectory: true)
            ownsWorkDirectory = true
        }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let inputSize = Self.size(of: input)
        byteBudget = options.byteBudget ?? max(4 * inputSize, 2 << 30)
        handlers = HandlerRegistry.handlers
    }

    func cleanUp() {
        if ownsWorkDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    private static func size(of url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return Int(DirectorySize.measure(url, within: url).bytes)
    }

    // MARK: - The loop

    func run() throws -> ExtractionSummary {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: input.path])
        }
        let root = makeNode(parent: nil, step: Step(.file, input.lastPathComponent),
                            content: isDirectory.boolValue ? .hostDirectory(input) : .hostFile(input), containerDepth: 0)
        queue.append(root)
        if isDirectory.boolValue { BundleHints.collect(at: input, into: self) }

        while let node = queue.popLast() {
            try Task.checkCancellation()
            guard nodesSeen < options.maxNodes else {
                skip(node, "the crawl reached its limit of \(options.maxNodes) files")
                break
            }
            nodesSeen += 1
            process(node)
            reportProgress()
        }
        let summary = try finish()
        emit(.done(nodes: nodesSeen, images: summary.records.count,
                   families: Set(summary.records.map(\.familyID)).count, skipped: skipped,
                   records: summary.recordsFile.path, seconds: Date().timeIntervalSince(started)))
        return summary
    }

    private func process(_ node: Node) {
        // The input itself is never filtered.
        if node.parentID != nil, let last = node.chain.last, last.kind == .entry || last.kind == .file {
            switch filter.verdict(for: last.name) {
            case .skip(let reason):
                skip(node, reason)
                return
            case .demote, .read:
                break
            }
        }
        let identification = FileIdentifier.identify(node)
        emit(.node(id: node.id, parent: node.parentID, name: node.name, kind: identification.kind.rawValue,
                   size: node.size, depth: node.depth, display: Step.display(node.chain), installer: identification.installer,
                   macType: node.mac.map { "\($0.type)/\($0.creator)" }))

        // A Mac file's resource fork, whatever its data fork is.
        if node.mac?.resourceFork != nil {
            MacResourceHandler.expand(node, crawl: self)
        }
        if identification.kind == .unknown, node.size == 0 { return }

        for handler in handlers where handler.handles(identification) {
            do {
                if try handler.expand(node, identification, self) == .handled { return }
            } catch {
                logger.warning("\(handler.name) couldn't read \(Step.display(node.chain)): \(error)")
                skip(node, "\(handler.name) couldn't read it: \(error.localizedDescription)")
                return
            }
        }
        switch identification.kind {
        case .unknown:
            if node.mac?.resourceFork == nil || node.size > 0 { Carving.carve(node, crawl: self) }
        default:
            skip(node, "nothing here reads \(identification.kind.rawValue) files")
        }
    }

    private func reportProgress() {
        guard Date().timeIntervalSince(lastProgress) > 0.5 else { return }
        lastProgress = Date()
        emit(.progress(nodes: nodesSeen, images: images.count, queued: queue.count, bytesExtracted: bytesExtracted))
    }

    // MARK: - For handlers

    func makeNode(parent: Node?, step: Step, content: Node.Content, containerDepth: Int? = nil) -> Node {
        nextID += 1
        var node = Node(id: nextID, parentID: parent?.id, chain: (parent?.chain ?? []) + [step],
                        depth: containerDepth ?? ((parent?.depth ?? 0) + 1), content: content)
        node.roles = parent?.roles ?? []
        return node
    }

    /// Report a node that is only a level of the tree (a disc's volume),
    /// not something to look into itself.
    func announce(_ node: Node, kind: String) {
        emit(.node(id: node.id, parent: node.parentID, name: node.chain.last?.name ?? "", kind: kind, size: node.size,
                   depth: node.depth, display: Step.display(node.chain), installer: nil))
    }

    /// A node found inside `parent`, to be looked into, unless that would
    /// go deeper than allowed. `demote` rules apply here, so what is under
    /// a runtime library's folder is ranked down.
    func enqueue(_ node: Node) {
        var node = node
        guard node.depth <= options.maxDepth else {
            skip(node, "deeper than \(options.maxDepth) containers")
            return
        }
        if let last = node.chain.last, case .demote = filter.verdict(for: last.name) {
            node.roles.insert(.runtimeLibrary)
        }
        queue.append(node)
    }

    /// Children are queued in reverse so they're looked into in order.
    func enqueue(_ nodes: [Node]) {
        for node in nodes.reversed() { enqueue(node) }
    }

    func skip(_ node: Node?, _ reason: String, name: String? = nil) {
        skipped += 1
        emit(.skip(node: node?.id, name: name ?? node.map { Step.display($0.chain) } ?? "", reason: reason))
    }

    func addHint(_ hint: TargetHint) {
        hints.append(hint)
    }

    func notePrograms(path: [String], size: Int, isInstaller: Bool, isGUI: Bool, hasIcon: Bool) {
        programs.append((path, size, isInstaller, isGUI, hasIcon))
    }

    /// A decoded image, found at `node` and then `steps` (the resource, the
    /// image's size). Deduped by its pixels: a second sighting adds its
    /// place and roles to the first.
    func addImage(_ image: RGBAImage, node: Node, steps: [Step], roles: Set<ImageRole> = [], familyKey: String? = nil,
                  iconSource: IconSource? = nil) {
        // Too small to be anything, or nothing to see.
        guard image.width >= 8, image.height >= 8, !image.isFullyTransparent else { return }
        let sha = image.pixelHash
        let depthText = image.bitDepth > 0 ? " \(image.bitDepth)-bit" : ""
        let chain = node.chain + steps + [Step(.image, "\(image.width)×\(image.height)\(depthText)")]
        let found: FoundImage
        let isNew: Bool
        if let existing = images[sha] {
            found = existing
            isNew = false
        } else {
            guard images.count < options.maxImages else {
                if images.count == options.maxImages { skip(node, "the crawl reached its limit of \(options.maxImages) images") }
                return
            }
            guard let png = image.pngData() else { return }
            do {
                try png.write(to: options.outputDirectory.appendingPathComponent("\(sha).png"))
            } catch {
                logger.error("Couldn't write \(sha).png: \(error)")
                return
            }
            imageOrder += 1
            found = FoundImage(sha256: sha, image: image, order: imageOrder)
            images[sha] = found
            isNew = true
        }
        found.sources += 1
        if found.chains.count < 50 { found.chains.append(chain) }
        found.roles.formUnion(roles.union(node.roles))
        if let iconSource { found.iconSources.insert(iconSource) }
        if let familyKey { found.familyKeys.insert(familyKey) }
        let nameRole = NameHints.role(for: node.chain + steps)
        if let nameRole { found.roles.insert(nameRole) }
        emit(.image(sha256: sha, node: node.id, width: image.width, height: image.height, bitDepth: image.bitDepth,
                    display: Step.display(chain), isNew: isNew))
    }

    // MARK: - Tools

    /// The tool called `name`, or nil having said (once) that it's missing.
    func tool(_ name: String, for node: Node) -> ExternalTool? {
        if let tool = tools[name] { return tool }
        if options.useTools, missingToolsReported.insert(name).inserted {
            logger.notice("\(name) isn't installed; what needs it is skipped")
        }
        skip(node, options.useTools ? "\(name) isn't installed" : "outside tools are turned off")
        return nil
    }

    /// The node as a file a tool can read: itself, if it's a file on the
    /// Mac; otherwise written to the work folder, with the siblings named
    /// (a multi-part set's other parts) beside it.
    func materialise(_ node: Node, siblings: [String] = []) -> URL? {
        if case .hostFile(let url) = node.content { return url }
        let folder = workDirectory.appendingPathComponent("in-\(node.id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(Self.safeName(node.name))
            guard let data = node.data(), spend(data.count, for: node) else { return nil }
            try data.write(to: url)
            for sibling in siblings {
                guard let content = node.siblings?(sibling) else { continue }
                let siblingNode = Node(id: 0, parentID: nil, chain: [], depth: 0, content: content)
                guard let bytes = siblingNode.data(), spend(bytes.count, for: node) else { continue }
                try bytes.write(to: folder.appendingPathComponent(Self.safeName(sibling)))
            }
            return url
        } catch {
            logger.error("Couldn't write \(node.name) for a tool: \(error)")
            skip(node, "couldn't write it out for a tool")
            return nil
        }
    }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "file" : cleaned
    }

    /// Count `bytes` against the budget; false (having said so) once it's spent.
    func spend(_ bytes: Int, for node: Node) -> Bool {
        guard bytesExtracted + bytes <= byteBudget else {
            skip(node, "the crawl's budget of \(byteBudget / (1 << 20)) MB to unpack is spent")
            return false
        }
        bytesExtracted += bytes
        return true
    }

    /// Run `tool` on `inputFile` into a fresh folder, then queue what it
    /// wrote as children of `node`. False if it failed or wrote nothing.
    @discardableResult
    func runTool(_ tool: ExternalTool, arguments: (_ input: URL, _ output: URL) -> [String], node: Node,
                 inputFile: URL, timeout: TimeInterval? = nil, detail: String? = nil, childRoles: Set<ImageRole> = [],
                 accept: (URL) -> Bool = { _ in true }) -> Bool {
        let output = workDirectory.appendingPathComponent("out-\(node.id)-\(tool.name)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            skip(node, "couldn't make a folder for \(tool.name)")
            return false
        }
        let inputSize = max(node.size, 1)
        let room = max(0, byteBudget - bytesExtracted)
        let perFile = min(room, max(inputSize * options.maxExpansionRatio, 64 << 20))
        let run = SandboxedRunner.run(tool, arguments: arguments(inputFile, output),
                                      readable: [inputFile.deletingLastPathComponent()], output: output,
                                      timeout: timeout ?? options.toolTimeout, maxFileBytes: max(perFile, 1 << 20))
        if run.bytesWritten > inputSize * options.maxExpansionRatio, run.bytesWritten > 64 << 20 {
            try? FileManager.default.removeItem(at: output)
            skip(node, "\(tool.name) wrote more than \(options.maxExpansionRatio) times its input; left alone")
            return false
        }
        guard spend(run.bytesWritten, for: node) else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        if !run.succeeded {
            let reason = run.timedOut ? "timed out" : "exited with \(run.status)"
            logger.notice("\(tool.name) \(reason) on \(node.name): \(run.messages.suffix(400))")
            if run.bytesWritten == 0 {
                skip(node, "\(tool.name) \(reason)")
                return false
            }
        }
        let children = DirectoryHandler.children(of: output, parent: node, crawl: self,
                                                 detail: detail ?? "via \(tool.name)", accept: accept).map { child in
            var child = child
            child.roles.formUnion(childRoles)
            return child
        }
        guard !children.isEmpty else {
            skip(node, "\(tool.name) found nothing in it")
            return false
        }
        enqueue(children)
        return true
    }

    // MARK: - The end

    private func finish() throws -> ExtractionSummary {
        Ranking.resolveHints(self)
        let records = Ranking.records(for: Array(images.values))
        let url = options.outputDirectory.appendingPathComponent("records.jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines = Data()
        for record in records {
            lines.append(try encoder.encode(record))
            lines.append(0x0A)
        }
        try lines.write(to: url)
        return ExtractionSummary(records: records, nodes: nodesSeen, skipped: skipped, recordsFile: url)
    }
}

/// Words in names that say what an image is for.
nonisolated enum NameHints {
    static let titleWords = ["logo", "title", "splash", "opening", "intro", "box", "cover", "front", "about", "banner",
                             "wizard", "welcome", "credits", "menu", "startup", "mainicon", "appicon"]
    static let uiWords = ["btn", "button", "cursor", "font", "mask", "tile", "sprite", "toolbar", "arrow", "check",
                          "radio", "scroll", "glyph"]

    /// From the last few steps' names (the file, the resource).
    static func role(for chain: [Step]) -> ImageRole? {
        let names = chain.suffix(2).map { ($0.name.split(separator: "/").last.map(String.init) ?? $0.name).lowercased() }
        // Words, not substrings: "confront" isn't "front". A word may run
        // on ("openingcine", "logo2").
        let words = names.joined(separator: " ").split { !$0.isLetter }.map(String.init)
        func has(_ list: [String]) -> Bool { words.contains { word in list.contains { word.hasPrefix($0) } } }
        if has(titleWords) { return .titleLikeName }
        if has(uiWords) { return .uiLikeName }
        return nil
    }
}

/// What a folder that is a Mac app bundle (or a wrapp) says about itself:
/// its icon, and for a wrapp the program it launches.
nonisolated enum BundleHints {
    static func collect(at root: URL, into crawl: Crawl) {
        let rootName = root.lastPathComponent.lowercased()
        let contents = root.appendingPathComponent("Contents")
        // A wrapp: the program its launch names, on the prefix's C: drive.
        let settingsURL = contents.appendingPathComponent("Resources/AppSettings.plist")
        if let data = try? Data(contentsOf: settingsURL),
           let settings = try? PropertyListDecoder().decode(WrappSettings.self, from: data) {
            let launch = settings.launch
            var program = launch.program
            if program.hasPrefix("steam:"), let exe = launch.options["steam.exe"] { program = exe }
            if let colon = program.firstIndex(of: ":"), ["wine", "big-fish", "dosbox"].contains(String(program[..<colon])) {
                let path = String(program[program.index(after: colon)...])
                crawl.addHint(TargetHint(path: path, role: .mainProgramIcon, reason: "the program the wrapp launches"))
            }
            if !settings.gameExePath.isEmpty {
                crawl.addHint(TargetHint(path: "C:" + settings.gameExePath, role: .mainProgramIcon,
                                         reason: "the wrapp's game"))
            }
        }
        // The bundle's own icon.
        if let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
           var icon = info["CFBundleIconFile"] as? String {
            if (icon as NSString).pathExtension.isEmpty { icon += ".icns" }
            let isWrapp = FileManager.default.fileExists(atPath: settingsURL.path)
            crawl.addHint(TargetHint(path: "/contents/resources/" + icon, role: isWrapp ? .wrappIcon : .appBundleIcon,
                                     relativeTo: [rootName], reason: "the app's icon"))
        }
    }
}
