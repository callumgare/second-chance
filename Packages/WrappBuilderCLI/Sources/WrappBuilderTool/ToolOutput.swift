import Foundation

/// Where a command's output goes: the terminal for `wrapp-builder`, sc's
/// own output for the same command run as `sc module …` or `sc engine …`.
public nonisolated protocol ToolOutput: Sendable {
    /// A line of what's happening, or a problem found.
    func line(_ text: String)
    /// What the command was for (a plan's steps): stdout, so it can be piped.
    func result(_ text: String)
    func success(_ text: String)
    func info(_ text: String)
}

/// What a command couldn't do, said in a sentence.
public nonisolated struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Plain lines: results on stdout, everything else on stderr.
public nonisolated struct StandardOutput: ToolOutput {
    public init() {}

    public func line(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    public func result(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    public func success(_ text: String) { line("✓ " + text) }
    public func info(_ text: String) { line(text) }
}
