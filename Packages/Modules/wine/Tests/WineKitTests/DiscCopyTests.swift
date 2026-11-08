import Darwin
import Testing
@testable import WineExecutor

struct DiscCopyTests {
    @Test("A hybrid disc's unreadable ._ associated file is left out of the copy, and nothing else is")
    func associatedFiles() {
        #expect(DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/._Acrobat Installer.exe", errno: EINVAL))
        #expect(DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/Data/._layer1.cxt", errno: EINVAL))
        // A read that failed for another reason is still a broken disc.
        #expect(!DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/._Acrobat Installer.exe", errno: EIO))
        // So is any other file that can't be read.
        #expect(!DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/Webmaster.exe", errno: EINVAL))
        #expect(!DiscCopy.isUnreadableAssociatedFile("/Volumes/disc/._folder/Webmaster.exe", errno: EINVAL))
    }
}
