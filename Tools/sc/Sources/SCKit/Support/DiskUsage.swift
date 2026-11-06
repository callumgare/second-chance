import Darwin
import Foundation

/// How much space deleting some folders would give back, allowing for APFS
/// clones, which `du` counts in full.
///
/// A worktree's caches start as clones of the main checkout's
/// (`Worktrees.clone`), and layers are clones of one another, so `du` can say
/// gigabytes where deleting frees almost nothing: blocks a clone shares stay
/// as long as one file still uses them. APFS tells each file its private size
/// (the blocks no other file shares), its clone family's id and how many files
/// are in that family. A file whose whole family is among what's deleted
/// counts its shared blocks once; one with family members elsewhere counts
/// only its private blocks. A clone that has since been changed leaves its
/// family while still sharing most blocks, and those shared blocks count only
/// when the file they're shared with is outside the set, so this can
/// undercount a little when both are deleted together; it never counts a
/// block twice. A volume without these attributes is measured as `du` would.
enum DiskUsage {
    /// The bytes deleting every folder (or file) in `urls` would free.
    nonisolated static func freed(by urls: [URL]) -> Int64 {
        var walk = Walk()
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            walk.add(url)
        }
        return walk.total
    }

    /// One file's allocated size and what APFS says of its clones.
    struct FileSpace: Equatable {
        var allocated: Int64
        /// Bytes no other file shares, or nil where the volume doesn't say.
        var privateSize: Int64?
        var cloneID: UInt64?
        var cloneCount: UInt32?
    }

    /// Sums a set of files, counting each clone family's shared blocks once
    /// when every member is in the set. Kept apart from the walk so it can be
    /// tested without making clones.
    struct Tally {
        private(set) var standalone: Int64 = 0
        private var families: [UInt64: (seen: UInt32, count: UInt32, shared: Int64, privateSum: Int64)] = [:]

        mutating func add(_ file: FileSpace) {
            guard let privateSize = file.privateSize else {
                standalone += file.allocated
                return
            }
            guard let id = file.cloneID, let count = file.cloneCount, count > 1 else {
                standalone += privateSize
                return
            }
            var family = families[id] ?? (seen: 0, count: count, shared: 0, privateSum: 0)
            family.seen += 1
            family.count = max(family.count, count)
            // The shared blocks are in every member; the largest allocation
            // less its own private blocks is the best guess at them.
            family.shared = max(family.shared, file.allocated - privateSize)
            family.privateSum += privateSize
            families[id] = family
        }

        var total: Int64 {
            standalone + families.values.reduce(0) { sum, family in
                sum + family.privateSum + (family.seen >= family.count ? family.shared : 0)
            }
        }
    }

    private struct Walk {
        var tally = Tally()
        /// Hard-linked files seen, by device and inode, so each counts once.
        var linked: Set<[UInt64]> = []

        var total: Int64 { tally.total }

        mutating func add(_ url: URL) {
            let path = strdup(url.path)
            defer { free(path) }
            var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(fts) }
            while let entry = fts_read(fts) {
                let info = Int32(entry.pointee.fts_info)
                guard let stat = entry.pointee.fts_statp?.pointee else { continue }
                let allocated = Int64(stat.st_blocks) * 512
                switch info {
                case FTS_F:
                    if stat.st_nlink > 1, !linked.insert([UInt64(stat.st_dev), UInt64(stat.st_ino)]).inserted { continue }
                    var file = DiskUsage.space(of: entry.pointee.fts_path)
                    file.allocated = allocated
                    tally.add(file)
                case FTS_D, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                    tally.add(FileSpace(allocated: allocated))
                default:
                    continue
                }
            }
        }
    }

    /// What `getattrlist` says of a file's clones; `allocated` is filled in by
    /// the caller from the walk's `stat`.
    nonisolated static func space(of path: UnsafePointer<CChar>) -> FileSpace {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT)
        // length, the returned set, then each attribute in bit order.
        let size = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
            + MemoryLayout<off_t>.size + MemoryLayout<UInt64>.size + MemoryLayout<UInt32>.size
        var buffer = [UInt8](repeating: 0, count: size + 16)
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        let status = buffer.withUnsafeMutableBytes { getattrlist(path, &request, $0.baseAddress, $0.count, options) }
        guard status == 0 else { return FileSpace(allocated: 0) }
        return buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<UInt32>.size
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            var file = FileSpace(allocated: 0)
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                file.privateSize = Int64(raw.loadUnaligned(fromByteOffset: offset, as: off_t.self))
                offset += MemoryLayout<off_t>.size
            }
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                file.cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                offset += MemoryLayout<UInt64>.size
            }
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT) != 0 {
                file.cloneCount = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            return file
        }
    }
}
