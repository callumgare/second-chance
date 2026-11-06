//
//  PuppetReply.swift
//  PuppetProtocol
//
//  Reading a control socket's reply: `ok` or `error <why>`, then words and
//  `name=value` fields; `windows` adds a line a window.

import CoreGraphics
import Foundation

nonisolated public struct PuppetReply: Sendable, Equatable {
    /// The whole reply, trimmed.
    public let text: String

    public init(_ text: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first line.
    public var head: String { text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" }

    public var isOK: Bool { head == "ok" || head.hasPrefix("ok ") }

    /// Why, for an `error` reply; nil for `ok`.
    public var error: String? {
        guard !isOK else { return nil }
        return head.hasPrefix("error ") ? String(head.dropFirst(6)) : head
    }

    /// The first line's words after `ok` that aren't fields: a capture's `<w>x<h>`.
    public var words: [String] {
        guard isOK else { return [] }
        return head.split(separator: " ").dropFirst().filter { !$0.contains("=") }.map(String.init)
    }

    /// The first line's `name=value` fields; empty for an error.
    public var fields: [String: String] {
        guard isOK else { return [:] }
        return Self.fields(of: head.split(separator: " ").dropFirst())
    }

    /// The first line after `ok`, as a person reads it.
    public var summary: String { isOK ? String(head.dropFirst(min(3, head.count))) : head }

    /// A `<w>x<h>` word: a capture's size in pixels.
    public var size: CGSize? { words.lazy.compactMap(Self.size).first }

    static func fields<S: Sequence>(of words: S) -> [String: String] where S.Element == Substring {
        var fields: [String: String] = [:]
        for word in words {
            let pair = word.split(separator: "=", maxSplits: 1)
            if pair.count == 2, fields[String(pair[0])] == nil { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }

    static func size(_ word: String) -> CGSize? {
        let parts = word.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]) else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// What `hello` says of the helper.
nonisolated public struct PuppetHello: Sendable, Equatable {
    public let version: Int
    public let pid: Int32?
    public let exe: String?
    public let commands: [String]

    /// From a `hello` reply; a version 1 helper, which has no `hello`, says error.
    public init(_ reply: PuppetReply) {
        let fields = reply.fields
        version = reply.isOK ? (fields["version"].flatMap(Int.init) ?? 2) : 1
        pid = fields["pid"].flatMap(Int32.init)
        exe = fields["exe"]
        commands = fields["commands"]?.split(separator: ",").map(String.init) ?? []
    }

    /// Whether it answers this request.
    public func supports(_ verb: String) -> Bool { commands.contains(verb) }
}

/// What `state` says of the game window.
nonisolated public struct PuppetWindowState: Sendable, Equatable {
    public let windowNumber: Int
    /// In points.
    public let size: CGSize
    /// Pixels per point.
    public let scale: CGFloat
    /// In a macOS fullscreen Space, or exactly covering its screen.
    public let fullscreen: Bool
    /// In a macOS fullscreen Space.
    public let native: Bool
    public let key: Bool
    public let active: Bool
    /// On the Space on screen; nil when the window doesn't say.
    public let onActiveSpace: Bool?
    /// The app has hidden the cursor and confined it to its window.
    public let cursorHeld: Bool
    /// What the app's own cursor locking says it's doing; nil when it doesn't say.
    public let cursorLock: String?

    /// From a `state` reply; nil for an error or a reply missing the window.
    public init?(_ reply: PuppetReply) {
        let fields = reply.fields
        guard let window = fields["window"].flatMap(Int.init),
              let size = fields["size"].flatMap(PuppetReply.size),
              let scale = fields["scale"].flatMap(Double.init) else { return nil }
        windowNumber = window
        self.size = size
        self.scale = CGFloat(scale)
        fullscreen = fields["fullscreen"] == "1"
        native = fields["native"] == "1"
        key = fields["key"] == "1"
        active = fields["active"] == "1"
        onActiveSpace = fields["onspace"].map { $0 == "1" }
        cursorHeld = fields["cursor"] == "held"
        cursorLock = fields["cursorlock"]
    }
}

/// One window from a `windows` reply.
nonisolated public struct PuppetWindow: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// The one the other requests act on: the biggest visible window.
        case game
        case panel
        case other
    }

    public let id: Int
    /// From the screen's top left, in points.
    public let frame: CGRect
    public let level: Int
    public let visible: Bool
    public let key: Bool
    public let main: Bool
    public let kind: Kind
    public let title: String

    /// Every window in a `windows` reply: `ok <n> windows`, then a line each.
    public static func all(in reply: PuppetReply) -> [PuppetWindow] {
        guard reply.isOK else { return [] }
        return reply.text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = PuppetReply.fields(of: line.split(separator: " "))
            guard let id = fields["id"].flatMap(Int.init) else { return nil }
            let frame = (fields["frame"] ?? "").split(separator: ",").compactMap { Double($0) }
            return PuppetWindow(
                id: id,
                frame: frame.count == 4 ? CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]) : .zero,
                level: fields["level"].flatMap(Int.init) ?? 0, visible: fields["visible"] == "1",
                key: fields["key"] == "1", main: fields["main"] == "1",
                kind: fields["kind"].flatMap(Kind.init) ?? .other,
                title: fields["title"]?.removingPercentEncoding ?? "")
        }
    }

    public init(id: Int, frame: CGRect, level: Int, visible: Bool, key: Bool, main: Bool, kind: Kind, title: String) {
        self.id = id
        self.frame = frame
        self.level = level
        self.visible = visible
        self.key = key
        self.main = main
        self.kind = kind
        self.title = title
    }
}

/// What the wrapp's `info` says of its info window.
nonisolated public struct WrappInfo: Sendable, Equatable {
    public let open: Bool
    public let warning: Bool

    public init?(_ reply: PuppetReply) {
        let fields = reply.fields
        guard reply.isOK, let open = fields["open"], let warning = fields["warning"] else { return nil }
        self.open = open == "1"
        self.warning = warning == "1"
    }
}
