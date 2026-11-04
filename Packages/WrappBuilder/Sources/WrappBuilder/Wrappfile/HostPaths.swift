//
//  HostPaths.swift
//  WrappBuilder
//
//  Which of a bundle's or module's files a build may read.

import Foundation

/// Where on the Mac a build may read files for a Wrappfile
/// (docs/wrappfile.md#what-a-build-may-read): folders of the bundle's or
/// module's own that it's allowed (`allow-paths`), given by the caller for a
/// bundle, by `module.yaml` for a module; or anywhere, with `*`. A file is
/// never allowed for being beside the Wrappfile.
public nonisolated struct HostPaths: Sendable, Equatable {
    /// Folders relative to the bundle's or module's folder, ending in `/`.
    public var allowed: [String]
    /// `--allow-path=*`: any path, for someone trying out a Wrappfile.
    public var any: Bool

    public init(allowed: [String] = [], any: Bool = false) {
        self.allowed = allowed.filter { $0 != "*" }
        self.any = any || allowed.contains("*")
    }

    /// Whether `relative`, a path in the bundle's or module's folder, may be
    /// read: one that goes above it never may.
    public func allows(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        guard !relative.hasPrefix("/"), !parts.contains("..") else { return false }
        if any { return true }
        return allowed.contains { folder in
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return relative.hasPrefix(prefix)
        }
    }

    /// The ways `relative` could be allowed, for the error refusing it.
    static func howToAllow(_ relative: String, of granter: String) -> String {
        let folder = (relative as NSString).deletingLastPathComponent
        return "Allow its folder in \(granter)'s allow-paths (\"\(folder.isEmpty ? "." : folder)/\"), pass it as an input, "
            + "pin it with --checksum=sha256:<hash>, or build with --allow-path"
    }
}
