//
//  PathRedactorTests.swift
//  SecondChanceKitTests
//
//  What a report keeps of a path: macOS's folders, ours, and what's on a
//  disc or in a program; the person's own folders become placeholders.

import Foundation
import Testing
@testable import SecondChanceKit

@Suite("Path redactor")
struct PathRedactorTests {
    private let mounts: [String: MountedVolume] = [
        "/Volumes/Nancy Drew": MountedVolume(kind: .discImage),
        "/Volumes/HAU Disk 1": MountedVolume(kind: .opticalDisc),
        "/Volumes/MyExternalHardDrive": MountedVolume(kind: .externalDrive),
        "/Volumes/WIN10": MountedVolume(kind: .internalDrive),
        "/Volumes/share": MountedVolume(kind: .networkDrive, source: "//nancy@nas.local/share"),
        "/Users/nancy/WebmasterWin": MountedVolume(kind: .opticalDisc),
    ]

    private func redactor() -> PathRedactor {
        PathRedactor(homePath: "/Users/nancy", mounts: mounts)
    }

    // MARK: The examples the rules were written from

    @Test("A folder of the person's own goes; the disc image in it stays")
    func folderInDownloads() {
        #expect(redactor().redact("/Users/nancy/Downloads/stuff/nancy-drew.iso") == "~/Downloads/<folder-1>/nancy-drew.iso")
    }

    @Test("A disc image's volume, or a disc's, is kept whole")
    func discVolume() {
        let redactor = redactor()
        #expect(redactor.redact("/Volumes/Nancy Drew/install/installer.exe") == "/Volumes/Nancy Drew/install/installer.exe")
        #expect(redactor.redact("/Volumes/HAU Disk 1/Setup.exe") == "/Volumes/HAU Disk 1/Setup.exe")
    }

    @Test("A drive's name and the folders on it go; a program on it is kept, with what's inside")
    func externalDrive() {
        #expect(redactor().redact("/Volumes/MyExternalHardDrive/games/Nancy Drew - White Wolf.app/Contents/Resources/something")
            == "/Volumes/<external-drive-1>/Nancy Drew - White Wolf.app/Contents/Resources/something")
    }

    @Test("Temporary folders are kept")
    func temporary() {
        let path = "/var/folders/r5/bktcjy_96_g43nvl7cz9sxfm0000gn/T/NancyDrew-2ED709B4-4972.app/Contents"
        #expect(redactor().redact(path) == path)
        #expect(redactor().redact("/private" + path) == "/private" + path)
        #expect(redactor().redact("/tmp/second-chance-x/log.txt") == "/tmp/second-chance-x/log.txt")
    }

    @Test("Second Chance's own folders in the Library are kept")
    func ours() {
        let redactor = redactor()
        #expect(redactor.redact("/Users/nancy/Library/Caches/SecondChance/game-patches/scarlet-hand/sshphone.zip")
            == "~/Library/Caches/SecondChance/game-patches/scarlet-hand/sshphone.zip")
        #expect(redactor.redact("/Users/nancy/Library/Application Support/SecondChance/stores/steam/sign-in/session.lock")
            == "~/Library/Application Support/SecondChance/stores/steam/sign-in/session.lock")
        #expect(redactor.redact("/Users/nancy/Library/Logs/SecondChance/unknown/launch-20261111-202917.log")
            == "~/Library/Logs/SecondChance/unknown/launch-20261111-202917.log")
        #expect(redactor.redact("/Users/nancy/Library/Caches/au.gare.callum.second-chance.program.nancy-drew.blue-moon/prefix/drive_c")
            == "~/Library/Caches/au.gare.callum.second-chance.program.nancy-drew.blue-moon/prefix/drive_c")
        #expect(redactor.redact("/Users/Shared/second-chance/installers/nancy-drew/old-clock/cd/disc-1.iso")
            == "/Users/Shared/second-chance/installers/nancy-drew/old-clock/cd/disc-1.iso")
    }

    @Test("Another app's folder in the Library is redacted")
    func otherApps() {
        #expect(redactor().redact("/Users/nancy/Library/Application Support/VMware Fusion/x.plist")
            == "~/Library/Application Support/<folder-1>/<file-1>")
    }

    @Test("A cloud folder is kept, what's in it goes, in one placeholder up to a disc image")
    func cloud() {
        let redactor = redactor()
        #expect(redactor.redact("/Users/nancy/Library/CloudStorage/Dropbox/blar/blar/foo/bar/nancy-drew.iso")
            == "~/Library/CloudStorage/<cloud-1>/nancy-drew.iso")
        #expect(redactor.redact("/Users/nancy/Library/Mobile Documents/com~apple~CloudDocs/Games/old-clock.iso")
            == "~/Library/Mobile Documents/<cloud-2>/old-clock.iso")
    }

    @Test("A user-content bundle is no program: its name and contents go")
    func photosLibrary() {
        #expect(redactor().redact("/Users/nancy/Pictures/Photos Library.photoslibrary/originals/A/IMG_1.jpg")
            == "~/Pictures/<folder-1>/<file-1>")
    }

    // MARK: Numbering

    @Test("The same folder is the same placeholder; another folder is the next number")
    func numbering() {
        let redactor = redactor()
        let text = """
            ~/Downloads/stuff/a.iso
            ~/Downloads/stuff/b.iso
            ~/Downloads/other/c.iso
            """
        #expect(redactor.redact(text) == """
            ~/Downloads/<folder-1>/a.iso
            ~/Downloads/<folder-1>/b.iso
            ~/Downloads/<folder-2>/c.iso
            """)
    }

    @Test("A new table starts at 1 again, so reports can't be linked")
    func freshTable() {
        #expect(redactor().redact("~/Downloads/other/c.iso") == "~/Downloads/<folder-1>/c.iso")
        #expect(redactor().redact("~/Downloads/stuff/c.iso") == "~/Downloads/<folder-1>/c.iso")
    }

    @Test("Redacting twice changes nothing more")
    func idempotent() {
        let redactor = redactor()
        let once = redactor.redact("""
            /Users/nancy/Downloads/stuff/nancy-drew.iso
            /Volumes/MyExternalHardDrive/games/White Wolf.app/Contents
            /Users/nancy/Library/CloudStorage/Dropbox/a/b.iso
            /Users/nancy/Desktop/notes.txt
            /Users/george/Desktop/a.iso
            """)
        #expect(redactor.redact(once) == once)
        #expect(PathRedactor(homePath: "/Users/nancy").redact(once) == once)
    }

    // MARK: Volumes

    @Test("A volume nothing is known about is redacted as a volume")
    func unknownVolume() {
        #expect(redactor().redact("/Volumes/Untitled/Setup.exe") == "/Volumes/<volume-1>/Setup.exe")
        #expect(redactor().redact("/Volumes/Untitled") == "/Volumes/<volume-1>")
    }

    @Test("An internal drive's name goes")
    func internalDrive() {
        #expect(redactor().redact("/Volumes/WIN10/Games/Setup.exe") == "/Volumes/<internal-drive-1>/Setup.exe")
    }

    @Test("A disc mounted outside /Volumes is kept as one")
    func discInHome() {
        #expect(redactor().redact("/Users/nancy/WebmasterWin/WEBMASTR.EXE") == "~/WebmasterWin/WEBMASTR.EXE")
    }

    @Test("A network drive's server, account and share go, as one placeholder wherever they're named")
    func network() {
        let redactor = redactor()
        #expect(redactor.redact("//nancy@nas.local/share on /Volumes/share (smbfs, nodev, nosuid, mounted by nancy)")
            == "//<network-drive-1> on /Volumes/<network-drive-1> (smbfs, nodev, nosuid, mounted by nancy)")
        #expect(redactor.redact("smb://nancy@nas.local/share/Games/a.iso") == "smb://<network-drive-1>/<folder-1>/a.iso")
        #expect(redactor.redact("afp://other.local/Media") == "afp://<network-drive-2>")
    }

    // MARK: Other forms

    @Test("Wine's view of the Mac, through Z:")
    func wine() {
        #expect(redactor().redact(#"Z:\Users\nancy\Downloads\stuff\Setup.exe"#) == #"Z:~\Downloads\<folder-1>\Setup.exe"#)
        #expect(redactor().redact(#"L"Z:\\Users\\nancy\\Desktop\\cider\\Files\\Game\\Spy.exe") not found"#)
            == #"L"Z:~\\Desktop\\<folder-1>\\Spy.exe") not found"#)
        // Inside the prefix is ours, Program Files and all.
        let prefix = #"C:\Program Files (x86)\Her Interactive\Sea of Darkness\SeaOfDarkness.exe"#
        #expect(redactor().redact(prefix) == prefix)
    }

    @Test("A file URL, percent-encoded")
    func fileURL() {
        #expect(redactor().redact("file:///Users/nancy/Downloads/My%20Games/old%20clock.iso")
            == "file://~/Downloads/<folder-1>/old%20clock.iso")
    }

    @Test("A home with a space, as a path and percent-encoded")
    func spacedHome() {
        let redactor = PathRedactor(homePath: "/Users/Nancy Drew")
        #expect(redactor.redact("/Users/Nancy%20Drew/Desktop/a.iso and /Users/Nancy Drew/Desktop/b.iso")
            == "~/Desktop/a.iso and ~/Desktop/b.iso")
    }

    @Test("Another account's home keeps that it was a home")
    func otherHome() {
        #expect(redactor().redact("/Users/george/Library/Caches/SecondChance/x") == "/Users/<user>/Library/Caches/SecondChance/x")
        #expect(redactor().redact("/Users/george/Desktop/secret/a.iso") == "/Users/<user>/Desktop/<folder-1>/a.iso")
    }

    @Test("The data volume's view of a home is still the home")
    func dataVolume() {
        #expect(redactor().redact("/System/Volumes/Data/Users/nancy/Desktop/x/a.iso") == "~/Desktop/<folder-1>/a.iso")
    }

    @Test("A container's app id goes; its Data is a home's layout")
    func containers() {
        #expect(redactor().redact("/Users/nancy/Library/Containers/com.example.App/Data/Documents/a.iso")
            == "~/Library/Containers/<folder-1>/Data/Documents/a.iso")
    }

    @Test("A Steam account's number in its userdata folder goes")
    func steamUserdata() {
        let path = "/Users/nancy/Library/Caches/SecondChance/stores/x/drive_c/Program Files (x86)/Steam/userdata/52079950/config"
        #expect(redactor().redact(path)
            == "~/Library/Caches/SecondChance/stores/x/drive_c/Program Files (x86)/Steam/userdata/<steam-id>/config")
    }

    // MARK: Paths in running text

    @Test("A path at the end of a line, in a sentence, in quotes and in brackets")
    func inText() {
        #expect(redactor().redact("Her Interactive download: /Users/nancy/Desktop/Setup.exe")
            == "Her Interactive download: ~/Desktop/Setup.exe")
        #expect(redactor().redact("Mounting /Users/nancy/Desktop/x/a.iso failed: no space")
            == "Mounting ~/Desktop/<folder-1>/a.iso failed: no space")
        #expect(redactor().redact("cd '/Users/nancy/Desktop/Sea of Darkness.app/Contents' && ls")
            == "cd '~/Desktop/Sea of Darkness.app/Contents' && ls")
        #expect(redactor().redact("(/Users/nancy/Documents/notes/plan.txt)") == "(~/Documents/<folder-1>/<file-1>)")
        #expect(redactor().redact("copy /Users/nancy/Desktop/a.iso to /Users/nancy/Movies/b/c.iso")
            == "copy ~/Desktop/a.iso to ~/Movies/<folder-1>/c.iso")
    }

    @Test("A file's name ends at its extension; a folder's runs to where nothing more can be told")
    func tails() {
        #expect(redactor().redact("/Users/nancy/Desktop/My Notes.txt exited 1") == "~/Desktop/<file-1> exited 1")
        // Fail safe: no extension, so the rest of the line could be the name.
        #expect(redactor().redact("/Users/nancy/Desktop/My Folder exited 1") == "~/Desktop/<folder-1>")
        #expect(redactor().redact("in /Users/nancy/Desktop/Photos, then") == "in ~/Desktop/<folder-1>, then")
        #expect(redactor().redact("/Users/nancy/Downloads") == "~/Downloads")
        #expect(redactor().redact("/Users/nancy/Downloads/") == "~/Downloads/")
        #expect(redactor().redact("saved to /Users/nancy/Downloads.") == "saved to ~/Downloads.")
    }

    @Test("Slashes that aren't paths are left alone")
    func notPaths() {
        let redactor = redactor()
        for text in ["start /wait SeaOfDarkness.exe", "1/2 done", "and/or", "msiexec /i setup.msi /qn",
                     "https://example.com/a/b?c=d", "x86_64/arm64"] {
            #expect(redactor.redact(text) == text)
        }
    }

    @Test("The places macOS keeps for itself are kept")
    func system() {
        for path in ["/System/Library/Frameworks/AppKit.framework/AppKit", "/usr/lib/libSystem.B.dylib",
                     "/Library/Application Support/Apple/x", "/Applications/Steam.app/Contents/MacOS/steam_osx",
                     "/opt/homebrew/bin/hdiutil", "/dev/disk4"] {
            #expect(redactor().redact(path) == path)
        }
        #expect(redactor().redact("/Applications/Games/X.app") == "/Applications/<folder-1>/X.app")
        #expect(redactor().redact("/Projects/secret/a.iso") == "/<folder-1>/a.iso")
    }
}
