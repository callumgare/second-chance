import ArgumentParser
import Testing
@testable import SCKit

struct SessionInputTests {
    @Test("Clicks, moves and drags read their points, and a button and count")
    func pointer() throws {
        #expect(try SessionInput.parse(["click", "920", "594"], button: nil, count: 1) == .click(x: 920, y: 594, buttons: 1, count: 1))
        #expect(try SessionInput.parse(["click", "1", "2"], button: "right", count: 2) == .click(x: 1, y: 2, buttons: 4, count: 2))
        #expect(try SessionInput.parse(["move", "3.5", "4"], button: nil, count: 1) == .move(x: 3.5, y: 4))
        #expect(try SessionInput.parse(["drag", "1", "2", "3", "4"], button: nil, count: 1) == .drag(x: 1, y: 2, toX: 3, toY: 4))
        #expect(throws: ValidationError.self) { try SessionInput.parse(["click", "920"], button: nil, count: 1) }
        #expect(throws: ValidationError.self) { try SessionInput.parse(["click", "1", "2"], button: "side", count: 1) }
        #expect(throws: ValidationError.self) { try SessionInput.parse(["wave"], button: nil, count: 1) }
    }

    @Test("Keys are names, characters, chords and repeats, as X11 keysyms")
    func keys() throws {
        #expect(try SessionInput.parse(["key", "return"], button: nil, count: 1) == .keys([[0xFF0D]]))
        #expect(try SessionInput.parse(["key", "cmd+q", "down*2"], button: nil, count: 1)
                == .keys([[0xFFE7, 0x71], [0xFF54], [0xFF54]]))
        #expect(try SessionInput.parse(["key", "F5"], button: nil, count: 1) == .keys([[0xFFC2]]))
        #expect(throws: ValidationError.self) { try SessionInput.parse(["key", "hyper"], button: nil, count: 1) }
    }

    @Test("Text is typed as Latin-1 keysyms, anything else as Unicode ones")
    func text() throws {
        #expect(try SessionInput.parse(["type", "hi", "there"], button: nil, count: 1) == .type("hi there"))
        #expect(SessionInput.character("é") == 0xE9)
        #expect(SessionInput.character("→") == 0x0100_2192)
    }

    @Test("A --then action splits at spaces outside quotes")
    func words() {
        #expect(SessionInput.words(#"type "a b"  key return"#) == ["type", "a b", "key", "return"])
    }
}
