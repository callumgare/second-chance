import Foundation
import Noora

/// All terminal output goes through here. Status, steps, tables and alerts go
/// to stderr; `result(_:)` is the only thing written to stdout, so
/// `open "$(sc wrapp build x)"` gets just the path.
///
/// Live output (spinners, collapsing steps, redrawing tables) only happens in
/// an interactive terminal with `--logs collapsed`. Otherwise every component
/// prints plain lines, and Noora is told the terminal isn't interactive.
final class UI: @unchecked Sendable {
    let environment: TerminalEnvironment
    let mode: LogMode
    let logsDir: URL
    let noora: Noora
    /// The region every live component draws into; nil when not live.
    let region: LiveRegion?

    var isLive: Bool { region != nil }
    var canPrompt: Bool { environment.canReadKeys && isLive }

    init(environment: TerminalEnvironment, mode: LogMode, logsDir: URL) {
        self.environment = environment
        self.mode = mode
        self.logsDir = logsDir
        let live = environment.isInteractive && mode == .collapsed
        let region = live ? LiveRegion() : nil
        self.region = region
        let pipeline = RegionAwarePipeline(region: region)
        noora = Noora(
            content: Self.content,
            terminal: Terminal(
                isInteractive: live,
                isColored: environment.isColored,
                // Noora's default exits(0) on SIGINT, which would skip
                // stopping children and report success. sc handles signals.
                signalBehavior: .none
            ),
            standardPipelines: StandardPipelines(output: pipeline, error: pipeline)
        )
    }

    /// Noora's wording, with the heading over a success or info alert's
    /// list ("Takeaways" by default) saying what the list is: results.
    static let content: Content = {
        let d = Content.default
        return Content(
            errorAlertTitle: d.errorAlertTitle,
            errorAlertRecommendedTitle: d.errorAlertRecommendedTitle,
            warningAlertTitle: d.warningAlertTitle,
            warningAlertRecommendedTitle: d.warningAlertRecommendedTitle,
            successAlertTitle: d.successAlertTitle,
            successAlertRecommendedTitle: "Results",
            infoAlertTitle: d.infoAlertTitle,
            infoAlertRecommendedTitle: "Results",
            choicePromptFilterTitle: d.choicePromptFilterTitle,
            choicePromptInstructionWithoutFilter: d.choicePromptInstructionWithoutFilter,
            choicePromptInstructionWithFilter: d.choicePromptInstructionWithFilter,
            choicePromptInstructionIsFiltering: d.choicePromptInstructionIsFiltering,
            multipleChoicePromptFilterTitle: d.multipleChoicePromptFilterTitle,
            multipleChoicePromptErrorTitle: d.multipleChoicePromptErrorTitle,
            multipleChoicePromptInstructionWithoutFilter: d.multipleChoicePromptInstructionWithoutFilter,
            multipleChoicePromptInstructionWithFilter: d.multipleChoicePromptInstructionWithFilter,
            multipleChoicePromptInstructionIsFiltering: d.multipleChoicePromptInstructionIsFiltering,
            textPromptValidationErrorsTitle: d.textPromptValidationErrorsTitle,
            yesOrNoChoicePromptInstruction: d.yesOrNoChoicePromptInstruction,
            yesOrNoChoicePromptPositiveText: d.yesOrNoChoicePromptPositiveText,
            yesOrNoChoicePromptNegativeText: d.yesOrNoChoicePromptNegativeText
        )
    }()

    // MARK: - Rendering targets

    /// Where one component draws: its own slot in the live region, or plain appending output.
    func renderer(trimmable: Bool = false, pinnedToBottom: Bool = false) -> RendererHandle {
        if let region {
            return RendererHandle(slot: region.addSlot(trimmable: trimmable, pinnedToBottom: pinnedToBottom))
        }
        return RendererHandle(slot: nil)
    }

    struct RendererHandle {
        fileprivate let slot: LiveRegion.Slot?
        var rendering: Rendering { slot ?? AppendingRenderer() }
        /// Keep the component's final frame on screen, above anything still live.
        func commit() { slot?.commit() }
        func remove() { slot?.remove() }
    }

    // MARK: - Messages

    /// A plain status line on stderr, above anything live.
    func line(_ text: String) {
        if let region { region.printAbove(text) } else { TTY.write(text.hasSuffix("\n") ? text : text + "\n") }
    }

    /// A muted line, for detail under a heading.
    func detail(_ text: String) {
        line(noora.format("\(.muted(text))"))
    }

    func info(_ message: TerminalText, takeaways: [TerminalText] = []) {
        noora.info(.alert(message, takeaways: takeaways))
    }

    func success(_ message: TerminalText, takeaways: [TerminalText] = []) {
        noora.success(.alert(message, takeaways: takeaways))
    }

    func warning(_ message: TerminalText, next: TerminalText? = nil) {
        noora.warning(.alert(message, takeaway: next))
    }

    /// Several warnings under one heading.
    func warnings(_ items: [(message: TerminalText, next: TerminalText?)]) {
        guard !items.isEmpty else { return }
        noora.warning(items.map { WarningAlert.alert($0.message, takeaway: $0.next) })
    }

    func error(_ error: SCError) {
        noora.error(.alert(TerminalText(stringLiteral: error.message),
                           takeaways: error.hints.map { TerminalText(stringLiteral: $0) }))
    }

    /// The command's result, on stdout.
    func result(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    func format(_ text: TerminalText) -> String { noora.format(text) }

    // MARK: - Tables

    // Noora 0.57.5's static `table(_:renderer:)` ignores the renderer it is
    // given and draws with a fresh `Renderer()`, which would tear a live
    // region. The updating table does honour it, so every table here is an
    // updating one — a static table is one that never updates.

    static func tableData(headers: [String], rows: [StyledTableRow]) -> TableData {
        TableData(columns: headers.map { TableColumn(title: $0) }, styledRows: rows)
    }

    func table(headers: [String], rows: [StyledTableRow]) async {
        let handle = renderer()
        await noora.table(
            Self.tableData(headers: headers, rows: rows),
            updates: AsyncStream<TableData> { $0.finish() },
            renderer: handle.rendering
        )
        handle.commit()
    }

    func table(headers: [String], rows: [[String]]) async {
        await table(headers: headers, rows: rows.map { $0.map { TableCellStyle.plain($0) } })
    }

    /// A table that redraws as `update` is called, until `finish`.
    func liveTable(headers: [String], rows: [StyledTableRow] = [], trimmable: Bool = true) -> LiveTable {
        LiveTable(ui: self, headers: headers, rows: rows, trimmable: trimmable)
    }

    final class LiveTable: @unchecked Sendable {
        private let headers: [String]
        private let continuation: AsyncStream<TableData>.Continuation
        private let task: Task<Void, Never>
        private let handle: RendererHandle

        fileprivate init(ui: UI, headers: [String], rows: [StyledTableRow], trimmable: Bool) {
            self.headers = headers
            let (stream, continuation) = AsyncStream<TableData>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.continuation = continuation
            let handle = ui.renderer(trimmable: trimmable)
            self.handle = handle
            let initial = UI.tableData(headers: headers, rows: rows)
            let noora = ui.noora
            task = Task { await noora.table(initial, updates: stream, renderer: handle.rendering) }
        }

        func update(_ rows: [StyledTableRow]) {
            continuation.yield(UI.tableData(headers: headers, rows: rows))
        }

        /// Stop updating; `keep` leaves the last version on screen.
        func finish(keep: Bool) async {
            continuation.finish()
            await task.value
            if keep { handle.commit() } else { handle.remove() }
        }
    }

    // MARK: - Steps

    /// A step with a spinner whose message can change, e.g. a build stage.
    func progressStep<T>(
        _ message: String,
        success: String? = nil,
        failure: String? = nil,
        _ body: @escaping (@escaping @Sendable (String) -> Void) async throws -> T
    ) async throws -> T {
        let handle = renderer()
        do {
            let result = try await noora.progressStep(
                message: message, successMessage: success, errorMessage: failure,
                showSpinner: true, renderer: handle.rendering, task: body
            )
            handle.commit()
            return result
        } catch {
            // Stopped with Ctrl-C: drop the step rather than leave a ⨯ on screen.
            if Task.isCancelled {
                handle.remove()
                throw CancellationError()
            }
            handle.commit()
            throw error
        }
    }

    // MARK: - Prompts (interactive only)

    /// Ask the user to pick one option, or nil when there's no one to ask.
    func choose<T: Equatable & CustomStringConvertible>(_ question: String, from options: [T]) -> T? {
        guard canPrompt, !options.isEmpty else { return nil }
        return noora.singleChoicePrompt(
            title: nil, question: TerminalText(stringLiteral: question), options: options,
            description: nil, collapseOnSelection: true, filterMode: options.count > 8 ? .enabled : .disabled,
            autoselectSingleChoice: false, renderer: Renderer()
        )
    }

    func chooseSeveral<T: Equatable & CustomStringConvertible>(_ question: String, from options: [T]) -> [T]? {
        guard canPrompt, !options.isEmpty else { return nil }
        return noora.multipleChoicePrompt(
            title: nil, question: TerminalText(stringLiteral: question), options: options,
            description: nil, collapseOnSelection: true, filterMode: .disabled,
            maxLimit: .unlimited, minLimit: .limited(count: 1, errorMessage: "Pick at least one."),
            renderer: Renderer()
        )
    }

    func confirm(_ question: String, default answer: Bool = false) -> Bool? {
        guard canPrompt else { return nil }
        return noora.yesOrNoChoicePrompt(
            title: nil, question: TerminalText(stringLiteral: question), defaultAnswer: answer,
            description: nil, collapseOnSelection: true, renderer: Renderer()
        )
    }
}

/// Noora writes some output straight to its pipelines (alerts, non-live
/// steps). While a live region is on screen, that output has to go above it
/// rather than through it.
struct RegionAwarePipeline: StandardPipelining {
    let region: LiveRegion?

    func write(content: String) {
        if let region, region.isActive {
            region.printAbove(content)
        } else {
            TTY.write(content)
        }
    }
}

// Noora's table values are immutable structs and enums of strings, but aren't
// declared Sendable; live tables pass them from the polling loop to the
// rendering task.
extension TableData: @retroactive @unchecked Sendable {}
extension TableCellStyle: @retroactive @unchecked Sendable {}
