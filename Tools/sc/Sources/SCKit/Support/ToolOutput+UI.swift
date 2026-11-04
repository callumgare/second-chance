import Foundation
import Noora
import WrappBuilderTool

/// sc's output for the builder tool's commands, which sc runs as its own
/// (`sc module`, `sc engine`).
struct UIToolOutput: ToolOutput {
    let ui: UI

    func line(_ text: String) { ui.line(text) }
    func result(_ text: String) { ui.result(text) }
    func success(_ text: String) { ui.success(TerminalText(stringLiteral: text)) }
    func info(_ text: String) { ui.info(TerminalText(stringLiteral: text)) }
}

extension Session {
    /// The builder tool's output, through sc's.
    var toolOutput: UIToolOutput { UIToolOutput(ui: ui) }
}

/// A command the builder's tool refused, as sc's error.
func runTool<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as ToolError {
        throw SCError(error.description)
    }
}
