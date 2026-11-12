import Foundation
import Testing
@testable import IconLabKit

/// The half-float conversions agree with Swift's own `Float16`, where it exists (Apple silicon).
@Suite struct HalfFloatTests {
    @Test func readsEveryHalf() {
        #if arch(arm64)
        for bits in UInt16.min...UInt16.max {
            let mine = HalfFloat.float(bits), swift = Float(Float16(bitPattern: bits))
            if swift.isNaN { #expect(mine.isNaN) } else { #expect(mine.bitPattern == swift.bitPattern, "bits \(bits)") }
        }
        #endif
        #expect(HalfFloat.float(0x3c00) == 1)
        #expect(HalfFloat.float(0xc000) == -2)
    }

    @Test(arguments: [Float(0), -0.0, 1, -2.5, 0.1, 65504, 70000, 1e-5, 6e-8, 2e-8, 3e-8, 0.33333, .infinity, -.infinity])
    func writesTheNearestHalf(_ value: Float) {
        #if arch(arm64)
        #expect(HalfFloat.bits(value) == Float16(value).bitPattern)
        #endif
        #expect(HalfFloat.float(HalfFloat.bits(1.5)) == 1.5)
    }
}
