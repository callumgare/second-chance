import Foundation
import Testing
@testable import DOSBoxKit
import WrappModules

struct DOSBoxPathsTests {
    let contents = URL(fileURLWithPath: "/Apps/Tyrian.app/Contents")

    @Test func cIsDOSBoxsDriveInTheApp() {
        #expect(DOSBoxPaths.location(of: "C:/TYRIAN/", type: "dosbox", in: contents)?.path
                == "/Apps/Tyrian.app/Contents/SharedSupport/dosbox/c/TYRIAN")
        #expect(DOSBoxPaths.location(of: "D:/x", type: "dosbox", in: contents) == nil)
    }

    @Test func olderSettingsNameAProgramFromTheDrivesRoot() {
        #expect(DOSBoxPaths.legacyProgramPath(of: "C:/TYRIAN/TYRIAN2K.EXE", type: "dosbox") == "/TYRIAN/TYRIAN2K.EXE")
    }
}
