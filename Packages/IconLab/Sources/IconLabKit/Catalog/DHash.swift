import Foundation

/// A difference hash: the picture shrunk to 9×8 grey, one bit per neighbouring pair (is the left brighter?). Copies of
/// the same art at different sizes or compressions land within a few bits of each other.
nonisolated public enum DHash {
    public static func hash(_ image: Bitmap) -> UInt64 {
        let small = image.flattened().resized(width: 9, height: 8)
        var h: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                let a = small.luma(small.index(x, y)), b = small.luma(small.index(x + 1, y))
                h = (h << 1) | (a > b ? 1 : 0)
            }
        }
        return h
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Same art: hashes within `bits` and shapes within 15% of each other's aspect.
    public static func same(_ a: (hash: UInt64, aspect: Double), _ b: (hash: UInt64, aspect: Double), bits: Int = 6) -> Bool {
        guard a.aspect > 0, b.aspect > 0, max(a.aspect, b.aspect) / min(a.aspect, b.aspect) < 1.15 else { return false }
        return distance(a.hash, b.hash) <= bits
    }
}
