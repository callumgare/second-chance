import Foundation
import Testing
@testable import SecondChanceKit

@Suite("Big Fish kept sign-in")
struct BigFishSessionStoreTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("big-fish-store-\(UUID().uuidString)")

    /// user.reg as Wine writes it, the Game Manager signed in.
    static let signedIn = """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        [Software\\\\Big Fish Games\\\\Client] 1793650000
        #time=1dc4c0e2a6b3c4e
        "AccessExpires"="1793653600"
        "AccessToken"="eyJhbGciOi.access"
        "Email"="person@example.com"
        "EmailError"=dword:00000000
        "RefreshExpires"="1794200000"
        "RefreshToken"="eyJhbGciOi.refresh"

        [Software\\\\Big Fish Games\\\\Client\\\\Settings] 1793650000
        "Language"="en"

        [Software\\\\Wine\\\\Drives] 1793650000
        "d:"="cdrom"

        """

    @Test func keepsOnlyTheSignInsValues() throws {
        let fragment = try #require(BigFishSessionStore.fragment(fromUserReg: Self.signedIn))
        #expect(fragment.hasPrefix("REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Big Fish Games\\Client]\r\n"))
        for line in [#""AccessToken"="eyJhbGciOi.access""#, #""RefreshToken"="eyJhbGciOi.refresh""#,
                     #""Email"="person@example.com""#, #""EmailError"=dword:00000000"#] {
            #expect(fragment.contains(line))
        }
        #expect(!fragment.contains("Language"), "Took a value from another key")
        #expect(!fragment.contains("cdrom"))
        #expect(!fragment.contains("#time"))
    }

    @Test func noTokensIsNoSignIn() {
        let signedOut = Self.signedIn.components(separatedBy: "\n").filter { !$0.contains("Token") }.joined(separator: "\n")
        #expect(BigFishSessionStore.fragment(fromUserReg: signedOut) == nil)
    }

    @Test func keepsRestoresAndSignsOut() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Self.signedIn.write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        let store = BigFishSessionStore(root: root.appendingPathComponent("store"))
        #expect(!store.hasSession)
        #expect(try store.restore(into: prefix) == nil)

        #expect(try store.capture(from: prefix))
        #expect(store.hasSession)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fragment.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        #expect(try store.restore(into: prefix) == BigFishSessionStore.fragmentWindowsPath)
        let restored = prefix.appendingPathComponent(BigFishSessionStore.fragmentInPrefix)
        #expect(FileManager.default.fileExists(atPath: restored.path))
        BigFishSessionStore.removeFragment(from: prefix)
        #expect(!FileManager.default.fileExists(atPath: restored.path))

        try store.signOut()
        #expect(!store.hasSession)
    }

    @Test func aPrefixWithNoSignInKeepsWhatWasKept() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let userReg = prefix.appendingPathComponent("user.reg")
        try Self.signedIn.write(to: userReg, atomically: true, encoding: .utf8)
        let store = BigFishSessionStore(root: root.appendingPathComponent("store"))
        #expect(try store.capture(from: prefix))
        try "WINE REGISTRY Version 2\n".write(to: userReg, atomically: true, encoding: .utf8)
        #expect(try !store.capture(from: prefix))
        #expect(store.hasSession)
    }
}
