//
//  ProgramImagesTests.swift
//  WrappKitTests
//
//  Reading images out of programs, installers and discs (ProgramImages, and
//  what it added to WindowsFormats and ClassicMacFormats), on files built
//  byte by byte (ProgramImagesFixtures). Every parser is also fed truncated
//  and bit-flipped copies: a damaged file gives less, never a crash or a hang.

import ClassicMacFormats
import Foundation
import Testing
@testable import ProgramImages
@testable import WindowsFormats

@Suite("Windows resources")
struct WindowsResourceTests {
    static let icon = Fixture.dibIcon4()

    static func program(overlay: [UInt8] = []) -> Data {
        Fixture.pe(resources: [
            .init(type: .id(3), name: .id(1), data: icon),
            .init(type: .id(14), name: .name("MAINICON"), data: Fixture.groupIcon(ids: [1], byteCount: icon.count)),
            .init(type: .id(2), name: .name("OPENING"), data: Fixture.dib24(width: 40, height: 20)),
            .init(type: .id(10), name: .name("LOGO"), data: [UInt8](pngData(width: 12, height: 10))),
        ], overlay: overlay)
    }

    static func pngData(width: Int, height: Int) -> Data {
        var image = RGBAImage.blank(width: width, height: height, bitDepth: 32)
        for y in 0..<height { for x in 0..<width { image?.set(x, y, UInt8((x * 20) & 0xFF), UInt8((y * 20) & 0xFF), 90, 255) } }
        return image?.pngData() ?? Data()
    }

    @Test("Every resource is listed, named ones by name")
    func listsResources() throws {
        let program = try #require(WindowsExecutable(data: Self.program()))
        let resources = program.resources
        #expect(resources.count == 4)
        #expect(resources.contains { $0.type == .id(14) && $0.name == .name("MAINICON") })
        #expect(resources.contains { $0.type == .id(2) && $0.name == .name("OPENING") && $0.data?.count == 40 + 20 * 120 })
    }

    @Test("An icon group gathers its images, and makes an .ico")
    func iconGroup() throws {
        let program = try #require(WindowsExecutable(data: Self.program()))
        let icons = ProgramIcons(resources: program.resources)
        #expect(icons.iconGroups.count == 1)
        let group = try #require(icons.group(forIconIndex: 0))
        #expect(group.name == .name("MAINICON"))
        #expect(group.images.count == 1)
        let ico = try #require(ICOFile(data: group.icoFile))
        #expect(ico.images.count == 1)
        #expect(ico.images.first?.data == Data(Self.icon))
    }

    @Test("A 4-bit icon decodes with its palette and its mask")
    func decodesIcon() throws {
        let image = try #require(WindowsImageDecoder.decodeIconImage(Data(Self.icon)))
        #expect(image.width == 16 && image.height == 16)
        #expect(image.bitDepth == 4)
        // Top left red, bottom right see-through, elsewhere blue.
        #expect(Array(image.pixels[0..<4]) == [255, 0, 0, 255])
        let last = (16 * 16 - 1) * 4
        #expect(image.pixels[last + 3] == 0)
        let blue = (8 * 16 + 9) * 4
        #expect(Array(image.pixels[blue..<blue + 4]) == [0, 0, 255, 255])
    }

    @Test("A bitmap resource decodes, rows the right way up")
    func decodesBitmap() throws {
        let image = try #require(WindowsImageDecoder.decodeBitmap(Data(Fixture.dib24(width: 40, height: 20))))
        #expect(image.width == 40 && image.height == 20)
        #expect(Array(image.pixels[0..<4]) == [0, 255, 0, 255])
        #expect(Array(image.pixels[4..<8]) == [160, 80, 40, 255])
    }

    @Test("What follows the last section is the overlay; UPX is noticed")
    func overlayAndUPX() throws {
        let program = try #require(WindowsExecutable(data: Self.program(overlay: [UInt8](repeating: 7, count: 100))))
        #expect(program.overlay?.count == 100)
        #expect(try #require(WindowsExecutable(data: Self.program())).overlay == nil)
        let packed = Fixture.pe(resources: [.init(type: .id(10), name: .id(1), data: [1, 2, 3])],
                                sectionNames: [".rsrc", "UPX0", "UPX1"])
        #expect(try #require(WindowsExecutable(data: packed)).isUPXPacked)
    }

    @Test("A 16-bit program's icon group is read")
    func neIcons() throws {
        let program = try #require(NEExecutable(data: Fixture.ne(icon: Self.icon)))
        #expect(program.moduleName == "TESTMOD")
        let icons = ProgramIcons(resources: program.resources)
        let group = try #require(icons.iconGroups.first)
        #expect(group.images.count == 1)
        #expect(WindowsImageDecoder.decodeIconImage(try #require(group.images.first?.data))?.width == 16)
    }

    @Test("A shortcut gives its target and icon")
    func shellLink() throws {
        let link = try #require(ShellLink(data: Fixture.shellLink(target: "C:\\Games\\Tank\\tank.exe",
                                                                   icon: "C:\\Games\\Tank\\tank.ico", iconIndex: -101)))
        #expect(link.target == "C:\\Games\\Tank\\tank.exe")
        #expect(link.iconLocation == "C:\\Games\\Tank\\tank.ico")
        #expect(link.iconIndex == -101)
    }

    @Test("autorun.inf's program and icon")
    func autorun() throws {
        let autorun = try #require(AutorunInf(text: "[AutoRun]\r\nopen=\"setup.exe\" /auto\r\nICON=game\\disc.ico,2\r\nlabel=GAME\r\n"))
        #expect(autorun.open == "setup.exe")
        #expect(autorun.icon == "game\\disc.ico")
        #expect(autorun.iconIndex == 2)
        #expect(autorun.label == "GAME")
    }

    @Test("MSI stream names unpack")
    func msiNames() {
        // "Icon" packed as two units (Ic, on) under the table marker.
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._")
        func pair(_ a: Character, _ b: Character) -> UInt16 {
            UInt16(0x3800 + (alphabet.firstIndex(of: a) ?? 0) + ((alphabet.firstIndex(of: b) ?? 0) << 6))
        }
        let packed = String(decoding: [0x4840, pair("I", "c"), pair("o", "n")], as: UTF16.self)
        #expect(MSIStreams.decode(packed) == "!Icon")
        #expect(MSIStreams.decode("plain") == "plain")
    }

    @Test("Damaged programs and icons give less, never a crash")
    func survivesDamage() {
        for data in Fixture.damaged(Self.program(overlay: [1, 2, 3, 4])) {
            if let program = WindowsExecutable(data: data) {
                _ = ProgramIcons(resources: program.resources).groups.flatMap(\.images).map {
                    WindowsImageDecoder.decodeIconImage($0.data)
                }
                _ = program.overlay
            }
        }
        for data in Fixture.damaged(Fixture.ne(icon: Self.icon)) {
            _ = NEExecutable(data: data).map { ProgramIcons(resources: $0.resources) }
        }
        for data in Fixture.damaged(Data(Fixture.ico(Self.icon))) {
            _ = ICOFile(data: data)?.images.map { WindowsImageDecoder.decodeIconImage($0.data) }
            _ = WindowsImageDecoder.decodeBitmap(data)
        }
        for data in Fixture.damaged(Fixture.shellLink(target: "C:\\a.exe", icon: "C:\\a.ico")) {
            _ = ShellLink(data: data)
        }
    }
}

@Suite("Classic Mac formats")
struct ClassicMacFormatTests {
    @Test("A resource fork's resources, and the bundle's icon family")
    func resourceFork() throws {
        let fork = try #require(ResourceFork(data: Data(Fixture.applicationFork())))
        #expect(fork.types == ["ICN#", "icl8", "BNDL", "FREF"])
        #expect(fork.bundleIconID() == 128)
        #expect(fork.bundleSignature == "TEST")
    }

    @Test("An icon family decodes, the colour icon masked by ICN#")
    func iconFamily() throws {
        let fork = try #require(ResourceFork(data: Data(Fixture.applicationFork())))
        let family = MacIconDecoder.family(128, in: fork)
        #expect(family.map(\.type) == ["icl8", "ICN#"])
        let colour = try #require(family.first?.image)
        // Index 5 of the 8-bit palette is FF FF 00.
        #expect(Array(colour.pixels[0..<4]) == [0xFF, 0xFF, 0x00, 255])
        #expect(MacPalettes.eightBit.count == 256)
        #expect(MacPalettes.eightBit[255] == (0, 0, 0))
    }

    @Test("MacBinary, AppleSingle and BinHex give both forks")
    func encodings() throws {
        let fork = Fixture.applicationFork()
        let binary = try #require(MacBinary.decode(Fixture.macBinary(name: "Game", type: "APPL", creator: "TEST",
                                                                     data: [1, 2, 3], resource: fork)))
        #expect(binary.name == "Game" && binary.type == "APPL" && binary.dataFork == Data([1, 2, 3]))
        #expect(binary.resourceFork == Data(fork))

        let single = try #require(AppleSingle.decode(Fixture.appleSingle(type: "APPL", data: [9], resource: fork)))
        #expect(single.type == "APPL" && single.hasCustomIcon && single.resourceFork == Data(fork))

        let hex = try #require(BinHex.decode(Fixture.binHex(name: "Game", type: "APPL", data: [0x90, 5, 6], resource: fork)))
        #expect(hex.name == "Game" && hex.dataFork == Data([0x90, 5, 6]) && hex.resourceFork == Data(fork))
    }

    @Test("An HFS volume's files, forks and Finder info")
    func hfs() throws {
        let image = Fixture.hfs(name: "Test Disc", application: "Game", data: [1, 2, 3, 4],
                                resource: Fixture.applicationFork(), volumeIcon: Fixture.applicationFork())
        let volume = try #require(HFSVolume(source: image))
        #expect(volume.name == "Test Disc")
        let entries = volume.entries()
        let game = try #require(entries.first { $0.name == "Game" })
        #expect(game.type == "APPL" && game.path == ["Game"])
        #expect(volume.dataFork(of: game) == Data([1, 2, 3, 4]))
        #expect(volume.resourceFork(of: game) == Data(Fixture.applicationFork()))
        #expect(entries.contains { $0.name == "Icon\r" })
    }

    @Test("Damaged Mac files give less, never a crash")
    func survivesDamage() {
        for data in Fixture.damaged(Data(Fixture.applicationFork())) {
            if let fork = ResourceFork(data: data) {
                _ = fork.bundleIconID()
                for id in Set(fork.resources.map(\.id)) { _ = MacIconDecoder.family(id, in: fork) }
            }
        }
        let fork = Fixture.applicationFork()
        for data in Fixture.damaged(Fixture.macBinary(name: "A", type: "APPL", creator: "X", data: [1], resource: fork)) {
            _ = MacBinary.decode(data)
        }
        for data in Fixture.damaged(Fixture.appleSingle(type: "APPL", data: [1], resource: fork)) {
            _ = AppleSingle.decode(data)
        }
        for data in Fixture.damaged(Fixture.binHex(name: "A", type: "APPL", data: [1], resource: fork)) {
            _ = BinHex.decode(data)
        }
        let image = Fixture.hfs(name: "V", application: "A", data: [1], resource: fork, volumeIcon: fork)
        for data in Fixture.damaged(image) {
            if let volume = HFSVolume(source: data) {
                for entry in volume.entries() {
                    _ = volume.dataFork(of: entry)
                    _ = volume.resourceFork(of: entry)
                }
            }
        }
    }
}

@Suite("Discs and carving")
struct DiscAndCarvingTests {
    @Test("An ISO 9660 image's files are read without mounting it")
    func iso() throws {
        let image = Fixture.iso(files: [("AUTORUN.INF", Fixture.ascii("[autorun]\nicon=setup.exe\n")),
                                        ("SETUP.EXE", [UInt8](WindowsResourceTests.program()))])
        let iso = try #require(ISO9660(source: image))
        #expect(iso.volumeName == "TESTDISC")
        let entries = iso.entries()
        #expect(entries.map(\.path) == ["AUTORUN.INF", "SETUP.EXE"])
        let setup = try #require(entries.last)
        #expect(iso.read(setup) == WindowsResourceTests.program())
    }

    @Test("A raw 2352-byte-sector image reads as its 2048-byte sectors")
    func rawSectors() throws {
        let iso = Fixture.iso(files: [("A.TXT", Fixture.ascii("hello"))])
        var raw = Data()
        for sector in 0..<(iso.count / 2048) {
            raw += Data([0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]) + Data([0, 2, 0, 1])
            raw += iso[(sector * 2048)..<((sector + 1) * 2048)]
            raw += Data(count: 288)
        }
        let source = try #require(RawSectorSource(raw))
        let read = try #require(ISO9660(source: source))
        #expect(read.entries().first.map { read.read($0) } == Data("hello".utf8))
    }

    @Test("Images are carved out of a blob whole, by their own structure")
    func carving() throws {
        let png = WindowsResourceTests.pngData(width: 20, height: 20)
        let bmp = try #require(DIBHeader.bmpFile(Data(Fixture.dib24(width: 10, height: 10))))
        var blob = Data(count: 333) + png + Data(count: 17) + bmp + Data("GIF89 not really".utf8)
        blob += Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0])  // a stray signature
        let hits = ImageCarver.carve(blob)
        #expect(hits.map(\.kind) == [.png, .bmp])
        #expect(hits.first?.range == 333..<(333 + png.count))
        #expect(hits.last?.range.count == bmp.count)
    }

    @Test("PCX: 8-bit with its palette at the end")
    func pcx() throws {
        var header = [UInt8](repeating: 0, count: 128)
        header[0] = 0x0A; header[1] = 5; header[2] = 1; header[3] = 8
        Fixture.put(Fixture.le16(3), into: &header, at: 8)  // xMax: 4 wide
        Fixture.put(Fixture.le16(1), into: &header, at: 10)  // yMax: 2 high
        header[65] = 1
        Fixture.put(Fixture.le16(4), into: &header, at: 66)
        // Row 1: a run of four 2s; row 2: 1 2 3 4.
        let pixels: [UInt8] = [0xC4, 2, 1, 2, 3, 4]
        var palette = [UInt8](repeating: 0, count: 768)
        palette[6] = 200  // colour 2: red 200
        let image = try #require(PCXDecoder.decode(Data(header + pixels + [0x0C] + palette)))
        #expect(image.width == 4 && image.height == 2)
        #expect(Array(image.pixels[0..<4]) == [200, 0, 0, 255])
    }

    @Test("Damaged discs and blobs give less, never a crash")
    func survivesDamage() {
        let image = Fixture.iso(files: [("A.EXE", [UInt8](WindowsResourceTests.program()))])
        for data in Fixture.damaged(image) {
            if let iso = ISO9660(source: data) { for entry in iso.entries() { _ = iso.read(entry) } }
            _ = ImageCarver.carve(data)
            _ = PCXDecoder.decode(data)
        }
    }
}

@Suite("Program image crawl")
struct ProgramImageCrawlTests {
    @Test("The filter's globs")
    func globs() {
        #expect(PathFilter.glob("**/drive_c/windows/**", "contents/sharedsupport/prefix/drive_c/windows/system32/a.dll"))
        #expect(PathFilter.glob("**/drive_c/windows/**", "drive_c/windows/"))
        #expect(!PathFilter.glob("**/drive_c/windows/**", "drive_c/windowsapps/a.dll"))
        #expect(PathFilter.glob("*.txt", "readme.txt"))
        #expect(!PathFilter.glob("*.txt", "a/readme.txt"))
        #expect(PathFilter.glob("program files*/common files/**", "program files (x86)/common files/x"))
        let filter = PathFilter(keep: ["autorun.inf"], skip: [.init(pattern: "*.inf", reason: "text")],
                                demote: [.init(pattern: "**/system32/**", reason: "system")])
        #expect(filter.verdict(for: "AUTORUN.INF") == .read)
        #expect(filter.verdict(for: "drivers/x.inf") == .skip("text"))
        #expect(filter.verdict(for: "windows/system32/a.dll") == .demote("system"))
    }

    @Test("In a wrapp, only its program and its own icon are read")
    func wrappFilter() throws {
        let wrapp = try PathFilter().forWrapp(keeping: ["contents/resources/AppIcon.icns",
                                                        "contents/resources/GenericWrappIcon.icns"])
        #expect(wrapp.verdict(for: "Contents/Resources/AppIcon.icns") == .read)
        #expect(wrapp.verdict(for: "Contents/Resources/GenericWrappIcon.icns") != .read)
        #expect(wrapp.verdict(for: "Contents/Resources/gui-icons.dat") != .read)
        #expect(wrapp.verdict(for: "Contents/Resources/scummvm/") != .read)
        #expect(wrapp.verdict(for: "Contents/Resources/") == .read)
        #expect(wrapp.verdict(for: "Contents/SharedSupport/game/data.pak") == .read)
        // Not a wrapp: a Mac app's resources are its own.
        #expect(try PathFilter().verdict(for: "Contents/Resources/gui-icons.dat") == .read)
    }

    @Test("The shipped filter table loads")
    func shippedTable() throws {
        let filter = try PathFilter()
        #expect(filter.verdict(for: "Contents/SharedSupport/prefix/drive_c/windows/system32/user32.dll") != .read)
    }

    /// A folder like an installed program: the program, a shortcut naming
    /// it, a loose icon, a picture with images in an unknown blob.
    private func installedProgram() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-images-\(UUID().uuidString)")
        let game = root.appendingPathComponent("drive_c/Games/Tank")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try WindowsResourceTests.program().write(to: game.appendingPathComponent("tank.exe"))
        try Fixture.shellLink(target: "C:\\Games\\Tank\\tank.exe", icon: nil)
            .write(to: root.appendingPathComponent("drive_c/Tank.lnk"))
        try Data(Fixture.ico(Fixture.dibIcon4(size: 32), size: 32)).write(to: game.appendingPathComponent("other.ico"))
        try (Data(count: 500) + WindowsResourceTests.pngData(width: 30, height: 30) + Data(count: 100))
            .write(to: game.appendingPathComponent("data.pak"))
        try Data("hello".utf8).write(to: game.appendingPathComponent("readme.txt"))
        return root
    }

    @Test("A crawl finds every image, says where, and ranks the program's icon first")
    func crawl() throws {
        let root = try installedProgram()
        let output = root.appendingPathComponent("out")
        defer { try? FileManager.default.removeItem(at: root) }
        let events = EventLog()
        var options = ExtractionOptions(outputDirectory: output)
        options.useTools = false
        let summary = try ProgramImageExtractor.extractSynchronously(root.appendingPathComponent("drive_c"), options: options) {
            events.append($0)
        }
        let records = summary.records
        let top = try #require(records.first)
        #expect(top.roles.contains(.shortcutIcon) && top.roles.contains(.mainProgramIcon) && top.roles.contains(.firstIconGroup))
        #expect(top.provenance.first?.display == "drive_c › Games/Tank/tank.exe › RT_GROUP_ICON MAINICON › 16×16 4-bit")
        #expect(records.contains { $0.provenance.contains { $0.display.contains("RT_BITMAP OPENING") } })
        #expect(records.contains { $0.provenance.contains { $0.display.contains("RT_RCDATA LOGO") } })
        #expect(records.contains { $0.roles.contains(.carved) && $0.width == 30 })
        #expect(records.contains { $0.provenance.contains { $0.display.hasSuffix("other.ico › 32×32 4-bit") } })
        for record in records {
            #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent(record.file).path))
        }
        #expect(FileManager.default.fileExists(atPath: summary.recordsFile.path))
        let lines = events.lines
        #expect(lines.contains { $0.contains("\"event\":\"skip\"") && $0.contains("readme.txt") })
        #expect(lines.last?.contains("\"event\":\"done\"") == true)
        #expect(lines.filter { $0.contains("\"event\":\"image\"") }.count >= records.count)
    }

    @Test("The same icon found twice is one image with both places")
    func dedupes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try WindowsResourceTests.program().write(to: root.appendingPathComponent("a.exe"))
        try Data(Fixture.ico(WindowsResourceTests.icon)).write(to: root.appendingPathComponent("a.ico"))
        var options = ExtractionOptions(outputDirectory: root.appendingPathComponent("out"))
        options.useTools = false
        let records = try ProgramImageExtractor.extractSynchronously(root, options: options) { _ in }.records
        let icon = try #require(records.first { $0.width == 16 && $0.height == 16 })
        #expect(icon.sources == 2)
        #expect(icon.provenance.count == 2)
    }

    @Test("A crawl asked to stop stops, with CancellationError")
    func stopsWhenCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try WindowsResourceTests.program().write(to: root.appendingPathComponent("a.exe"))
        var options = ExtractionOptions(outputDirectory: root.appendingPathComponent("out"))
        options.useTools = false
        options.isCancelled = { true }
        await #expect(throws: CancellationError.self) {
            _ = try await ProgramImageExtractor.extract(root, options: options) { _ in }
        }
        // a cancelled task stops it too, though the crawl runs on a thread of its own
        options.isCancelled = nil
        let task = Task { try await ProgramImageExtractor.extract(root, options: options) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test("A hybrid disc's Mac side: the volume icon and the application's own")
    func macDisc() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let disc = root.appendingPathComponent("disc.hfs")
        // The volume icon: a different family (ID -16455) from the app's.
        let volumeIcon = Fixture.resourceFork([("ICN#", -16455, nil, [UInt8](repeating: 0xAA, count: 128)
                                                + [UInt8](repeating: 0xFF, count: 128))])
        try Fixture.hfs(name: "Game CD", application: "Game", data: [], resource: Fixture.applicationFork(),
                        volumeIcon: volumeIcon).write(to: disc)
        var options = ExtractionOptions(outputDirectory: root.appendingPathComponent("out"))
        options.useTools = false
        let records = try ProgramImageExtractor.extractSynchronously(disc, options: options) { _ in }.records
        #expect(records.contains { $0.roles.contains(.volumeIcon) })
        let app = try #require(records.first { $0.roles.contains(.macAppIcon) && $0.bitDepth == 8 })
        #expect(app.provenance.first?.display == "disc.hfs › Game CD › Game › resource fork › icl8 128 › 32×32 8-bit")
    }

    // sandbox-exec is deprecated; should a macOS drop it, this says so as a skip.
    @Test("A tool runs sandboxed: it can't write outside its folder, and its links are removed",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")))
    func sandbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside")
        let shell = ExternalTool(name: "bash", executable: URL(fileURLWithPath: "/bin/bash"))
        let run = SandboxedRunner.run(shell, arguments: [
            "-c", "echo hi > '\(output.path)/inside'; ln -s /etc/hosts '\(output.path)/link'; echo no > '\(outside.path)'",
        ], readable: [root], output: output, timeout: 30, maxFileBytes: 1 << 20)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("inside").path))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: output.appendingPathComponent("link").path)) == nil)
        #expect(run.bytesWritten == 3)
    }

    @Test("A tool that runs too long is stopped",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")))
    func timeout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("program-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let shell = ExternalTool(name: "bash", executable: URL(fileURLWithPath: "/bin/bash"))
        let started = Date()
        let run = SandboxedRunner.run(shell, arguments: ["-c", "while :; do :; done"], readable: [root], output: output,
                                      timeout: 1, maxFileBytes: 1 << 20)
        #expect(run.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

/// Events collected from the crawl's thread.
nonisolated final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func append(_ event: ExtractionEvent) {
        lock.lock()
        defer { lock.unlock() }
        collected.append(event.jsonLine)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
