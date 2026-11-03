import Testing
@testable import SecondChanceKit

@Suite("Wine's registry")
struct WineRegistryTests {
    @Test("Values are written as a .reg file writes them")
    func regData() {
        #expect(WineRegistry.regData(.string("cdrom")) == #""cdrom""#)
        #expect(WineRegistry.regData(.string(#"C:\Games\"Nancy""#)) == #""C:\\Games\\\"Nancy\"""#)
        #expect(WineRegistry.regData(.dword(1)) == "dword:00000001")
        #expect(WineRegistry.regData(.dword(0xDEADBEEF)) == "dword:deadbeef")
    }
}
