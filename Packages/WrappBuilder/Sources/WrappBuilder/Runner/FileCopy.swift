//
//  FileCopy.swift
//  WrappBuilder
//
//  Copying into a tree, archives, and .ini files: what the core's
//  instructions are made of.

import Foundation
import ProcessKit

/// Copies into a tree: a folder's contents merged with what's there, a
/// file's contents alone.
nonisolated enum FileCopy {
    /// `source` into `destination`: a folder's contents merged in (a file of
    /// the same name replaced, as a later disc's are by an earlier's), a
    /// file to `destination`, or into it with `intoFolder`.
    static func copy(_ source: URL, to destination: URL, intoFolder: Bool) throws {
        let files = FileManager.default
        var isFolder: ObjCBool = false
        let resolved = source.resolvingSymlinksInPath()
        guard files.fileExists(atPath: resolved.path, isDirectory: &isFolder) else {
            throw StepFailure.failed("there's nothing at \(source.path) to copy")
        }
        if isFolder.boolValue {
            try merge(resolved, into: destination)
        } else {
            let target = intoFolder ? destination.appendingPathComponent(source.lastPathComponent) : destination
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try copyFile(resolved, to: target)
        }
    }

    static func merge(_ from: URL, into: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: into, withIntermediateDirectories: true)
        // A disc's folders and files are read-only; the app's copies needn't
        // be, or a later one couldn't replace them, nor the app be removed.
        _ = chmod(into.path, 0o755)
        // AppleDouble files (`._name`) are a Mac file's resource fork and
        // Finder info, as a hybrid disc's ISO side lists them.
        for name in try files.contentsOfDirectory(atPath: from.path) where !name.hasPrefix("._") {
            let source = from.appendingPathComponent(name), target = into.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            files.fileExists(atPath: source.path, isDirectory: &isFolder)
            var targetIsFolder: ObjCBool = false
            let exists = files.fileExists(atPath: target.path, isDirectory: &targetIsFolder)
            if exists, !(isFolder.boolValue && targetIsFolder.boolValue) { try files.removeItem(at: target) }
            if isFolder.boolValue {
                try merge(source, into: target)
            } else {
                try copyFile(source, to: target)
            }
        }
    }

    /// A file's contents alone: a resource fork or Finder info would fail
    /// the app's codesign.
    static func copyFile(_ source: URL, to target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: target.path,
                NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
            ])
        }
        _ = chmod(target.path, 0o644)
    }

    /// `source` at `target` as a clone (`clonefile`, nothing to copy on the
    /// same volume), or a copy where it can't be cloned.
    static func clone(_ source: URL, to target: URL) throws {
        if Darwin.clonefile(source.path, target.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: target)
    }
}

/// Archives a step's download comes in.
nonisolated enum Archive {
    /// The download itself, or with `unpack=zip` its member, in `work`
    /// (which the caller removes).
    static func member(of download: URL, named member: String?, unpack: String?, in work: URL,
                       called name: String, origin: String) async throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard unpack == "zip", let member else {
            let copy = work.appendingPathComponent(name.isEmpty ? download.lastPathComponent : name)
            try await Blocking.run { try FileCopy.clone(download, to: copy) }
            return copy
        }
        try await unzip(download, into: work, origin: origin)
        // The step names the member exactly: filenames follow no pattern
        // worth guessing at.
        let found = work.appendingPathComponent(member)
        guard FileManager.default.fileExists(atPath: found.path) else {
            throw StepFailure.failed("\(origin): \(name) has no \(member)")
        }
        return found
    }

    /// `archive` unpacked into `folder`, overwriting, so a rebuild is the same.
    static func unzip(_ archive: URL, into folder: URL, origin: String) async throws {
        let result = try await Process.output(of: "/usr/bin/unzip", ["-q", "-o", archive.path, "-d", folder.path])
        guard result.succeeded else { throw StepFailure.failed("\(origin): \(archive.lastPathComponent) couldn't be unzipped") }
    }
}

/// `EDIT --ini`: settings changed in an .ini file's sections, or added.
public nonisolated enum IniEdit {
    public struct Setting: Sendable, Equatable, CustomStringConvertible {
        public let section: String
        public let key: String
        public let value: String

        public init(section: String, key: String, value: String) {
            self.section = section
            self.key = key
            self.value = value
        }

        /// `<section>.<key>=<value>`.
        public init?(_ text: String) {
            guard let equals = text.firstIndex(of: "="), let dot = text[..<equals].firstIndex(of: ".") else { return nil }
            self.init(section: String(text[..<dot]), key: String(text[text.index(after: dot)..<equals]),
                      value: String(text[text.index(after: equals)...]))
        }

        public var description: String { "\(section).\(key)=\(value)" }
    }

    /// `text`, an .ini file's, with `settings` set: the lines changed, and
    /// those not there added at the end of their section (or a new one),
    /// or with `keysMustExist`, named as missing. Its line endings are kept:
    /// Windows programs' files (cnc-ddraw's) end lines with CRLF.
    public static func edit(_ text: String, settings: [Setting], keysMustExist: Bool) -> (text: String, missing: [String]) {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: newline)
        var missing: [String] = []
        for setting in settings {
            var section = ""
            var sectionEnd: Int?
            var found = false
            for index in lines.indices {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    section = String(line.dropFirst().dropLast())
                    continue
                }
                guard section.caseInsensitiveCompare(setting.section) == .orderedSame else { continue }
                sectionEnd = index + 1
                guard let equals = line.firstIndex(of: "="),
                      line[..<equals].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(setting.key) == .orderedSame
                else { continue }
                lines[index] = "\(line[..<equals].trimmingCharacters(in: .whitespaces))=\(setting.value)"
                found = true
            }
            guard !found else { continue }
            if keysMustExist {
                missing.append("\(setting.section).\(setting.key)")
            } else if let sectionEnd {
                lines.insert("\(setting.key)=\(setting.value)", at: sectionEnd)
            } else {
                lines += ["[\(setting.section)]", "\(setting.key)=\(setting.value)"]
            }
        }
        return (lines.joined(separator: newline), missing)
    }
}
