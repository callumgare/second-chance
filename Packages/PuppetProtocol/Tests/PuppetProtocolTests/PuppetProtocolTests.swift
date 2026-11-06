import CoreGraphics
import Foundation
import Testing
@testable import PuppetProtocol

struct PuppetRequestTests {
    @Test("Requests are written as the helper reads them", arguments: [
        (PuppetRequest.hello, "hello"),
        (.capture(path: "/tmp/a.png", scale: 0.1), "capture /tmp/a.png scale=0.100"),
        (.capture(path: "/tmp/a.png", region: CGRect(x: 10, y: 20, width: 30, height: 40)), "capture /tmp/a.png region=10,20,30,40"),
        (.click(CGPoint(x: 120, y: 340.5), button: .right, count: 2), "click 120 340.5 button=right count=2"),
        (.drag(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4), steps: 5), "drag 1 2 3 4 steps=5"),
        (.scroll(CGPoint(x: 400, y: 300), lines: -3), "scroll 400 300 -3"),
        (.scroll(CGPoint(x: 400, y: 300), lines: 2, across: 1), "scroll 400 300 2 across=1"),
        (.key("escape", hold: 150), "key escape hold=150"),
        (.type("Hi there"), "type Hi%20there"),
        (.yield(pid: 42), "yield 42"),
        (.audio(seconds: 5), "audio 5"),
        (.audio(seconds: 2.5), "audio 2.5"),
    ])
    func line(request: PuppetRequest, line: String) {
        #expect(request.line == line)
    }

    @Test("An action's words become its request")
    func actions() throws {
        #expect(try PuppetRequest.action(["click", "10", "20"], button: .right) == .click(CGPoint(x: 10, y: 20), button: .right))
        #expect(try PuppetRequest.action(["type", "hello", "there"]) == .type("hello there"))
        #expect(try PuppetRequest.action(["scroll", "1", "2", "up"]) == .scroll(CGPoint(x: 1, y: 2), lines: -3))
        #expect(try PuppetRequest.action(["scroll", "1", "2", "down", "10"]) == .scroll(CGPoint(x: 1, y: 2), lines: 10))
        #expect(try PuppetRequest.action(["scroll", "1", "2", "left", "2"]) == .scroll(CGPoint(x: 1, y: 2), lines: 0, across: -2))
        #expect(try PuppetRequest.action(["key", "cmd+s"], hold: 80) == .key("cmd+s", hold: 80))
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["click", "10"]) }
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["scroll", "1", "2", "3"]) }
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["scroll", "1", "2", "down", "0"]) }
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["jump"]) }
    }

    @Test("Keys as people write them become one key request, in canonical form, 0.3 s between presses unless they say")
    func keys() throws {
        #expect(try PuppetRequest.keys("up return*2") == .key("up wait=300ms return wait=300ms return"))
        #expect(try PuppetRequest.keys("command+S", hold: 80) == .key("cmd+S", hold: 80))
        #expect(try PuppetRequest.keys("escape:hold=4s") == .key("escape:hold=4000ms"))
        #expect(try PuppetRequest.keys("gap=100ms up up wait=1s return")
            == .key("up wait=100ms up wait=1000ms return"))
        #expect(try PuppetRequest.keys("escape wait=0 escape") == .key("escape wait=0ms escape"))
        #expect(try PuppetRequest.action(["key", "f12:hold=5s"]) == .key("f12:hold=5000ms"))
        #expect(try PuppetRequest.action(["key", "up", "down"]) == .key("up wait=300ms down"))
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.keys("escape:hold=40s") }
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.keys("escape wait=1s") }
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["key", "gap=1s"]) }
    }

    @Test("A key request is sent as one line, its waits words, not options")
    func keyLine() {
        #expect(PuppetRequest.key("escape:hold=4000ms").line == "key escape:hold=4000ms")
        #expect(PuppetRequest.key("up wait=300ms return", hold: 150).line == "key up wait=300ms return hold=150")
    }

    @Test("A key request's reply is waited for as long as its presses, holds and waits take")
    func keyTimeout() {
        #expect(PuppetRequest.key("escape:hold=25000ms").timeout == 45)
        #expect(PuppetRequest.key("escape").timeout < 21)
        #expect(PuppetRequest.key("up wait=30000ms up wait=30000ms up").timeout > 80)
        #expect(PuppetRequest.key("up wait=1000ms up", hold: 500).timeout == 22)
    }

    @Test("Every action has its usage")
    func usage() {
        #expect(Set(PuppetRequest.usage.keys) == Set(PuppetRequest.actionVerbs))
    }
}

struct PuppetReplyTests {
    @Test("A reply's fields, words and error")
    func fields() {
        let capture = PuppetReply("ok 1280x720\n")
        #expect(capture.isOK && capture.size == CGSize(width: 1280, height: 720))
        let error = PuppetReply("error no game window")
        #expect(!error.isOK && error.error == "no game window" && error.fields.isEmpty)
        #expect(PuppetReply("ok").isOK && PuppetReply("okay").isOK == false)
    }

    @Test("hello says the version and what the helper answers")
    func hello() {
        let hello = PuppetHello(PuppetReply("ok version=3 pid=12 exe=iji.exe commands=hello,state,scroll"))
        #expect(hello.version == 3 && hello.pid == 12 && hello.exe == "iji.exe" && hello.supports("scroll"))
        #expect(PuppetHello(PuppetReply("error unknown request: hello")).version == 1)
    }

    @Test("state reads the game window")
    func state() throws {
        let state = try #require(PuppetWindowState(PuppetReply(
            "ok window=7 size=800x600 scale=2 fullscreen=0 native=0 key=1 active=1 onspace=1 cursor=held cursorlock=locked")))
        #expect(state.windowNumber == 7 && state.size == CGSize(width: 800, height: 600) && state.scale == 2)
        #expect(state.key && state.cursorHeld && state.cursorLock == "locked" && state.onActiveSpace == true)
        #expect(PuppetWindowState(PuppetReply("error timed out")) == nil)
    }

    @Test("windows lists each window, its title decoded")
    func windows() {
        let reply = PuppetReply("""
        ok 2 windows
        id=5 frame=0,25,800,632 level=0 visible=1 key=1 main=1 kind=game title=Iji%20-%20Press%20Alt%2BF4
        id=6 frame=10,10,183,83 level=3 visible=0 key=0 main=0 kind=panel title=
        """)
        let windows = PuppetWindow.all(in: reply)
        #expect(windows.count == 2)
        #expect(windows[0].kind == .game && windows[0].title == "Iji - Press Alt+F4" && windows[0].frame.height == 632)
        #expect(windows[1].kind == .panel && !windows[1].visible)
    }

    @Test("The wrapp's info")
    func info() {
        #expect(WrappInfo(PuppetReply("ok open=1 warning=0")) == WrappInfo(PuppetReply("ok warning=0 open=1")))
        #expect(WrappInfo(PuppetReply("ok open=1 warning=0"))?.open == true)
        #expect(WrappInfo(PuppetReply("error")) == nil)
    }
}

struct PuppetSocketTests {
    @Test("Nothing listening is said, not hung on")
    func notListening() {
        let socket = PuppetSocket(path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString).sock")
        #expect(throws: PuppetSocket.Failure.self) { try socket.send(.hello, timeout: 1) }
    }
}

struct AudioLevelTests {
    @Test func parsesTheTapsLevelLines() {
        #expect(AudioLevel(line: "level t=0.10 peak=0.500000 rms=0.250000") == AudioLevel(time: 0.1, peak: 0.5, rms: 0.25))
        #expect(AudioLevel(line: "process pid=12 object=80 output=1") == nil)
        #expect(AudioLevel(line: "level t=0.10 peak=x rms=0.2") == nil)
    }

    @Test func silenceIsSilentEvenWithAStreamOpen() {
        let levels = (1...20).map { AudioLevel(time: Double($0) / 10, peak: 0.0002, rms: 0.0001) }
        #expect(AudioLevel.summary(levels).hasPrefix("silent:"))
        #expect(AudioLevel.summary([]).hasPrefix("no samples"))
    }

    @Test func soundAndClippingAreToldApart() {
        let quiet = (1...10).map { AudioLevel(time: Double($0) / 10, peak: 0, rms: 0) }
        let loud = (11...20).map { AudioLevel(time: Double($0) / 10, peak: 0.5, rms: 0.1) }
        #expect(AudioLevel.summary(quiet + loud) == "sound in 10 of 20 windows (peak -6.0 dBFS, RMS up to -20.0 dBFS)")
        let clipped = loud + [AudioLevel(time: 2.1, peak: 1.0, rms: 0.7)]
        #expect(AudioLevel.summary(clipped).hasPrefix("clipping: 1 of 11 windows reach full scale"))
    }

    @Test func rowsShowASecondEach() {
        let levels = (1...15).map { AudioLevel(time: Double($0) / 10, peak: $0 > 10 ? 0.5 : 0, rms: $0 > 10 ? 0.5 : 0) }
        let rows = AudioLevel.rows(levels)
        #expect(rows.count == 2)
        #expect(rows[0].contains("··········"))
        #expect(rows[0].hasSuffix("peak -inf, rms -inf"))
        #expect(rows[1].hasPrefix("  1.0s  █████ "))
    }

    @Test func readsTheHelpersAudioReply() throws {
        let reply = PuppetReply("""
            ok sound windows=3 sounding=2 clipped=0 peak=0.500000 rms=0.100000 streams=1 buffers=30 format=float32 hooked=1
            level t=0.1 peak=0.000000 rms=0.000000
            level t=0.2 peak=0.500000 rms=0.100000
            level t=0.3 peak=0.250000 rms=0.050000
            """)
        let audio = try #require(PuppetAudio(reply))
        #expect(audio.levels.count == 3 && audio.levels[1] == AudioLevel(time: 0.2, peak: 0.5, rms: 0.1))
        #expect(audio.verdict == .sound && audio.streams == 1 && audio.format == "float32" && audio.hooked)
        #expect(audio.summary == "sound in 2 of 3 windows (peak -6.0 dBFS, RMS up to -20.0 dBFS); 1 stream, float32")
    }

    @Test func aGameWithNoSoundOpenIsSilent() throws {
        let reply = "ok silent windows=1 sounding=0 clipped=0 peak=0 rms=0 streams=0 buffers=0 format=unknown hooked=0\nlevel t=0.1 peak=0 rms=0"
        let audio = try #require(PuppetAudio(PuppetReply(reply)))
        #expect(audio.verdict == .silent && !audio.hooked)
        #expect(audio.summary.hasSuffix("the game hasn't opened Wine's Core Audio output"))
        #expect(PuppetAudio(PuppetReply("error no audio measure here")) == nil)
    }

    @Test func fullScaleIsClipping() throws {
        let audio = try #require(PuppetAudio(PuppetReply("ok clipping hooked=1\nlevel t=0.1 peak=1.000000 rms=0.700000")))
        #expect(audio.verdict == .clipping)
    }
}
