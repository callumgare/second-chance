import Darwin
import Foundation
import Testing
@testable import SCKit

@Suite("sc clean")
struct CleanTests {
    @Test("A clone family counts once when all of it is deleted, and not at all when some of it stays")
    func cloneFamilies() {
        let clone = DiskUsage.FileSpace(allocated: 1000, privateSize: 0, cloneID: 7, cloneCount: 2)
        var both = DiskUsage.Tally()
        both.add(clone)
        both.add(clone)
        #expect(both.total == 1000)

        var one = DiskUsage.Tally()
        one.add(clone)
        #expect(one.total == 0)

        var plain = DiskUsage.Tally()
        plain.add(DiskUsage.FileSpace(allocated: 400, privateSize: 300, cloneID: 9, cloneCount: 1))
        plain.add(DiskUsage.FileSpace(allocated: 4096))
        #expect(plain.total == 300 + 4096)
    }

    @Test("Deleting a clone frees nothing while the original stays, and both free the file's size once")
    func realClones() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sc-clean-tests-\(UUID().uuidString)")
        let original = base.appendingPathComponent("main/DerivedData")
        let copy = base.appendingPathComponent("worktree/DerivedData")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = 4 << 20
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }).write(to: original.appendingPathComponent("big"))
        #expect(clonefile(original.appendingPathComponent("big").path, copy.appendingPathComponent("big").path, 0) == 0)

        let clone = DiskUsage.freed(by: [copy])
        let all = DiskUsage.freed(by: [original, copy])
        #expect(clone < 64 << 10)
        #expect(all >= Int64(bytes) && all < Int64(bytes) + 256 << 10)
    }

    @Test("A process is using a folder when its command line names it or a path inside it")
    func folderUsers() {
        let listing = """
          101 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme Second Chance -derivedDataPath /r/DerivedData build
          102 /r/DerivedData/Build/Products/Debug/Second Chance.app/Contents/MacOS/Second Chance
          103 /bin/bash /r/.claude/worktrees/x/DerivedData/sc-jobs/1/job.sh
          104 /usr/bin/tail -f /r/DerivedData2/log
          105 /bin/ls /r/DerivedData
        """
        let users = FolderUsers.matching(listing, folder: URL(fileURLWithPath: "/r/DerivedData"), excluding: 105)
        #expect(users == [
            FolderUsers.User(pid: 101, name: "xcodebuild"),
            FolderUsers.User(pid: 102, name: "Second Chance"),
        ])
    }

    @Test("Xcode's folders for a checkout, or named after the repo's project with nothing to say whose, are this repo's")
    func xcodeFolders() {
        typealias Folder = XcodeDerivedData.Folder
        let folders = [
            Folder(name: "SecondChance-avrtzuliojkaijeesdwswiqtzgev", workspace: "/r/SecondChance.xcodeproj"),
            Folder(name: "SecondChance-bkutabmyyevjmfcwoduprowglxnw", workspace: "/r/.claude/worktrees/gone/SecondChance.xcodeproj"),
            Folder(name: "WrappKit-cekormqixxpmmpgfnvmcsoxdibkk", workspace: "/elsewhere/WrappKit"),
            Folder(name: "WrappKit-dmjlvkpttjlfipebsznwwzlydbuc", workspace: "/w/Packages/WrappKit"),
            Folder(name: "SecondChance-esrlfglaptyvdwcqmbymzjresplr", workspace: nil),
            Folder(name: "Other-fngaudspblvwvgdanonrpsorwbvh", workspace: nil),
            Folder(name: "SecondChance-x", workspace: nil),
            Folder(name: "ModuleCache.noindex", workspace: nil),
            Folder(name: "Sibling-ghsqkfjqiuvmhufcmtixhijkalzr", workspace: "/r2/Sibling.xcodeproj"),
        ]
        let ours = XcodeDerivedData.ours(folders, checkouts: [URL(fileURLWithPath: "/r"), URL(fileURLWithPath: "/w")], projects: ["SecondChance"])
        #expect(ours == [
            "SecondChance-avrtzuliojkaijeesdwswiqtzgev",
            "SecondChance-bkutabmyyevjmfcwoduprowglxnw",
            "WrappKit-dmjlvkpttjlfipebsznwwzlydbuc",
            "SecondChance-esrlfglaptyvdwcqmbymzjresplr",
        ])
    }
}
