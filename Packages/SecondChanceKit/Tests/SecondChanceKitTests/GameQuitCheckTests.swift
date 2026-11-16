import Foundation
import Testing
@testable import ProcessKit
@testable import SecondChanceKit
@testable import WindowsFormats
@testable import WineKit
@testable import WrappFormat
@testable import WrappLogging

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
        #expect(failure.explanation.contains("screen setting this Mac doesn't have"))
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

    // From The Deadly Device on Wine 11.22 (2026-11-16), which logs this from
    // its first frame on and was blamed for quitting from its own menu.
    private let drawError = #"0378:err:d3d:wined3d_check_gl_call >>>>>>> GL_INVALID_OPERATION (0x502) from glDrawArrays @ dlls\wined3d\context_gl.c / 4437."#

    @Test("An error the game logged all along doesn't explain its quit")
    func ignoresRecurringErrors() {
        let check = started()
        check.observe(line: firstFrame, at: start + 1)
        for second in stride(from: 1.0, through: 60, by: 0.5) {
            check.observe(line: drawError, at: start + second)
        }
        #expect(check.failure(exitedAt: start + 60.3) == nil)
    }

    @Test("A new error just before the exit counts, however many old ones follow it")
    func newErrorAmongRecurring() throws {
        let check = started()
        check.observe(line: firstFrame, at: start + 1)
        check.observe(line: drawError, at: start + 1)
        check.observe(line: refusedMode, at: start + 59.5)
        for frame in 0..<200 {
            check.observe(line: drawError, at: start + 59.5 + Double(frame) * 0.002)
        }
        let failure = try #require(check.failure(exitedAt: start + 60))
        #expect(failure.summary == "it quit 0.5 s after Wine reported an error")
    }

    @Test("An error that started less than recurringLead before the exit, and seldom, still counts")
    func errorStartingNearTheExit() {
        let check = started()
        check.observe(line: firstFrame, at: start + 1)
        for second in stride(from: 55.0, through: 60, by: 0.5) {
            check.observe(line: drawError, at: start + second)
        }
        #expect(check.failure(exitedAt: start + 60.3) != nil)
    }

    @Test("An error logged floodCount times before the exit's window doesn't explain it, however recently it began")
    func ignoresFloods() {
        // The Deadly Device on Wine 11.22: the flood from its first frame,
        // quit from its menu 9.3 s later.
        let check = started()
        check.observe(line: firstFrame, at: start + 40.4)
        for frame in 0..<3_400 {
            check.observe(line: drawError, at: start + 40.4 + Double(frame) * 0.0027)
        }
        #expect(check.failure(exitedAt: start + 49.7) == nil)
    }

    @Test("A flood that begins within the exit's window still counts")
    func floodJustBeforeTheExit() {
        let check = started()
        check.observe(line: firstFrame, at: start + 1)
        for frame in 0..<200 {
            check.observe(line: drawError, at: start + 59.5 + Double(frame) * 0.002)
        }
        #expect(check.failure(exitedAt: start + 60) != nil)
    }

    @Test("Two of the same error are one kind, whichever thread logged them and wherever")
    func errorKinds() {
        #expect(GameQuitCheck.kind(of: drawError) == GameQuitCheck.kind(of: drawError.replacingOccurrences(of: "0378:", with: "03a8:")))
        #expect(GameQuitCheck.kind(of: "037c:err:d3d:resource_unload Resource 02359C68 is being unloaded while mapped.")
            == GameQuitCheck.kind(of: "0388:err:d3d:resource_unload Resource 01201578 is being unloaded while mapped."))
        #expect(GameQuitCheck.kind(of: drawError) != GameQuitCheck.kind(of: refusedMode))
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

    // From the free trial of White Wolf quit from its own menu (2026-11-13):
    // the Game Manager's window redrew 0.6 s before the game exited.
    @Test("The Game Manager's drawing errors count only outside Big Fish", arguments: [
        "0224:err:d3d:wined3d_check_gl_call >>>>>>> GL_INVALID_FRAMEBUFFER_OPERATION (0x506) from glBlitFramebuffer() @ "
            + "/Users/gcenx/Documents/GitHub/wine-private/dlls/wined3d/texture.c / 546.",
        "0224:err:d3d:wined3d_context_gl_set_pixel_format wglSetPixelFormatWINE failed to set pixel format 21 on device context 2601005D.",
        "0224:err:d3d:wined3d_context_gl_update_window Failed to get a device context for window 06DAFF08.",
    ])
    func bigFishErrors(_ line: String) {
        let check = GameQuitCheck(graphicsAPI: .direct3D, throughSteam: false, throughBigFish: true)
        check.observe(line: armed, at: start)
        check.windowDidAppear()
        check.observe(line: firstFrame, at: start + 1)
        check.observe(line: line, at: start + 10)
        #expect(check.failure(exitedAt: start + 10.6) == nil)
        let direct = started()
        direct.observe(line: firstFrame, at: start + 1)
        direct.observe(line: line, at: start + 10)
        #expect(direct.failure(exitedAt: start + 10.6) != nil)
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
        #expect(check.wasQuitRequested)
    }

    @Test("A game nothing asked to quit wasn't asked to")
    func notRequested() {
        let check = GameQuitCheck(graphicsAPI: .direct3D, throughSteam: false)
        check.observe(line: armed, at: start)
        check.observe(line: "second-chance-helper[QuitWatch] notice: first frame on screen", at: start)
        #expect(!check.wasQuitRequested)
    }

    @Test("Quitting while winedbg writes a crash's backtrace is a failure; long after, it isn't")
    func quitAfterCrash() throws {
        let crash = "wine: Unhandled page fault on read access to 00000000 at address 0045A1B2 (thread 0024), starting debugger..."
        let check = started(.directDraw)
        check.observe(line: firstFrame, at: start + 1)
        check.observe(line: crash, at: start + 60)
        let failure = try #require(check.failure(exitedAt: start + 64))
        #expect(failure.summary == "it quit 4.0 s after an exception nothing handled")
        #expect(failure.explanation == "Something went wrong inside the game, and it had to close.")
        #expect(check.failure(exitedAt: start + 60 + GameQuitCheck.crashWindow + 1) == nil)
    }

    @Test("An unhandled exception reads as a crash")
    func crash() {
        #expect(GameQuitCheck.isWineError("wine: Unhandled page fault on read access to 00000000 at address 0045A1B2"))
        #expect(GameQuitCheck.knownCause(of: "wine: Unhandled page fault on read access to 00000000") == "Something went wrong inside the game, and it had to close.")
        #expect(!GameQuitCheck.isWineError("0130:fixme:d3d:wined3d_check_device_format_conversion"))
    }
}
