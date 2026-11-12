import CoreML
import CoreVideo
import Foundation

/// Moving pictures in and out of Core ML: a Bitmap as a 32BGRA pixel buffer (for image inputs) or as a planar
/// RGB float array (for tensor inputs), and an output array back to a Bitmap.
nonisolated enum ModelIO {
    /// Over white, as an opaque BGRA pixel buffer.
    static func pixelBuffer(_ b: Bitmap) throws -> CVPixelBuffer {
        let f = b.flattened()
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, f.width, f.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { throw IconLabError.tool("couldn't make a pixel buffer") }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { throw IconLabError.tool("pixel buffer without memory") }
        let row = CVPixelBufferGetBytesPerRow(buf)
        let p = base.assumingMemoryBound(to: UInt8.self)
        f.pixels.withUnsafeBufferPointer { src in
            for y in 0..<f.height {
                for x in 0..<f.width {
                    let s = (y * f.width + x) * 4, d = y * row + x * 4
                    p[d] = src[s + 2]; p[d + 1] = src[s + 1]; p[d + 2] = src[s]; p[d + 3] = 255
                }
            }
        }
        return buf
    }

    /// [1, 3, h, w] Float32 in 0…1 (or normalised with `mean`/`std`), over white.
    static func planar(_ b: Bitmap, mean: [Float] = [0, 0, 0], std: [Float] = [1, 1, 1], type: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
        let f = b.flattened()
        let a = try MLMultiArray(shape: [1, 3, NSNumber(value: f.height), NSNumber(value: f.width)], dataType: .float32)
        let plane = f.width * f.height
        let p = a.dataPointer.assumingMemoryBound(to: Float.self)
        f.pixels.withUnsafeBufferPointer { src in
            for i in 0..<plane {
                for c in 0..<3 { p[c * plane + i] = (Float(src[i * 4 + c]) / 255 - mean[c]) / std[c] }
            }
        }
        if type == .float32 { return a }
        let out = try MLMultiArray(shape: a.shape, dataType: type)
        for i in 0..<a.count { out[i] = a[i] }
        return out
    }

    /// Every value of an array as Float, whatever its type and strides (assumes the array is contiguous).
    static func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        // Core ML's outputs may be laid out with padded strides: read each element where its strides say, in order.
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        var packed = [Int](repeating: 1, count: shape.count)
        for k in stride(from: shape.count - 2, through: 0, by: -1) { packed[k] = packed[k + 1] * shape[k + 1] }
        if !shape.isEmpty, strides != packed {
            func offsets() -> [Int] {
                var out = [Int](repeating: 0, count: n)
                var idx = [Int](repeating: 0, count: shape.count)
                for i in 0..<n {
                    var o = 0
                    for k in 0..<shape.count { o += idx[k] * strides[k] }
                    out[i] = o
                    var k = shape.count - 1
                    while k >= 0 { idx[k] += 1; if idx[k] < shape[k] { break }; idx[k] = 0; k -= 1 }
                }
                return out
            }
            let offs = offsets()
            switch a.dataType {
            case .float32:
                let p = a.dataPointer.assumingMemoryBound(to: Float.self)
                return offs.map { p[$0] }
            case .float16:
                let p = a.dataPointer.assumingMemoryBound(to: UInt16.self)
                return offs.map { HalfFloat.float(p[$0]) }
            case .double:
                let p = a.dataPointer.assumingMemoryBound(to: Double.self)
                return offs.map { Float(p[$0]) }
            default:
                return (0..<n).map { a[$0].floatValue }
            }
        }
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: p, count: n))
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: UInt16.self)
            return UnsafeBufferPointer(start: p, count: n).map { HalfFloat.float($0) }
        case .double:
            let p = a.dataPointer.assumingMemoryBound(to: Double.self)
            return UnsafeBufferPointer(start: p, count: n).map { Float($0) }
        default:
            return (0..<n).map { a[$0].floatValue }
        }
    }

    /// A one-channel pixel buffer (OneComponent8 or a float format) or BGRA one, as an opaque grey Bitmap.
    static func greyBitmap(_ pb: CVPixelBuffer) -> Bitmap {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var out = Bitmap(width: w, height: h)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return out }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        for y in 0..<h {
            for x in 0..<w {
                let v: UInt8
                switch fmt {
                case kCVPixelFormatType_OneComponent8: v = base.load(fromByteOffset: y * row + x, as: UInt8.self)
                case kCVPixelFormatType_OneComponent16Half:
                    v = UInt8(max(0, min(255, HalfFloat.float(base.load(fromByteOffset: y * row + x * 2, as: UInt16.self)) * 255)))
                case kCVPixelFormatType_OneComponent32Float:
                    v = UInt8(max(0, min(255, base.load(fromByteOffset: y * row + x * 4, as: Float.self) * 255)))
                default: v = base.load(fromByteOffset: y * row + x * 4 + 1, as: UInt8.self)   // BGRA: green
                }
                let i = out.index(x, y)
                out.pixels[i] = v; out.pixels[i + 1] = v; out.pixels[i + 2] = v; out.pixels[i + 3] = 255
            }
        }
        return out
    }

    /// The first input or output of a kind (models name theirs differently).
    static func input(_ m: MLModel, _ type: MLFeatureType) -> MLFeatureDescription? {
        m.modelDescription.inputDescriptionsByName.values.sorted { $0.name < $1.name }.first { $0.type == type }
    }
}
