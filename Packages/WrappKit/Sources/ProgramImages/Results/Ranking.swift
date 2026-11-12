//
//  Ranking.swift
//  ProgramImages
//
//  After the crawl: which images are the program's own icon (hints from the
//  wrapp's launch, shortcuts, autorun.inf matched against where each icon
//  was found), which are sizes of the same art (families), and a score for
//  how likely each is to make a good icon, with its reasons. Where an image
//  came from counts most, then its shape, then its content.

import Foundation

nonisolated enum Ranking {
    /// Give each image the roles the hints name, and if nothing named the
    /// main program, guess it: the shallowest, then largest, windowed
    /// program with an icon that isn't an installer or a tool.
    static func resolveHints(_ crawl: Crawl) {
        let images = Array(crawl.images.values)
        for image in images {
            for source in image.iconSources {
                for hint in crawl.hints where hint.matches(source.path) {
                    let applies: Bool
                    switch hint.iconIndex {
                    case nil: applies = source.groupIndex == 0
                    case let index? where index >= 0: applies = source.groupIndex == index
                    case let index?: applies = source.groupID == -index
                    }
                    if applies { image.roles.insert(hint.role) }
                }
            }
        }
        guard !images.contains(where: { $0.roles.contains(.mainProgramIcon) }) else { return }
        let excluded = ["setup", "install", "unins", "config", "launcher", "register", "update", "patch", "readme"]
        let candidates = crawl.programs.filter { program in
            let name = program.path.last ?? ""
            return !program.isInstaller && program.isGUI && program.hasIcon && name.hasSuffix(".exe")
                && !excluded.contains(where: name.hasPrefix)
        }
        guard let main = candidates.min(by: { ($0.path.count, -$0.size) < ($1.path.count, -$1.size) }) else { return }
        for image in images where image.iconSources.contains(where: { $0.path == main.path && $0.groupIndex == 0 }) {
            image.roles.insert(.likelyMainProgramIcon)
        }
    }

    /// The records: scored, grouped into families, best first.
    static func records(for images: [FoundImage]) -> [ImageRecord] {
        let images = images.sorted { $0.order < $1.order }
        var parent = Array(images.indices)
        func root(_ item: Int) -> Int {
            var item = item
            while parent[item] != item {
                parent[item] = parent[parent[item]]
                item = parent[item]
            }
            return item
        }
        func union(_ a: Int, _ b: Int) {
            let (rootA, rootB) = (root(a), root(b))
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }

        // Images found together as one icon (a group's sizes, a Mac family).
        // A classic Mac's SICN (a generic small-icon list, which aliases share) is no icon's member: it mustn't join
        // the icons it's found beside into one family.
        var byKey: [String: Int] = [:]
        for (position, image) in images.enumerated() where !image.chains.allSatisfy({ $0.contains { $0.name.hasPrefix("SICN") } }) {
            for key in image.familyKeys {
                if let first = byKey[key] { union(first, position) } else { byKey[key] = position }
            }
        }
        // Then perceptually: the same art at other sizes or depths, by
        // difference hash, among images of about the same shape. Flat images
        // hash alike whatever they show, so they're left out.
        let hashes = images.map { $0.image.differenceHash }
        var buckets: [Int: [Int]] = [:]
        for (position, image) in images.enumerated() {
            let bits = hashes[position].nonzeroBitCount
            guard bits >= 6, bits <= 58, image.image.dominantColourShare < 0.9 else { continue }
            let aspect = Int((Double(image.image.width) / Double(image.image.height) * 8).rounded())
            buckets[aspect, default: []].append(position)
        }
        // Only images of different sizes or depths join this way (the same art at the same size and depth would
        // be the same pixels, which dedupe already merged), and small ones need a closer match: at 32×32, two
        // different icons can hash within a few bits.
        for members in buckets.values {
            for (offset, a) in members.enumerated() {
                for b in members[(offset + 1)...] {
                    let left = images[a].image, right = images[b].image
                    guard (left.width, left.height, left.bitDepth) != (right.width, right.height, right.bitDepth) else { continue }
                    let small = max(left.width, left.height, right.width, right.height) <= 64
                    if (hashes[a] ^ hashes[b]).nonzeroBitCount <= (small ? 2 : 6) { union(a, b) }
                }
            }
        }

        let scored = images.map { score($0) }
        var families: [Int: [Int]] = [:]
        for position in images.indices { families[root(position), default: []].append(position) }
        var records: [ImageRecord] = []
        for members in families.values {
            // The representative: the largest, deepest, best scored.
            guard let best = members.max(by: { a, b in
                let left = images[a].image, right = images[b].image
                return (left.width * left.height, left.bitDepth, scored[a].score)
                    < (right.width * right.height, right.bitDepth, scored[b].score)
            }) else { continue }
            let familyScore = members.map { scored[$0].score }.max() ?? 0
            for member in members {
                let image = images[member]
                let (score, reasons) = scored[member]
                // A family is as good as its best member; each member keeps its own reasons.
                let combined = member == best ? max(score, familyScore) : score
                records.append(ImageRecord(
                    sha256: image.sha256, file: image.sha256 + ".png", width: image.image.width,
                    height: image.image.height, bitDepth: image.image.bitDepth, hasAlpha: image.image.hasAlpha,
                    familyID: images[best].sha256, isFamilyRepresentative: member == best, familySize: members.count,
                    provenance: image.chains.map { ImageRecord.Provenance(steps: $0, display: Step.display($0)) },
                    sources: image.sources, roles: image.roles.sorted { $0.rawValue < $1.rawValue },
                    score: (combined * 10).rounded() / 10,
                    scoreReasons: member == best && combined > score ? reasons + ["family's best member scores \(familyScore)"]
                        : reasons,
                    dHash: String(format: "%016llx", hashes[member])))
            }
        }
        return records.sorted { ($0.score, $0.width * $0.height, $1.sha256) > ($1.score, $1.width * $1.height, $0.sha256) }
    }

    /// How likely an image is to make a good icon, and why.
    static func score(_ found: FoundImage) -> (score: Double, reasons: [String]) {
        var score = 0.0
        var reasons: [String] = []
        func add(_ points: Double, _ reason: String) {
            score += points
            reasons.append("\(points > 0 ? "+" : "")\(Int(points)) \(reason)")
        }
        let roles = found.roles
        // Where it came from.
        if roles.contains(.mainProgramIcon) { add(60, "the main program's icon") }
        if roles.contains(.likelyMainProgramIcon) { add(40, "the icon of the likeliest main program") }
        if roles.contains(.macAppIcon) { add(45, "a Mac application's own icon") }
        if roles.contains(.shortcutIcon) { add(45, "a shortcut's icon") }
        if roles.contains(.msiIcon) { add(45, "the MSI's icon") }
        if roles.contains(.volumeIcon) { add(55, "the disc's own icon") }
        if roles.contains(.autorunIcon) { add(40, "autorun.inf's icon") }
        if roles.contains(.customIcon), !roles.contains(.volumeIcon) { add(25, "a custom icon") }
        if roles.contains(.appBundleIcon) { add(30, "the app's icon") }
        if roles.contains(.wrappIcon) { add(10, "the wrapp's icon") }
        if roles.contains(.firstIconGroup) { add(15, "a program's first icon group") }
        if roles.contains(.installerOwnIcon) { add(10, "an installer's icon") }
        if roles.contains(.icon), !roles.contains(.firstIconGroup) { add(5, "an icon") }
        if roles.contains(.installerArt) { add(5, "installer art") }
        if roles.contains(.titleLikeName) { add(12, "a name like logo or title") }
        if roles.contains(.uiLikeName) { add(-12, "a name like button or cursor") }
        if roles.contains(.runtimeLibrary) { add(-40, "from a runtime library or system folder") }
        if roles.contains(.cursor) { add(-30, "a cursor") }
        if roles.contains(.carved) { add(-3, "found by its signature") }
        if found.sources > 1 { add(Double(min(found.sources, 6) - 1) * 3, "found in \(found.sources) places") }

        // Shape.
        let image = found.image
        let side = Double(max(image.width, image.height))
        add(min(18, 2 * log2(side)), "\(image.width)×\(image.height)")
        let aspect = Double(max(image.width, image.height)) / Double(min(image.width, image.height))
        if aspect > 4 {
            add(-25, "a strip, not a picture (\(String(format: "%.1f", aspect)):1)")
        } else if aspect > 2 {
            add(-8, "long and thin")
        }
        if side <= 16 { add(-5, "tiny") }

        // Content.
        // One colour is one shade over most of it: two close shades (a pinstripe of two dark blues) are a pattern,
        // which can be an icon's background.
        let flat = image.dominantColourShare > 0.85 && image.dominantColourSpread < 2.5
        if flat { add(-20, "mostly one colour") }
        let luma = image.meanLuma
        // Solid black or white is filler (a mask, a blank background); a dark or light picture with something in it
        // can be an icon's background, so darkness or lightness alone costs nothing.
        if flat, luma < 12 { add(-15, "nearly black") } else if flat, luma > 248 { add(-10, "nearly white") }
        if image.hasAlpha, !image.isFullyTransparent { add(5, "has transparency") }
        if roles.contains(.videoFrame), luma < 24 { add(-10, "a dark frame") }
        return (score, reasons)
    }
}
