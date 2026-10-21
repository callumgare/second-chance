import ArgumentParser
import Foundation

/// What a debug option turns into for the program being run.
struct DebugEffect: Equatable, Sendable {
    var arguments: [String] = []
    var environment: [String: String] = [:]

    mutating func merge(_ other: DebugEffect) {
        arguments += other.arguments.filter { !arguments.contains($0) }
        environment.merge(other.environment) { _, new in new }
    }
}

/// The program a `--debug` value is for.
enum DebugTarget: Sendable {
    /// Second Chance.app run interactively (`sc app run`).
    case app
    /// Second Chance.app building a wrapp headlessly (`sc wrapp build`).
    case wrappBuild
    /// A wrapp (`sc wrapp run`).
    case wrapp
}

/// Every `--debug` value, in one table: adding a switch is adding a row.
struct DebugOption: Sendable {
    let name: String
    /// Name of the value it takes (`wine=<channels>`), or nil for a plain switch.
    let valueName: String?
    let help: String
    let targets: Set<DebugTarget>
    let effect: @Sendable (String?) -> DebugEffect

    static let all: [DebugOption] = [
        DebugOption(name: "log-window", valueName: nil,
                    help: "Show the floating log window.",
                    targets: [.app, .wrappBuild, .wrapp]) { _ in DebugEffect(arguments: ["--debug"]) },
        DebugOption(name: "skip-installer", valueName: nil,
                    help: "Don't run the game's installer (tests wrapp construction only).",
                    targets: [.app, .wrappBuild]) { _ in DebugEffect(arguments: ["--skip-installer"]) },
        DebugOption(name: "strict-install", valueName: nil,
                    help: "Don't fall back to an interactive install when the silent one fails.",
                    targets: [.wrappBuild]) { _ in DebugEffect(environment: ["STRICT_INSTALL": "true"]) },
        DebugOption(name: "settings-dialog", valueName: nil,
                    help: "Show the wrapp's debug settings dialog before launching.",
                    targets: [.wrapp]) { _ in DebugEffect(arguments: ["--debug-options"]) },
        DebugOption(name: "wine", valueName: "channels",
                    help: "Wine debug channels (WINEDEBUG), e.g. wine=+seh,+d3d9. Per-frame channels log a lot.",
                    targets: [.app, .wrappBuild, .wrapp]) { DebugEffect(environment: ["SECOND_CHANCE_WINEDEBUG": $0 ?? ""]) },
        DebugOption(name: "keep-in-dock", valueName: nil,
                    help: "Don't hide the wrapp from the Dock once the game starts.",
                    targets: [.wrapp]) { _ in DebugEffect(environment: ["SECOND_CHANCE_KEEP_IN_DOCK": "1"]) },
        DebugOption(name: "no-native-fullscreen", valueName: nil,
                    help: "Leave native fullscreen unarmed.",
                    targets: [.wrapp]) { _ in DebugEffect(environment: ["SECOND_CHANCE_NATIVE_FULLSCREEN": "0"]) },
        DebugOption(name: "no-cursor-lock", valueName: nil,
                    help: "Leave the cnc-ddraw cursor lock unarmed.",
                    targets: [.wrapp]) { _ in DebugEffect(environment: ["SECOND_CHANCE_CURSOR_LOCK": "0"]) },
        DebugOption(name: "no-mode-scaling", valueName: nil,
                    help: "Leave Direct3D unscaled when Wine emulates the game's display mode.",
                    targets: [.wrapp]) { _ in DebugEffect(environment: ["SECOND_CHANCE_MODE_SCALING": "0"]) },
        DebugOption(name: "no-prestart-desktop", valueName: nil,
                    help: "Let Wine start its desktop on demand instead of before the game.",
                    targets: [.wrapp]) { _ in DebugEffect(environment: ["SECOND_CHANCE_PRESTART_DESKTOP": "0"]) },
        DebugOption(name: "no-diagnostics", valueName: nil,
                    help: "Don't capture a diagnostics bundle when the game starts badly.",
                    targets: [.wrapp]) { _ in DebugEffect(environment: ["SECOND_CHANCE_DIAGNOSTICS": "0"]) },
        DebugOption(name: "reporting", valueName: nil,
                    help: "Send failure reports from this Debug build (needs SECOND_CHANCE_SENTRY_DSN or a DSN in the build).",
                    targets: [.app, .wrappBuild, .wrapp]) { _ in DebugEffect(environment: ["SECOND_CHANCE_REPORTING": "1"]) },
        DebugOption(name: "slow-start", valueName: "seconds",
                    help: "Seconds without a window before a slow-start diagnostics bundle (1 forces one).",
                    targets: [.wrapp]) { DebugEffect(environment: ["SECOND_CHANCE_DIAG_SLOW_SECONDS": $0 ?? ""]) },
    ]

    static func available(for target: DebugTarget) -> [DebugOption] {
        all.filter { $0.targets.contains(target) }
    }

    var usage: String { valueName.map { "\(name)=<\($0)>" } ?? name }

    /// The help text listing a target's options, for `--help` and `--debug help`.
    static func helpText(for target: DebugTarget) -> String {
        let options = available(for: target)
        let width = options.map(\.usage.count).max() ?? 0
        return options.map { "\($0.usage.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.help)" }
            .joined(separator: "\n")
    }

    /// Parse `--debug` values (each may be comma-separated) into one effect.
    ///
    /// Commas separate options, except inside a value: in
    /// `log-window,wine=+seh,+d3d9` the `+d3d9` isn't an option name, so it
    /// continues `wine`'s value.
    static func resolve(_ values: [String], for target: DebugTarget) throws -> DebugEffect {
        let options = available(for: target)
        let known = Set(all.map(\.name))
        var items: [(name: String, value: String?)] = []
        for value in values {
            for segment in value.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
                let name = segment.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                if !known.contains(name), let last = items.last, last.value != nil {
                    items[items.count - 1].value = (last.value ?? "") + "," + segment
                    continue
                }
                guard !segment.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let parts = segment.split(separator: "=", maxSplits: 1).map(String.init)
                items.append((parts[0].trimmingCharacters(in: .whitespaces), parts.count > 1 ? parts[1] : nil))
            }
        }

        var effect = DebugEffect()
        for item in items {
            guard let option = options.first(where: { $0.name == item.name }) else {
                throw ValidationError("Unknown --debug value '\(item.name)'. Choose from:\n\(helpText(for: target))")
            }
            if option.valueName != nil, item.value?.isEmpty ?? true {
                throw ValidationError("--debug \(option.name) needs a value: \(option.usage)")
            }
            if option.valueName == nil, item.value != nil {
                throw ValidationError("--debug \(option.name) doesn't take a value.")
            }
            effect.merge(option.effect(item.value))
        }
        return effect
    }
}

// One options group per target, so each command's --help lists just its own values.

private func debugHelp(_ target: DebugTarget) -> ArgumentHelp {
    ArgumentHelp(
        "Debug behaviour to switch on (repeatable, or comma-separated). `--debug help` lists them.",
        discussion: DebugOption.helpText(for: target),
        valueName: "option"
    )
}

private func checkForHelp(_ values: [String], target: DebugTarget) throws {
    if values.contains("help") {
        throw CleanExit.message("--debug options:\n\(DebugOption.helpText(for: target))")
    }
}

struct AppDebugOptions: ParsableArguments {
    @Option(name: .customLong("debug"), help: debugHelp(.app))
    var values: [String] = []

    func validate() throws {
        try checkForHelp(values, target: .app)
        _ = try DebugOption.resolve(values, for: .app)
    }

    func effect() throws -> DebugEffect { try DebugOption.resolve(values, for: .app) }
}

struct WrappBuildDebugOptions: ParsableArguments {
    @Option(name: .customLong("debug"), help: debugHelp(.wrappBuild))
    var values: [String] = []

    func validate() throws {
        try checkForHelp(values, target: .wrappBuild)
        _ = try DebugOption.resolve(values, for: .wrappBuild)
    }

    func effect() throws -> DebugEffect { try DebugOption.resolve(values, for: .wrappBuild) }
}

struct WrappDebugOptions: ParsableArguments {
    @Option(name: .customLong("debug"), help: debugHelp(.wrapp))
    var values: [String] = []

    func validate() throws {
        try checkForHelp(values, target: .wrapp)
        _ = try DebugOption.resolve(values, for: .wrapp)
    }

    func effect() throws -> DebugEffect { try DebugOption.resolve(values, for: .wrapp) }
}
