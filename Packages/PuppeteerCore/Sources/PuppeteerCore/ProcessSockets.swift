//
//  ProcessSockets.swift
//  WrappPuppeteer
//
//  Finding the processes serving control sockets in a directory, by the
//  sockets' names.

import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.ProcessSockets")

/// The processes serving control sockets named after their own PID,
/// `<prefix><pid>.sock`, in a directory.
///
/// A directory private to one run holds only sockets of processes that run
/// started, so this finds them directly: no name to match, and nothing of
/// the same name started elsewhere (another wrapp, another test) counts.
nonisolated public enum ProcessSockets {
    /// The PIDs, lowest first, of the live processes with a socket in
    /// `directory`. A socket outlives its process, so one whose process has
    /// gone is left out.
    public static func livePids(in directory: String, prefix: String) -> [Int32] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            logger.debug("Couldn't list \(directory): \(error)")
            return []
        }
        return names.compactMap { pid(fromSocketNamed: $0, prefix: prefix) }
            .filter(ProcessControl.isAlive)
            .sorted()
    }

    /// The PID in a socket's name, `<prefix><pid>.sock`, or nil for any
    /// other name.
    static func pid(fromSocketNamed name: String, prefix: String) -> Int32? {
        guard name.hasPrefix(prefix), name.hasSuffix(".sock") else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(".sock".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }
}
