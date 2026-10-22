import Foundation
import Testing
@testable import SecondChance

@Suite("Game quit check")
struct GameQuitCheckTests {
    // From the launch of The White Wolf of Icicle Creek that quit when the
    // display had no 800x600 mode.
    private let refusedMode = #"013c:err:system:NtUserChangeDisplaySettings Changing L"\\\\.\\DISPLAY1" display settings returned -2."#
    private let armed = "second-chance-helper[QuitWatch] notice: armed in Game.exe"
    private let firstFrame = "second-chance-helper[QuitWatch] notice: first frame on screen"
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func started(_ graphicsAPI: GameGraphicsAPI = .direct3D, throughSteam: Bool = false) -> GameQuitCheck {
        let check = GameQuitCheck(graphicsAPI: graphicsAPI, throughSteam: throughSteam)
        check.observe(line: armed, at: start)
        check.windowDidAppear()
        return check
    }

    @Test("A Direct3D game that drew and quit with no Wine error near the end was quit")
    func quitAfterDrawing() {
        let check = started()
        check.observe(line: firstFrame, at: start + 1)
        #expect(check.failure(exitedAt: start + 60) == nil)
    }

    @Test("A Direct3D game that quit before drawing failed, and Wine's refusal says why")
    func quitBeforeDrawing() throws {
        let check = started()
        check.observe(line: refusedMode, at: start + 1.2)
        let failure = try #require(check.failure(exitedAt: start + 2))
        #expect(failure.summary == "it quit before it drew anything")
        #expect(failure.explanation.contains("display mode this Mac doesn't have"))
        #expect(failure.wineErrors == [refusedMode])
    }

    @Test("A cnc-ddraw game's frames say nothing, so it isn't judged by them")
    func ignoresCncDdrawFrames() {
        #expect(started(.directDraw).failure(exitedAt: start + 60) == nil)
        #expect(started(.unknown).failure(exitedAt: start + 60) == nil)
    }

    @Test("Without quit watch armed, a missing first frame proves nothing")
    func needsQuitWatchForFrames() {
        let check = GameQuitCheck(graphicsAPI: .direct3D, throughSteam: false)
        check.windowDidAppear()
        #expect(check.failure(exitedAt: start + 60) == nil)
    }

    @Test("A game that quit before its window appeared failed")
    func quitBeforeWindow() throws {
        let check = GameQuitCheck(graphicsAPI: .directDraw, throughSteam: false)
        let failure = try #require(check.failure(exitedAt: start + 5))
        #expect(failure.summary == "it quit before its window appeared")
        // A frame on screen means it had one, whether the wrapp saw it or not.
        check.observe(line: armed, at: start)
        check.observe(line: firstFrame, at: start + 1)
        #expect(check.failure(exitedAt: start + 60) == nil)
    }

    @Test("Quitting just after a Wine error is a failure; long after, it isn't")
    func quitAfterWineError() throws {
        let error = "0124:err:module:import_dll Library Ndui.dll (which is needed by L\"Game.exe\") not found"
        let check = started(.directDraw)
        check.observe(line: error, at: start + 10)
        let failure = try #require(check.failure(exitedAt: start + 10.5))
        #expect(failure.summary == "it quit 0.5 s after Wine reported an error")
        #expect(failure.explanation == "The game couldn't load a file it needs.")
        #expect(check.failure(exitedAt: start + 10 + GameQuitCheck.errorWindow + 1) == nil)
    }

    @Test("Routine Wine errors every launch logs don't count", arguments: [
        "0130:err:vulkan:init_vulkan Failed to load Wine graphics driver supporting Vulkan.",
        "0144:err:vulkan:vulkan_init_once Failed to load libvulkan.1.dylib",
        #"0128:err:environ:init_peb starting L"C:\\Nancy Drew\\Game.exe" in experimental wow64 mode"#,
        "00e8:err:hid:handle_DeviceMatchingCallback Ignoring HID device 0x7f9323770500 (vid 2222, pid 0092): not a joystick or gamepad",
        "0130:err:system:NtUserChangeDisplaySettings Changing (null) display settings returned -2.",
    ])
    func ignoresRoutineErrors(_ line: String) {
        let check = started(.directDraw)
        check.observe(line: line, at: start + 1)
        #expect(check.failure(exitedAt: start + 2) == nil)
    }

    @Test("Steam's start-up errors count only outside Steam")
    func steamErrors() {
        let line = "013c:err:ole:com_get_class_object class {aa509086-5ca9-4c25-8f95-589d3c07b48a} not registered"
        let steam = started(.directDraw, throughSteam: true)
        steam.observe(line: line, at: start + 1)
        #expect(steam.failure(exitedAt: start + 2) == nil)
        let direct = started(.directDraw)
        direct.observe(line: line, at: start + 1)
        #expect(direct.failure(exitedAt: start + 2) != nil)
    }

    @Test("Nothing that was asked to quit failed", arguments: [true, false])
    func askedToQuit(fromInside: Bool) {
        let check = GameQuitCheck(graphicsAPI: .direct3D, throughSteam: false)
        check.observe(line: armed, at: start)
        check.observe(line: refusedMode, at: start + 1)
        if fromInside {
            check.observe(line: "second-chance-helper[QuitWatch] notice: quit requested", at: start + 1)
        } else {
            check.quitRequested("the Mac is logging out or shutting down")
        }
        #expect(check.failure(exitedAt: start + 2) == nil)
    }

    @Test("An unhandled exception reads as a crash")
    func crash() {
        #expect(GameQuitCheck.isWineError("wine: Unhandled page fault on read access to 00000000 at address 0045A1B2"))
        #expect(GameQuitCheck.knownCause(of: "wine: Unhandled page fault on read access to 00000000") == "The game crashed.")
        #expect(!GameQuitCheck.isWineError("0130:fixme:d3d:wined3d_check_device_format_conversion"))
    }
}
