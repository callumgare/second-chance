import Foundation
import Testing
@testable import WineExecutor
import WineKit

struct LeftoverWaitTests {
    @Test("A wait's allowance runs out after its limit, a loaded Mac's seconds counting half")
    func allowance() {
        var idle = WaitAllowance(limit: 300)
        var early = (0..<299).map { _ in idle.spend(1, heavy: false) }
        #expect(!early.contains(true))
        let idleOut = idle.spend(1, heavy: false)
        #expect(idleOut)
        var loaded = WaitAllowance(limit: 300)
        early = (0..<599).map { _ in loaded.spend(1, heavy: true) }
        #expect(!early.contains(true))
        let loadedOut = loaded.spend(1, heavy: true)
        #expect(loadedOut)
    }

    @Test("Leftovers get 5 minutes unless SECOND_CHANCE_WINE_LEFTOVER_SECONDS says otherwise")
    func limit() {
        #expect(WineExecutor.leftoverLimit(environment: [:]) == 300)
        #expect(WineExecutor.leftoverLimit(environment: ["SECOND_CHANCE_WINE_LEFTOVER_SECONDS": "900"]) == 900)
        #expect(WineExecutor.leftoverLimit(environment: ["SECOND_CHANCE_WINE_LEFTOVER_SECONDS": "0"]) == 300)
        #expect(WineExecutor.leftoverLimit(environment: ["SECOND_CHANCE_WINE_LEFTOVER_SECONDS": "soon"]) == 300)
    }
}
