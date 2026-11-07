import Foundation
@testable import IconLabAPI
import Testing

/// The page built into IconLabAPI's resources is the page in Tools/icon-lab/web: its recorded hash
/// (`Resources/source.sha256`, written by `sc icon-lab build`) is the source's.
@Suite struct WebBuildTests {
    /// Tests/IconLabKitTests/WebBuildTests.swift → the checkout.
    static let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let resources = checkout.appendingPathComponent("Packages/IconLab/Sources/IconLabAPI/Resources")

    @Test func builtPageMatchesItsSource() throws {
        let recorded = try String(contentsOf: Self.resources.appendingPathComponent("source.sha256"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = try WebSourceHash.compute(root: Self.checkout.appendingPathComponent("Tools/icon-lab/web"))
        #expect(recorded == source, "Icon Lab's built page is stale: its source in Tools/icon-lab/web has changed. Run `sc icon-lab build`.")
    }

    @Test func pageIsBundled() throws {
        let root = try #require(IconLabAPI.bundledWebRoot, "IconLabAPI has no built page in its resources. Run `sc icon-lab build`.")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path))
    }

    @Test func bundledPageIsServed() async throws {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-webtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let api = IconLabAPI(dataDir: data)
        let answer = await api.handle(APIRequest(method: "GET", path: "/", query: [], headers: [:], body: Data()))
        #expect(answer.status == 200)
        #expect(answer.headers["Content-Type"] == "text/html")
    }
}
