import Foundation
import Noora

/// What xcodebuild is doing, from its raw output.
///
/// xcbeautify shows compiler messages but not the build's own progress, and
/// some steps print nothing for a long time — a script phase's output only
/// arrives when the phase ends (WrappTemplate's "Download And Copy Wine
/// Files" can take most of a minute). xcodebuild does announce each task as
/// it starts, e.g.
///
///     PhaseScriptExecution Download\ And\ Copy\ Wine\ Files /…/Script-E2A1….sh (in target 'WrappTemplate' from project 'SecondChance')
///
/// so those lines say what is happening now.
enum XcodeActivity {
    static func describe(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line == rawLine || !rawLine.hasPrefix("    ") else { return nil }

        if line.hasPrefix("Resolve Package Graph") { return "Resolving packages" }
        if line.hasPrefix("ComputePackagePrebuildTargetDependencyGraph") || line.hasPrefix("Prepare packages") {
            return "Preparing packages"
        }
        if line.hasPrefix("ComputeTargetDependencyGraph") { return "Planning the build" }

        guard let verb = line.split(separator: " ", maxSplits: 1).first.map(String.init),
              let target = target(in: line) else { return nil }

        let what: String
        switch verb {
        case "PhaseScriptExecution":
            what = "running “\(scriptName(in: line))”"
        case "SwiftCompile", "CompileSwift", "CompileC":
            what = file(in: line).map { "compiling \($0)" } ?? "compiling"
        case "SwiftDriver", "SwiftDriverJobDiscovery": what = "planning Swift compilation"
        case "SwiftEmitModule", "EmitSwiftModule": what = "emitting module"
        case "ScanDependencies": what = "scanning dependencies"
        case "Ld": what = "linking"
        case "CreateUniversalBinary": what = "making a universal binary"
        case "CodeSign": what = "signing"
        case "Copy", "CpResource", "CopySwiftLibs", "Ditto": what = "copying"
        case "ProcessInfoPlistFile": what = "processing Info.plist"
        case "Validate", "ValidateEmbeddedBinary": what = "validating"
        case "GenerateDSYMFile": what = "generating dSYM"
        case "CompileAssetCatalog", "CompileAssetCatalogVariant": what = "compiling assets"
        default: return nil
        }
        return "\(target): \(what)"
    }

    private static func target(in line: String) -> String? {
        guard let start = line.range(of: "(in target '") else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    /// The phase name: everything up to the first unescaped space, unescaped.
    private static func scriptName(in line: String) -> String {
        var name = ""
        var escaped = false
        for ch in line.dropFirst("PhaseScriptExecution ".count) {
            if escaped { name.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == " " { break }
            name.append(ch)
        }
        return name
    }

    /// The source file's name, from the last path before "(in target".
    private static func file(in line: String) -> String? {
        let head = line.components(separatedBy: " (in target").first ?? line
        let words = head.replacingOccurrences(of: "\\ ", with: "\u{0}").split(separator: " ")
        let source = words.last { $0.hasSuffix(".swift") || $0.hasSuffix(".c") || $0.hasSuffix(".m") || $0.hasSuffix(".mm") }
        return source.map { URL(fileURLWithPath: String($0).replacingOccurrences(of: "\u{0}", with: " ")).lastPathComponent }
    }
}

/// A live line under a step: a spinner, what is happening now, and how long
/// the step has been running — so a step whose output has gone quiet still
/// visibly moves.
final class ActivityLine: @unchecked Sendable {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let ui: UI
    private let handle: UI.RendererHandle
    private let describe: @Sendable (String) -> String?
    private let started = Date()
    private let lock = NSLock()
    private var current: String
    private var ticker: Task<Void, Never>?

    init(ui: UI, initial: String = "starting", describe: @escaping @Sendable (String) -> String? = XcodeActivity.describe) {
        self.ui = ui
        handle = ui.renderer()
        self.describe = describe
        current = initial
    }

    /// Feed a raw output line; lines that say what's happening update the text.
    func see(_ line: String) {
        guard let text = describe(line) else { return }
        lock.withLock { current = text }
    }

    func start() {
        ticker = Task { [weak self] in
            var frame = 0
            while !Task.isCancelled {
                self?.render(frame: frame)
                frame += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        ticker?.cancel()
        handle.remove()
    }

    private func render(frame: Int) {
        let text = lock.withLock { current }
        let seconds = Int(Date().timeIntervalSince(started))
        let line = "  " + ui.format("\(.primary(Self.frames[frame % Self.frames.count]))") + " "
            + ui.format("\(.muted("\(text) · \(Self.duration(seconds))"))")
        handle.rendering.render(line, standardPipeline: RegionAwarePipeline(region: ui.region))
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }
}
