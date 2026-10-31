import Foundation
import CryptoKit
import SQLite3

/// What `questbits import` reads besides the QuestBits database, all read-only: source
/// files (quotes and hashes) and claude-mem work_state events.
enum ImportSources {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }

    /// A source's timestamp text as a date: ISO 8601 (with or without fractional seconds),
    /// or SQLite's "yyyy-MM-dd HH:mm:ss" (UTC). nil when it is neither.
    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// A source file as read now. `error` when it cannot be read (every item quoting it
    /// becomes a conflict).
    struct File {
        let config: ImportConfig.SourceFile
        let path: String
        let text: String?
        let sha256: String?
        let modified: Date?
        let error: String?

        /// The file's lines (a final newline ends the last line; it does not start another).
        var lines: [String] {
            guard let text else { return [] }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return lines
        }

        static func read(_ config: ImportConfig.SourceFile) -> File {
            let path = expand(config.path)
            guard let data = FileManager.default.contents(atPath: path) else {
                return File(config: config, path: path, text: nil, sha256: nil, modified: nil, error: "cannot read \(path)")
            }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return File(config: config, path: path, text: String(decoding: data, as: UTF8.self),
                        sha256: ImportSources.sha256(data), modified: modified, error: nil)
        }
    }

    /// The text a SourceRef points at, with where it was found (1-based line numbers: a
    /// locator for the reviewer, not an identity).
    struct Quote {
        let text: String
        let firstLine: Int
        let lastLine: Int
    }

    static func resolve(_ ref: ImportConfig.SourceRef, in file: File) throws -> Quote {
        if let error = file.error { throw CLIError.failure(error) }
        let lines = file.lines
        if let needle = ref.lineContains {
            let hits = lines.indices.filter { lines[$0].contains(needle) }
            guard hits.count == 1 else {
                throw CLIError.failure(hits.isEmpty ? "no line contains \"\(needle)\" (source changed?)"
                                                    : "\(hits.count) lines contain \"\(needle)\"; make it unique")
            }
            let end = min(lines.count, hits[0] + max(1, ref.lines ?? 1))
            return Quote(text: lines[hits[0]..<end].joined(separator: "\n"), firstLine: hits[0] + 1, lastLine: end)
        }
        if let heading = ref.section?.trimmingCharacters(in: .whitespaces) {
            let hits = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == heading }
            guard hits.count == 1 else {
                throw CLIError.failure(hits.isEmpty ? "no heading \"\(heading)\" (source changed?)"
                                                    : "\(hits.count) headings \"\(heading)\"")
            }
            let level = headingLevel(heading)
            var end = hits[0] + 1
            while end < lines.count {
                let l = headingLevel(lines[end])
                if l > 0 && l <= level { break }
                end += 1
            }
            let body = lines[hits[0]..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Quote(text: body, firstLine: hits[0] + 1, lastLine: end)
        }
        throw CLIError.failure("source ref needs line_contains or section")
    }

    private static func headingLevel(_ line: String) -> Int {
        let hashes = line.prefix(while: { $0 == "#" }).count
        return hashes > 0 && line.dropFirst(hashes).first == " " ? hashes : 0
    }

    // MARK: - claude-mem work_state

    struct Event {
        let id: Int64
        let project: String
        let list: String
        let createdAt: String
        let fields: [String: Any]
        let fieldsJSON: String
    }

    struct ListCount: Hashable {
        let project: String
        let list: String
        let count: Int
        let maxId: Int64
    }

    /// The work_state database, opened read-only (SQLITE_OPEN_READONLY: SQLite refuses any
    /// write on this connection). Nothing here writes claude-mem's state.
    final class WorkStateDB {
        private var db: OpaquePointer?

        init(path: String) throws {
            let p = expand(path)
            guard FileManager.default.fileExists(atPath: p) else { throw CLIError.failure("no work_state database at \(p)") }
            if sqlite3_open_v2(p, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
                sqlite3_close(db); db = nil
                throw CLIError.failure("work_state database: \(message)")
            }
            sqlite3_busy_timeout(db, 5000)
        }

        deinit { sqlite3_close(db) }

        func lists() throws -> [ListCount] {
            var out: [ListCount] = []
            try query("SELECT project, list_name, COUNT(*), MAX(id) FROM work_state_entries GROUP BY project, list_name "
                      + "ORDER BY project, list_name;", []) { stmt in
                out.append(ListCount(project: text(stmt, 0), list: text(stmt, 1),
                                     count: Int(sqlite3_column_int64(stmt, 2)), maxId: sqlite3_column_int64(stmt, 3)))
            }
            return out
        }

        func events(project: String, list: String) throws -> [Event] {
            var out: [Event] = []
            try query("SELECT id, project, list_name, created_at, fields FROM work_state_entries "
                      + "WHERE project=? AND list_name=? ORDER BY id;", [project, list]) { stmt in
                let json = text(stmt, 4)
                let fields = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
                out.append(Event(id: sqlite3_column_int64(stmt, 0), project: text(stmt, 1), list: text(stmt, 2),
                                 createdAt: text(stmt, 3), fields: fields, fieldsJSON: json))
            }
            return out
        }

        private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
            sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
        }

        private func query(_ sql: String, _ binds: [String], row: (OpaquePointer?) -> Void) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw CLIError.failure("work_state query: \(String(cString: sqlite3_errmsg(db)))")
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, b) in binds.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), b, -1, transient) }
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { return }
                guard rc == SQLITE_ROW else { throw CLIError.failure("work_state query: \(String(cString: sqlite3_errmsg(db)))") }
                row(stmt)
            }
        }
    }

    // MARK: - Database copies

    /// Copy a QuestBits database to `dest` with SQLite's online backup API: a consistent
    /// snapshot even while the app or an MCP server writes it (WAL included), unlike a file
    /// copy. The source is only ever opened read-only, never migrated (`openSourceReadOnly`);
    /// `dest` is replaced, and may not be the source itself. Then the copy's integrity is
    /// checked.
    static func backup(_ source: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw CLIError.failure("no database at \(source.path)")
        }
        // Replacing dest would delete the source before it is read.
        let canonical = { (u: URL) in u.resolvingSymlinksInPath().standardizedFileURL.path }
        guard canonical(source) != canonical(dest) else {
            throw CLIError.failure("\(source.path) is the copy this run writes: copy it elsewhere first, or use another --out")
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dest.path + suffix) }
        defer {
            // Runs after both are closed: a -shm left without a -wal holds nothing.
            if !FileManager.default.fileExists(atPath: dest.path + "-wal") {
                try? FileManager.default.removeItem(atPath: dest.path + "-shm")
            }
        }
        var src: OpaquePointer?
        var dst: OpaquePointer?
        defer { sqlite3_close(src); sqlite3_close(dst) }
        let immutableStamp = try openSourceReadOnly(source, &src)
        sqlite3_busy_timeout(src, 5000)
        guard sqlite3_open(dest.path, &dst) == SQLITE_OK else {
            throw CLIError.failure("cannot create \(dest.path): \(String(cString: sqlite3_errmsg(dst)))")
        }
        guard let b = sqlite3_backup_init(dst, "main", src, "main") else {
            throw CLIError.failure("backup failed: \(String(cString: sqlite3_errmsg(dst)))")
        }
        var rc: Int32
        repeat {
            rc = sqlite3_backup_step(b, -1)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { sqlite3_sleep(100) }
        } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        sqlite3_backup_finish(b)
        guard rc == SQLITE_DONE else { throw CLIError.failure("backup failed: \(String(cString: sqlite3_errstr(rc)))") }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(dst, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              let result = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }), result == "ok" else {
            throw CLIError.failure("the copy at \(dest.path) failed its integrity check")
        }
        // One self-contained file (the copy took the source's WAL mode with it).
        sqlite3_finalize(stmt); stmt = nil
        sqlite3_exec(dst, "PRAGMA journal_mode=DELETE;", nil, nil, nil)
        // An immutable open sees no other writer: if one started meanwhile, the copy may
        // mix two states, so it is not used.
        if let before = immutableStamp, fileStamp(source) != before {
            throw CLIError.failure("\(source.path) changed while it was copied: run again")
        }
    }

    /// Open a database for reading only, without ever writing to it or beside it.
    /// - A plain read-only open, when SQLite can read it so and the -shm is there (a WAL
    ///   database another process has open).
    /// - Else, when there is no -wal with content (no process has it open, and every write
    ///   is in the main file): read-only and immutable (`immutable=1`: no locks, no -shm),
    ///   with the file's size and date kept so `backup` can tell a writer that started
    ///   meanwhile. A read-write open would create -wal/-shm and could replay or checkpoint
    ///   a leftover -wal into the source.
    /// - Else (a -wal with frames and no usable -shm: a crash leftover) it refuses.
    /// Returns the stamp for an immutable open, nil for a plain one.
    private static func openSourceReadOnly(_ source: URL, _ src: inout OpaquePointer?) throws -> [Double]? {
        let fm = FileManager.default
        let wal = (try? fm.attributesOfItem(atPath: source.path + "-wal"))?[.size] as? NSNumber
        // Without a -shm, even a read-only open of a WAL database may create one beside the
        // source (and rebuild a leftover -wal's index in it): only the paths below then.
        if fm.fileExists(atPath: source.path + "-shm"), sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
           sqlite3_exec(src, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK {
            return nil
        }
        sqlite3_close(src); src = nil
        guard (wal?.int64Value ?? 0) == 0 else {
            throw CLIError.failure("\(source.path) has unsaved changes in its -wal file and cannot be read safely "
                                   + "without changing it: open QuestBits once (it saves them), quit it, and run again")
        }
        let stamp = fileStamp(source)
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = source.path
        comps.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard let uri = comps.string,
              sqlite3_open_v2(uri, &src, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              sqlite3_exec(src, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) == SQLITE_OK else {
            let why = src.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            throw CLIError.failure("cannot open \(source.path) read-only: \(why)")
        }
        return stamp
    }

    /// The database file's size and modification date, and whether a -wal is there.
    private static func fileStamp(_ url: URL) -> [Double] {
        let fm = FileManager.default
        let a = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        return [(a[.size] as? NSNumber)?.doubleValue ?? -1,
                (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1,
                fm.fileExists(atPath: url.path + "-wal") ? 1 : 0]
    }
}
