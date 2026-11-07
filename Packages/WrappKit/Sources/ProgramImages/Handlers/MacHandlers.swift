//
//  MacHandlers.swift
//  ProgramImages
//
//  Classic Mac files: their resource forks' icons (each icon family, the
//  application's own through its bundle, a custom icon, a volume's icon)
//  and pictures; and the encodings that carry a Mac file through a world of
//  one fork (MacBinary, AppleSingle/Double, BinHex), unwrapped into a node
//  with both forks.

import ClassicMacFormats
import Foundation

nonisolated enum MacResourceHandler {
    static func expand(_ node: Node, crawl: Crawl) {
        guard let mac = node.mac, let forkData = mac.resourceFork, let fork = ResourceFork(data: forkData) else { return }
        let fileName = node.name
        let isApplication = mac.type == "APPL" || mac.type == "appe" || mac.type == "APPC"
        var done: Set<Int> = []

        func family(_ id: Int, roles: Set<ImageRole>, label: String) {
            done.insert(id)
            for decoded in MacIconDecoder.family(id, in: fork) {
                crawl.addImage(decoded.image, node: node, steps: [Step(.fork, label), Step(.resource, decoded.label)],
                               roles: roles.union([.icon]), familyKey: "\(node.id)/family \(id)",
                               iconSource: IconSource(path: node.matchPath, groupIndex: 0, groupID: id))
            }
        }

        // The application's own icon, through its bundle.
        if let id = fork.bundleIconID(forFileType: "APPL") {
            family(id, roles: isApplication ? [.macAppIcon, .firstIconGroup] : [.macAppIcon], label: "resource fork")
        }
        // A custom icon: a volume's, if this is the root's Icon\r.
        if fork.resource("ICN#", id: ResourceFork.customIconID) != nil || fork.resource("icns", id: ResourceFork.customIconID) != nil
            || fork.resource("icl8", id: ResourceFork.customIconID) != nil {
            var roles: Set<ImageRole> = [.customIcon]
            if fileName == "Icon\r" && mac.isVolumeRoot { roles.insert(.volumeIcon) }
            family(ResourceFork.customIconID, roles: roles, label: "resource fork")
        }
        // Every other icon, each ID a family.
        let ids = Set(fork.resources.filter { MacIconDecoder.iconTypes.contains($0.type) }.map(\.id)).subtracting(done)
        for id in ids.sorted() {
            family(id, roles: [], label: "resource fork")
        }
        // Pictures.
        for picture in fork.resources(ofType: "PICT").prefix(500) {
            guard let image = ImageIODecoder.decodePICT(picture.data) else { continue }
            let name = picture.name.map { " “\($0)”" } ?? ""
            crawl.addImage(image, node: node, steps: [Step(.fork, "resource fork"), Step(.resource, "PICT \(picture.id)\(name)")],
                           roles: [.picture])
        }
    }
}

nonisolated struct MacEncodingHandler: NodeHandler {
    let name = "mac-encoding"

    func handles(_ identification: Identification) -> Bool {
        [.macBinary, .appleSingle, .binHex, .resourceFork].contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        guard let data = node.data() else { return .declined }
        let file: MacFile?
        switch identification.kind {
        case .macBinary: file = MacBinary.decode(data)
        case .appleSingle: file = AppleSingle.decode(data, name: node.name)
        case .binHex: file = BinHex.decode(data)
        default:
            // A bare resource fork (.rsrc, or a fork a tool wrote out).
            file = MacFile(name: node.name, type: "", creator: "", finderFlags: 0, dataFork: Data(), resourceFork: data)
        }
        guard let file else { return .declined }
        var child = crawl.makeNode(parent: node, step: Step(.entry, file.name, detail: identification.kind.rawValue),
                                   content: .bytes(file.dataFork))
        child.mac = MacMetadata(type: file.type, creator: file.creator, finderFlags: file.finderFlags,
                                resourceFork: file.resourceFork)
        crawl.enqueue(child)
        return .handled
    }
}
