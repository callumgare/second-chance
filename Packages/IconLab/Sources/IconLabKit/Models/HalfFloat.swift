import Foundation

/// IEEE 754 half-precision numbers as their 16 bits. Swift's `Float16` is unavailable on Intel Macs, and the app is
/// built for both, so Core ML's float16 arrays are read and written through this instead.
nonisolated enum HalfFloat {
    /// The value the bits hold.
    static func float(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int(bits >> 10) & 0x1f
        let fraction = UInt32(bits & 0x03ff)
        switch exponent {
        case 0:
            // zero or subnormal: fraction × 2^-24
            let magnitude = Float(fraction) * Float(sign: .plus, exponent: -24, significand: 1)
            return sign == 0 ? magnitude : -magnitude
        case 0x1f:
            return Float(bitPattern: sign | 0x7f80_0000 | (fraction << 13))   // infinity or NaN
        default:
            return Float(bitPattern: sign | (UInt32(exponent - 15 + 127) << 23) | (fraction << 13))
        }
    }

    /// The nearest half to `value` (rounding to nearest, ties to even), as bits.
    static func bits(_ value: Float) -> UInt16 {
        let f = value.bitPattern
        let sign = UInt16((f >> 16) & 0x8000)
        let exponent = Int((f >> 23) & 0xff)
        var mantissa = f & 0x007f_ffff
        if exponent == 0xff { return sign | 0x7c00 | (mantissa != 0 ? 0x200 : 0) }   // infinity or NaN
        let e = exponent - 127 + 15
        if e >= 0x1f { return sign | 0x7c00 }                                          // too big: infinity
        if e <= 0 {
            // subnormal (or zero): shift the full significand down, rounding
            if e < -10 { return sign }
            mantissa |= 0x0080_0000
            let shift = UInt32(14 - e)
            var half = mantissa >> shift
            let rest = mantissa & ((1 << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if rest > halfway || (rest == halfway && half & 1 == 1) { half += 1 }
            return sign | UInt16(half)
        }
        var half = UInt32(e) << 10 | (mantissa >> 13)
        let rest = mantissa & 0x1fff
        if rest > 0x1000 || (rest == 0x1000 && half & 1 == 1) { half += 1 }   // may carry into the exponent, as it should
        return sign | UInt16(half & 0x7fff)
    }
}
