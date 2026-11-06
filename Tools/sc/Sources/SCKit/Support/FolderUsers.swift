import Foundation

/// The processes using a folder, going by their command lines: a build in a
/// checkout's DerivedData, or something run from it.
///
/// Every build that writes to a checkout's DerivedData names it: `sc` passes
/// xcodebuild `-derivedDataPath`, and the compilers xcodebuild starts are
/// given paths inside it. So does what runs from it: the app `sc app run`
/// launched, the test host, a GUI-session job's script in `sc-jobs`. Xcode's
/// own window builds into ~/Library/Developer/Xcode/DerivedData, not here.
/// Every user's processes are looked at, since a test user's login can run
/// something from this checkout too.
enum FolderUsers {
    struct User: Equatable {
        let pid: Int32
        let name: String
    }

    static func of(_ folder: URL) async -> [User] {
        guard let listing = try? await Proc.collect("/bin/ps", ["-axww", "-o", "pid=,command="]), listing.succeeded else { return [] }
        return matching(listing.output, folder: folder, excluding: getpid())
    }

    /// The `ps -o pid=,command=` lines whose command names `folder` or
    /// something inside it, other than `excluding`'s.
    static func matching(_ listing: String, folder: URL, excluding: Int32) -> [User] {
        let paths = Set([folder.standardizedFileURL.path, folder.resolvingSymlinksInPath().path])
        return listing.split(separator: "\n").compactMap { line in
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]), pid != excluding else { return nil }
            let command = String(trimmed[space...].drop { $0 == " " })
            guard paths.contains(where: { names(command, $0) }) else { return nil }
            return User(pid: pid, name: name(of: command))
        }
    }

    /// Whether `command` has `path` itself, or a path beneath it, rather than
    /// a sibling that only starts the same (`DerivedData2`).
    private static func names(_ command: String, _ path: String) -> Bool {
        var rest = command[...]
        while let range = rest.range(of: path) {
            let after = rest[range.upperBound...].first
            if after == nil || after == "/" || after == " " || after == "\"" || after == "'" || after == "=" { return true }
            rest = rest[range.upperBound...]
        }
        return false
    }

    /// The program's name: its executable's last path component, or an app's
    /// name when it's inside one.
    private static func name(of command: String) -> String {
        if let app = command.range(of: ".app/Contents/MacOS/"), !command[..<app.lowerBound].contains(" -") {
            return (String(command[..<app.lowerBound]) as NSString).lastPathComponent
        }
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        return (executable as NSString).lastPathComponent
    }
}
