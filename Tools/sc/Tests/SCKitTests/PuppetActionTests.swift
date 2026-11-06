import CoreGraphics
import Foundation
import Testing
@testable import SCKit

@Suite("Puppet actions and their replies")
struct PuppetActionTests {
    /// A thumbnail of Probe's size, grey, with a brighter block where asked.
    private func picture(block: (x: Int, y: Int, w: Int, h: Int)? = nil) -> [UInt8] {
        var pixels = [UInt8](repeating: 100, count: Probe.width * Probe.height)
        if let block {
            for y in block.y..<(block.y + block.h) {
                for x in block.x..<(block.x + block.w) { pixels[y * Probe.width + x] = 220 }
            }
        }
        return pixels
    }

    @Test("A small change is told, and where it is, rather than rounded to nothing")
    func smallChange() throws {
        let before = picture(block: (10, 40, 30, 3))
        let after = picture(block: (10, 46, 30, 3))
        let share = Frames.changedShare(before, after)
        #expect(share == 2)  // 180 of 9,216 pixels
        let box = try #require(Frames.changedBox(before, after, width: Probe.width, height: Probe.height))
        #expect(box == CGRect(x: 10, y: 40, width: 30, height: 9))
        #expect(Frames.changedBox(before, before, width: Probe.width, height: Probe.height) == nil)
    }

    @Test("A step's reply: what came and went, the change and where, in window points")
    func stepLines() {
        var before = Probe.empty, after = Probe.empty
        before.thumbnail = picture()
        after.thumbnail = picture(block: (64, 36, 16, 9))
        after.size = CGSize(width: 1280, height: 720)
        after.windows = ["7": "\"Options\" (300x200)"]
        let step = PuppetOutcome.step("key down", before: before, after: after)
        #expect(step.appeared == ["\"Options\" (300x200)"])
        #expect(step.changedBox == [640, 360, 160, 90])
        #expect(step.lines == ["new: +window \"Options\" (300x200)", "key down → changed 2% at 640,360 160x90"])
    }

    @Test("Under 1% says <1%, and no capture says so")
    func shares() {
        var step = PuppetStep(action: "key up")
        step.changed = 0.3
        #expect(step.lines[1] == "key up → changed <1%")
        step.changed = nil
        #expect(step.lines[1] == "key up → changed ? (no capture)")
        step.ended = true
        step.screen = "menu"
        #expect(step.lines == ["new: the program has ended", "key up → changed ? (no capture) → screen: menu"])
    }

    @Test("--json's reply is every step")
    func json() throws {
        let reply = PuppetActionCommand.Reply(steps: [PuppetStep(action: "key escape", changed: 12.5)], error: nil)
        let data = try JSONEncoder().encode(reply)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"action\":\"key escape\"") && text.contains("\"changed\":12.5"))
        #expect(PuppetJSON.line(["a": 1, "b": Optional<String>.none as Any]) == "{\"a\":1}")
    }
}
