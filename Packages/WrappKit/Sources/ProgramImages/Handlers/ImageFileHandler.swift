//
//  ImageFileHandler.swift
//  ProgramImages
//
//  Image files: what ImageIO reads (PNG, JPEG, GIF, BMP, TIFF, TGA, ICNS,
//  PICT), PCX natively, and the carving of images out of anything unread.

import Foundation
import WindowsFormats

nonisolated struct ImageFileHandler: NodeHandler {
    let name = "image-file"

    func handles(_ identification: Identification) -> Bool {
        [.png, .jpeg, .gif, .bmp, .tiff, .tga, .icns, .pict, .pcx].contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let data = node.data() else { return .declined }
        var images: [RGBAImage]
        switch identification.kind {
        case .pcx:
            images = PCXDecoder.decode(data).map { [$0] } ?? []
        case .pict:
            // A PICT file has a 512-byte header; a Mac file's data fork may not.
            images = ImageIODecoder.decodePICT(data, hasFileHeader: true).map { [$0] }
                ?? ImageIODecoder.decodePICT(data).map { [$0] } ?? []
        case .tga:
            images = ImageIODecoder.decode(data, typeHint: "com.truevision.tga-image")
        default:
            images = ImageIODecoder.decode(data)
        }
        guard !images.isEmpty else {
            // Not readable by ImageIO: deark's turn, if it's here.
            return .declined
        }
        let isIconFamily = identification.kind == .icns
        for image in images {
            crawl.addImage(image, node: node, steps: [], roles: isIconFamily ? [.icon] : [.picture],
                           familyKey: isIconFamily ? "\(node.id)/icns" : nil,
                           iconSource: isIconFamily ? IconSource(path: node.matchPath, groupIndex: 0, groupID: nil) : nil)
        }
        return .handled
    }

    /// The images in `data` if it's an image file of a kind read without
    /// help (a resource or stream that is a whole PNG, BMP, icon …).
    static func decodeKnown(_ data: Data) -> [RGBAImage] {
        let head = [UInt8](data.prefix(16))
        guard head.count >= 8 else { return [] }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8, 0xFF])
            || head.starts(with: Array("GIF8".utf8)) || head.starts(with: Array("icns".utf8))
            || (head.starts(with: Array("BM".utf8)) && data.u32(at: 14).map { [12, 40, 52, 56, 108, 124].contains($0) } == true) {
            return ImageIODecoder.decode(data)
        }
        if head.starts(with: [0, 0, 1, 0]), let file = ICOFile(data: data) {
            return file.images.compactMap { WindowsImageDecoder.decodeIconImage($0.data) }
        }
        // A bare DIB (a BITMAPINFOHEADER and pixels).
        if data.u32(at: 0) == 40, let header = DIBHeader(data: data), header.height > 0, data.count >= header.pixelOffset {
            return WindowsImageDecoder.decodeBitmap(data).map { [$0] } ?? []
        }
        return []
    }
}

/// Images found by their signatures inside what nothing reads.
nonisolated enum Carving {
    /// The most bytes carved from one file: past it, the rest is left.
    static let limit = 768 << 20

    static func carve(_ node: Node, crawl: Crawl) {
        guard crawl.options.carve, node.size >= 256 else { return }
        guard node.size <= limit else {
            crawl.skip(node, "too large to search for images (\(node.size / (1 << 20)) MB)")
            return
        }
        guard let data = node.data() else { return }
        carve(data, label: nil, node: node, crawl: crawl)
    }

    static func carve(_ data: Data, label: String?, node: Node, crawl: Crawl) {
        let hits = ImageCarver.carve(data.prefix(limit), stop: { crawl.isCancelled })
        for hit in hits {
            guard let bytes = data.bytes(in: hit.range) else { continue }
            let images = ImageIODecoder.decode(bytes, maxImages: 1)
            let at = "\(hit.kind.rawValue) @0x\(String(hit.range.lowerBound, radix: 16))"
            let steps = (label.map { [Step(.resource, $0)] } ?? []) + [Step(.carved, at)]
            for image in images {
                crawl.addImage(image, node: node, steps: steps, roles: [.carved])
            }
        }
    }
}
