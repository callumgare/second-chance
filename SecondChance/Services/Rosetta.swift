//
//  Rosetta.swift
//  SecondChance
//
//  Wine is x86_64, so on Apple silicon every Wine program runs under Rosetta,
//  which macOS doesn't install until something asks for it. Opening an
//  Intel-only app from the Finder makes macOS offer it, but Second Chance is
//  universal, and Wine started from a shell just fails: `sh` reports "Bad CPU
//  type in executable" and exits 126, so a build stops at its first Wine
//  program with `WineError.executionFailed`. So a build checks first and
//  offers to install it (`WrappBuildInput.ensureRosetta`).
//
//  A wrapp needs no check of its own: its executable is x86_64 only, so
//  without Rosetta none of its code would run, and macOS offers Rosetta when
//  it is opened, as for any Intel app.
//

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.Rosetta")

nonisolated enum Rosetta {

    enum InstallOutcome: Equatable {
        case installed
        /// The person cancelled macOS's password prompt.
        case cancelled
        /// `softwareupdate` failed, or Rosetta still doesn't run afterwards.
        case failed(reason: String)
    }

    /// Whether this Mac can run x86_64 programs: by running one, the way
    /// Wine would be run, rather than by looking for Rosetta's files.
    static func isInstalled() async -> Bool {
        #if arch(x86_64)
        // An Intel Mac, or this process is already running under Rosetta.
        return true
        #else
        do {
            let result = try await Process.output(of: "/usr/bin/arch", ["-x86_64", "/usr/bin/true"])
            if !result.succeeded {
                let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                logger.warning("Rosetta isn't installed: arch -x86_64 exited \(result.status): \(detail)")
            }
            return result.succeeded
        } catch {
            // Couldn't even ask: let the build find out for itself.
            logger.error("Couldn't check for Rosetta: \(ErrorChain.describe(error))")
            return true
        }
        #endif
    }

    /// Install Rosetta with `softwareupdate`, which needs an administrator:
    /// macOS asks for a password through `osascript`.
    static func install() async -> InstallOutcome {
        logger.notice("Installing Rosetta")
        let command = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"
        let prompt = "Second Chance wants to install Rosetta, which the games need."
        let script = "do shell script \"\(command)\" with administrator privileges with prompt \"\(prompt)\""
        let result: ProcessOutput
        do {
            result = try await Process.output(of: "/usr/bin/osascript", ["-e", script])
        } catch {
            logger.error("Couldn't run osascript to install Rosetta: \(ErrorChain.describe(error))")
            return .failed(reason: error.localizedDescription)
        }
        let output = (result.output + result.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        // AppleScript's userCanceledErr.
        if result.errorOutput.contains("(-128)") {
            logger.notice("The person cancelled installing Rosetta")
            return .cancelled
        }
        guard result.succeeded else {
            logger.error("Installing Rosetta failed (osascript exited \(result.status)): \(output)")
            return .failed(reason: output)
        }
        guard await isInstalled() else {
            logger.error("softwareupdate said it installed Rosetta, but it still doesn't run: \(output)")
            return .failed(reason: output)
        }
        logger.notice("Installed Rosetta")
        return .installed
    }
}
