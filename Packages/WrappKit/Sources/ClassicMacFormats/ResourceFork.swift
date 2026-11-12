//
//  ResourceFork.swift
//  ClassicMacFormats
//
//  A classic Mac resource fork: a header giving where its data and map are,
//  the map's list of types, each type's list of references (ID, name,
//  attributes and where its data is), and the names. Inside Macintosh: More
//  Macintosh Toolbox, "Resource Manager", has the layout. A file's icons
//  (ICN#, icl8, cicn…), its pictures (PICT) and the Finder's bundle (BNDL,
//  FREF) that says which icons are the application's own all live here.
//  Every read is bounds-checked and every list capped.

import Foundation

nonisolated public struct MacResource: Sendable {
    /// Its four-character type: 'ICN#', 'PICT'.
    public let type: String
    public let id: Int
    public let name: String?
    public let data: Data
}

nonisolated public struct ResourceFork: Sendable {
    public let resources: [MacResource]

    /// Nil if `data` isn't a resource fork.
    public init?(data: Data) {
        guard data.count >= 16 + 30, let dataOffset = data.be32(at: 0), let mapOffset = data.be32(at: 4),
              let dataLength = data.be32(at: 8), let mapLength = data.be32(at: 12),
              dataOffset >= 16, mapOffset >= 16, mapLength >= 30,
              mapOffset + mapLength <= data.count, dataOffset + dataLength <= data.count,
              let typeListOffset = data.be16(at: mapOffset + 24), let nameListOffset = data.be16(at: mapOffset + 26)
        else { return nil }
        let typeList = mapOffset + typeListOffset
        let nameList = mapOffset + nameListOffset
        guard let typeCountMinusOne = data.be16(at: typeList) else { return nil }
        // An empty fork says 0xFFFF types (none).
        let typeCount = typeCountMinusOne == 0xFFFF ? 0 : typeCountMinusOne + 1
        var resources: [MacResource] = []
        for index in 0..<min(typeCount, 1024) {
            let entry = typeList + 2 + index * 8
            guard let type = data.osType(at: entry), let countMinusOne = data.be16(at: entry + 4),
                  let referenceOffset = data.be16(at: entry + 6) else { return nil }
            for reference in 0..<min(countMinusOne + 1, 8192) {
                let at = typeList + referenceOffset + reference * 12
                guard let id = data.be16Signed(at: at), let nameOffset = data.be16(at: at + 2),
                      let location = data.be32(at: at + 4) else { break }
                let start = dataOffset + (location & 0xFF_FFFF)
                guard let length = data.be32(at: start),
                      let bytes = data.subdata(checked: (start + 4)..<(start + 4 + length)) else { continue }
                let name = nameOffset == 0xFFFF ? nil : data.pascalString(at: nameList + nameOffset)
                resources.append(MacResource(type: type, id: id, name: name, data: bytes))
                guard resources.count < 100_000 else { break }
            }
        }
        self.resources = resources
    }

    public func resource(_ type: String, id: Int) -> MacResource? {
        resources.first { $0.type == type && $0.id == id }
    }

    public func resources(ofType type: String) -> [MacResource] {
        resources.filter { $0.type == type }
    }

    /// The types it holds, in order.
    public var types: [String] {
        var seen: Set<String> = []
        return resources.compactMap { seen.insert($0.type).inserted ? $0.type : nil }
    }

    /// The resource ID of the application's own icon family: the Finder's
    /// bundle (BNDL) maps the FREF whose file type is 'APPL' (for a
    /// document, its type) to a local icon ID, and that local ID to the
    /// ICN#'s (and icl8's, ics#'s …) real ID. Nil without a bundle.
    public func bundleIconID(forFileType fileType: String = "APPL") -> Int? {
        guard let bundle = resources(ofType: "BNDL").first?.data, let types = bundle.be16(at: 6) else { return nil }
        var iconMap: [Int: Int] = [:]
        var frefMap: [Int: Int] = [:]
        var offset = 8
        for _ in 0..<min(types + 1, 64) {
            guard let type = bundle.osType(at: offset), let count = bundle.be16(at: offset + 4) else { break }
            offset += 6
            for _ in 0..<min(count + 1, 1024) {
                guard let local = bundle.be16Signed(at: offset), let id = bundle.be16Signed(at: offset + 2) else { break }
                if type == "ICN#" { iconMap[local] = id }
                if type == "FREF" { frefMap[local] = id }
                offset += 4
            }
        }
        for (_, frefID) in frefMap.sorted(by: { $0.key < $1.key }) {
            guard let fref = resource("FREF", id: frefID)?.data, fref.osType(at: 0) == fileType,
                  let localIcon = fref.be16Signed(at: 4), let icon = iconMap[localIcon] else { continue }
            return icon
        }
        return nil
    }

    /// The application's signature (its creator code), from its bundle.
    public var bundleSignature: String? { resources(ofType: "BNDL").first?.data.osType(at: 0) }

    /// A file's custom icon (kHasCustomIcon), always ID -16455.
    public static let customIconID = -16455
}
