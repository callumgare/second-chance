//
//  HandlerRegistry.swift
//  ProgramImages
//
//  Which handler reads which kind of file, in order: native readers first,
//  then the outside tools for what they don't read, so a tool is the
//  fallback for anything a native handler declines. A handler finds images
//  in its node (`Crawl.addImage`), nodes inside it (`Crawl.enqueue`), or
//  both (a self-extracting installer's icon and its payload).

import Foundation

nonisolated enum HandlerRegistry {
    static let handlers: [any NodeHandler] = [
        DirectoryHandler(),
        WindowsProgramHandler(),
        IconFileHandler(),
        ImageFileHandler(),
        ShellLinkHandler(),
        AutorunHandler(),
        CompoundFileHandler(),
        DiscHandler(),
        MacEncodingHandler(),
        ArchiveToolHandler(),
        InstallShieldHandler(),
        StuffItHandler(),
        DearkHandler(),
        VideoHandler(),
        DeferredHandler(),
    ]
}

/// Formats known but not read yet, each said so rather than carved blind.
nonisolated struct DeferredHandler: NodeHandler {
    let name = "deferred"

    func handles(_ identification: Identification) -> Bool {
        [.director, .flash, .herCIF, .herAVF, .installShieldHeader, .dosProgram, .extendedProgram]
            .contains(identification.kind)
    }

    func expand(_ node: Node, _ identification: Identification, _ crawl: Crawl) throws -> HandlerOutcome {
        switch identification.kind {
        case .director:
            crawl.skip(node, "Director movies' cast bitmaps aren't read yet")
        case .flash:
            crawl.skip(node, "Flash files aren't read")
        case .herCIF:
            crawl.skip(node, "Her Interactive's CIF archives aren't read yet")
        case .herAVF:
            crawl.skip(node, "Her Interactive's AVF videos aren't read yet")
        case .installShieldHeader:
            // Read with its cabinet (data1.cab), by unshield.
            return .handled
        default:
            // DOS programs and extenders hold no icons.
            return .handled
        }
        return .handled
    }
}
