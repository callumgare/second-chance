//
//  FullscreenSetting.swift
//  WrappFormat
//
//  Where a Wine game keeps its own fullscreen setting, as its launch says
//  (`LAUNCH --wine.fullscreen-setting=…`), so the wrapp can keep it in step
//  with the player's use of the window's fullscreen button
//  (docs/wine-in-process-helpers.md#the-players-choice-kept).

import Foundation
import WindowsFormats

/// A value at a place in a file: the game's fullscreen setting.
///
/// Written `file=<Windows path>,format=allegro-packfile|bytes,offset=<n>,bytes=<1|2|4|8>,fullscreen=<value>,windowed=<value>`,
/// each value an integer (`-1`, `0`, `0xFF`), stored little-endian in
/// `bytes` bytes. `allegro-packfile` reads the file through
/// `AllegroPackfile` and counts the offset in what it holds; `bytes` counts
/// it in the file as it is. A file that checks itself with a sum takes
/// `checksum-offset=<n>,checksum-scale=<n>` as well: the sum, the same
/// width as the value, counts the value `checksum-scale` times, so it moves
/// by that many times the value's change (Icy Tower's is 17 × the sum of
/// its settings and 28, at 96).
nonisolated public struct FullscreenSetting: Sendable, Equatable {
    public enum Format: String, Sendable, CaseIterable {
        case allegroPackfile = "allegro-packfile"
        case bytes
    }

    /// The file, in Wine: `C:/IcyTower/tower.cfg`.
    public var file: String
    public var format: Format
    public var offset: Int
    public var width: Int
    /// The value's bytes, little-endian, for each choice.
    public var fullscreen: Data
    public var windowed: Data
    /// Where the file's sum of its settings is, and how many times it
    /// counts the value: nil for a file with none.
    public var checksum: Checksum?

    public struct Checksum: Sendable, Equatable {
        public var offset: Int
        public var scale: Int64
    }

    /// The option's name, as a launch records it.
    public static let option = "wine.fullscreen-setting"

    /// The option's text, checked: throws a message saying what's wrong.
    public init(parsing text: String) throws(ParseError) {
        var fields: [String: String] = [:]
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else {
                throw ParseError("\"\(part)\" isn't <name>=<value>")
            }
            guard Self.fields.contains(pair[0]) else {
                throw ParseError("it has no \(pair[0]): it takes \(Self.fields.joined(separator: ", "))")
            }
            guard fields.updateValue(pair[1], forKey: pair[0]) == nil else { throw ParseError("it says \(pair[0]) twice") }
        }
        for name in Self.required where fields[name] == nil {
            throw ParseError("it needs \(name)= as well: \(Self.required.map { "\($0)=" }.joined(separator: ","))")
        }
        var file = fields["file", default: ""]
        if file.hasPrefix("wine:") { file.removeFirst("wine:".count) }
        guard file.uppercased().hasPrefix("C:/"), file.count > 3 else {
            throw ParseError("file=\(file): it's a file on Wine's C: drive, C:/…")
        }
        guard let format = Format(rawValue: fields["format", default: ""]) else {
            throw ParseError("format=\(fields["format", default: ""]): it's \(Format.allCases.map(\.rawValue).joined(separator: " or "))")
        }
        guard let offset = Int(fields["offset", default: ""]), offset >= 0 else {
            throw ParseError("offset=\(fields["offset", default: ""]): it's a number of bytes from the start, 0 or more")
        }
        guard let width = Int(fields["bytes", default: ""]), [1, 2, 4, 8].contains(width) else {
            throw ParseError("bytes=\(fields["bytes", default: ""]): the value is 1, 2, 4 or 8 bytes")
        }
        func value(_ name: String) throws(ParseError) -> Data {
            let written = fields[name, default: ""]
            guard let bytes = Self.littleEndian(written, width: width) else {
                throw ParseError("\(name)=\(written): it's a whole number that fits its bytes=\(width), as 0, -1 or 0xFF")
            }
            return bytes
        }
        let fullscreen = try value("fullscreen"), windowed = try value("windowed")
        guard fullscreen != windowed else { throw ParseError("fullscreen and windowed are the same value") }
        switch (fields["checksum-offset"], fields["checksum-scale"]) {
        case (nil, nil):
            checksum = nil
        case let (offsetText?, scaleText?):
            guard let at = Int(offsetText), at >= 0, at + width <= offset || at >= offset + width else {
                throw ParseError("checksum-offset=\(offsetText): it's a number of bytes from the start, apart from the value")
            }
            guard let scale = Int64(scaleText), scale != 0 else {
                throw ParseError("checksum-scale=\(scaleText): it's how many times the sum counts the value, a whole number other than 0")
            }
            checksum = Checksum(offset: at, scale: scale)
        default:
            throw ParseError("checksum-offset and checksum-scale go together")
        }
        self.file = file
        self.format = format
        self.offset = offset
        self.width = width
        self.fullscreen = fullscreen
        self.windowed = windowed
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    private static let required = ["file", "format", "offset", "bytes", "fullscreen", "windowed"]
    private static let fields = required + ["checksum-offset", "checksum-scale"]

    /// `text` (decimal, signed or not, or 0x hex) in `width` bytes,
    /// little-endian; nil when it isn't a number or doesn't fit.
    static func littleEndian(_ text: String, width: Int) -> Data? {
        let bits = UInt64(width * 8)
        let value: UInt64
        if text.lowercased().hasPrefix("0x") {
            guard let unsigned = UInt64(text.dropFirst(2), radix: 16) else { return nil }
            value = unsigned
        } else if text.hasPrefix("-") {
            guard let signed = Int64(text), bits == 64 || signed >= -(Int64(1) << (bits - 1)) else { return nil }
            value = UInt64(bitPattern: signed)
        } else {
            guard let unsigned = UInt64(text) else { return nil }
            value = unsigned
        }
        if bits < 64, !text.hasPrefix("-"), value >> bits != 0 { return nil }
        return Data((0..<width).map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) })
    }

    /// Little-endian bytes as a number.
    private static func integer(_ bytes: Data) -> UInt64 {
        bytes.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    // MARK: - Applying it

    /// What `apply` did, for the log.
    public enum Outcome: Equatable, Sendable {
        case written
        case alreadySet
        /// Left alone, and why.
        case leftAlone(String)
    }

    /// Sets the file at `url` to the player's choice, unless it's missing,
    /// isn't what this says it is, or already has it. A link (a `files=`
    /// mount's) is written through, so its store keeps the change.
    public func apply(fullscreen choice: Bool, at url: URL) -> Outcome {
        let target = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else { return .leftAlone("there's no such file yet") }
        let file: Data
        do {
            file = try Data(contentsOf: target)
        } catch {
            return .leftAlone("it couldn't be read: \(error.localizedDescription)")
        }
        var contents = file
        var packed = false
        if format == .allegroPackfile {
            do {
                (contents, packed) = try AllegroPackfile.read(file)
            } catch {
                return .leftAlone("\(error)")
            }
        }
        guard contents.count >= max(offset, checksum?.offset ?? 0) + width else {
            return .leftAlone("it's \(contents.count) bytes, too short for a value at \(max(offset, checksum?.offset ?? 0))")
        }
        let range = contents.startIndex + offset ..< contents.startIndex + offset + width
        let current = Data(contents[range])
        let wanted = choice ? fullscreen : windowed
        if current == wanted { return .alreadySet }
        guard current == fullscreen || current == windowed else {
            return .leftAlone("the value there is \(current.map { String(format: "%02x", $0) }.joined()), neither fullscreen's nor windowed's")
        }
        contents.replaceSubrange(range, with: wanted)
        if let checksum {
            // Modulo the width, as the program's own sum wraps.
            let at = contents.startIndex + checksum.offset ..< contents.startIndex + checksum.offset + width
            let change = Self.integer(wanted) &- Self.integer(current)
            let sum = Self.integer(Data(contents[at])) &+ UInt64(bitPattern: checksum.scale) &* change
            contents.replaceSubrange(at, with: Data((0..<width).map { UInt8(truncatingIfNeeded: sum >> (UInt64($0) * 8)) }))
        }
        let written = format == .allegroPackfile ? AllegroPackfile.write(contents, packed: packed) : contents
        do {
            try written.write(to: target, options: .atomic)
        } catch {
            return .leftAlone("it couldn't be written: \(error.localizedDescription)")
        }
        return .written
    }
}
