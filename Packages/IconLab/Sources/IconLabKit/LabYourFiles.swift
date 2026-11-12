import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.Lab")

/// Pictures the person adds by hand (dropped from the Finder), and clearing a source without gathering again.
nonisolated extension Lab {
    static let yourFiles = "Your files"

    /// Adds a picture the person dropped in: a "Your files" picture, picked, at the top of the suitability scale
    /// (it's what they chose), and analysed as any other. The same picture again is the one already there.
    public func addOwnPicture(_ slug: String, name: String, data: Data) async throws -> MediaRecord {
        guard await store.program(slug) != nil else { throw IconLabError.notFound("program \(slug)") }
        let safeName = (name as NSString).lastPathComponent.isEmpty ? "picture.png" : (name as NSString).lastPathComponent
        let ext = (safeName as NSString).pathExtension.isEmpty ? "png" : (safeName as NSString).pathExtension
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iconlab-\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        defer {
            do { try FileManager.default.removeItem(at: tmp) } catch { logger.debug("Couldn't remove \(tmp.path): \(error)") }
        }
        guard Bitmap.load(tmp) != nil else { throw IconLabError.tool("\(safeName) isn't a picture Icon Lab can read") }
        var rec = try await store.addMedia(slug, from: tmp, name: safeName, source: Lab.yourFiles, provenance: "Added by you › \(safeName)")
        rec.deep = (rec.deep ?? [:]).merging(["byHand": .bool(true)]) { _, b in b }
        try await store.upsertMedia(slug, rec)
        rec = try await pickAll(slug, rec.id, true)
        await analyse(slug, rec.id)
        return rec
    }

    /// Removes every picture a source found (`"files"` for Your files, which also forgets its scans), without
    /// gathering again. Returns how many were removed.
    @discardableResult
    public func clearSource(_ slug: String, _ source: String) async throws -> Int {
        let match: (MediaRecord) -> Bool = source == "files"
            ? { $0.source == Lab.yourFiles }
            : { m in m.remote?.source == source }
        let count = await store.media(slug).filter(match).count
        try await removeMedia(slug, where: match)
        if source == "files" {
            let scans = store.dir(slug).appendingPathComponent("scans")
            if FileManager.default.fileExists(atPath: scans.path) {
                do { try FileManager.default.removeItem(at: scans) } catch { logger.warning("Couldn't forget \(slug)'s scans: \(error)") }
            }
        }
        return count
    }
}
