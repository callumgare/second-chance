import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import IconLabAPI
@testable import IconLabKit

/// Whether Xcode's actool is here, which compiling an `.icns` needs.
nonisolated enum Xcode {
    static let hasActool: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--find", "actool"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()
}

/// The host's programs, wrapps and bundles through the API, over scratch folders: a data folder, a built-apps folder
/// with a made-up app in it, and a Bundles folder with two made-up bundles.
@Suite final class HostRouteTests {
    let root: URL
    let bundles: URL
    let apps: URL
    let api: IconLabAPI

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-host-\(UUID().uuidString)")
        bundles = root.appendingPathComponent("Bundles")
        apps = root.appendingPathComponent("built-apps")
        let fm = FileManager.default
        for (id, manifest, wrappfile) in [
            ("freeware/plain", "format: 1\nid: \"freeware/plain\"\ntitle: \"Plain\"\n\neditions: []\n",
             "FROM --module=wine@10 prefix AS download\nLAUNCH --wine.graphics=unknown \\\n    \"C:/plain.exe\"\n"),
            ("demo/two-stages", "format: 1\nid: \"demo/two-stages\"\ntitle: \"Two Stages\"\nallow-paths: [\"mac/\"]   # a script\n",
             "FROM scratch AS a\nLAUNCH a\nFROM scratch AS b\nLAUNCH b\n"),
        ] {
            let folder = bundles.appendingPathComponent(id)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.yaml"))
            try Data(wrappfile.utf8).write(to: folder.appendingPathComponent("Wrappfile"))
        }
        let app = apps.appendingPathComponent("Plain.app/Contents")
        try fm.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.plain", "CFBundleIconName": "AppIcon", "CFBundleExecutable": "plain"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("MacOS/plain"))
        let host = LabHostInfo(knownPrograms: KnownProgram.read(bundles: bundles), bundles: bundles)
        api = IconLabAPI(dataDir: root.appendingPathComponent("data"), webRoot: nil, tools: LabTools(builtApps: apps), host: host)
    }

    deinit {
        do { try FileManager.default.removeItem(at: root) } catch { Issue.record("couldn't remove \(root.path): \(error)") }
    }

    func call(_ method: String, _ path: String, _ body: String? = nil) async -> APIResponse {
        await api.handle(APIRequest(method: method, path: path, body: Data((body ?? "").utf8)))
    }

    func json(_ r: APIResponse) throws -> Any { try JSONSerialization.jsonObject(with: r.bodyData()) }

    /// A design of shapes alone, so it renders with no pictures.
    func saveDesign(_ slug: String) async throws -> String {
        let doc = Doc(name: "Bands", program: slug, fill: Fill(kind: .solid, color: RGB(20, 40, 80)),
                      groups: [Group(name: "G", layers: [Layer(name: "Bands", content: .shape(Shape("bands", ["colors": ["#ff0000", "#00ff00"]])))])])
        let r = await call("POST", "/api/programs/\(slug)/pins", String(decoding: try JSONEncoder().encode(["doc": doc]), as: UTF8.self))
        #expect(r.status == 200)
        return doc.id
    }

    @Test func listsTheHostsProgramsAndOpensOneByItsBundle() async throws {
        let host = try #require(json(await call("GET", "/api/host")) as? [String: Any])
        #expect(host["knownPrograms"] as? Int == 2 && host["saveToBundle"] as? Bool == true && host["wrapps"] as? Bool == true)
        let known = try #require(json(await call("GET", "/api/known-programs")) as? [[String: Any]])
        #expect(known.map { $0["id"] as? String } == ["freeware/plain", "demo/two-stages"])
        #expect(known.first?["slug"] as? String == "freeware--plain" && known.first?["opened"] as? Bool == false)
        let made = await call("POST", "/api/known-programs/open", #"{"id": "freeware/plain"}"#)
        #expect(made.status == 201)
        #expect(await call("POST", "/api/known-programs/open", #"{"id": "freeware/plain"}"#).status == 200)
        #expect(await call("POST", "/api/known-programs/open", #"{"id": "nope/none"}"#).status == 404)
        let program = try #require(json(await call("GET", "/api/programs/freeware--plain")) as? [String: Any])
        #expect(program["bundleId"] as? String == "freeware/plain" && program["title"] as? String == "Plain")
    }

    @Test func listsTheBuiltWrapps() async throws {
        let wrapps = try #require(json(await call("GET", "/api/wrapps")) as? [[String: Any]])
        #expect(wrapps.count == 1)
        #expect(wrapps.first?["name"] as? String == "Plain" && wrapps.first?["bundleIdentifier"] as? String == "test.plain")
    }

    @Test func refusesAWrappItDidntBuildUnlessAsked() async throws {
        let slug = "freeware--plain"
        #expect(await call("POST", "/api/known-programs/open", #"{"id": "freeware/plain"}"#).status == 201)
        let id = try await saveDesign(slug)
        let elsewhere = root.appendingPathComponent("Elsewhere.app")
        try FileManager.default.copyItem(at: apps.appendingPathComponent("Plain.app"), to: elsewhere)
        let r = await call("POST", "/api/programs/\(slug)/try-icon", #"{"id": "\#(id)", "wrapp": "\#(elsewhere.path)"}"#)
        #expect(r.status == 400)
        #expect(await call("POST", "/api/programs/\(slug)/try-icon", #"{"wrapp": "\#(elsewhere.path)"}"#).status == 400)
    }

    @Test(.enabled(if: Xcode.hasActool, "compiling an .icns needs Xcode's actool"))
    func putsADesignOnABuiltWrapp() async throws {
        let slug = "freeware--plain"
        #expect(await call("POST", "/api/known-programs/open", #"{"id": "freeware/plain"}"#).status == 201)
        let id = try await saveDesign(slug)
        let app = apps.appendingPathComponent("Plain.app")
        let r = await call("POST", "/api/programs/\(slug)/try-icon", #"{"id": "\#(id)", "wrapp": "\#(app.path)"}"#)
        #expect(r.status == 200, "\(String(decoding: (try? r.bodyData()) ?? Data(), as: UTF8.self))")
        let plist = try #require(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
        #expect(plist["CFBundleIconFile"] as? String == "\(slug).icns")
        #expect(plist["CFBundleIconName"] == nil)
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/\(slug).icns").path))
    }

    @Test(.enabled(if: Xcode.hasActool, "compiling an .icns needs Xcode's actool"))
    func savesDesignsToTheBundleAndAddsItsIconLines() async throws {
        let slug = "freeware--plain"
        #expect(await call("POST", "/api/known-programs/open", #"{"id": "freeware/plain"}"#).status == 201)
        let a = try await saveDesign(slug), b = try await saveDesign(slug)
        let r = await call("POST", "/api/programs/\(slug)/save-to-bundle", #"{"ids": ["\#(a)", "\#(b)"]}"#)
        #expect(r.status == 200, "\(String(decoding: (try? r.bodyData()) ?? Data(), as: UTF8.self))")
        let saved = try #require(json(r) as? [String: Any])
        #expect(saved["files"] as? [String] == ["assets/plain.icon", "assets/plain.icns", "assets/plain-2.icon", "assets/plain-2.icns"])
        #expect(saved["allowPathAdded"] as? Bool == true && saved["canAddLines"] as? Bool == true)
        let folder = bundles.appendingPathComponent("freeware/plain")
        let manifest = try String(contentsOf: folder.appendingPathComponent("manifest.yaml"), encoding: .utf8)
        #expect(manifest.contains("title: \"Plain\"\nallow-paths: [\"assets/\"]   # its icon\n"))
        let set = try #require(json(await call("POST", "/api/programs/\(slug)/save-to-bundle/lines")) as? [String: Any])
        #expect(set["lines"] as? [String] == ["COPY bundle:assets/plain.icns /Resources/plain.icns", "APP --icon=/Resources/plain.icns"])
        #expect(set["change"] as? String == "added")
        let wrappfile = try String(contentsOf: folder.appendingPathComponent("Wrappfile"), encoding: .utf8)
        #expect(wrappfile.hasSuffix("    \"C:/plain.exe\"\n# Its icon, made in Icon Lab (assets/plain.icon, compiled by `sc generate`).\n"
            + "COPY bundle:assets/plain.icns /Resources/plain.icns\nAPP --icon=/Resources/plain.icns\n"))
    }

    @Test func savingNeedsAProgramFromABundle() async throws {
        let result = #"{"key": "x", "title": "Loose", "platforms": [], "ids": {}, "links": {}, "hits": [], "score": 1, "mergeReasons": []}"#
        let r = await call("POST", "/api/programs", #"{"result": \#(result)}"#)
        let slug = try #require((json(r) as? [String: Any])?["slug"] as? String)
        #expect(await call("POST", "/api/programs/\(slug)/save-to-bundle", #"{"ids": ["x"]}"#).status == 400)
    }

    @Test func anIconItHasIsPointedAtTheNewOne() throws {
        // an APP --icon and the COPY that put its icon in /Resources/: both pointed at the saved one
        let own = "FROM scratch AS a\nLAUNCH a\nCOPY bundle:assets/old.icns /Resources/old.icns\nAPP --icon=/Resources/old.icns --name=A\n"
        let (o, oc) = try #require(Lab.settingIcon(own, name: "x"))
        #expect(oc == "updated")
        #expect(o == "FROM scratch AS a\nLAUNCH a\nCOPY bundle:assets/x.icns /Resources/x.icns\nAPP --icon=/Resources/x.icns --name=A\n")
        #expect(Lab.settingIcon(o, name: "x")?.1 == "unchanged")
        // a module's icon, from another place: the COPY added, the APP pointed
        let module = "FROM scratch AS a\nCOPY module:nancy-drew:/assets/nancy-drew.icns /Resources/nancy-drew.icns\nAPP --icon=/Resources/nancy-drew.icns\n"
        let (m, _) = try #require(Lab.settingIcon(module, name: "x"))
        #expect(m.contains("COPY bundle:assets/x.icns /Resources/x.icns\nAPP --icon=/Resources/x.icns\n"))
        // a module's function that sets its icon: replaced, keeping its indent
        let fn = "FROM scratch AS a\n  DO nancy-drew.set-icon\nLAUNCH a\n"
        let (f, fc) = try #require(Lab.settingIcon(fn, name: "x"))
        #expect(fc == "replaced")
        #expect(f == "FROM scratch AS a\n  COPY bundle:assets/x.icns /Resources/x.icns\n  APP --icon=/Resources/x.icns\nLAUNCH a\n")
        // an APP line without an icon gets one
        #expect(Lab.settingIcon("FROM scratch AS a\nAPP --name=A\n", name: "x")?.0
            == "FROM scratch AS a\nCOPY bundle:assets/x.icns /Resources/x.icns\nAPP --icon=/Resources/x.icns --name=A\n")
    }

    @Test func aStageItCantPlaceIsLeftToThePerson() {
        let two = "FROM scratch AS a\nLAUNCH a\nFROM scratch AS b\nLAUNCH b\n"
        #expect(Lab.addingIconLines(two, name: "x") == nil)
        #expect(Lab.allowingAssets("id: \"a/b\"\nallow-paths: [\"mac/\"]   # a script\n").0 == "id: \"a/b\"\nallow-paths: [\"mac/\", \"assets/\"]   # a script\n")
        #expect(Lab.allowingAssets("allow-paths: [\"assets/\"]\n").1 == false)
        #expect(Lab.allowingAssets("allow-paths:\n  - \"mac/\"\n").2 != nil)
        #expect(KnownProgram.slug(forBundle: "nancy-drew/old-clock") == "nancy-drew--old-clock")
    }

    /// A made-up Icon Composer icon whose one layer is a black disc on nothing (one colour, nearly black), scanned
    /// into the bundle's program through `api`: the scan's job when it ended, and the pictures it added.
    func scanIcon(_ api: IconLabAPI) async throws -> (job: Jobs.Job?, added: [MediaRecord]) {
        let icon = root.appendingPathComponent("drawn.icon")
        if !FileManager.default.fileExists(atPath: icon.path) {
            try FileManager.default.createDirectory(at: icon.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            try Data(#"{"groups":[{"layers":[{"image-name":"Shape.png","name":"Shape"}]}]}"#.utf8).write(to: icon.appendingPathComponent("icon.json"))
            let ctx = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 40, y: 40, width: 432, height: 432))
            let png = try #require(ctx.makeImage())
            let dest = try #require(CGImageDestinationCreateWithURL(icon.appendingPathComponent("Assets/Shape.png") as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, png, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        let lab = api.lab
        let slug = try await lab.openKnown("freeware/plain").slug
        let scan = try await lab.extract(slug, path: icon.path)
        var job: Jobs.Job?
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            job = await lab.jobs.all().first { $0.scan == scan && ($0.state == "done" || $0.state == "failed") }
            if job != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return (job, await lab.store.media(slug).filter { $0.source == "Your files" })
    }

    /// An Icon Composer icon's layers are often one-colour silhouettes, which the extractor ranks as hardly art: a
    /// chosen `.icon` brings them all in anyway (and, with no `ictool` to render it, only them).
    @Test func anIconsLayersAllComeIn() async throws {
        let (job, added) = try await scanIcon(api)
        #expect(job?.state == "done")
        #expect(job?.detail == "1 picture added")
        #expect(added.count == 1)
    }

    /// With Icon Composer's `ictool`, a chosen `.icon` comes in as it looks too: rendered, an icon.
    @Test(.enabled(if: LabTools.installedICTool != nil, "needs Xcode's Icon Composer"))
    func anIconComesInRenderedToo() async throws {
        let withTool = IconLabAPI(dataDir: root.appendingPathComponent("data-ictool"), webRoot: nil,
                                  tools: LabTools(ictool: LabTools.installedICTool, builtApps: apps),
                                  host: LabHostInfo(knownPrograms: KnownProgram.read(bundles: bundles), bundles: bundles))
        let (job, added) = try await scanIcon(withTool)
        #expect(job?.detail == "2 pictures added")
        let rendered = try #require(added.first { $0.name == "drawn.png" })
        #expect(rendered.kind == "icon")
        #expect(rendered.width == 1024)
    }

    /// Choosing Second Chance's program from a search result that a program was already opened from (by its ids)
    /// makes the bundle's program with that one's pins and design in it, rather than an empty one beside it.
    @Test func choosingTheBundlesResultCarriesOnTheWorkDoneOnIt() async throws {
        let store = api.lab.store
        var old = Store.ProgramInfo(slug: "plain-old", title: "Plain")
        old.ids = ["wikidata": "Q42"]
        try await store.saveProgram(old)
        var st = Store.State()
        st.pins = ["d1", "d2"]
        st.current = "d3"
        st.dropped = ["d2"]
        try await store.saveState("plain-old", st)

        var r = Merger.merge([hit("wikidata", "Q42", "Plain", ids: ["wikidata": "Q42"])])[0]
        r.bundleId = "freeware/plain"
        let slug = try await api.catalog.createProgram(r)
        #expect(slug == KnownProgram.slug(forBundle: "freeware/plain"))
        #expect(await store.program("plain-old") == nil)
        let now = await store.state(slug)
        #expect(now.pins == ["d1", "d2"] && now.current == "d3" && now.dropped == ["d2"])
        #expect(await store.program(slug)?.ids?["wikidata"] == "Q42")
    }

    @Test func aQueuedJobCanBeCancelled() async throws {
        let jobs = Jobs(width: 1)
        let gate = AsyncStream<Void>.makeStream()
        let first = await jobs.enqueue(title: "Hold") { _ in for await _ in gate.stream {} }
        let second = await jobs.enqueue(title: "Waiting") { _ in }
        #expect(await jobs.cancel(second))
        #expect(await jobs.all().first { $0.id == second }?.detail == "cancelled")
        #expect(await jobs.cancel(first))
        gate.continuation.finish()
        #expect(await !jobs.cancel("nothing"))
    }
}
