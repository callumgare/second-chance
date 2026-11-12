import ArgumentParser
import CryptoKit
import Foundation

/// `sc icon-lab`: Icon Lab's page (Tools/icon-lab/web), built into IconLabAPI's resources, and the dev host that
/// serves it with Vite's live reload. See docs/dev-cli.md#icon-lab.
struct IconLabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icon-lab",
        abstract: "Build Icon Lab's page, or serve it for working on it.",
        subcommands: [IconLabBuildCommand.self, IconLabServeCommand.self]
    )
}

enum IconLabPaths {
    static func web(_ repo: Repo) -> URL { repo.root.appendingPathComponent("Tools/icon-lab/web") }
    static func server(_ repo: Repo) -> URL { repo.root.appendingPathComponent("Tools/icon-lab/server") }
    static func resources(_ repo: Repo) -> URL { repo.root.appendingPathComponent("Packages/IconLab/Sources/IconLabAPI/Resources") }
    /// The dev host's data when none is named: a scratch folder of this checkout's, never the standalone tool's.
    static func scratchData(_ repo: Repo) -> URL { repo.root.appendingPathComponent(".local/icon-lab-dev/data") }

    /// The page's packages, installed once (`npm ci`) when there are none.
    static func ensurePackages(_ session: Session) async throws {
        let web = web(session.repo)
        guard Proc.which("npm") != nil else {
            throw SCError("npm isn't installed, and the page needs it to build.", hints: ["brew install node"])
        }
        guard !FileManager.default.fileExists(atPath: web.appendingPathComponent("node_modules").path) else { return }
        try await session.ui.logStep("Installing the page's packages (npm ci)", log: "icon-lab-npm-ci", success: "Installed the page's packages") { sink in
            try await Proc.stream("npm", ["ci", "--no-audit", "--no-fund"], cwd: web) { await sink.line($0) }
        }
    }

    /// The hash of the page's source, as `WebSourceHash` in IconLabAPI computes it (keep the two in step): every
    /// file but `node_modules`, `dist`, hidden files and `README.md`, sorted by relative path, each as
    /// `<path>\t<sha256>\n`, and the SHA-256 of those lines.
    static func sourceHash(_ root: URL) throws -> String {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let skip: Set<String> = ["node_modules", "dist", "README.md"]
        var files: [String] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return "" }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let regular = (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
            if name.hasPrefix(".") || skip.contains(name) {
                // only a folder's: skipDescendants after a file skips the folder enumerated next
                if !regular { walker.skipDescendants() }
                continue
            }
            guard regular else { continue }
            files.append(String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)))
        }
        var lines = ""
        for path in files.sorted() {
            lines += "\(path)\t\(hex(SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(path)))))\n"
        }
        return hex(SHA256.hash(data: Data(lines.utf8)))
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// The size of everything under a folder, in bytes.
    static func size(_ folder: URL) -> Int {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = walker?.nextObject() as? URL {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}

struct IconLabBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build Icon Lab's page into IconLabAPI's resources.",
        discussion: """
        Installs the page's packages when it has none (npm ci), type-checks and builds Tools/icon-lab/web with \
        Vite into Packages/IconLab/Sources/IconLabAPI/Resources/web, and writes the source's hash beside it \
        (source.sha256). The built page is checked in, so a Mac building the app needs no Node; a test fails \
        while it's stale.
        """
    )

    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let session = try Session.start(global)
        try await IconLabPaths.ensurePackages(session)
        let web = IconLabPaths.web(session.repo)
        try await session.ui.logStep("Building the page", log: "icon-lab-build", success: "Built the page") { sink in
            try await Proc.stream("npm", ["run", "build"], cwd: web) { await sink.line($0) }
        }
        let resources = IconLabPaths.resources(session.repo)
        let hash = try IconLabPaths.sourceHash(web)
        try (hash + "\n").write(to: resources.appendingPathComponent("source.sha256"), atomically: true, encoding: .utf8)
        let size = IconLabPaths.size(resources.appendingPathComponent("web"))
        session.ui.success("Icon Lab's page is built (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))).")
    }
}

struct IconLabServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run Icon Lab's dev server and the page's live-reloading dev server in front of it.",
        discussion: """
        Builds and runs Tools/icon-lab/server (the API over HTTP on 127.0.0.1, its events on a WebSocket) with \
        --data, and Vite's dev server for Tools/icon-lab/web, its /api proxied to the dev server. Open the page \
        Vite prints. Without --data the data is a scratch folder, .local/icon-lab-dev/data. Ctrl-C stops both.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Option(help: "Icon Lab's data folder (programs, caches, catalogue copies, models).")
    var data: String?

    @Option(help: "The dev server's port.")
    var port: Int = 8767

    @Option(help: "The page's dev server's port.")
    var webPort: Int = 5173

    func validate() throws {
        // The standalone tool's engine uses 8766; two engines on one data folder would fight over it.
        guard port != 8766 else { throw ValidationError("Port 8766 is the standalone Icon Lab's: choose another.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        try await IconLabPaths.ensurePackages(session)
        let dataDir = data.map { URL(fileURLWithPath: $0) } ?? IconLabPaths.scratchData(session.repo)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let server = IconLabPaths.server(session.repo)
        try await session.ui.logStep("Building the dev server", log: "icon-lab-server-build", success: "Built the dev server") { sink in
            try await Proc.stream("swift", ["build", "--package-path", server.path, "--product", "icon-lab-server"]) { await sink.line($0) }
        }
        let binary = try await Proc.collect("swift", ["build", "--package-path", server.path, "--show-bin-path"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines) + "/icon-lab-server"
        session.ui.line("Data: \(dataDir.path)")
        let ui = session.ui
        try await withThrowingTaskGroup(of: (String, Int32).self) { group in
            group.addTask {
                ("The dev server", try await Proc.stream(binary, ["--data", dataDir.path, "--port", String(port)], cwd: session.repo.root) { ui.line("engine │ " + $0) })
            }
            group.addTask {
                ("Vite", try await Proc.stream("npx", ["vite", "--port", String(webPort)], env: ["ICON_LAB_ENGINE": "http://127.0.0.1:\(port)"],
                                               cwd: IconLabPaths.web(session.repo)) { ui.line("web    │ " + $0) })
            }
            // Either stopping stops both.
            if let (name, status) = try await group.next() {
                group.cancelAll()
                if status != 0, !Task.isCancelled { throw SCError("\(name) stopped (exit \(status)).") }
            }
        }
    }
}
