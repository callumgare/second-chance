//
//  IconCompile.swift
//  ProcessKit
//
//  An Icon Composer icon (`.icon`) compiled to the `.icns` an app's
//  Info.plist names, by Xcode's actool. `sc generate` compiles the bundles'
//  and modules' icons with it, and Icon Lab its designs.

import Foundation

nonisolated public enum IconCompile {
    public struct Failure: LocalizedError, Sendable {
        public let icon: URL
        public let detail: String
        public var errorDescription: String? { "actool couldn't compile \(icon.lastPathComponent): \(detail)" }
    }

    /// `icon` compiled as the app icon called `name`, as `.icns` bytes. Needs Xcode (`xcrun actool`); actool's output
    /// is the same for the same icon.
    public static func icns(from icon: URL, name: String) async throws -> Data {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("icon-compile-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }
        let compiled = try await Process.output(of: "/usr/bin/xcrun", [
            "actool", icon.path, "--compile", scratch.path, "--app-icon", name,
            "--platform", "macosx", "--minimum-deployment-target", "15.0",
            "--output-partial-info-plist", scratch.appendingPathComponent("partial.plist").path,
        ])
        let made = scratch.appendingPathComponent("\(name).icns")
        guard compiled.succeeded, let data = try? Data(contentsOf: made) else {
            throw Failure(icon: icon, detail: compiled.errorOutput.isEmpty ? compiled.output : compiled.errorOutput)
        }
        return data
    }
}
