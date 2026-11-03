import CryptoKit
import Foundation
import Testing
@testable import WrappBuilder

/// The matcher engine: each kind, the tie rule, near misses, and the
/// matchers' syntax in a manifest. GameDetectorTests (the app's) checks the
/// shipped bundles give the slugs detection gave before bundles.
struct DetectionTests {
    private static let id = "test/program"
    private static let other = "test/other"

    private func index(_ matchers: [Matcher], bundle: String = id) -> DetectionIndex {
        DetectionIndex(rules: matchers.map { .init(bundleID: bundle, edition: "cd", matcher: $0) },
                       programs: [.init(bundleID: bundle, title: "Test")])
    }

    private func source(_ names: String..., folder: URL? = nil, volume: String? = nil) -> DetectionSource {
        DetectionSource(signals: names.map { .init(.exeVersion, $0) }, location: folder.map { .folder($0) },
                        volumeName: volume)
    }

    private func recognised(_ result: DetectionIndex.Result) -> String? {
        if case .recognised(let match) = result { match.bundleID } else { nil }
    }

    /// A folder of files: path → contents.
    private func disc(_ files: [String: Data]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (path, data) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return root
    }

    // MARK: Each kind

    @Test func textIsFoundAnywhereCaseAside() {
        let index = index([.text("old clock")])
        #expect(recognised(index.detect(source("NANCY DREW: SECRET OF THE OLD CLOCK"))) == Self.id)
        #expect(recognised(index.detect(source("old", "clock"))) == Self.id, "names are joined with spaces")
        #expect(recognised(index.detect(source("oldclock"))) == nil)
    }

    @Test func aWordIsBetweenSpacesCaseAndAll() {
        let index = index([.word("SEA")])
        #expect(recognised(index.detect(source("Nancy Drew SEA"))) == Self.id)
        #expect(recognised(index.detect(source("SEA"))) == Self.id)
        #expect(recognised(index.detect(source("Nancy Drew sea"))) == nil)
        #expect(recognised(index.detect(source("SEASIDE"))) == nil)
        #expect(recognised(index.detect(source("(SEA)"))) == nil, "a word is between spaces, as today's codes were")
    }

    @Test func aFileExistsByGlobCaseAside() throws {
        let folder = try disc(["Game/Nancy.cid": Data("x".utf8), "SETUP.EXE": Data()])
        #expect(recognised(index([.fileExists(file: "game/nancy.cid")]).detect(source(folder: folder))) == Self.id)
        #expect(recognised(index([.fileExists(file: "Game/*.cid")]).detect(source(folder: folder))) == Self.id)
        #expect(recognised(index([.fileExists(file: "setup.exe")]).detect(source(folder: folder))) == Self.id)
        #expect(recognised(index([.fileExists(file: "*.cid")]).detect(source(folder: folder))) == nil, "* doesn't cross a /")
        #expect(recognised(index([.fileExists(file: "Game/Other.cid")]).detect(source(folder: folder))) == nil)
    }

    @Test func aDownloadIsItsOneFile() throws {
        let folder = try disc(["Nancy_Drew_Setup.exe": Data("Product=Sea of Darkness".utf8)])
        let download = DetectionSource(signals: [], location: .file(folder.appendingPathComponent("Nancy_Drew_Setup.exe")))
        #expect(recognised(index([.fileContains(file: "*.exe", text: "Product=Sea")]).detect(download)) == Self.id)
    }

    @Test func aFileContainsTextInUTF8OrUTF16() throws {
        let utf16 = try #require("Secrets Can Kill".data(using: .utf16LittleEndian))
        let folder = try disc(["a.bin": Data([0, 1]) + Data("Product=Old Clock".utf8), "b.bin": Data([9]) + utf16])
        #expect(recognised(index([.fileContains(file: "a.bin", text: "Product=Old Clock")]).detect(source(folder: folder))) == Self.id)
        #expect(recognised(index([.fileContains(file: "*.bin", text: "Secrets Can Kill")]).detect(source(folder: folder))) == Self.id)
        #expect(recognised(index([.fileContains(file: "a.bin", text: "product=old clock")]).detect(source(folder: folder))) == nil,
                "text in a file is matched as written")
    }

    @Test func aFileHashIsItsSizeAndTheMD5OfItsFirstBytes() throws {
        let contents = Data((0..<200).map { UInt8($0) })
        let folder = try disc(["ciftree.dat": contents])
        let md5 = Insecure.MD5.hash(data: contents.prefix(100)).map { String(format: "%02x", $0) }.joined()
        #expect(recognised(index([.fileHash(file: "ciftree.dat", size: 200, md5: md5, bytes: 100)]).detect(source(folder: folder))) == Self.id)
        #expect(recognised(index([.fileHash(file: "ciftree.dat", size: 201, md5: md5, bytes: 100)]).detect(source(folder: folder))) == nil)
        #expect(recognised(index([.fileHash(file: "ciftree.dat", size: 200, md5: md5, bytes: 101)]).detect(source(folder: folder))) == nil)
    }

    @Test func aProgramsVersionInfoAndAnMSIsSubjectAreReadCaseAside() throws {
        let folder = try disc(["SETUP.EXE": Data("pe".utf8), "game.msi": Data("msi".utf8)])
        let readers = WindowsReaders(
            versionStrings: { $0.lastPathComponent == "SETUP.EXE" ? ["ProductName": "Nancy Drew Secrets Can Kill Remastered"] : nil },
            msiSubject: { $0.pathExtension == "msi" ? "Nancy Drew: The Haunting of Castle Malloy" : nil }
        )
        let exe = index([.exeVersion(file: "setup.exe", key: "ProductName", text: "secrets can kill remastered")])
        #expect(recognised(exe.detect(source(folder: folder), readers: readers)) == Self.id)
        let otherKey = index([.exeVersion(file: "setup.exe", key: "CompanyName", text: "secrets")])
        #expect(recognised(otherKey.detect(source(folder: folder), readers: readers)) == nil)
        let msi = index([.msiSummary(file: Matcher.defaultMSI, subject: "castle malloy")])
        #expect(recognised(msi.detect(source(folder: folder), readers: readers)) == Self.id)
    }

    @Test func aVolumeNameIsWholeCaseAsideWithWildcards() {
        #expect(recognised(index([.volumeName("SCK_*")]).detect(source(volume: "sck_1"))) == Self.id)
        #expect(recognised(index([.volumeName("SCK")]).detect(source(volume: "SCK_1"))) == nil)
        #expect(recognised(index([.volumeName("SCK")]).detect(source())) == nil)
    }

    // MARK: The tie rule

    @Test func theLongestMatchWinsWhateverTheOrder() {
        let rules: [DetectionIndex.Rule] = [
            .init(bundleID: "nancy-drew/secrets-can-kill", matcher: .text("secrets can kill")),
            .init(bundleID: "nancy-drew/secrets-can-kill-remastered", matcher: .text("secrets can kill remastered")),
        ]
        for order in [rules, rules.reversed()] {
            let index = DetectionIndex(rules: order, programs: [])
            #expect(recognised(index.detect(source("Nancy Drew Secrets Can Kill Remastered"))) == "nancy-drew/secrets-can-kill-remastered")
            #expect(recognised(index.detect(source("Secrets Can Kill"))) == "nancy-drew/secrets-can-kill")
        }
    }

    @Test func aHashBeatsAnyText() throws {
        let contents = Data("data".utf8)
        let folder = try disc(["data.bin": contents])
        let md5 = Insecure.MD5.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let index = DetectionIndex(rules: [
            .init(bundleID: Self.other, matcher: .text("a very long title indeed")),
            .init(bundleID: Self.id, edition: "cd", matcher: .fileHash(file: "data.bin", size: 4, md5: md5, bytes: 5000)),
        ], programs: [])
        guard case .recognised(let match) = index.detect(source("A Very Long Title Indeed", folder: folder)) else {
            Issue.record("not recognised")
            return
        }
        #expect(match.bundleID == Self.id)
        #expect(match.rule.edition == "cd")
    }

    @Test func aTrueTieIsAmbiguous() {
        let index = DetectionIndex(rules: [
            .init(bundleID: Self.other, matcher: .text("twin")),
            .init(bundleID: Self.id, matcher: .text("pair")),
        ], programs: [])
        guard case .ambiguous(let tied) = index.detect(source("twin pair")) else {
            Issue.record("a tie wasn't reported as one")
            return
        }
        #expect(tied.map(\.bundleID) == [Self.other, Self.id])
    }

    @Test func oneBundleMatchingTwiceIsNoTie() {
        let index = DetectionIndex(rules: [
            .init(bundleID: Self.id, matcher: .text("twin")),
            .init(bundleID: Self.id, matcher: .word("PAIR")),
        ], programs: [])
        #expect(recognised(index.detect(source("twin PAIR"))) == Self.id)
    }

    // MARK: Near misses

    @Test func mostOfATitlesWordsIsANearMiss() {
        let index = DetectionIndex(rules: [.init(bundleID: Self.id, matcher: .text("secret of the old clock"))],
                                   programs: [.init(bundleID: Self.id, title: "Secret of the Old Clock", series: "Nancy Drew")])
        let result = index.detect(DetectionSource(signals: [.init(.setupIni, "Old Clock Secret Edition"), .init(.folderName, "OC_1")]))
        guard case .unrecognised(let nearMiss) = result, let nearMiss else {
            Issue.record("no near miss in \(result)")
            return
        }
        #expect(nearMiss.bundleID == Self.id)
        #expect(nearMiss.reason == .titleWords)
        #expect(nearMiss.signalKinds == [.setupIni, .folderName])
    }

    @Test func aSeriesAloneIsANearMiss() {
        let index = DetectionIndex(rules: [.init(bundleID: Self.id, matcher: .text("secret of the old clock"))],
                                   programs: [.init(bundleID: Self.id, title: "Secret of the Old Clock", series: "Nancy Drew")])
        guard case .unrecognised(let nearMiss) = index.detect(source("Nancy Drew: Clock")), let nearMiss else {
            Issue.record("no near miss")
            return
        }
        #expect(nearMiss.bundleID == nil)
        #expect(nearMiss.reason == .series)
        #expect(nearMiss.series == "Nancy Drew")
        guard case .unrecognised(nil) = index.detect(source("Something Else Entirely")) else {
            Issue.record("a near miss with nothing like a title")
            return
        }
    }

    @Test func aHashedFileWithAnotherMD5IsANearMissWithTheFilesDetails() throws {
        let contents = Data("other bytes".utf8)
        let folder = try disc(["Data/ciftree.dat": contents])
        let index = index([.fileHash(file: "data/ciftree.dat", size: 99, md5: String(repeating: "0", count: 32), bytes: 5000)])
        guard case .unrecognised(let nearMiss) = index.detect(source(folder: folder)), let nearMiss else {
            Issue.record("no near miss")
            return
        }
        #expect(nearMiss.reason == .fileHash)
        #expect(nearMiss.file?.name == "Data/ciftree.dat")
        #expect(nearMiss.file?.size == contents.count)
        #expect(nearMiss.file?.md5 == Insecure.MD5.hash(data: contents).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: In a manifest

    private static let manifest = """
    format: 1
    id: "nancy-drew/old-clock"
    version: 1
    title: "The Secret of the Old Clock"
    editions:
      - id: "cd"
        source: "disc"
        inputs: [{ id: "disc-1" }]
        detect:
          aliases: ["Nancy Drew OC"]
          codes: ["OCK"]
          matchers:
            - file-exists: "Game/Nancy.cid"
            - file-contains: { file: "setup.ini", text: "Product=Old Clock" }
            - file-hash: { file: "ciftree.dat", size: 10, md5: "0123456789abcdef0123456789abcdef" }
            - exe-version: { file: "setup.exe", key: "ProductName", text: "Old Clock" }
            - msi-summary: { subject: "Old Clock" }
            - volume-name: "OC_*"

    """

    private func problems(_ yaml: String) throws -> [String] {
        let validator = try SchemaValidator()
        try validator.addSchema(Data(contentsOf: bundlesRoot.appendingPathComponent("manifest.schema.json")))
        return try validator.problems(with: try YAML12.load(yaml), against: ProgramBundle.manifestSchemaID).map(\.description)
    }

    @Test func everyKindIsWrittenInTheManifest() throws {
        #expect(try problems(Self.manifest) == [])
        let manifest = try Manifest.decode(try YAML12.load(Self.manifest))
        let rules = DetectionIndex.rules(manifest)
        #expect(rules.filter { $0.edition == nil }.map(\.matcher) == [.text("secret of the old clock"), .text("nancy drew oc"), .word("OCK")])
        #expect(rules.filter { $0.edition == "cd" }.map(\.matcher) == [
            .fileExists(file: "Game/Nancy.cid"),
            .fileContains(file: "setup.ini", text: "Product=Old Clock"),
            .fileHash(file: "ciftree.dat", size: 10, md5: "0123456789abcdef0123456789abcdef", bytes: Matcher.defaultHashBytes),
            .exeVersion(file: "setup.exe", key: "ProductName", text: "Old Clock"),
            .msiSummary(file: Matcher.defaultMSI, subject: "Old Clock"),
            .volumeName("OC_*"),
        ])
    }

    @Test(arguments: [
        // Two kinds in one matcher
        "- { file-exists: \"a\", volume-name: \"b\" }",
        // A kind there isn't
        "- { file-size: \"a\" }",
        // A path from the root
        "- file-exists: \"/setup.exe\"",
        // An md5 that isn't one
        "- file-hash: { file: \"a\", size: 1, md5: \"abc\" }",
        // A version string Windows doesn't have
        "- exe-version: { file: \"setup.exe\", key: \"Title\", text: \"a\" }",
        // A mistyped field
        "- file-contains: { file: \"a\", txt: \"b\" }",
    ])
    func aMatcherIsCheckedStrictly(matcher: String) throws {
        let yaml = Self.manifest.replacingOccurrences(of: "- volume-name: \"OC_*\"", with: matcher)
        #expect(try !problems(yaml).isEmpty, "\(matcher) passed")
    }

    // MARK: The shipped bundles

    @Test func everyShippedBundleIsRecognisedByItsTitleAlone() throws {
        let index = try DetectionIndex.load(bundlesAt: bundlesRoot)
        let loader = try ProgramBundleLoader(root: bundlesRoot, modules: nil)
        for bundle in try loader.loadAll().get() {
            let result = index.detect(DetectionSource(signals: [.init(.exeVersion, "Nancy Drew: \(bundle.manifest.title)")]))
            #expect(recognised(result) == bundle.manifest.id, "\(bundle.manifest.title): \(result)")
        }
    }
}
