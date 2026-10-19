import ArgumentParser

/// Makes a help request that names a command `sc` doesn't have an error.
///
/// swift-argument-parser answers `--help` (and `sc help …`) for the deepest
/// command the leading words name and drops the rest, so `sc build wrapp
/// --help` printed the root help as though `build` were fine. Without `--help`
/// the same words are rejected; this rejects them with it too, before parsing.
/// It walks the real command tree, so new commands need nothing here.
enum HelpRequestCheck {
    static func validate(_ arguments: [String]) throws {
        let options = arguments.prefix { $0 != "--" }
        let candidates: ArraySlice<String>
        if options.first == "help" {
            candidates = options.dropFirst()
        } else if options.contains("--help") || options.contains("-h") {
            candidates = options
        } else {
            return
        }
        let words = candidates.filter { !$0.hasPrefix("-") }

        var command: ParsableCommand.Type = SC.self
        var path: [String] = []
        for (index, word) in words.enumerated() {
            // A leaf's words are its own arguments, as are those a group hands
            // to its default subcommand (`sc test stay-tuned`).
            if command.configuration.subcommands.isEmpty { return }
            guard let next = subcommand(of: command, named: word) else {
                if command.configuration.defaultSubcommand != nil { return }
                throw unknown(word, under: command, path: path, words: Array(words[index...]))
            }
            command = next
            path.append(word)
        }
    }

    private static func subcommand(of command: ParsableCommand.Type, named word: String) -> ParsableCommand.Type? {
        command.configuration.subcommands.first {
            $0._commandName == word || $0.configuration.aliases.contains(word)
        }
    }

    private static func unknown(_ word: String, under command: ParsableCommand.Type, path: [String], words: [String]) -> SCError {
        let parent = (["sc"] + path).joined(separator: " ")
        let names = command.configuration.subcommands.map { $0._commandName }
        var hints: [String] = []
        // The same words in a different order, e.g. `build wrapp` for `wrapp build`.
        let reordered = commandPath(from: SC.self, using: path + words)
        if reordered.contains(word) {
            hints.append("Did you mean 'sc \(reordered.joined(separator: " "))'?")
        }
        hints.append("'\(parent)' has: \(names.joined(separator: ", ")).")
        return SCError("Unknown command '\(parent) \(word)'.", hints: hints, exitCode: ExitCode.validationFailure.rawValue)
    }

    /// The deepest command path whose names all appear in `words`, in any order.
    private static func commandPath(from command: ParsableCommand.Type, using words: [String]) -> [String] {
        var remaining = words
        var command = command
        var path: [String] = []
        while let next = command.configuration.subcommands.first(where: { remaining.contains($0._commandName) }) {
            remaining.removeAll { $0 == next._commandName }
            path.append(next._commandName)
            command = next
        }
        return path
    }
}
