//
//  PathRedactor.swift
//  SecondChanceKit
//
//  Takes the person's own folders and files out of the paths in a report's
//  text, keeping what isn't theirs: the parts of a path that are macOS's
//  (~/Library/Caches), Second Chance's own (SecondChance/…, the installers
//  store, a wrapp's prefix), and everything inside a disc, a disc image or
//  a program (a .app, an .exe). What's left — the folders they made, a
//  drive's name, a cloud folder — becomes a numbered placeholder that says
//  what it was: `~/Downloads/<folder-1>/nancy-drew.iso`. A placeholder's
//  number stands for one place for as long as one table lasts (a report),
//  so two lines naming the same folder still show it; a new table starts
//  again at 1, so reports can't be linked by them.
//
//  docs/failure-reports.md ("What leaves the Mac") has the rules.

import Foundation
import os

nonisolated public struct PathRedactor: Sendable {

    /// What a placeholder stands for.
    public enum Kind: String, Sendable {
        case folder, file, cloud, volume
        case externalDrive = "external-drive"
        case internalDrive = "internal-drive"
        case networkDrive = "network-drive"
    }

    let homeKey: String
    let mounts: [String: MountedVolume]
    let table: PlaceholderTable

    /// - Parameters:
    ///   - homePath: the person's home folder, which becomes `~`.
    ///   - mounts: what's known of the volumes paths may be on, by mount
    ///     point (`VolumeKinds.known()`).
    ///   - table: the placeholders handed out so far, shared by everything
    ///     redacted for one report.
    public init(homePath: String, mounts: [String: MountedVolume] = [:], table: PlaceholderTable = PlaceholderTable()) {
        homeKey = Self.key(homePath)
        var normalised: [String: MountedVolume] = [:]
        for (path, volume) in mounts where Self.key(path) != "/" { normalised[Self.key(path)] = volume }
        self.mounts = normalised
        self.table = table
    }

    /// `text` with the paths in it redacted. Paths are found where they
    /// start (`/…`, `~/…`, `Z:\…`, `file://`, `smb://`, `//host/share`),
    /// each line on its own.
    public func redact(_ text: String) -> String {
        guard text.contains("/") || text.contains(":\\") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.contains("/") || line.contains(":\\") else { return String(line) }
            return redactLine(Array(line.unicodeScalars))
        }.joined(separator: "\n")
    }

    // MARK: Finding paths

    private func redactLine(_ line: [Unicode.Scalar]) -> String {
        var out = String.UnicodeScalarView()
        var index = 0
        while index < line.count {
            if let (replacement, end) = path(in: line, at: index), end > index {
                out.append(contentsOf: replacement.unicodeScalars)
                index = end
            } else {
                out.append(line[index])
                index += 1
            }
        }
        return String(out)
    }

    /// The path starting at `index`, redacted, and where it ends.
    private func path(in line: [Unicode.Scalar], at index: Int) -> (String, Int)? {
        let character = line[index]
        if Scan.isLetter(character), index == 0 || !Scan.isSchemeCharacter(line[index - 1]),
           let (scheme, afterScheme) = Scan.scheme(in: line, at: index) {
            switch scheme {
            case "file": return fileURL(line, from: index, path: afterScheme)
            case _ where Self.networkSchemes.contains(scheme): return networkURL(line, from: index, scheme: scheme, rest: afterScheme)
            default:
                // Another URL (https://…) is no file's path: left whole.
                let end = Scan.tokenEnd(line, from: afterScheme)
                return (String(String.UnicodeScalarView(line[index..<end])), end)
            }
        }
        if character == "Z" || character == "z", index + 2 < line.count, line[index + 1] == ":", line[index + 2] == "\\",
           index == 0 || !Scan.isAlphanumeric(line[index - 1]) {
            return windowsPath(line, from: index)
        }
        guard Scan.isBoundary(line, before: index) else { return nil }
        if character == "/", index + 1 < line.count, line[index + 1] == "/", let share = networkShare(line, from: index) {
            return share
        }
        if character == "/", index + 1 < line.count, !Scan.isSpace(line[index + 1]) {
            return posixPath(line, from: index)
        }
        if character == "~", index + 1 < line.count, line[index + 1] == "/" {
            return posixPath(line, from: index)
        }
        return nil
    }

    private func posixPath(_ line: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        let fromHome = line[start] == "~"
        let read = Scan.components(line, from: start + 1, separator: "/", closer: Scan.closer(line, before: start))
        if !fromHome, read.middle.isEmpty {
            // A word after a slash ("start /wait", "/s", "1 /2") is no path,
            // unless it names a folder at the top of the disk.
            let first = String(read.tail.prefix { !Scan.isSpaceCharacter($0) }).lowercased()
            guard Self.rootPlaces[first] != nil else { return nil }
        }
        let base = fromHome ? homeKey.split(separator: "/").map(String.init) : []
        let walked = walk(base + read.middle, tail: read.tail, place: .root, keyPrefix: "", checkMounts: true)
        return (walked.render(separator: "/", root: "/"), read.end)
    }

    /// Wine's view of the Mac, through its Z: drive: `Z:\Users\…` (or
    /// `Z:\\Users\\…` in a quoted string).
    private func windowsPath(_ line: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        let read = Scan.components(line, from: start + 2, separator: "\\", closer: Scan.closer(line, before: start))
        let walked = walk(read.middle, tail: read.tail, place: .root, keyPrefix: "", checkMounts: true)
        let drive = String(line[start]) + ":"
        return (drive + walked.render(separator: read.separator, root: read.separator), read.end)
    }

    private func fileURL(_ line: [Unicode.Scalar], from start: Int, path pathStart: Int) -> (String, Int)? {
        let end = Scan.tokenEnd(line, from: pathStart)
        var path = String(String.UnicodeScalarView(line[pathStart..<end]))
        if path.lowercased().hasPrefix("localhost/") { path.removeFirst("localhost".count) }
        let decoded = path.removingPercentEncoding ?? path
        guard decoded.hasPrefix("/") || decoded.hasPrefix("~/") else {
            return (String(String.UnicodeScalarView(line[start..<end])), end)
        }
        var parts = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fromHome = parts.first == "~"
        parts.removeFirst()
        let tail = parts.popLast() ?? ""
        let base = fromHome ? homeKey.split(separator: "/").map(String.init) : []
        var walked = walk(base + parts, tail: tail, place: .root, keyPrefix: "", checkMounts: true)
        walked.parts = walked.parts.map { part in
            Self.isPlaceholder(part) ? part : (part.addingPercentEncoding(withAllowedCharacters: Self.urlComponentAllowed) ?? part)
        }
        return ("file://" + walked.render(separator: "/", root: "/"), end)
    }

    /// A network drive's address: `smb://user@host/share/…`. The server,
    /// the account and the share become one placeholder.
    private func networkURL(_ line: [Unicode.Scalar], from start: Int, scheme: String, rest: Int) -> (String, Int)? {
        let end = Scan.tokenEnd(line, from: rest)
        let address = String(String.UnicodeScalarView(line[rest..<end]))
        var parts = address.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let authority = parts.isEmpty ? "" : parts.removeFirst()
        let share = parts.isEmpty ? "" : parts.removeFirst()
        let drive = table.placeholder(.networkDrive, for: Self.shareKey(authority: authority, share: share))
        let prefix = String(String.UnicodeScalarView(line[start..<rest])) + drive
        guard !parts.isEmpty else { return (prefix, end) }
        let tail = parts.removeLast()
        let walked = walk(parts, tail: tail, place: .user(.folder), keyPrefix: Self.shareKey(authority: authority, share: share),
                          checkMounts: false)
        return (prefix + "/" + walked.parts.joined(separator: "/") + walked.rest, end)
    }

    /// A network share as `mount` and `smbutil` show one:
    /// `//user@host/share on /Volumes/share (smbfs, …)`.
    private func networkShare(_ line: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        var index = start + 2
        var authority = String.UnicodeScalarView()
        while index < line.count, line[index] != "/", !Scan.isSpace(line[index]) {
            authority.append(line[index])
            index += 1
        }
        guard index < line.count, line[index] == "/", !authority.isEmpty,
              String(authority).unicodeScalars.allSatisfy({ Scan.isHostCharacter($0) }) else { return nil }
        index += 1
        var share = String.UnicodeScalarView()
        while index < line.count, line[index] != "/", !Scan.isSpace(line[index]), !Scan.isHardStop(line, index, closer: nil) {
            share.append(line[index])
            index += 1
        }
        guard !share.isEmpty else { return nil }
        let key = Self.shareKey(authority: String(authority), share: String(share))
        let drive = "//" + table.placeholder(.networkDrive, for: key)
        guard index < line.count, line[index] == "/" else { return (drive, index) }
        let read = Scan.components(line, from: index, separator: "/", closer: Scan.closer(line, before: start))
        let walked = walk(read.middle, tail: read.tail, place: .user(.folder), keyPrefix: key, checkMounts: false)
        return (drive + walked.render(separator: "/", root: "/"), read.end)
    }

    static func shareKey(authority: String, share: String) -> String {
        "//" + (authority.removingPercentEncoding ?? authority).lowercased() + "/" + (share.removingPercentEncoding ?? share).lowercased()
    }

    // MARK: Walking a path

    /// Where in the Mac's folders a walk has got to, which says what the
    /// next name is.
    enum Place: Equatable {
        case root, system, systemVolumes, users, shared, volumes
        case home, applications, library, libraryFolder, containers, containerItem
        /// Everything from here on is kept: macOS's own, ours, or inside a
        /// disc or a program.
        case keepAll
        /// The person's own: each name is redacted as `kind`, unless it's a
        /// disc image or a program, inside which everything is kept.
        case user(Kind)
    }

    enum Decision {
        case keep(Place)
        case user(Kind)
        case replace(String, Place)
        /// One name redacted on its own (a container's app id), then on.
        case redactOne(Kind, Place)
        case drive(Kind, key: String)
    }

    struct Walked {
        var home = false
        var parts: [String] = []
        var rest = ""

        func render(separator: String, root: String) -> String {
            let joined = parts.joined(separator: separator)
            if home { return "~" + (parts.isEmpty ? "" : separator + joined) + rest }
            return root + joined + rest
        }
    }

    /// `components` (from the top of the disk) and `tail` (the text the last
    /// name runs into, which may hold more than the name) redacted.
    func walk(_ components: [String], tail: String, place start: Place, keyPrefix: String, checkMounts: Bool) -> Walked {
        var walked = Walked()
        var place = start
        var key = keyPrefix
        var run: (kind: Kind, key: String)?
        var keyRewrite: (from: String, to: String)?

        func rewritten(_ path: String) -> String {
            guard let rewrite = keyRewrite, path.hasPrefix(rewrite.from) else { return path }
            return rewrite.to + path.dropFirst(rewrite.from.count)
        }
        func flush() {
            guard let open = run else { return }
            walked.parts.append(table.placeholder(open.kind, for: rewritten(open.key)))
            run = nil
        }
        func apply(_ decision: Decision, name: String, isTail: Bool) {
            switch decision {
            case .keep(let next):
                flush()
                walked.parts.append(name)
                place = next
            case .replace(let replacement, let next):
                flush()
                walked.parts.append(replacement)
                place = next
            case .redactOne(let kind, let next):
                flush()
                walked.parts.append(table.placeholder(kind, for: rewritten(key)))
                place = next
            case .user(let kind):
                if isTail {
                    flush()
                    // The last name is a file or a folder of its own, even on
                    // a drive whose name a placeholder already stands for.
                    let hasExtension = !(name as NSString).pathExtension.isEmpty
                    let tailKind: Kind = kind == .cloud ? .cloud : (hasExtension ? .file : .folder)
                    walked.parts.append(table.placeholder(tailKind, for: rewritten(key)))
                } else if run != nil {
                    run?.key = key
                } else {
                    run = (kind, key)
                }
                place = .user(kind)
            case .drive(let kind, let driveKey):
                flush()
                keyRewrite = driveKey == key ? nil : (key, driveKey)
                if isTail {
                    walked.parts.append(table.placeholder(kind, for: driveKey))
                } else {
                    run = (kind, key)
                }
                place = .user(kind)
            }
        }
        func becomeHome() {
            run = nil
            walked = Walked(home: true)
            place = .home
        }

        for (index, component) in components.enumerated() {
            key += "/" + Self.keyName(component)
            if isHome(key) {
                becomeHome()
                continue
            }
            let decision = (checkMounts ? mountDecision(key, name: component, place: place) : nil)
                ?? step(place, component, previous: index > 0 ? components[index - 1] : nil)
            apply(decision, name: component, isTail: false)
        }

        guard !tail.isEmpty else {
            flush()
            if !components.isEmpty, !(walked.home && walked.parts.isEmpty) { walked.parts.append("") }
            return walked
        }
        let (name, rest) = extent(of: tail, in: place)
        walked.rest = rest
        guard !name.isEmpty else {
            flush()
            return walked
        }
        key += "/" + Self.keyName(name)
        if isHome(key) {
            becomeHome()
            return walked
        }
        let decision = (checkMounts ? mountDecision(key, name: name, place: place) : nil)
            ?? step(place, name, previous: components.last)
        apply(decision, name: name, isTail: true)
        flush()
        return walked
    }

    private func isHome(_ key: String) -> Bool {
        homeKey != "/" && (key == homeKey || key == "/system/volumes/data" + homeKey)
    }

    /// What the name at `key` is when it's a volume's mount point: kept
    /// whole for a disc, its own placeholder for a drive.
    private func mountDecision(_ key: String, name: String, place: Place) -> Decision? {
        if place == .keepAll || Self.isPlaceholder(name) { return nil }
        let volume: MountedVolume
        if let known = mounts[key] {
            volume = known
        } else if key.hasPrefix("/volumes/"), key.dropFirst("/volumes/".count).contains("/") == false {
            volume = MountedVolume(kind: .unknown)
        } else {
            return nil
        }
        switch volume.kind {
        case .discImage, .opticalDisc: return .keep(.keepAll)
        case .externalDrive: return .drive(.externalDrive, key: volume.source.map(Self.key) ?? key)
        case .internalDrive: return .drive(.internalDrive, key: key)
        case .networkDrive: return .drive(.networkDrive, key: volume.source.map(Self.sourceKey) ?? key)
        case .unknown: return .drive(.volume, key: key)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func step(_ place: Place, _ name: String, previous: String?) -> Decision {
        let lower = name.lowercased()
        switch place {
        case .keepAll:
            // A Steam account's number names its folder in Steam's userdata.
            if previous?.lowercased() == "userdata", !name.isEmpty, name.allSatisfy(\.isNumber) {
                return .replace("<steam-id>", .keepAll)
            }
            return .keep(.keepAll)
        case .root:
            if let next = Self.rootPlaces[lower] { return .keep(next) }
            return userStep(.folder, name)
        case .system:
            return .keep(lower == "volumes" ? .systemVolumes : .keepAll)
        case .systemVolumes:
            return .keep(lower == "data" ? .root : .keepAll)
        case .users:
            if lower == "shared" { return .keep(.shared) }
            if Self.isPlaceholder(name) { return .keep(.home) }
            // Another account's home: that it was one, not whose.
            return .replace("<user>", .home)
        case .shared:
            if lower == "second-chance" { return .keep(.keepAll) }
            return userStep(.folder, name)
        case .volumes:
            return Self.isPlaceholder(name) ? .keep(.user(.folder)) : .user(.volume)
        case .home:
            if let next = Self.homePlaces[lower] { return .keep(next) }
            return userStep(.folder, name)
        case .applications:
            if lower == "utilities" { return .keep(.user(.folder)) }
            return userStep(.folder, name)
        case .library:
            if let next = Self.libraryPlaces[lower] { return .keep(next) }
            return userStep(.folder, name)
        case .libraryFolder:
            if Self.isOurs(lower) { return .keep(.keepAll) }
            return userStep(.folder, name)
        case .containers:
            if Self.isOurs(lower) { return .keep(.keepAll) }
            if Self.isPlaceholder(name) { return .keep(.containerItem) }
            return .redactOne(.folder, .containerItem)
        case .containerItem:
            if lower == "data" { return .keep(.home) }
            return userStep(.folder, name)
        case .user(let kind):
            return userStep(kind, name)
        }
    }

    private func userStep(_ kind: Kind, _ name: String) -> Decision {
        if Self.keepsContents(name) { return .keep(.keepAll) }
        if Self.isPlaceholder(name) { return .keep(.user(.folder)) }
        return .user(kind)
    }

    /// Where the name at the start of `tail` ends: the rest is the line's
    /// own text. When that can't be told, all of it is taken as the name, so
    /// what's unclear is redacted rather than kept.
    func extent(of tail: String, in place: Place) -> (name: String, rest: String) {
        if place == .keepAll { return (tail, "") }
        if let placeholder = Self.leadingPlaceholder(tail) {
            return (placeholder, String(tail.dropFirst(placeholder.count)))
        }
        let lower = tail.lowercased()
        if place == .libraryFolder || place == .containers, Self.isOurs(lower) { return (tail, "") }
        let children: [String] = switch place {
        case .root: Array(Self.rootPlaces.keys)
        case .home: Array(Self.homePlaces.keys)
        case .library: Array(Self.libraryPlaces.keys)
        case .users, .shared: ["shared", "second-chance"]
        case .system: ["volumes"]
        case .systemVolumes: ["data"]
        case .containerItem: ["data"]
        case .libraryFolder: ["secondchance"]
        default: []
        }
        for child in children.sorted(by: { $0.count > $1.count }) where lower.hasPrefix(child) {
            if let after = tail.unicodeScalars.dropFirst(child.unicodeScalars.count).first, Scan.isAlphanumeric(after) { continue }
            let split = tail.index(tail.startIndex, offsetBy: child.count)
            return (String(tail[..<split]), String(tail[split...]))
        }
        // A name with a known extension ends with it: `Setup.exe exited 1`.
        if let end = Self.knownExtensionEnd(in: tail) {
            return (String(tail[..<end]), String(tail[end...]))
        }
        // Then what seldom stands in a name, or the whole of it.
        var name = tail
        for stop in [", ", " (", " - "] {
            if let range = name.range(of: stop) { name = String(name[..<range.lowerBound]) }
        }
        while let last = name.last, last.isWhitespace || ".,;!?)".contains(last) { name.removeLast() }
        return (name, String(tail.dropFirst(name.count)))
    }

    // MARK: Names

    /// Folders at the top of the disk, and where each leads.
    static let rootPlaces: [String: Place] = [
        "system": .system, "users": .users, "volumes": .volumes, "applications": .applications,
        "library": .keepAll, "usr": .keepAll, "bin": .keepAll, "sbin": .keepAll, "etc": .keepAll, "dev": .keepAll,
        "cores": .keepAll, "opt": .keepAll, "private": .keepAll, "var": .keepAll, "tmp": .keepAll, "nix": .keepAll,
    ]

    /// A home's standard folders.
    static let homePlaces: [String: Place] = [
        "desktop": .user(.folder), "documents": .user(.folder), "downloads": .user(.folder), "movies": .user(.folder),
        "music": .user(.folder), "pictures": .user(.folder), "public": .user(.folder), "sites": .user(.folder),
        ".trash": .user(.folder), "applications": .applications, "library": .library,
    ]

    /// A Library's standard folders. In most, each app has a folder of its
    /// own, kept only when it's ours; the cloud folders hold the person's
    /// files.
    static let libraryPlaces: [String: Place] = {
        var places: [String: Place] = [
            "containers": .containers, "cloudstorage": .user(.cloud), "mobile documents": .user(.cloud),
        ]
        for folder in ["caches", "application support", "logs", "preferences", "saved application state", "httpstorages",
                       "webkit", "cookies", "launchagents", "group containers", "application scripts", "fonts", "frameworks",
                       "developer", "keychains", "autosave information", "daemon containers", "services", "sounds",
                       "spelling", "input methods", "keyboard layouts", "screen savers", "internet plug-ins", "metadata",
                       "mail", "messages", "safari", "calendars", "accounts", "assistants", "biome", "sharing", "staging",
                       "photos", "translation", "weather", "dictionaries", "printers", "colorsync", "audio"] {
            places[folder] = .libraryFolder
        }
        return places
    }()

    /// Second Chance's own folders in a Library folder: `SecondChance`, and
    /// those named by an app's id (the app's, a wrapp's: `au.gare.callum.…`).
    static func isOurs(_ lowercasedName: String) -> Bool {
        lowercasedName == "secondchance" || lowercasedName.hasPrefix("au.gare.callum.")
    }

    /// Extensions of a disc image, a program or a program bundle: whatever
    /// is in one isn't the person's, so it's kept, name and all.
    static let keepExtensions: Set<String> = [
        // Disc images, and classic Mac disk images.
        "iso", "dmg", "sparsebundle", "sparseimage", "cdr", "toast", "img", "bin", "cue", "nrg", "mdf", "mds", "ccd",
        "chd", "udf", "b5t", "b6t", "cif", "isz", "dsk", "hfv", "image", "smi",
        // Programs and program bundles.
        "app", "exe", "msi", "bundle", "framework", "plugin", "appex", "xpc", "kext", "prefpane", "saver", "qlgenerator",
    ]

    static func keepsContents(_ name: String) -> Bool {
        keepExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Extensions a name in running text can be taken to end with.
    static let knownExtensions: Set<String> = keepExtensions.union([
        "dll", "txt", "log", "ini", "cfg", "json", "plist", "xml", "zip", "gz", "tgz", "tar", "rar", "7z", "pdf", "png",
        "jpg", "jpeg", "gif", "bmp", "ico", "icns", "sav", "dat", "cab", "inf", "reg", "bat", "cmd", "sh", "md", "html",
        "htm", "mp3", "wav", "ogg", "avi", "mp4", "mov", "bik", "his", "rom", "ips", "lock", "sock", "yaml", "yml",
        "drv", "ocx", "sys", "hdr", "lnk", "url", "vdf", "acf", "db", "sqlite", "shadow",
    ])

    /// The end of the first known extension in `text` that a name ends with.
    static func knownExtensionEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while let dot = text[index...].firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" { end = text.index(after: end) }
            if knownExtensions.contains(text[text.index(after: dot)..<end].lowercased()) { return end }
            index = text.index(after: dot)
        }
        return nil
    }

    /// Something this or an earlier redaction put in a path.
    static func isPlaceholder(_ name: String) -> Bool {
        leadingPlaceholder(name) == name
    }

    static func leadingPlaceholder(_ text: String) -> String? {
        guard text.first == "<", let close = text.firstIndex(of: ">") else { return nil }
        let inner = text[text.index(after: text.startIndex)..<close]
        guard !inner.isEmpty, inner.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }) else { return nil }
        return String(text[...close])
    }

    static let networkSchemes: Set<String> = ["smb", "afp", "nfs", "cifs", "webdav", "dav", "davs", "ftp", "ftps", "sftp"]

    static let urlComponentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()

    static func keyName(_ name: String) -> String {
        (name.removingPercentEncoding ?? name).lowercased()
    }

    /// A path as a key: lowercased (APFS ignores case), without a trailing slash.
    static func key(_ path: String) -> String {
        var key = path.lowercased()
        while key.count > 1, key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// A network mount's source (`//user@host/share`) as a key.
    static func sourceKey(_ source: String) -> String {
        guard source.hasPrefix("//") else { return key(source) }
        let parts = source.dropFirst(2).split(separator: "/", maxSplits: 1).map(String.init)
        return shareKey(authority: parts.first ?? "", share: parts.count > 1 ? parts[1] : "")
    }
}

/// The placeholders one report has handed out: the same place is the same
/// placeholder throughout it, and each kind is numbered from 1.
nonisolated public final class PlaceholderTable: Sendable {
    private struct State {
        var byKey: [String: String] = [:]
        var counts: [String: Int] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    func placeholder(_ kind: PathRedactor.Kind, for key: String) -> String {
        state.withLock { state in
            let entry = kind.rawValue + "\u{0}" + key
            if let existing = state.byKey[entry] { return existing }
            let number = (state.counts[kind.rawValue] ?? 0) + 1
            state.counts[kind.rawValue] = number
            let placeholder = "<\(kind.rawValue)-\(number)>"
            state.byKey[entry] = placeholder
            return placeholder
        }
    }
}

/// Reading a line of text for the paths in it.
nonisolated enum Scan {
    static func isLetter(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(scalar) }
    static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(scalar) }
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool { CharacterSet.whitespaces.contains(scalar) }
    static func isSpaceCharacter(_ character: Character) -> Bool { character.isWhitespace }
    static func isSchemeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (isAlphanumeric(scalar) || "+.-".unicodeScalars.contains(scalar))
    }
    static func isHostCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (isAlphanumeric(scalar) || "._-@:;[]%".unicodeScalars.contains(scalar))
    }

    /// What may stand before a path: the start of a line, a space, or
    /// punctuation that opens or separates.
    static func isBoundary(_ line: [Unicode.Scalar], before index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = line[index - 1]
        return isSpace(previous) || "\"'([{<=,;|>:`".unicodeScalars.contains(previous)
    }

    /// The quote or bracket that closes the one a path opened after.
    static func closer(_ line: [Unicode.Scalar], before index: Int) -> Unicode.Scalar? {
        guard index > 0 else { return nil }
        switch line[index - 1] {
        case "'": return "'"
        case "(": return ")"
        case "[": return "]"
        case "<": return ">"
        default: return nil
        }
    }

    /// `name://` at `index`: the scheme, lowercased, and where what follows it starts.
    static func scheme(in line: [Unicode.Scalar], at index: Int) -> (String, Int)? {
        var end = index
        while end < line.count, isSchemeCharacter(line[end]) { end += 1 }
        guard end > index, end + 2 < line.count, line[end] == ":", line[end + 1] == "/", line[end + 2] == "/" else { return nil }
        return (String(String.UnicodeScalarView(line[index..<end])).lowercased(), end + 3)
    }

    /// Where a URL ends: the first space, quote or closing bracket.
    static func tokenEnd(_ line: [Unicode.Scalar], from index: Int) -> Int {
        var end = index
        while end < line.count, !isSpace(line[end]), !"\"'<>)]`|{}".unicodeScalars.contains(line[end]) { end += 1 }
        return end
    }

    /// Whether a path at `index` ends there, before a character no name has
    /// in running text, or the start of another path.
    static func isHardStop(_ line: [Unicode.Scalar], _ index: Int, closer: Unicode.Scalar?) -> Bool {
        let character = line[index]
        if "\t\r\"`|{}".unicodeScalars.contains(character) || character == closer { return true }
        if character == ":", index + 1 == line.count || isSpace(line[index + 1]) { return true }
        if isSpace(character), index + 1 < line.count {
            let next = line[index + 1]
            if next == "/" || (next == "~" && index + 2 < line.count && line[index + 2] == "/") { return true }
            if isLetter(next), index + 3 < line.count, line[index + 2] == ":", line[index + 3] == "\\" { return true }
            if isLetter(next), scheme(in: line, at: index + 1) != nil { return true }
            for arrow in [" -> ", " → ", " => "] where matches(line, index, arrow) { return true }
        }
        return false
    }

    static func matches(_ line: [Unicode.Scalar], _ index: Int, _ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard index + scalars.count <= line.count else { return false }
        return Array(line[index..<index + scalars.count]) == scalars
    }

    struct Components {
        var middle: [String] = []
        var tail = ""
        var end = 0
        var separator = "/"
    }

    /// The names of a path from `start`: those a separator ends, then the
    /// text the last one runs into, up to a hard stop. A run of separators
    /// is one (Wine writes `\\` in a quoted string).
    static func components(_ line: [Unicode.Scalar], from start: Int, separator: Unicode.Scalar, closer: Unicode.Scalar?) -> Components {
        var result = Components(separator: String(separator))
        var index = start
        var firstRun = true
        func consumeSeparators() {
            var run = String.UnicodeScalarView()
            while index < line.count, line[index] == separator {
                run.append(line[index])
                index += 1
            }
            if firstRun, !run.isEmpty {
                result.separator = String(run)
                firstRun = false
            }
        }
        consumeSeparators()
        var current = String.UnicodeScalarView()
        while index < line.count {
            if line[index] == separator {
                result.middle.append(String(current))
                current = String.UnicodeScalarView()
                consumeSeparators()
                continue
            }
            if isHardStop(line, index, closer: closer) { break }
            current.append(line[index])
            index += 1
        }
        result.tail = String(current)
        result.end = index
        return result
    }
}
