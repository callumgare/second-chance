import CoreGraphics
import Testing
@testable import PuppeteerCore

/// Which app is in front, from the window server's front-to-back list.
@Suite("The window in front")
struct WindowFinderTests {
    private func window(_ pid: Int32, _ name: String, layer: Int = 0, alpha: Double = 1,
                        size: CGSize = CGSize(width: 800, height: 600)) -> WindowInfo {
        WindowInfo(number: pid, ownerPid: pid, ownerName: name, bounds: CGRect(origin: .zero, size: size), layer: layer, alpha: alpha)
    }

    @Test("The first ordinary window is in front, past the menu bar, Dock and Notification Centre above it")
    func firstOrdinaryWindow() {
        // As a test session lists them, TextEdit having come in front of a game.
        let windows = [
            window(503, "Window Server", layer: 24, size: CGSize(width: 1920, height: 30)),
            window(4650, "Notification Centre", layer: 21, size: CGSize(width: 1920, height: 1080)),
            window(4583, "Dock", layer: 20, size: CGSize(width: 1920, height: 1080)),
            window(24244, "TextEdit"),
            window(23049, "wine"),
        ]
        #expect(WindowFinder.frontOwner(of: windows) == 24244)
        #expect(WindowFinder.frontOwner(of: Array(windows.dropLast(2)) + [window(23049, "wine")]) == 23049)
    }

    @Test("Invisible and tiny windows aren't taken for the one in front")
    func skipsInvisibleAndTiny() {
        let windows = [
            window(5911, "Peekaboo", alpha: 0),
            window(23049, "wine", size: CGSize(width: 1, height: 1)),
            window(23049, "wine"),
        ]
        #expect(WindowFinder.frontOwner(of: windows) == 23049)
        #expect(WindowFinder.frontOwner(of: [window(5911, "Peekaboo", alpha: 0)]) == nil)
        #expect(WindowFinder.frontOwner(of: [window(4583, "Dock", layer: 20)]) == nil)
    }
}
