//
//  ReportPreview.swift
//  Shared
//
//  What a failure report would send, for the person to look over before
//  choosing: the details both levels carry, and the files only a detailed
//  one adds, redacted exactly as they would be sent (`ReportBundle.stage`).
//  Shown by `ReportPreviewWindow`.

import Foundation
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.Shared.Reporting")

nonisolated struct ReportPreview: Sendable {

    struct Field: Sendable, Hashable {
        let label: String
        let value: String
    }

    struct File: Sendable, Identifiable, Hashable {
        enum Content: Sendable, Hashable {
            case text(String)
            case image(URL)
        }
        /// The file's path inside the report's zip.
        let id: String
        let content: Content
    }

    /// In every report, basic or detailed.
    var fields: [Field]
    /// Only in a detailed report.
    var detailedFields: [Field] = []
    var files: [File] = []
    /// Where the files were put together; removed when the preview closes.
    var directory: URL?

    func removeFiles() {
        guard let directory else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.warning("Couldn't remove the report preview's files: \(error.localizedDescription)")
        }
    }

    // MARK: Making one

    /// A failure's report, as `FailureReporter.sendNow` would put it together
    /// now. Slow (screenshots, the diagnostics bundle, redacting the log):
    /// call it off the main actor.
    static func failure(_ report: FailureReport, process: FailureReporter.Process) async -> ReportPreview {
        let redactor = ReportRedactor.current
        var tags = report.tags
        if let game = report.game { tags["game"] = game }
        if let source = report.source { tags["source"] = source }
        if let engine = report.engine { tags["engine"] = engine }
        var fields = common(process: process)
        fields.append(Field(label: String(localized: "What failed"), value: report.what))
        fields.append(Field(label: String(localized: "How it failed"), value: report.kind))
        if let stage = report.stage { fields.append(Field(label: String(localized: "Step"), value: stage)) }
        fields += tagFields(tags, redactor: redactor)

        var preview = ReportPreview(fields: fields)
        if let summary = report.summary {
            preview.detailedFields = [Field(label: String(localized: "Summary of the failure"), value: redactor.redact(summary))]
        }
        let directory = workDirectory()
        preview.directory = directory
        let diagnostics = await report.diagnostics?()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let screenshots: [URL] = if let taken = report.screenshots {
                taken.files
            } else {
                await WindowScreenshots.capture(into: directory)
            }
            let staging = try ReportBundle.stage(log: LogExporter.render(), diagnostics: diagnostics,
                                                 screenshots: screenshots, redactor: redactor, in: directory)
            preview.files = files(in: staging)
        } catch {
            logger.error("Couldn't put together the files for the report preview: \(ErrorChain.describe(error))")
        }
        return preview
    }

    /// A crash from the previous run, as `FailureReporter.resend` would send
    /// it. Quick enough to make on the main thread, as the alert asking about
    /// the crash has to: no screenshots, and no zip.
    static func previousRunCrash(exception: String, tags: [String: String], log: URL?, crashReport: URL?,
                                 process: FailureReporter.Process) -> ReportPreview {
        let redactor = ReportRedactor.current
        var fields = common(process: process)
        fields.append(Field(label: String(localized: "What happened"), value: redactor.redact(exception)))
        fields.append(Field(label: String(localized: "Where"),
                            value: String(localized: "Which part of the code each thread was running when it crashed")))
        fields += tagFields(tags, redactor: redactor)

        var preview = ReportPreview(fields: fields)
        let directory = workDirectory()
        preview.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let text = try log.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
            let staging = try ReportBundle.stage(log: text ?? "[no log was kept for the run that crashed]\n",
                                                 diagnostics: nil, crashReport: crashReport, redactor: redactor, in: directory)
            preview.files = files(in: staging)
        } catch {
            logger.error("Couldn't put together the files for the crash report preview: \(ErrorChain.describe(error))")
        }
        return preview
    }

    private static func workDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("second-chance-report-preview-\(UUID().uuidString)", isDirectory: true)
    }

    /// What every report says about the Mac and this copy of Second Chance.
    private static func common(process: FailureReporter.Process) -> [Field] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let place = switch process {
        case .app: String(localized: "Second Chance")
        case .wrapp: String(localized: "The game's app")
        }
        return [
            Field(label: String(localized: "Second Chance version"), value: String(localized: "\(version) (build \(build))")),
            Field(label: String(localized: "macOS version"), value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            Field(label: String(localized: "Mac"), value: "\(RunContext.machineModel()), \(RunContext.processArchitecture)"),
            Field(label: String(localized: "Memory"), value: "\(ProcessInfo.processInfo.physicalMemory >> 30) GB"),
            Field(label: String(localized: "Memory running short"), value: FailureReporter.worstMemoryPressure),
            Field(label: String(localized: "Opened from a temporary copy"),
                  value: AppTranslocation.isTranslocated() ? String(localized: "Yes") : String(localized: "No")),
            Field(label: String(localized: "Where it happened"), value: place),
            Field(label: String(localized: "Installation ID"),
                  value: String(localized: "A random number for this copy of Second Chance, not linked to you")),
        ]
    }

    /// Tags worth showing, by name, in a fixed order; any others after them.
    private static let tagLabels: [(key: String, label: String)] = [
        ("game", String(localized: "Game")),
        ("source", String(localized: "Installed from")),
        ("engine", String(localized: "Engine")),
        ("caused_by", String(localized: "Caused by")),
        ("exit_code", String(localized: "Exit code")),
        ("signal", String(localized: "Signal")),
        ("copy_protection", String(localized: "Copy protection")),
    ]

    /// Tags the preview's own fields already cover, or `FailureReporter`
    /// sets as it sends.
    private static let coveredTags: Set<String> = [
        "process", "translocated", "memory", "memory_pressure", "report_detail", "crash", "stage",
    ]

    private static func tagFields(_ tags: [String: String], redactor: ReportRedactor) -> [Field] {
        var remaining = tags.filter { !coveredTags.contains($0.key) }
        var fields: [Field] = []
        for (key, label) in tagLabels {
            if let value = remaining.removeValue(forKey: key) { fields.append(Field(label: label, value: redactor.redact(value))) }
        }
        fields += remaining.sorted { $0.key < $1.key }.map { Field(label: $0.key, value: redactor.redact($0.value)) }
        return fields
    }

    /// The staged files, the log first, then by path.
    private static func files(in staging: URL) -> [File] {
        guard let walker = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        // Resolved, as the walker may name the folder by another path
        // (/private/var for /var).
        let root = staging.resolvingSymlinksInPath().path
        var files: [File] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))
            if url.pathExtension.lowercased() == "png" {
                files.append(File(id: path, content: .image(url)))
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                files.append(File(id: path, content: .text(text)))
            }
        }
        return files.sorted { lhs, rhs in
            if lhs.id == ReportBundle.logFileName { return true }
            if rhs.id == ReportBundle.logFileName { return false }
            return lhs.id < rhs.id
        }
    }
}
