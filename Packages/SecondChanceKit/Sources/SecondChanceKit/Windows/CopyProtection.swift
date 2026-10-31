//
//  CopyProtection.swift
//  Shared
//
//  The disc copy protection a game's .exe is wrapped in, told by the
//  sections the wrapper adds to it. Such a wrapper checks the disc through a
//  Windows driver Wine doesn't have, so a wrapped game may not start. It is
//  only logged and tagged on a failure report, not acted on: nothing yet
//  shows a game failing because of it. Sentry SECOND-CHANCE-J, two games
//  from unrecognised discs that died with an illegal instruction a second
//  in, with .exes importing no graphics DLL, is the case it is there to
//  explain or rule out. Only names that belong to a wrapper alone are
//  matched, so a game that merely shares a packer isn't taken for one.

import Foundation

nonisolated public enum CopyProtection: String, Equatable, Sendable {
    case secuROM = "securom"
    case safeDisc = "safedisc"
    case starForce = "starforce"

    /// The protection `url` is wrapped in, or nil when it has none we know
    /// of, or isn't a Windows program.
    public init?(exeAt url: URL) {
        guard let exe = WindowsExecutable(contentsOf: url) else { return nil }
        self.init(sectionNames: exe.sectionNames)
    }

    public init?(sectionNames: [String]) {
        let names = sectionNames.map { $0.lowercased() }
        if names.contains(where: { [".securom", ".cms_t", ".cms_d"].contains($0) }) {
            self = .secuROM
        } else if names.contains(where: { ["stxt774", "stxt371"].contains($0) }) {
            self = .safeDisc
        } else if names.contains(where: { $0.hasPrefix(".sforce") }) {
            self = .starForce
        } else {
            return nil
        }
    }

    /// Its maker's name for it, for a log line.
    public var name: String {
        switch self {
        case .secuROM: return "SecuROM"
        case .safeDisc: return "SafeDisc"
        case .starForce: return "StarForce"
        }
    }
}
