//
//  ImageIODecoder.swift
//  ProgramImages
//
//  Everything ImageIO reads — PNG, JPEG, GIF, BMP, TIFF, TGA, ICNS, PICT and
//  the rest (CGImageSourceCopyTypeIdentifiers) — with its claimed size
//  checked before anything is decoded, since a crafted header can ask for
//  gigabytes.

import CoreGraphics
import Foundation
import ImageIO

nonisolated public enum ImageIODecoder {
    /// Up to `maxImages` images from `data` (an .icns or .tiff holds
    /// several; a GIF's frames after its first are left out). `typeHint`
    /// is a UTI, for formats ImageIO doesn't recognise by their bytes.
    public static func decode(_ data: Data, typeHint: String? = nil, maxImages: Int = 32) -> [RGBAImage] {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let typeHint { options[kCGImageSourceTypeIdentifierHint] = typeHint }
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return [] }
        let type = CGImageSourceGetType(source) as String?
        let count = type == "com.compuserve.gif" ? min(1, CGImageSourceGetCount(source))
            : min(CGImageSourceGetCount(source), maxImages)
        var images: [RGBAImage] = []
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= RGBAImage.maxSide, height <= RGBAImage.maxSide,
                  width * height <= RGBAImage.maxPixels,
                  let cgImage = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else { continue }
            // Bits a sample, times the channels: 24 or 32 for most. A
            // palette image's depth is its index's (8, or 4).
            let depth = properties[kCGImagePropertyDepth] as? Int
            let channels = (properties[kCGImagePropertyHasAlpha] as? Bool ?? false) ? 4 : 3
            let indexed = (properties[kCGImagePropertyColorModel] as? String) == nil && depth.map { $0 < 8 } == true
            if let image = RGBAImage(cgImage: cgImage, bitDepth: depth.map { indexed ? $0 : $0 * channels }) {
                images.append(image)
            }
        }
        return images
    }

    /// A PICT, as a resource or a file without its 512-byte header: one is
    /// put in front, as ImageIO expects a file.
    public static func decodePICT(_ data: Data, hasFileHeader: Bool = false) -> RGBAImage? {
        let file = hasFileHeader ? data : Data(count: 512) + data
        return decode(file, typeHint: "com.apple.pict", maxImages: 1).first
    }
}
