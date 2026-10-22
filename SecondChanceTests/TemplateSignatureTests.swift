import Testing
import Foundation
@testable import SecondChance

/// `WrappBuildHelper.verifyTemplateSignatures`: a template whose non-Mach-O
/// files lost the signatures they keep in extended attributes fails at once.
@Suite("Template signature check")
struct TemplateSignatureTests {

    /// A minimal bundle signed the way `setup-wine.sh` signs the template:
    /// each file in `Frameworks` on its own, then the bundle. The DLL isn't
    /// Mach-O, so codesign keeps its signature in extended attributes.
    private func makeSignedBundle() throws -> (bundle: URL, dll: URL) {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent("template-\(UUID().uuidString).app")
        let contents = bundle.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/Template"))
        let plist: [String: Any] = ["CFBundleExecutable": "Template", "CFBundleIdentifier": "test.template", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let dll = contents.appendingPathComponent("Frameworks/renderer/d3d9.dll")
        try fm.createDirectory(at: dll.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ not really a DLL".utf8).write(to: dll)
        try codesign(["--force", "--sign", "-", dll.path])
        try codesign(["--force", "--sign", "-", bundle.path])
        return (bundle, dll)
    }

    private func codesign(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "codesign \(arguments.joined(separator: " ")) failed")
    }

    @Test("An intact template passes")
    func intactPasses() throws {
        let (bundle, _) = try makeSignedBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        try WrappBuildHelper.shared.verifyTemplateSignatures(bundle)
    }

    @Test("A template copied without extended attributes fails with templateSignaturesLost")
    func strippedFails() throws {
        let (bundle, dll) = try makeSignedBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }
        for name in ["com.apple.cs.CodeDirectory", "com.apple.cs.CodeRequirements"] {
            _ = removexattr(dll.path, name, 0)
        }
        #expect {
            try WrappBuildHelper.shared.verifyTemplateSignatures(bundle)
        } throws: { error in
            guard case WrappError.templateSignaturesLost = error else { return false }
            return true
        }
    }
}
