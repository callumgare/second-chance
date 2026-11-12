//
//  WineDriveFailure.swift
//  WineKit
//
//  Why a drive letter couldn't be set, in words a basic report can carry.

import Foundation
import WrappLogging

nonisolated extension WineDrives {
    /// Why a drive letter couldn't be set: which step failed, and what was
    /// at the entry and the folder above it when it did. A report's `kind`
    /// names the step (`WineDrives.Failure.placingEntry`), its tags say what
    /// was found, and its `caused_by` the system's error. A launch that
    /// couldn't mount the saves once reported only "file exists"
    /// (`NSCocoaErrorDomain 516`), which `dosdevices` being a file and a link
    /// left at `a:` both give.
    ///
    /// Its `localizedDescription` is the system error's, which the wrapp
    /// shows the player; `description`, which the log has, says it all.
    public enum Failure: Error, CustomNSError, ReportTaggedError, CustomStringConvertible {
        /// `dosdevices` couldn't be made.
        case makingDrivesFolder(Detail)
        /// The link or blocking file couldn't be made under its own name in
        /// `dosdevices`, before being renamed into place.
        case makingEntry(Detail)
        /// It couldn't be renamed over the drive's name.
        case placingEntry(Detail)

        public struct Detail: Sendable {
            /// The entry's name: `a:`, `y::`, or `dosdevices`.
            public let entry: String
            /// Its path, for the log alone.
            public let path: String
            /// What was at `path` once the step had failed.
            public let found: Found
            /// What was at the folder holding it.
            public let foundAbove: Found
            public let underlying: Error
        }

        public var detail: Detail {
            switch self {
            case .makingDrivesFolder(let detail), .makingEntry(let detail), .placingEntry(let detail): detail
            }
        }

        private var step: String {
            switch self {
            case .makingDrivesFolder: "make the drives folder"
            case .makingEntry: "make a drive's entry"
            case .placingEntry: "put a drive's entry in place"
            }
        }

        public var description: String {
            "Couldn't \(step) at \(detail.path): found \(detail.found.rawValue) there "
                + "and \(detail.foundAbove.rawValue) above it: \(detail.underlying)"
        }

        /// The entry's name is one of Wine's (`a:`, `y::`) or `dosdevices`:
        /// fixed words, never a path.
        public var reportTags: [String: String] {
            ["drive_entry": detail.entry, "found": detail.found.rawValue, "found_above": detail.foundAbove.rawValue]
        }

        public static var errorDomain: String { "WineDrives.Failure" }

        public var errorCode: Int {
            switch self {
            case .makingDrivesFolder: 1
            case .makingEntry: 2
            case .placingEntry: 3
            }
        }

        public var errorUserInfo: [String: Any] {
            [NSUnderlyingErrorKey: detail.underlying as NSError,
             NSLocalizedDescriptionKey: detail.underlying.localizedDescription]
        }
    }

    /// What is at a path, without following a link there, in fixed words.
    public enum Found: String, Sendable {
        case nothing
        case folder
        case file
        case linkToFolder = "link-to-folder"
        case linkToFile = "link-to-file"
        case linkToOther = "link-to-other"
        case brokenLink = "broken-link"
        case other
        /// Something is there, but it couldn't be looked at (`EACCES`).
        case unreadable

        public var isLink: Bool {
            switch self {
            case .linkToFolder, .linkToFile, .linkToOther, .brokenLink: true
            default: false
            }
        }

        public static func at(_ path: String) -> Found {
            var info = stat()
            guard lstat(path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .nothing : .unreadable }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: return .folder
            case S_IFREG: return .file
            case S_IFLNK:
                var target = stat()
                guard stat(path, &target) == 0 else { return .brokenLink }
                switch target.st_mode & S_IFMT {
                case S_IFDIR: return .linkToFolder
                case S_IFREG: return .linkToFile
                default: return .linkToOther
                }
            default: return .other
            }
        }
    }
}
