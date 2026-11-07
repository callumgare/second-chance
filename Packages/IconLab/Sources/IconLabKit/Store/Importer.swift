import Foundation

/// Brings the first lab's games (`v1/games/<slug>/`) into the store: images, masks and what was learnt of each.
nonisolated public enum Importer {
    public static func importV1(gamesDir: URL, store: Store) async throws -> [String] {
        let fm = FileManager.default
        var done: [String] = []
        for slug in (try? fm.contentsOfDirectory(atPath: gamesDir.path)) ?? [] {
            let g = gamesDir.appendingPathComponent(slug)
            guard let gameData = try? Data(contentsOf: g.appendingPathComponent("game.json")),
                  let game = try? JSONSerialization.jsonObject(with: gameData) as? [String: Any] else { continue }
            if await store.program(slug) != nil { continue }
            try await store.saveProgram(.init(slug: slug, title: game["title"] as? String ?? slug))
            let analysis = (try? Data(contentsOf: g.appendingPathComponent("analysis.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] } ?? [:]
            let images = g.appendingPathComponent("images")
            for name in ((try? fm.contentsOfDirectory(atPath: images.path)) ?? []).sorted() where !name.hasSuffix(".thumb.png") {
                let file = images.appendingPathComponent(name)
                guard Bitmap.load(file) != nil else { continue }
                let a = analysis[name] ?? [:]
                let source = name.hasPrefix("ia-") ? "Internet Archive" : name.hasPrefix("wikipedia") ? "Wikipedia" : name.hasPrefix("local-") ? "Your files" : "Imported"
                var rec = try await store.addMedia(slug, from: file, name: name, source: source,
                                                   kind: (a["kind"] as? String).map(MediaKind.fromV1))
                if a["kind_set"] != nil { rec.kindSet = true }
                if let m = a["mask"] as? String {
                    let mask = g.appendingPathComponent(m)
                    if fm.fileExists(atPath: mask.path) {
                        try? fm.createDirectory(at: store.maskFile(slug, rec.id).deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.removeItem(at: store.maskFile(slug, rec.id))
                        try fm.copyItem(at: mask, to: store.maskFile(slug, rec.id))
                        rec.hasMask = true
                    }
                }
                if let metrics = a["metrics"] as? [String: Any], let circle = metrics["circle_at"] as? [Double],
                   (metrics["circle"] as? Double ?? 0) > 0.5 {
                    rec.analysis.circle = circle
                }
                rec.picked = true
                try await store.upsertMedia(slug, rec)
            }
            done.append(slug)
        }
        return done
    }
}
