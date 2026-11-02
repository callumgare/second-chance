//
//  FreeSpace.swift
//  SecondChance
//
//  Checks there's room for a build before it starts copying, so a full disk
//  is said plainly at the start rather than surfacing later as an installer's
//  exit code or a failed copy.

import Foundation
import Logging
import SecondChanceKit

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.FreeSpace")

nonisolated enum FreeSpace {
    /// What a build needs besides the game itself: the template's engine
    /// and the Wine prefix, with room to spare.
    static let buildOverhead: Int64 = 3 * 1_000_000_000

    /// Bytes free for important work on the volume holding `url`, as macOS
    /// counts it (purgeable space included); nil if it can't say.
    static func available(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage
        } catch {
            logger.warning("Couldn't read the free space at \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// Throw `notEnoughSpace` unless `needed` bytes are free where `url` is.
    /// When the free space can't be read, the build goes ahead.
    static func ensure(_ needed: Int64, at url: URL) throws {
        guard let available = available(at: url) else { return }
        logger.notice("Free space: \(describe(available)) at \(url.path); the build needs about \(describe(needed))")
        if available < needed {
            logger.critical("Not enough free space: \(describe(needed)) needed, \(describe(available)) free")
            throw WrappBuildError.notEnoughSpace(needed: needed, available: available)
        }
    }

    /// The size of what's at `url`: a file's, or a volume's used space for a
    /// disc's root. Nil if it can't say.
    static func size(of url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .fileSizeKey, .isDirectoryKey,
            ])
            if values.isVolume == true, let total = values.volumeTotalCapacity {
                return Int64(total - (values.volumeAvailableCapacity ?? 0))
            }
            if values.isDirectory == true {
                return DirectorySize.measure(url).bytes
            }
            return values.fileSize.map(Int64.init)
        } catch {
            logger.warning("Couldn't read the size of \(url.path): \(error.localizedDescription)")
            return nil
        }
    }

    /// "4.2 GB", as Finder would say it.
    static func describe(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
