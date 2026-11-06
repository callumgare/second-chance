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
    ])
    func line(request: PuppetRequest, line: String) {
        #expect(request.line == line)
    }

    @Test("An action's words become its request")
    func actions() throws {
        #expect(try PuppetRequest.action(["click", "10", "20"], button: .right) == .click(CGPoint(x: 10, y: 20), button: .right))
        #expect(try PuppetRequest.action(["type", "hello", "there"]) == .type("hello there"))
        #expect(try PuppetRequest.action(["scroll", "1", "2", "-3"]) == .scroll(CGPoint(x: 1, y: 2), lines: -3))
        #expect(try PuppetRequest.action(["key", "cmd+s"], hold: 80) == .key("cmd+s", hold: 80))
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["click", "10"]) }
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["scroll", "1", "2", "1.5"]) }
        #expect(throws: PuppetProtocolError.self) { try PuppetRequest.action(["jump"]) }
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
