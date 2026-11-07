import Foundation
import SQLite3

/// A small wrapper over the system SQLite, for the local indexes (LaunchBox, TheGamesDB, My Abandonware).
nonisolated final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            throw IconLabError.tool("SQLite: \(msg) (\(path))")
        }
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw IconLabError.tool("SQLite: \(msg)")
        }
    }

    final class Statement {
        let stmt: OpaquePointer?
        init(_ s: OpaquePointer?) { stmt = s }
        deinit { sqlite3_finalize(stmt) }

        func bind(_ args: [Any?]) {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            for (i, a) in args.enumerated() {
                let n = Int32(i + 1)
                switch a {
                case nil: sqlite3_bind_null(stmt, n)
                case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
                case let v as Double: sqlite3_bind_double(stmt, n, v)
                case let v as String: sqlite3_bind_text(stmt, n, v, -1, SQLiteDB.transient)
                case let v?: sqlite3_bind_text(stmt, n, "\(v)", -1, SQLiteDB.transient)
                }
            }
        }

        func run(_ args: [Any?]) {
            bind(args)
            sqlite3_step(stmt)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw IconLabError.tool("SQLite: \(String(cString: sqlite3_errmsg(db)))") }
        return Statement(s)
    }

    /// Rows as arrays of Int / Double / String / nil.
    func query(_ sql: String, _ args: [Any?] = []) throws -> [[Any?]] {
        lock.lock(); defer { lock.unlock() }
        let st = try prepare(sql)
        st.bind(args)
        var rows: [[Any?]] = []
        while sqlite3_step(st.stmt) == SQLITE_ROW {
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(st.stmt) {
                switch sqlite3_column_type(st.stmt, c) {
                case SQLITE_INTEGER: row.append(Int(sqlite3_column_int64(st.stmt, c)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(st.stmt, c))
                case SQLITE_NULL: row.append(nil)
                default: row.append(sqlite3_column_text(st.stmt, c).map { String(cString: $0) })
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// An FTS5 query from what someone typed: every word must match, the last as a prefix ("kid pi" finds "Kid Pix").
    static func ftsQuery(_ q: String) -> String? {
        let toks = Titles.tokens(q, keepStopwords: true).filter { !$0.isEmpty }
        guard !toks.isEmpty else { return nil }
        return toks.enumerated().map { i, t in "\"\(t)\"" + (i == toks.count - 1 && t.count >= 2 ? "*" : "") }.joined(separator: " ")
    }
}

/// A local copy of a source's database, rebuilt from a download in a job and refreshed weekly.
actor LocalIndex {
    let dir: URL
    let dbName: String
    let maxAge: TimeInterval
    private var db: SQLiteDB?
    private(set) var building = false
    private(set) var lastError: String?

    init(dir: URL, dbName: String = "index.sqlite", maxAge: TimeInterval = 7 * 86400) {
        self.dir = dir
        self.dbName = dbName
        self.maxAge = maxAge
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    var dbFile: URL { dir.appendingPathComponent(dbName) }

    var exists: Bool { FileManager.default.fileExists(atPath: dbFile.path) }

    var stale: Bool {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: dbFile.path)[.modificationDate]) as? Date else { return true }
        return Date().timeIntervalSince(d) > maxAge
    }

    func open() -> SQLiteDB? {
        if let db { return db }
        guard exists else { return nil }
        db = try? SQLiteDB(path: dbFile.path, readOnly: true)
        return db
    }

    /// Runs `build` (which writes a new database at the URL it's given) unless one is running, then swaps it in.
    func rebuild(_ build: @Sendable (URL) async throws -> Void) async throws {
        guard !building else { return }
        building = true
        defer { building = false }
        let tmp = dir.appendingPathComponent(dbName + ".new")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try await build(tmp)
            db = nil
            try? FileManager.default.removeItem(at: dbFile)
            try FileManager.default.moveItem(at: tmp, to: dbFile)
            lastError = nil
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            lastError = "\(error)"
            throw error
        }
    }

    /// Marks the copy as fresh without rebuilding (the download hadn't changed).
    func touch() {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dbFile.path)
    }

    func needsRefresh(force: Bool) -> Bool { !building && (force || !exists || stale) }
}
