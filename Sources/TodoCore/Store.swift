import Foundation
import SQLite3

// SQLite wants this when binding Swift strings (transient → it copies the bytes).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .prepare(let m): return "sqlite prepare failed: \(m)"
        case .step(let m): return "sqlite step failed: \(m)"
        case .notFound(let m): return "not found: \(m)"
        case .invalid(let m): return "invalid: \(m)"
        }
    }
}

/// Thread-safe (serialized) SQLite-backed data store shared by the app and the MCP server.
/// WAL mode lets both processes read/write concurrently without clobbering.
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public let dbURL: URL

    /// Images attached to task details: files in `attachments/` next to the database,
    /// referenced from the markdown as `attachments/<name>` (`Store.attachmentPrefix`).
    public var attachmentsURL: URL {
        dbURL.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
    }
    public static let attachmentPrefix = "attachments/"

    /// Save an image for a task detail; returns the path to put in the markdown. The name
    /// is random, so files never collide; nothing else is written. Deleting a task or
    /// removing the image from its detail leaves the file.
    public func saveAttachment(_ data: Data, fileExtension ext: String) throws -> String {
        let clean = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        let name = UUID().uuidString.lowercased() + "." + (clean.isEmpty ? "png" : String(clean.prefix(5)))
        try FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        try data.write(to: attachmentsURL.appendingPathComponent(name), options: .atomic)
        return Self.attachmentPrefix + name
    }

    /// The file behind an attachment path from a detail, or nil when the path is not one
    /// (or tries to leave the folder).
    public func attachmentFile(_ path: String) -> URL? {
        guard path.hasPrefix(Self.attachmentPrefix) else { return nil }
        let name = String(path.dropFirst(Self.attachmentPrefix.count)).removingPercentEncoding ?? ""
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return attachmentsURL.appendingPathComponent(name)
    }

    /// Default shared location: ~/Library/Application Support/TodoApp/db.sqlite
    /// Dev builds (compiled with -D DEV_BUILD) use a separate TodoAppDev
    /// directory so experiments never touch production data.
    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if DEV_BUILD
        let dir = "TodoAppDev"
        #else
        let dir = "TodoApp"
        #endif
        return base.appendingPathComponent(dir, isDirectory: true)
                   .appendingPathComponent("db.sqlite", isDirectory: false)
    }

    public init(url: URL = Store.defaultDatabaseURL()) throws {
        self.dbURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        // Concurrency + durability tuning for two-process access.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        exec("PRAGMA busy_timeout=5000;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Low-level helpers

    @discardableResult
    private func exec(_ sql: String) -> Int32 {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Open a write transaction. Throws on SQLITE_BUSY (busy_timeout has already
    /// elapsed) so callers never silently run their read-modify-write outside a
    /// transaction — the cross-process serialization guarantee is real, not best-effort.
    private func beginImmediate() throws {
        if exec("BEGIN IMMEDIATE;") != SQLITE_OK {
            throw StoreError.step("begin immediate failed: \(errmsg())")
        }
    }

    private func errmsg() -> String { String(cString: sqlite3_errmsg(db)) }

    /// Does a column exist on a table? (used for additive migrations)
    private func columnExists(_ table: String, _ column: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(stmt, 1)) == column { return true }
        }
        return false
    }

    private func prepare(_ sql: String, _ binds: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare("\(errmsg()) — sql: \(sql)")
        }
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func runWrite(_ sql: String, _ binds: [SQLValue]) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.step(errmsg())
        }
    }

    /// Scalar string query (first column of first row), nil if no row.
    private func queryString(_ sql: String, _ binds: [SQLValue]) -> String? {
        guard let stmt = try? prepare(sql, binds) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    private func queryInt(_ sql: String, _ binds: [SQLValue]) -> Int64? {
        guard let stmt = try? prepare(sql, binds) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func lastInsertId() -> Int64 { sqlite3_last_insert_rowid(db) }

    // MARK: - Migrations

    private func migrate() throws {
        exec("""
        CREATE TABLE IF NOT EXISTS projects (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            name        TEXT NOT NULL,
            created_at  REAL NOT NULL,
            sort_order  INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS tasks (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            title       TEXT NOT NULL,
            detail      TEXT NOT NULL DEFAULT '',
            link        TEXT,
            status      TEXT NOT NULL DEFAULT 'todo',
            created_at  REAL NOT NULL,
            updated_at  REAL NOT NULL,
            sort_order  INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id);")
        exec("""
        CREATE TABLE IF NOT EXISTS focus_sessions (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at    REAL NOT NULL,
            ended_at      REAL NOT NULL,
            focus_seconds INTEGER NOT NULL
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)

        // --- Additive migration: short codes ---
        if !columnExists("projects", "code") { exec("ALTER TABLE projects ADD COLUMN code TEXT;") }
        if !columnExists("projects", "task_seq") { exec("ALTER TABLE projects ADD COLUMN task_seq INTEGER NOT NULL DEFAULT 0;") }
        if !columnExists("tasks", "code") { exec("ALTER TABLE tasks ADD COLUMN code TEXT;") }
        backfillCodes()

        // --- Additive migration: project description + task priority/due/tags ---
        if !columnExists("projects", "detail") { exec("ALTER TABLE projects ADD COLUMN detail TEXT NOT NULL DEFAULT '';") }
        if !columnExists("tasks", "priority") { exec("ALTER TABLE tasks ADD COLUMN priority TEXT NOT NULL DEFAULT 'none';") }
        if !columnExists("tasks", "due_date") { exec("ALTER TABLE tasks ADD COLUMN due_date REAL;") }
        if !columnExists("tasks", "tags") { exec("ALTER TABLE tasks ADD COLUMN tags TEXT NOT NULL DEFAULT '';") }

        // --- Additive migration: timestamps + effort + change history ---
        if !columnExists("tasks", "started_at") { exec("ALTER TABLE tasks ADD COLUMN started_at REAL;") }
        if !columnExists("tasks", "completed_at") { exec("ALTER TABLE tasks ADD COLUMN completed_at REAL;") }
        if !columnExists("tasks", "effort_seconds") { exec("ALTER TABLE tasks ADD COLUMN effort_seconds INTEGER NOT NULL DEFAULT 0;") }
        exec("""
        CREATE TABLE IF NOT EXISTS task_history (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id   INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            ts        REAL NOT NULL,
            field     TEXT NOT NULL,
            old_value TEXT NOT NULL DEFAULT '',
            new_value TEXT NOT NULL DEFAULT ''
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_history_task ON task_history(task_id);")

        // --- Additive migration: recurring tasks ---
        if !columnExists("tasks", "recurrence") { exec("ALTER TABLE tasks ADD COLUMN recurrence TEXT;") }

        // --- Additive migration: subtasks (one level of nesting) ---
        if !columnExists("tasks", "parent_id") { exec("ALTER TABLE tasks ADD COLUMN parent_id INTEGER REFERENCES tasks(id) ON DELETE CASCADE;") }
        exec("CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id);")

        // --- Additive migration: task dependencies (blocked-by edges) ---
        exec("""
        CREATE TABLE IF NOT EXISTS task_deps (
            task_id       INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            depends_on_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            PRIMARY KEY(task_id, depends_on_id)
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_deps_task ON task_deps(task_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_deps_depends ON task_deps(depends_on_id);")

        // --- Additive migration: non-blocking task relations (1.5.0) ---
        // kind relates (one row per pair, task_id < other_id, read both ways) or duplicates
        // (task_id is the duplicate of other_id). Blocking stays in task_deps. No CHECK on
        // kind, so a later kind needs no table rebuild; Store validates it.
        exec("""
        CREATE TABLE IF NOT EXISTS task_relations (
            task_id    INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            other_id   INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            kind       TEXT NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY(task_id, other_id, kind)
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_relations_other ON task_relations(other_id);")

        // --- Additive migration: time estimate (compared against effort_seconds) ---
        if !columnExists("tasks", "estimate_seconds") { exec("ALTER TABLE tasks ADD COLUMN estimate_seconds INTEGER NOT NULL DEFAULT 0;") }

        // --- Additive migration: reusable task templates ---
        exec("""
        CREATE TABLE IF NOT EXISTS task_templates (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            name             TEXT NOT NULL,
            title            TEXT NOT NULL,
            detail           TEXT NOT NULL DEFAULT '',
            priority         TEXT NOT NULL DEFAULT 'none',
            tags             TEXT NOT NULL DEFAULT '',
            estimate_seconds INTEGER NOT NULL DEFAULT 0,
            created_at       REAL NOT NULL
        );
        """)

        // --- Additive migration: waiting status (who it waits on + why) ---
        if !columnExists("tasks", "waiting_on") { exec("ALTER TABLE tasks ADD COLUMN waiting_on TEXT;") }
        if !columnExists("tasks", "waiting_reason") { exec("ALTER TABLE tasks ADD COLUMN waiting_reason TEXT;") }
        // When the task last entered waiting (the inbox's "waiting since"); NULL unless waiting.
        if !columnExists("tasks", "waiting_since") { exec("ALTER TABLE tasks ADD COLUMN waiting_since REAL;") }

        // --- Additive migration: task notes (append-only log; detail stays the spec) ---
        // The kind list is fixed in the table's CHECK: a new NoteKind needs a table rebuild
        // (see migrateNotesV2, which rebuilt it for 1.4.0).
        exec(Self.notesTableSQL("task_notes"))
        try migrateNotesV2()
        exec("CREATE INDEX IF NOT EXISTS idx_notes_task_ts ON task_notes(task_id, ts);")
        // Earlier text of a note the user edited (newest edit = highest id).
        exec("""
        CREATE TABLE IF NOT EXISTS task_note_edits (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            note_id INTEGER NOT NULL REFERENCES task_notes(id) ON DELETE CASCADE,
            ts      REAL NOT NULL,
            text    TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_note_edits_note ON task_note_edits(note_id);")

        // --- Additive migration: archived projects (NULL = active) ---
        if !columnExists("projects", "archived_at") { exec("ALTER TABLE projects ADD COLUMN archived_at REAL;") }

        // --- Additive migration: a project's repo / workspace folder (1.5.0; NULL = none) ---
        if !columnExists("projects", "repo_path") { exec("ALTER TABLE projects ADD COLUMN repo_path TEXT;") }

        // --- Additive migration: questions an agent leaves for the user (ask loop) ---
        // No project column: a question follows its task (and the task's project) on a move.
        exec("""
        CREATE TABLE IF NOT EXISTS questions (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id       INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            session_id    TEXT,
            kind          TEXT NOT NULL DEFAULT 'choice',
            prompt        TEXT NOT NULL,
            context       TEXT NOT NULL DEFAULT '',
            options       TEXT NOT NULL DEFAULT '[]',
            blocks_task   INTEGER NOT NULL DEFAULT 1,
            status        TEXT NOT NULL DEFAULT 'open',
            answer        TEXT,
            answer_choice INTEGER,
            cancel_reason TEXT,
            asked_at      REAL NOT NULL,
            answered_at   REAL,
            resumed_at    REAL,
            parked        INTEGER NOT NULL DEFAULT 0
        );
        """)
        // parked = 1: asking this question is what moved the task to waiting on the user.
        if !columnExists("questions", "parked") {
            exec("ALTER TABLE questions ADD COLUMN parked INTEGER NOT NULL DEFAULT 0;")
        }
        exec("CREATE INDEX IF NOT EXISTS idx_questions_status ON questions(status, asked_at);")
        exec("CREATE INDEX IF NOT EXISTS idx_questions_task ON questions(task_id);")

        // --- Additive migration: agent guides (1.4.2) ---
        // Append-only versions: the newest row of a scope is its guide, and a restore writes
        // the old text as a new version. project_id NULL is the guide for every project.
        exec("""
        CREATE TABLE IF NOT EXISTS guide_versions (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            project_id  INTEGER REFERENCES projects(id) ON DELETE CASCADE,
            ts          REAL NOT NULL,
            markdown    TEXT NOT NULL,
            author      TEXT NOT NULL CHECK(author IN \(Self.sqlList(NoteAuthor.allCases.map(\.rawValue)))),
            session_id  TEXT,
            reason      TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_guide_versions_project ON guide_versions(project_id, id);")

        // --- Additive migration: typed task links + working branch (1.5.0) ---
        // A task's links, oldest first; the primary one (first that is not a branch) is
        // mirrored into the legacy tasks.link column (kept, see syncLegacyLinks). No CHECK on kind or author: the
        // store validates them, so a new LinkKind needs no table rebuild.
        exec("""
        CREATE TABLE IF NOT EXISTS task_links (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id    INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            kind       TEXT NOT NULL DEFAULT 'other',
            url        TEXT NOT NULL,
            title      TEXT,
            author     TEXT,
            source     TEXT,
            created_at REAL NOT NULL,
            UNIQUE(task_id, url)
        );
        """)
        // The git branch the task's work is on now (NULL = none); earlier branches are links.
        if !columnExists("tasks", "branch") { exec("ALTER TABLE tasks ADD COLUMN branch TEXT;") }
        syncLegacyLinks()

        // --- Data repair: status-derived fields (every open; touches only rows that need it) ---
        repairStatusFields()
    }

    /// The task_notes table as of 1.4.0. `author` is NULL on older notes (and on notes an
    /// older binary still writes): who wrote them was not recorded. `history_id` is the
    /// status change a note came with, `question_id` the question it records.
    private static func notesTableSQL(_ name: String) -> String {
        """
        CREATE TABLE IF NOT EXISTS \(name) (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id     INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            ts          REAL NOT NULL,
            kind        TEXT NOT NULL DEFAULT 'note' CHECK(kind IN \(sqlList(NoteKind.allCases.map(\.rawValue)))),
            text        TEXT NOT NULL,
            author      TEXT CHECK(author IN \(sqlList(NoteAuthor.allCases.map(\.rawValue)))),
            session_id  TEXT,
            history_id  INTEGER,
            question_id INTEGER,
            edited_at   REAL
        );
        """
    }

    /// 1.4.0: rebuild a pre-1.4.0 task_notes (whose CHECK allows only note, decision and
    /// review) as `notesTableSQL`, keeping every row and id. One BEGIN IMMEDIATE, re-checked
    /// inside it, so the app and MCP server opening together rebuild it once. Older
    /// binaries keep working on the new table: their INSERT names only the old columns.
    /// A failed attempt rolls back (the old table stays) and is retried; if every attempt
    /// fails the open fails, since every notes query needs the new columns.
    private func migrateNotesV2() throws {
        var lastError: Error?
        for attempt in 1...3 {
            guard !columnExists("task_notes", "author") else { return }
            do {
                try beginImmediate()
                if !columnExists("task_notes", "author") {
                    exec("DROP TABLE IF EXISTS task_notes_v2;")
                    try runWrite(Self.notesTableSQL("task_notes_v2"), [])
                    try runWrite("INSERT INTO task_notes_v2 (id, task_id, ts, kind, text) "
                                 + "SELECT id, task_id, ts, kind, text FROM task_notes;", [])
                    try runWrite("DROP TABLE task_notes;", [])
                    try runWrite("ALTER TABLE task_notes_v2 RENAME TO task_notes;", [])
                }
                if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
                return
            } catch {
                exec("ROLLBACK;")
                lastError = error
                NSLog("QuestBits: notes migration attempt \(attempt) failed: \(error)")
                Thread.sleep(forTimeInterval: 1)
            }
        }
        throw StoreError.open("notes migration failed: \(lastError.map { "\($0)" } ?? "unknown error")")
    }

    /// Repair the fields that follow a task's status, on every open: rows written before
    /// every status path went through `statusTimestampExprs`, and rows an older binary
    /// still writes to the same file (an MCP server or app from before 1.3.0):
    /// - done with no `completed_at`: the last status change into done, else `updated_at`;
    /// - started (in progress or done) with no `started_at`: the first status change into
    ///   one, capped at `completed_at`, else `completed_at`, else `updated_at`;
    /// - not done but `completed_at` set: cleared (a reopened or dropped task);
    /// - waiting with no `waiting_since`: the last status change into waiting, else `updated_at`;
    /// - not waiting but `waiting_on` / `waiting_reason` / `waiting_since` set: cleared.
    /// Each UPDATE is guarded by its own WHERE, so a healthy database is only read: one
    /// EXISTS scan, and no write transaction unless it finds a row to fix. The fixes run
    /// in one BEGIN IMMEDIATE (the app and MCP server can open together); on failure it
    /// rolls back and logs, and the next open retries. Not tied to `PRAGMA user_version`
    /// (pre-release 1.3.0 builds left it at 1 or 2; a future one-off step should use 3+).
    private func repairStatusFields() {
        let done = TaskStatus.done.rawValue, waiting = TaskStatus.waiting.rawValue
        // History rows carry the raw value (create) or the display name (update).
        let names: (TaskStatus) -> [String] = { [$0.rawValue, $0.display] }
        let doneNames = Self.sqlList(names(.done))
        let waitingNames = Self.sqlList(names(.waiting))
        let startedNames = Self.sqlList(TaskStatus.allCases.filter(\.impliesStarted).flatMap(names))
        let startedStatuses = Self.sqlList(TaskStatus.allCases.filter(\.impliesStarted).map(\.rawValue))
        let needsDone = "status = '\(done)' AND completed_at IS NULL"
        let needsStart = "status IN \(startedStatuses) AND started_at IS NULL"
        let staleDone = "status != '\(done)' AND completed_at IS NOT NULL"
        let needsWaiting = "status = '\(waiting)' AND waiting_since IS NULL"
        let staleWaiting = "status != '\(waiting)' AND (waiting_on IS NOT NULL OR waiting_reason IS NOT NULL OR waiting_since IS NOT NULL)"
        let any = [needsDone, needsStart, staleDone, needsWaiting, staleWaiting].map { "(\($0))" }.joined(separator: " OR ")
        guard queryInt("SELECT EXISTS(SELECT 1 FROM tasks WHERE \(any));", []) == 1 else { return }
        do {
            try beginImmediate()
            let before = sqlite3_total_changes(db)
            // completed_at first: the started_at fill below caps at it.
            try runWrite(
                """
                UPDATE tasks SET completed_at = COALESCE(
                    (SELECT MAX(h.ts) FROM task_history h
                     WHERE h.task_id = tasks.id AND h.field = 'status' AND h.new_value IN \(doneNames)),
                    updated_at)
                WHERE \(needsDone);
                """, [])
            // First start from history, capped at completed_at (min() is NULL if either is).
            try runWrite(
                """
                UPDATE tasks SET started_at = COALESCE(min(s.ts, completed_at), s.ts, completed_at, updated_at)
                FROM (SELECT t.id AS tid,
                             (SELECT MIN(h.ts) FROM task_history h
                              WHERE h.task_id = t.id AND h.field = 'status' AND h.new_value IN \(startedNames)) AS ts
                      FROM tasks t WHERE \(needsStart)) AS s
                WHERE s.tid = tasks.id AND \(needsStart);
                """, [])
            try runWrite("UPDATE tasks SET completed_at = NULL WHERE \(staleDone);", [])
            try runWrite(
                """
                UPDATE tasks SET waiting_since = COALESCE(
                    (SELECT MAX(h.ts) FROM task_history h
                     WHERE h.task_id = tasks.id AND h.field = 'status' AND h.new_value IN \(waitingNames)),
                    updated_at)
                WHERE \(needsWaiting);
                """, [])
            try runWrite(
                "UPDATE tasks SET waiting_on = NULL, waiting_reason = NULL, waiting_since = NULL WHERE \(staleWaiting);", [])
            let fixed = sqlite3_total_changes(db) - before
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            NSLog("QuestBits: repaired status fields (\(fixed) row updates)")
        } catch {
            exec("ROLLBACK;")
            NSLog("QuestBits: status-field repair failed, will retry on next open: \(error)")
        }
    }

    /// Assign codes to any pre-existing rows that lack them.
    private func backfillCodes() {
        // Projects without a code.
        var pending: [(id: Int64, name: String)] = []
        if let stmt = try? prepare("SELECT id, name FROM projects WHERE code IS NULL OR code='';", []) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                pending.append((sqlite3_column_int64(stmt, 0), String(cString: sqlite3_column_text(stmt, 1))))
            }
            sqlite3_finalize(stmt)
        }
        for p in pending {
            let code = uniqueProjectCode(from: p.name)
            try? runWrite("UPDATE projects SET code=? WHERE id=?;", [.text(code), .int(p.id)])
        }

        // Tasks without a code — number them per project by id order.
        let projectIds = (try? listProjectIdsRaw()) ?? []
        for pid in projectIds {
            guard let pcode = queryString("SELECT code FROM projects WHERE id=?;", [.int(pid)]) else { continue }
            var seq = Int(queryInt("SELECT task_seq FROM projects WHERE id=?;", [.int(pid)]) ?? 0)
            var taskIds: [Int64] = []
            if let stmt = try? prepare("SELECT id FROM tasks WHERE project_id=? AND (code IS NULL OR code='') ORDER BY id;", [.int(pid)]) {
                while sqlite3_step(stmt) == SQLITE_ROW { taskIds.append(sqlite3_column_int64(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
            for tid in taskIds {
                seq += 1
                try? runWrite("UPDATE tasks SET code=? WHERE id=?;", [.text("\(pcode)-\(seq)"), .int(tid)])
            }
            if !taskIds.isEmpty {
                try? runWrite("UPDATE projects SET task_seq=? WHERE id=?;", [.int(Int64(seq)), .int(pid)])
            }
        }
    }

    private func listProjectIdsRaw() throws -> [Int64] {
        let stmt = try prepare("SELECT id FROM projects ORDER BY id;", [])
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    // MARK: - Code generation

    /// Derive a short uppercase code from a name: word-initials for multi-word
    /// names, else the first three letters. Falls back to "PRJ".
    private func baseProjectCode(from name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let alnum: (Substring) -> String = { String($0.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        var base: String
        if words.count >= 2 {
            base = words.prefix(4).compactMap { alnum($0).first.map(String.init) }.joined()
        } else {
            base = String(alnum(words.first ?? "").prefix(3))
        }
        if base.isEmpty { base = "PRJ" }
        return base
    }

    /// A project code as typed, trimmed and upper-cased; nil unless it is 1–10 ASCII
    /// letters and digits starting with a letter (task codes are "<code>-<n>").
    public static func normalizedProjectCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let letter: (Unicode.Scalar) -> Bool = { ("A"..."Z").contains($0) }
        guard (1...10).contains(code.unicodeScalars.count), let first = code.unicodeScalars.first, letter(first),
              code.unicodeScalars.allSatisfy({ letter($0) || ("0"..."9").contains($0) }) else { return nil }
        return code
    }

    /// `raw` checked as the code of project `id` (nil: a new project): well formed and not
    /// another project's code, archived ones included. Called inside the write transaction.
    private func validProjectCodeUnlocked(_ raw: String, for id: Int64?) throws -> String {
        guard let code = Self.normalizedProjectCode(raw) else {
            throw StoreError.invalid("a project code is 1–10 letters A–Z or digits, starting with a letter")
        }
        if let other = queryString("SELECT name FROM projects WHERE code=? COLLATE NOCASE AND id IS NOT ?;",
                                   [.text(code), id.map(SQLValue.int) ?? .null]) {
            throw StoreError.invalid("\(code) is already the code of project \(other)")
        }
        return code
    }

    /// A project code unique among existing projects, archived ones included so their
    /// codes stay reserved (appends 2, 3, … on clash).
    private func uniqueProjectCode(from name: String) -> String {
        let base = baseProjectCode(from: name)
        var candidate = base
        var n = 1
        while queryInt("SELECT COUNT(*) FROM projects WHERE code=?;", [.text(candidate)]) ?? 0 > 0 {
            n += 1
            candidate = "\(base)\(n)"
        }
        return candidate
    }

    // MARK: - Projects

    @discardableResult
    /// `guideTemplate` starts the project's guide from that template, as its first version
    /// (by `author`, in the same transaction).
    /// `code` sets the project's code (checked as setProjectCode does); nil or empty
    /// derives one from the name.
    /// `repoPath` sets its folder (checked as setProjectRepoPath does); nil or empty = none.
    public func createProject(name: String, detail: String = "", code customCode: String? = nil,
                              repoPath rawRepoPath: String? = nil, guideTemplate: GuideTemplate? = nil,
                              author: NoteAuthor = .user, sessionId: String? = nil) throws -> Project {
        let repoPath = try rawRepoPath.flatMap(Self.normalizedRepoPath)
        lock.lock(); defer { lock.unlock() }
        // The code pick, the end-of-list sort_order and the INSERT are one read-modify-write
        // the app and MCP server can race on (both picking the same code).
        do {
            try beginImmediate()
            let now = Date()
            let code = try customCode.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                .map { try validProjectCodeUnlocked($0, for: nil) } ?? uniqueProjectCode(from: name)
            if let repoPath { try requireRepoPathFreeUnlocked(repoPath, for: nil) }
            guard let sortOrder = queryInt("SELECT \(Self.nextProjectSortOrderSQL);", []) else { throw StoreError.step(errmsg()) }
            try runWrite(
                "INSERT INTO projects (name, code, detail, task_seq, created_at, sort_order, repo_path) VALUES (?, ?, ?, 0, ?, ?, ?);",
                [.text(name), .text(code), .text(detail), .int(Int64(now.timeIntervalSince1970)), .int(sortOrder),
                 repoPath.map(SQLValue.text) ?? .null]
            )
            let id = lastInsertId()
            if let guideTemplate {
                let session = sessionId.flatMap { $0.isEmpty ? nil : $0 }
                try runWrite(
                    "INSERT INTO guide_versions (project_id, ts, markdown, author, session_id, reason) VALUES (?, ?, ?, ?, ?, ?);",
                    [.int(id), .double(now.timeIntervalSince1970), .text(guideTemplate.markdown), .text(author.rawValue),
                     session.map(SQLValue.text) ?? .null, .text(guideTemplate.reason)])
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return Project(id: id, code: code, name: name, detail: detail, createdAt: now, sortOrder: Int(sortOrder),
                           repoPath: repoPath)
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// The sort_order after every project (archived ones too): new and unarchived projects go last.
    private static let nextProjectSortOrderSQL = "(SELECT COALESCE(MAX(sort_order)+1,0) FROM projects)"

    /// Persist a new sidebar order for the active projects (`ids` in desired order).
    /// Inside one BEGIN IMMEDIATE it re-reads the active projects and writes a dense
    /// sort_order 0, 1, … over them in one UPDATE: ids deleted or archived meanwhile are
    /// skipped, and active projects missing from `ids` (e.g. just created by an agent)
    /// keep their relative order after the given ones. Archived projects keep their
    /// sort_order (they list after the active ones, and unarchiving puts one last).
    public func reorderProjects(ids: [Int64]) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            var current: [Int64] = []
            var stored: [Int64: Int64] = [:]
            let stmt = try prepare("SELECT id, sort_order FROM projects WHERE archived_at IS NULL ORDER BY sort_order, id;", [])
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                current.append(id)
                stored[id] = sqlite3_column_int64(stmt, 1)
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
            let active = Set(current)
            var seen = Set<Int64>()
            let given = ids.filter { active.contains($0) && seen.insert($0).inserted }
            // Only rows whose position changed: an unchanged order writes nothing (no poll reload).
            let moved = (given + current.filter { !seen.contains($0) }).enumerated()
                .map { (id: $0.element, order: Int64($0.offset)) }
                .filter { stored[$0.id] != $0.order }
            if !moved.isEmpty {
                let cases = Array(repeating: "WHEN ? THEN ?", count: moved.count).joined(separator: " ")
                let marks = Array(repeating: "?", count: moved.count).joined(separator: ", ")
                let binds = moved.flatMap { [SQLValue.int($0.id), .int($0.order)] } + moved.map { SQLValue.int($0.id) }
                try runWrite("UPDATE projects SET sort_order = CASE id \(cases) END WHERE id IN (\(marks));", binds)
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Canonical project column list (order must match `projectFromRow`).
    private static let projectCols = "id, code, name, detail, created_at, sort_order, archived_at, repo_path"

    /// Projects in sidebar order: active ones by sort_order (new projects go last), then
    /// archived ones by sort_order; id breaks ties. `includeArchived: false` leaves out
    /// archived ones.
    public func listProjects(includeArchived: Bool = true) throws -> [Project] {
        lock.lock(); defer { lock.unlock() }
        let whereSQL = includeArchived ? "" : "WHERE archived_at IS NULL "
        let stmt = try prepare(
            "SELECT \(Self.projectCols) FROM projects \(whereSQL)ORDER BY archived_at IS NOT NULL, sort_order, id;", [])
        defer { sqlite3_finalize(stmt) }
        var out: [Project] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(projectFromRow(stmt))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    private func projectFromRow(_ stmt: OpaquePointer?) -> Project {
        Project(
            id: sqlite3_column_int64(stmt, 0),
            code: colText(stmt, 1),
            name: colText(stmt, 2),
            detail: colText(stmt, 3),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
            sortOrder: Int(sqlite3_column_int64(stmt, 5)),
            archivedAt: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            repoPath: colTextOpt(stmt, 7)
        )
    }

    /// Archive (`archived: true`) or unarchive a project; returns it with its count of
    /// open tasks (read in the same transaction). Idempotent: archiving an archived
    /// project keeps its original `archived_at`, and unarchiving moves a project to the
    /// end of the active list only when it was archived. Its tasks stay as they are, and
    /// its code stays taken (`uniqueProjectCode` checks every project).
    @discardableResult
    public func setProjectArchived(id: Int64, archived: Bool) throws -> (project: Project, openTasks: Int) {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            if archived {
                try runWrite("UPDATE projects SET archived_at = COALESCE(archived_at, ?) WHERE id=?;",
                             [.double(Date().timeIntervalSince1970), .int(id)])
            } else {
                // Back at the end of the active list; an active project keeps its place.
                try runWrite(
                    """
                    UPDATE projects SET archived_at = NULL, sort_order = CASE WHEN archived_at IS NULL THEN sort_order
                        ELSE \(Self.nextProjectSortOrderSQL) END WHERE id=?;
                    """, [.int(id)])
            }
            guard sqlite3_changes(db) == 1 else { throw StoreError.notFound("project \(id)") }
            let stmt = try prepare("SELECT \(Self.projectCols) FROM projects WHERE id=?;", [.int(id)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.notFound("project \(id)") }
            let project = projectFromRow(stmt)
            let open = openTaskCountUnlocked(id)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return (project, open)
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// New or moved tasks go to active projects only (the app's move/copy menus list no
    /// archived ones), so new work never lands out of cross-project lists. Reading and
    /// updating tasks already in an archived project stays allowed, and so does a
    /// recurring task's next occurrence or a duplicate within its own project.
    /// App and MCP share this one rule; callers hold the lock (and, for a write that
    /// follows, BEGIN IMMEDIATE so an archive can't land in between).
    private func requireActiveProjectUnlocked(_ projectId: Int64) throws {
        guard let archived = queryInt("SELECT archived_at IS NOT NULL FROM projects WHERE id=?;",
                                      [.int(projectId)]) else {
            throw StoreError.notFound("project \(projectId)")
        }
        if archived != 0 {
            let code = queryString("SELECT code FROM projects WHERE id=?;", [.int(projectId)]) ?? "\(projectId)"
            throw StoreError.invalid("project \(code) is archived; unarchive it first")
        }
    }

    /// How many of a project's tasks (subtasks included) are still open (not `isClosed`);
    /// the same rule as `ProjectCounts.open`.
    private func openTaskCountUnlocked(_ projectId: Int64) -> Int {
        Int(queryInt("SELECT COUNT(*) FROM tasks WHERE project_id=? AND status NOT IN \(Self.closedStatusSQL);",
                     [.int(projectId)]) ?? 0)
    }

    /// Update a project's name and/or description (only provided fields change).
    public func updateProject(id: Int64, name: String? = nil, detail: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var sets: [String] = []
        var binds: [SQLValue] = []
        if let name { sets.append("name=?"); binds.append(.text(name)) }
        if let detail { sets.append("detail=?"); binds.append(.text(detail)) }
        guard !sets.isEmpty else { return }
        binds.append(.int(id))
        try runWrite("UPDATE projects SET \(sets.joined(separator: ", ")) WHERE id=?;", binds)
    }

    /// Change a project's code and return it as stored (upper-cased). Its tasks keep
    /// their codes, as a moved task does, so references to them stay valid; new tasks
    /// take the new code. Checked and written in one BEGIN IMMEDIATE.
    @discardableResult
    public func setProjectCode(id: Int64, code raw: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            guard queryInt("SELECT id FROM projects WHERE id=?;", [.int(id)]) != nil else {
                throw StoreError.notFound("project \(id)")
            }
            let code = try validProjectCodeUnlocked(raw, for: id)
            try runWrite("UPDATE projects SET code=? WHERE id=?;", [.text(code), .int(id)])
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return code
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Set (or, with nil or an empty path, clear) a project's repo folder and return it as
    /// stored: absolute, ~ expanded, `.`/`..` and trailing slashes removed. Symlinks stay
    /// as typed (find_project resolves them when it compares). No other active project may
    /// have the same folder; nested folders are fine (the deeper one wins in find_project).
    /// Checked and written in one BEGIN IMMEDIATE.
    @discardableResult
    public func setProjectRepoPath(id: Int64, path raw: String?) throws -> String? {
        let path = try raw.flatMap(Self.normalizedRepoPath)
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            guard queryInt("SELECT id FROM projects WHERE id=?;", [.int(id)]) != nil else {
                throw StoreError.notFound("project \(id)")
            }
            if let path { try requireRepoPathFreeUnlocked(path, for: id) }
            try runWrite("UPDATE projects SET repo_path=? WHERE id=?;", [path.map(SQLValue.text) ?? .null, .int(id)])
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return path
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Throws when an active project other than `id` already has `path` (compared resolved,
    /// so a symlink to the same folder counts). Archived projects may share it: find_project
    /// skips them. Called inside the write transaction.
    private func requireRepoPathFreeUnlocked(_ path: String, for id: Int64?) throws {
        let resolved = Self.resolvedPath(path)
        let stmt = try prepare("SELECT code, repo_path FROM projects WHERE repo_path IS NOT NULL "
                               + "AND archived_at IS NULL AND id IS NOT ?;", [id.map(SQLValue.int) ?? .null])
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let other = colTextOpt(stmt, 1), Self.resolvedPath(other) == resolved {
                throw StoreError.invalid("\(path) is already the folder of project \(colText(stmt, 0))")
            }
        }
    }

    /// The active project whose repo folder holds `path` (the folder itself or anything
    /// under it), or nil. When several do, as with a workspace and a repo inside it, the
    /// deepest folder wins; a tie (only possible after an unarchive) goes to sidebar order.
    /// Archived projects and projects without a folder never match. The path must be
    /// absolute (or start with ~); a relative one is an error.
    public func findProject(path: String) throws -> Project? {
        guard Self.isAbsolute(path) else { throw StoreError.invalid("path must be absolute (or start with ~): \(path)") }
        return Self.bestProject(for: path, among: try listProjects(includeArchived: false))
    }

    /// find_project's rule over projects already read (no database access), for callers
    /// that hold a project list: the first of `projects` whose folder contains `path` most
    /// specifically. Archived projects are skipped here too.
    public static func bestProject(for path: String, among projects: [Project]) -> Project? {
        guard isAbsolute(path) else { return nil }
        let target = resolvedPath(path)
        var best: (project: Project, depth: Int)?
        for p in projects where !p.isArchived {
            guard let root = p.repoPath.map(resolvedPath), pathIsInside(target, root: root) else { continue }
            let depth = root == "/" ? 0 : root.split(separator: "/").count
            if depth > (best?.depth ?? -1) { best = (p, depth) }
        }
        return best?.project
    }

    /// Open, in-progress and waiting-on-user task counts of one project (subtasks included),
    /// as `ProjectCounts` counts them; `done` is left 0.
    public func openTaskCounts(projectId: Int64) throws -> ProjectCounts {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(
            """
            SELECT COALESCE(SUM(status NOT IN \(Self.closedStatusSQL)), 0),
                   COALESCE(SUM(status = ?), 0),
                   COALESCE(SUM(status = ? AND waiting_on = ?), 0)
            FROM tasks WHERE project_id=?;
            """, [.text(TaskStatus.inProgress.rawValue), .text(TaskStatus.waiting.rawValue),
                  .text(WaitingOn.user.rawValue), .int(projectId)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.step(errmsg()) }
        var c = ProjectCounts()
        c.open = Int(sqlite3_column_int64(stmt, 0))
        c.inProgress = Int(sqlite3_column_int64(stmt, 1))
        c.waitingOnUser = Int(sqlite3_column_int64(stmt, 2))
        return c
    }

    // MARK: Repo paths (pure; shared by the app, MCP server and later the CLI and hooks)

    /// Absolute, or starting with ~ (after trimming).
    public static func isAbsolute(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("/") || s == "~" || s.hasPrefix("~/")
    }

    /// A repo folder as typed, in the form it is stored: trimmed, ~ expanded, `.`/`..` and
    /// trailing slashes removed; nil when empty (no folder). Symlinks are kept. Throws on
    /// a relative path, which would depend on whoever reads it.
    public static func normalizedRepoPath(_ raw: String) throws -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        guard isAbsolute(s) else { throw StoreError.invalid("the repo folder must be a full path (starting with / or ~): \(s)") }
        return lexicalPath(s)
    }

    /// ~ expanded, `.`/`..`, doubled and trailing slashes removed — by text only (not
    /// URL.standardized, which also rewrites /private/tmp as /tmp).
    private static func lexicalPath(_ s: String) -> String {
        let expanded = (s.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var parts: [Substring] = []
        for part in expanded.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The path as the file system sees it, for comparing: `lexicalPath`, then symlinks
    /// resolved and each existing component in its on-disk case (realpath, so a path
    /// typed in another case on a case-insensitive volume compares equal). Components
    /// that don't exist (yet) are kept as typed after the deepest one that does.
    public static func resolvedPath(_ raw: String) -> String {
        var head = lexicalPath(raw)
        var tail: [String] = []
        while true {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            if realpath(head, &buf) != nil {
                let base = String(cString: buf)
                guard !tail.isEmpty else { return base }
                return (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
            }
            guard head != "/", !head.isEmpty else { return lexicalPath(raw) }
            let ns = head as NSString
            tail.append(ns.lastPathComponent)
            head = ns.deletingLastPathComponent
        }
    }

    /// Is `path` the folder `root` or inside it? Both already `resolvedPath`. Compares by
    /// whole components: /x/careservice does not contain /x/careservice-2026.
    public static func pathIsInside(_ path: String, root: String) -> Bool {
        root == "/" ? path.hasPrefix("/") : (path == root || path.hasPrefix(root + "/"))
    }

    public func renameProject(id: Int64, name: String) throws {
        try updateProject(id: id, name: name)
    }

    public func deleteProject(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try runWrite("DELETE FROM projects WHERE id=?;", [.int(id)])
    }

    /// Resolve a project id from its code (case-insensitive). Locks internally.
    /// A project's code, or nil when there is no such project.
    public func projectCode(id: Int64) -> String? {
        lock.lock(); defer { lock.unlock() }
        return queryString("SELECT code FROM projects WHERE id=?;", [.int(id)])
    }

    public func projectId(forCode code: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return queryInt("SELECT id FROM projects WHERE code=? COLLATE NOCASE;", [.text(code)])
    }

    // MARK: - Tasks

    /// Canonical task column list (order must match `taskFromRow`).
    private static let taskCols = "id, code, project_id, title, detail, link, status, priority, due_date, tags, started_at, completed_at, effort_seconds, created_at, updated_at, sort_order, recurrence, parent_id, estimate_seconds, waiting_on, waiting_reason, waiting_since, branch"
    /// `taskCols` qualified with `tasks.`, for queries that join another table.
    private static let qualifiedTaskCols = taskCols.components(separatedBy: ", ").map { "tasks.\($0)" }.joined(separator: ", ")
    /// How many columns `taskCols` selects: the index of a column a query adds after them.
    private static let taskColCount = Int32(taskCols.components(separatedBy: ", ").count)

    /// `link` (legacy single link) becomes the task's primary link, its kind guessed;
    /// `author` is recorded on it. `branch` is the working branch (`normalizedBranch`).
    @discardableResult
    public func createTask(projectId: Int64, title: String, detail: String = "", link: String? = nil,
                           status: TaskStatus = .todo, waitingOn: WaitingOn? = nil, waitingReason: String? = nil,
                           priority: Priority = .none,
                           dueDate: Date? = nil, tags: [String] = [], recurrence: String? = nil,
                           parentId: Int64? = nil, estimateSeconds: Int = 0,
                           branch: String? = nil, author: NoteAuthor? = nil) throws -> TodoTask {
        let link = try link.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try Self.normalizedLinkURL($0) }
        let branch = try Self.normalizedBranch(branch)
        lock.lock(); defer { lock.unlock() }
        // The task_seq bump, its read-back and the INSERT are one read-modify-write the
        // app and MCP server can race on (both reading the same seq → duplicate codes).
        do {
            try beginImmediate()
            try requireActiveProjectUnlocked(projectId)
            let task = try createTaskUnlocked(projectId: projectId, title: title, detail: detail, link: link,
                                              status: status, waitingOn: waitingOn, waitingReason: waitingReason,
                                              priority: priority, dueDate: dueDate, tags: tags,
                                              recurrence: recurrence, parentId: parentId, estimateSeconds: estimateSeconds,
                                              branch: branch, author: author)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return task
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Insert a task without taking the lock or opening a transaction — for use inside
    /// already-locked methods (e.g. spawning the next occurrence of a recurring task from
    /// updateTask, which already holds BEGIN IMMEDIATE).
    /// `source` (duplicates) seeds the status timestamps: the rule runs as if moving the
    /// source's row to `status`, so a copy of a done task keeps its original times rather
    /// than counting as a new completion. Without it the task starts from an empty todo.
    @discardableResult
    private func createTaskUnlocked(projectId: Int64, title: String, detail: String = "", link: String? = nil,
                                    status: TaskStatus = .todo, waitingOn: WaitingOn? = nil, waitingReason: String? = nil,
                                    priority: Priority = .none,
                                    dueDate: Date? = nil, tags: [String] = [], recurrence: String? = nil,
                                    parentId: Int64? = nil, estimateSeconds: Int = 0,
                                    branch: String? = nil, author: NoteAuthor? = nil,
                                    timestampsFrom source: TodoTask? = nil,
                                    enforceNesting: Bool = true) throws -> TodoTask {
        let now = Date()
        let reason = waitingReason.flatMap { $0.isEmpty ? nil : $0 }
        if let msg = Self.waitingViolation(status: status, waitingOn: waitingOn,
                                           settingWaitingFields: Self.setsWaitingFields(waitingOn, reason)) {
            throw StoreError.invalid(msg)
        }
        // Enforce the one-level nesting invariant at the data layer so EVERY caller
        // (MCP, UI, recurrence spawn) is covered: a parent must itself be top-level.
        // moveTask's cascade and the recurrence subtask-clone only walk direct children,
        // so a grandchild would silently orphan on those paths. Internal callers that
        // already know the parent is top-level pass enforceNesting:false to skip the lookup.
        if enforceNesting, let parentId { try requireTopLevelParentUnlocked(parentId) }
        // A subtask must not recur: on completion a recurring task spawns a fresh
        // top-level occurrence, so a recurring subtask would leak a detached duplicate.
        // Force recurrence to nil whenever this task has a parent.
        let effectiveRecurrence = parentId == nil ? recurrence : nil
        // Next per-project sequence number → task code.
        // A code already taken is skipped: tasks keep their codes when they move or their
        // project's code changes, so another task may hold "<code>-<n>".
        let pcode = queryString("SELECT code FROM projects WHERE id=?;", [.int(projectId)]) ?? "PRJ"
        var code: String
        repeat {
            try runWrite("UPDATE projects SET task_seq = task_seq + 1 WHERE id=?;", [.int(projectId)])
            let seq = queryInt("SELECT task_seq FROM projects WHERE id=?;", [.int(projectId)]) ?? 1
            code = "\(pcode)-\(seq)"
        } while (queryInt("SELECT COUNT(*) FROM tasks WHERE code=? COLLATE NOCASE;", [.text(code)]) ?? 0) > 0
        let due: SQLValue = dueDate.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null
        let nowSecs = Int64(now.timeIntervalSince1970)
        let secs: (Date?) -> SQLValue = { $0.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null }
        // started_at/completed_at/waiting_since come from the shared status rule, evaluated
        // over a one-row "prior" table (the source's status + timestamps, or an empty todo).
        // The prior waiting_since is always NULL: a waiting copy is a new ask, waiting from now.
        let ts = Self.statusTimestampExprs(status, now: nowSecs)
        try runWrite(
            """
            INSERT INTO tasks (project_id, code, title, detail, branch, status, waiting_on, waiting_reason, priority, due_date, tags, recurrence, parent_id, estimate_seconds, started_at, completed_at, waiting_since, created_at, updated_at, sort_order)
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(ts.startedAt), \(ts.completedAt), \(ts.waitingSince), ?, ?, (SELECT COALESCE(MAX(sort_order)+1,0) FROM tasks WHERE project_id=?)
            FROM (SELECT ? AS status, ? AS started_at, ? AS completed_at, NULL AS waiting_since);
            """,
            [.int(projectId), .text(code), .text(title), .text(detail), branch.map(SQLValue.text) ?? .null,
             .text(status.rawValue), waitingOn.map { .text($0.rawValue) } ?? .null, reason.map(SQLValue.text) ?? .null,
             .text(priority.rawValue), due, .text(encodeTags(tags)),
             effectiveRecurrence.map(SQLValue.text) ?? .null, parentId.map(SQLValue.int) ?? .null,
             .int(Int64(max(0, estimateSeconds)))]
            + ts.binds
            + [.int(nowSecs), .int(nowSecs), .int(projectId),
               .text((source?.status ?? .todo).rawValue), secs(source?.startedAt), secs(source?.completedAt)]
        )
        let id = lastInsertId()
        // The legacy column is written only as the mirror of the primary link.
        if let link { try setLegacyLinkUnlocked(taskId: id, raw: link, author: author, log: false, bump: false) }
        logEvent(id, "created", "", title)
        if status != .todo { logEvent(id, "status", TaskStatus.todo.display, status.display) }
        if let waitingOn { logEvent(id, "waiting on", "", waitingOn.rawValue) }
        guard let task = getTaskUnlocked(id) else { throw StoreError.notFound("task \(id)") }
        return task
    }

    /// One project's tasks, or every task (archived projects too) when `projectId` is nil,
    /// in board order (`boardOrderSQL`).
    public func listTasks(projectId: Int64? = nil) throws -> [TodoTask] {
        lock.lock(); defer { lock.unlock() }
        if let pid = projectId {
            return try readTasks("SELECT \(Self.taskCols) FROM tasks WHERE project_id=? ORDER BY sort_order, id;", [.int(pid)])
        }
        return try readTasks(
            "SELECT \(Self.qualifiedTaskCols) FROM tasks \(Self.projectJoinSQL) ORDER BY \(Self.boardOrderSQL);", [])
    }

    /// Tasks matching `filter`, filtered in SQL and ordered by status (`TaskStatus.listRank`:
    /// in progress, waiting, todo, done, dropped), then board order (`boardOrderSQL`).
    /// Values are bound, never interpolated.
    public func listTasks(matching filter: TaskFilter) throws -> [TodoTask] {
        lock.lock(); defer { lock.unlock() }
        var conds: [String] = []
        var binds: [SQLValue] = []
        if let pid = filter.projectId {
            conds.append("project_id=?"); binds.append(.int(pid))
        }
        if let statuses = filter.statuses {
            // An empty set matches nothing rather than everything.
            conds.append(statuses.isEmpty ? "0" : "status IN (\(Self.placeholders(statuses.count)))")
            binds += statuses.map { .text($0.rawValue) }
        }
        if let tag = filter.tag {
            // Tags are stored comma-joined (encodeTags trims them; spaces around commas are
            // also dropped here in case an older row kept them). Wrap both sides in commas
            // so only a whole tag matches; instr, not LIKE, so % and _ are literal.
            // lower() folds ASCII letters only.
            conds.append("instr(',' || lower(REPLACE(REPLACE(trim(tags), ', ', ','), ' ,', ',')) || ',', "
                         + "',' || lower(?) || ',') > 0")
            binds.append(.text(tag))
        }
        if let parentId = filter.parentId {
            conds.append("parent_id=?"); binds.append(.int(parentId))
        }
        if filter.projectId == nil && filter.parentId == nil && !filter.includeArchived {
            conds.append(Self.activeProjectSQL)
        }
        let whereSQL = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        let orderSQL = filter.sort == .board ? Self.treeOrderSQL : "\(Self.statusRankSQL), \(Self.boardOrderSQL)"
        return try readTasks(
            "SELECT \(Self.qualifiedTaskCols) FROM tasks \(Self.projectJoinSQL) \(whereSQL) ORDER BY \(orderSQL);", binds)
    }

    /// Run a `taskCols` SELECT and read every row; a step error throws instead of
    /// returning a partial list. Caller holds the lock.
    private func readTasks(_ sql: String, _ binds: [SQLValue]) throws -> [TodoTask] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [TodoTask] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(taskFromRow(stmt))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    /// The task's project is not archived — for cross-project task lists (a WHERE
    /// condition over the `tasks` table's `project_id`).
    static let activeProjectSQL = "project_id NOT IN (SELECT id FROM projects WHERE archived_at IS NOT NULL)"
    /// The same rule as `activeProjectSQL`, as a join that also brings the project in as
    /// `p` (for its code). Change the two together.
    static let activeProjectJoinSQL = "JOIN projects p ON p.id = tasks.project_id AND p.archived_at IS NULL"

    /// Brings each task's project in as `p`, for `boardOrderSQL`. Task columns in WHERE
    /// clauses stay unqualified: none of them is also a `projects` column.
    private static let projectJoinSQL = "JOIN projects p ON p.id = tasks.project_id"
    /// Cross-project task order: projects in sidebar order (`listProjects`: active ones by
    /// sort_order, then archived ones), then each project's own task order.
    private static let boardOrderSQL =
        "p.archived_at IS NOT NULL, p.sort_order, p.id, tasks.sort_order, tasks.id"
    /// `TaskSort.board`: the order the app's list shows. Projects as in `boardOrderSQL`;
    /// within a project each top-level task by sort_order, followed by its own subtasks by
    /// sort_order. A subtask keeps its parent's place even when the parent is filtered out.
    private static let treeOrderSQL =
        "p.archived_at IS NOT NULL, p.sort_order, p.id, "
        + "COALESCE((SELECT pt.sort_order FROM tasks pt WHERE pt.id = tasks.parent_id), tasks.sort_order), "
        + "COALESCE(tasks.parent_id, tasks.id), tasks.parent_id IS NOT NULL, tasks.sort_order, tasks.id"

    /// `TaskStatus.listRank` as a SQL expression over the `status` column.
    private static let statusRankSQL = "CASE status "
        + TaskStatus.allCases.map { "WHEN '\($0.rawValue)' THEN \($0.listRank) " }.joined()
        + "ELSE \(TaskStatus.allCases.count) END"

    /// Subtasks of a parent task, ordered like the main list.
    public func subtasks(parentId: Int64) throws -> [TodoTask] {
        lock.lock(); defer { lock.unlock() }
        return subtasksUnlocked(parentId)
    }

    /// Direct subtasks of a parent without taking the lock — for use inside
    /// already-locked scopes (e.g. carrying a checklist onto a recurrence spawn).
    private func subtasksUnlocked(_ parentId: Int64) -> [TodoTask] {
        guard let stmt = try? prepare("SELECT \(Self.taskCols) FROM tasks WHERE parent_id=? ORDER BY sort_order, id;", [.int(parentId)]) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [TodoTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(taskFromRow(stmt)) }
        return out
    }

    /// Completion progress of a parent's subtasks: (done, total). Dropped subtasks are
    /// left out of both — they are no longer part of the work.
    public func subtaskProgress(parentId: Int64) throws -> (done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(
            "SELECT COUNT(*), COALESCE(SUM(CASE WHEN status='\(TaskStatus.done.rawValue)' THEN 1 ELSE 0 END),0) "
            + "FROM tasks WHERE parent_id=? AND status != '\(TaskStatus.dropped.rawValue)';",
            [.int(parentId)]
        )
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, 0) }
        return (Int(sqlite3_column_int64(stmt, 1)), Int(sqlite3_column_int64(stmt, 0)))
    }

    public func getTask(id: Int64) throws -> TodoTask {
        lock.lock(); defer { lock.unlock() }
        guard let t = getTaskUnlocked(id) else { throw StoreError.notFound("task \(id)") }
        return t
    }

    /// Read a task without taking the lock — for use inside already-locked methods.
    private func getTaskUnlocked(_ id: Int64) -> TodoTask? {
        guard let stmt = try? prepare("SELECT \(Self.taskCols) FROM tasks WHERE id=?;", [.int(id)]) else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? taskFromRow(stmt) : nil
    }

    /// `logEvent` for a field typed into the app a keystroke at a time (the branch): when
    /// the task's latest history row is a change of the same field less than a minute old,
    /// that row takes the new value (and goes when the value is back where it started)
    /// instead of a row per keystroke. Best-effort, like logEvent.
    private func logTypedEvent(_ taskId: Int64, _ field: String, _ old: String, _ new: String) {
        let now = Int64(Date().timeIntervalSince1970)
        if let stmt = try? prepare("SELECT id, field, ts, old_value FROM task_history WHERE task_id=? ORDER BY id DESC LIMIT 1;",
                                   [.int(taskId)]) {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW, colText(stmt, 1) == field, now - sqlite3_column_int64(stmt, 2) < 60 {
                let rowId = sqlite3_column_int64(stmt, 0), first = colText(stmt, 3)
                if first == new {
                    try? runWrite("DELETE FROM task_history WHERE id=?;", [.int(rowId)])
                } else {
                    try? runWrite("UPDATE task_history SET new_value=?, ts=? WHERE id=?;", [.text(new), .int(now), .int(rowId)])
                }
                return
            }
        }
        logEvent(taskId, field, old, new)
    }

    /// Append a change-history row (caller already holds the lock). Returns its id, or
    /// nil if the insert failed (history is best-effort and never fails the write).
    @discardableResult
    private func logEvent(_ taskId: Int64, _ field: String, _ old: String, _ new: String) -> Int64? {
        do {
            try runWrite(
                "INSERT INTO task_history (task_id, ts, field, old_value, new_value) VALUES (?, ?, ?, ?, ?);",
                [.int(taskId), .int(Int64(Date().timeIntervalSince1970)), .text(field), .text(old), .text(new)]
            )
            return lastInsertId()
        } catch {
            return nil
        }
    }

    public func taskHistory(taskId: Int64) throws -> [TaskEvent] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT id, task_id, ts, field, old_value, new_value FROM task_history WHERE task_id=? ORDER BY ts DESC, id DESC;", [.int(taskId)])
        defer { sqlite3_finalize(stmt) }
        var out: [TaskEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TaskEvent(
                id: sqlite3_column_int64(stmt, 0),
                taskId: sqlite3_column_int64(stmt, 1),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                field: colText(stmt, 3),
                oldValue: colText(stmt, 4),
                newValue: colText(stmt, 5)
            ))
        }
        return out
    }

    /// Ids of tasks currently In Progress in projects not archived — for effort accrual
    /// (only the tasks the In Progress view and menu bar show earn focus time).
    public func inProgressTaskIds() throws -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT id FROM tasks WHERE status='in_progress' AND \(Self.activeProjectSQL);", [])
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    /// The inbox: waiting tasks that wait on the user — plus those waiting on a third party
    /// with `includeExternal` — across every project not archived, each with its project's
    /// code. Longest waiting first: `waiting_since` (falling back to `updated_at` for a row
    /// an older build set waiting without it), then id. Filtered and sorted in SQL.
    public func inbox(includeExternal: Bool = false) throws -> [(task: TodoTask, projectCode: String)] {
        lock.lock(); defer { lock.unlock() }
        let who: [WaitingOn] = includeExternal ? [.user, .external] : [.user]
        let stmt = try prepare(
            "SELECT \(Self.qualifiedTaskCols), p.code FROM tasks \(Self.activeProjectJoinSQL) "
            + "WHERE tasks.status=? AND tasks.waiting_on IN (\(Self.placeholders(who.count))) "
            + "ORDER BY COALESCE(tasks.waiting_since, tasks.updated_at), tasks.id;",
            [.text(TaskStatus.waiting.rawValue)] + who.map { .text($0.rawValue) })
        defer { sqlite3_finalize(stmt) }
        var out: [(task: TodoTask, projectCode: String)] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append((taskFromRow(stmt), colText(stmt, Self.taskColCount)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    /// Add focused seconds to a task's effort total.
    public func addEffort(toTaskId id: Int64, seconds: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try runWrite("UPDATE tasks SET effort_seconds = effort_seconds + ? WHERE id=?;", [.int(Int64(seconds)), .int(id)])
    }

    /// Resolve a task id from its code (case-insensitive). Locks internally.
    public func taskId(forCode code: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return queryInt("SELECT id FROM tasks WHERE code=? COLLATE NOCASE;", [.text(code)])
    }

    /// The one timestamp rule for a status write: SQL expressions for the new
    /// `started_at` / `completed_at` / `waiting_since`, evaluated against the prior row's
    /// `status` and those columns (an UPDATE's SET sees the pre-update row; createTask
    /// supplies a one-row prior table). `binds` follow the started, completed, waiting order.
    /// Every path that writes a status uses it — updateTask, and createTask for the initial
    /// status, so duplicates, templates and recurrence spawns too:
    /// - started_at: stamped once on entering a status that `impliesStarted`; never cleared.
    /// - completed_at: stamped on entering done (kept if already done); cleared otherwise —
    ///   dropped included, since abandoning a task is not a completion.
    /// - waiting_since: stamped on entering waiting (kept while it stays waiting, also when
    ///   who it waits on changes); cleared on any other status.
    private static func statusTimestampExprs(_ status: TaskStatus, now: Int64)
        -> (startedAt: String, completedAt: String, waitingSince: String, binds: [SQLValue]) {
        var binds: [SQLValue] = []
        var started = "started_at"
        if status.impliesStarted { started = "COALESCE(started_at, ?)"; binds.append(.int(now)) }
        var completed = "NULL"
        if status == .done {
            completed = "CASE WHEN status='\(TaskStatus.done.rawValue)' AND completed_at IS NOT NULL THEN completed_at ELSE ? END"
            binds.append(.int(now))
        }
        var waiting = "NULL"
        if status == .waiting {
            waiting = "CASE WHEN status='\(TaskStatus.waiting.rawValue)' AND waiting_since IS NOT NULL THEN waiting_since ELSE ? END"
            binds.append(.int(now))
        }
        return (started, completed, waiting, binds)
    }

    /// The waiting rule, shared by createTask and every update path: a `waiting` task
    /// must say who it waits on, and only a waiting task may carry waiting_on /
    /// waiting_reason. `status` and `waitingOn` are the values the row would end up with.
    /// Returns the violation, or nil when the combination is valid.
    private static func waitingViolation(status: TaskStatus, waitingOn: WaitingOn?,
                                         settingWaitingFields: Bool) -> String? {
        if status == .waiting {
            return waitingOn == nil ? "status waiting needs waiting_on (user or external)" : nil
        }
        return settingWaitingFields
            ? "waiting_on / waiting_reason only apply to a waiting task (set status: waiting)" : nil
    }

    /// Does a write set waiting fields? A who, or a non-empty reason — clearing a
    /// reason is harmless on any task.
    private static func setsWaitingFields(_ waitingOn: WaitingOn?, _ waitingReason: String??) -> Bool {
        waitingOn != nil || !((waitingReason ?? nil) ?? "").isEmpty
    }

    /// `waitingOn` nil leaves it alone (it cannot be cleared while waiting);
    /// `waitingReason` .some(nil) or .some("") clears the reason. Any status other than
    /// waiting clears both, and setting either on a task that will not be waiting is an error.
    /// `note` (optional, e.g. a summary when closing) is written in the same transaction and
    /// linked to the status change, if the update made one; an empty note text is an error.
    public func updateTask(id: Int64, title: String? = nil, detail: String? = nil, link: String?? = nil,
                           status: TaskStatus? = nil, priority: Priority? = nil,
                           dueDate: Date?? = nil, tags: [String]? = nil, recurrence: String?? = nil,
                           estimateSeconds: Int? = nil,
                           waitingOn: WaitingOn? = nil, waitingReason: String?? = nil,
                           parentId: Int64?? = nil,
                           branch: String?? = nil, author: NoteAuthor? = nil,
                           note: NoteDraft? = nil) throws {
        let noteText = try note.map { try Self.noteBody($0.text) }
        // link: .some(nil) or .some("") removes the primary link; see setLegacyLinkUnlocked.
        let link: String?? = try link.map { v in
            try v.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try Self.normalizedLinkURL($0) }
        }
        let branch: String?? = try branch.map { try Self.normalizedBranch($0) }
        lock.lock(); defer { lock.unlock() }
        let apply = { [self] (spawnRecurrence: Bool) in
            let eventId = try applyTaskUpdateUnlocked(
                id: id, title: title, detail: detail, link: link, status: status, priority: priority,
                dueDate: dueDate, tags: tags, recurrence: recurrence, estimateSeconds: estimateSeconds,
                waitingOn: waitingOn, waitingReason: waitingReason, parentId: parentId,
                branch: branch, author: author, spawnRecurrence: spawnRecurrence)
            if let note, let noteText {
                _ = try insertNoteUnlocked(taskId: id, text: noteText, kind: note.kind, author: note.author,
                                           sessionId: note.sessionId, statusEventId: eventId)
            }
        }
        // Writes that depend on the stored row run inside BEGIN IMMEDIATE, re-read there:
        // any status write (its history row names the status it replaced, a move to done
        // may spawn the next occurrence — two processes could each spawn one), and the
        // waiting rule depends on whether the task is already waiting. A note rides along
        // in the same transaction, so the update and its note land together or not at all.
        // A new parent is checked against the parent's row and the task's subtasks.
        // A legacy link reads the task's links and rewrites them and the mirror.
        let needsTransaction = status != nil || Self.setsWaitingFields(waitingOn, waitingReason) || note != nil
            || parentId != nil || link != nil
        guard needsTransaction else { return try apply(true) }
        do {
            try beginImmediate()
            try apply(true)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
        } catch {
            // Clear any transaction left open (a failed COMMIT, or a BEGIN that hit an
            // already-open connection) so the shared connection is never poisoned for
            // later writes. ROLLBACK is a harmless no-op when no transaction is active.
            exec("ROLLBACK;")
            // Degrade gracefully: still mark the task done even if the atomic spawn could
            // not run under write contention. A missed occurrence beats a failed mark-done
            // or a stuck connection; nothing is orphaned (rolled back above). Only for a
            // write failure — a rejected or missing task is reported as is. Not with a
            // note: outside a transaction the update and its note could land apart.
            guard status == .done, note == nil, let e = error as? StoreError, case .step = e else { throw error }
            try apply(false)
        }
    }

    /// Apply one update to many tasks in a single BEGIN IMMEDIATE, all or nothing:
    /// every task is checked (waiting rule, existence) and written inside the
    /// transaction, so one bad task leaves the whole batch unchanged. `addTags` merges
    /// into each task's tags (keeps existing). Same field semantics as `updateTask`.
    /// `waitingOnDefault`: a move to waiting without `waitingOn` keeps each task's own
    /// who, and a task waiting on no one takes this one (nil = such a task is an error).
    public func bulkUpdateTasks(ids: [Int64], status: TaskStatus? = nil, priority: Priority? = nil,
                                dueDate: Date?? = nil, addTags: [String]? = nil,
                                waitingOn: WaitingOn? = nil, waitingOnDefault: WaitingOn? = nil,
                                waitingReason: String?? = nil, parentId: Int64?? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let apply = { [self] (spawnRecurrence: Bool) in
            try beginImmediate()
            for id in ids {
                do {
                    try applyTaskUpdateUnlocked(id: id, status: status, priority: priority, dueDate: dueDate,
                                                addTags: addTags, waitingOn: waitingOn, waitingOnDefault: waitingOnDefault,
                                                waitingReason: waitingReason, parentId: parentId,
                                                spawnRecurrence: spawnRecurrence)
                } catch StoreError.invalid(let msg) {
                    // Name the task that failed the batch.
                    let code = queryString("SELECT code FROM tasks WHERE id=?;", [.int(id)]) ?? "task \(id)"
                    throw StoreError.invalid("\(code): \(msg)")
                }
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
        }
        do {
            try apply(true)
        } catch {
            exec("ROLLBACK;")
            // Degrade as updateTask does: on a write failure in a move to done, retry the
            // whole batch without spawning recurrences — still one transaction, so the
            // batch stays all or nothing. A rejected or missing task is reported as is.
            guard status == .done, let e = error as? StoreError, case .step = e else { throw error }
            do {
                try apply(false)
            } catch {
                exec("ROLLBACK;")
                throw error
            }
        }
    }

    /// The one task-update path, without taking the lock or opening a transaction: the
    /// callers above decide that. Reads the row, checks the waiting rule against it,
    /// writes, spawns the next occurrence on a recurring task's move into done (when
    /// `spawnRecurrence`), and logs history — all against the same read, so inside a
    /// caller's transaction the check, write and log see one consistent row. Returns the
    /// id of the status change's history row, when the status changed.
    @discardableResult
    private func applyTaskUpdateUnlocked(id: Int64, title: String? = nil, detail: String? = nil, link: String?? = nil,
                                         status: TaskStatus? = nil, priority: Priority? = nil,
                                         dueDate: Date?? = nil, tags: [String]? = nil, addTags: [String]? = nil,
                                         recurrence: String?? = nil, estimateSeconds: Int? = nil,
                                         waitingOn: WaitingOn? = nil, waitingOnDefault: WaitingOn? = nil,
                                         waitingReason: String?? = nil, parentId: Int64?? = nil,
                                         branch: String?? = nil, author: NoteAuthor? = nil,
                                         spawnRecurrence: Bool) throws -> Int64? {
        guard let old = getTaskUnlocked(id) else { throw StoreError.notFound("task \(id)") }
        // parentId .some(id): make it a subtask of that task; .some(nil): a top-level task.
        var newParent: Int64?? = nil
        if let parentId, parentId != old.parentId {
            if let pid = parentId { try checkNewParentUnlocked(old, pid, recurrence: recurrence) }
            newParent = .some(parentId)
        }
        // A move to waiting with no who keeps the task's own, else takes the default.
        let waitingOn = waitingOn ?? (status == .waiting && old.waitingOn == nil ? waitingOnDefault : nil)
        if let msg = Self.waitingViolation(status: status ?? old.status, waitingOn: waitingOn ?? old.waitingOn,
                                           settingWaitingFields: Self.setsWaitingFields(waitingOn, waitingReason)) {
            throw StoreError.invalid(msg)
        }
        var tags = tags
        if let addTags {
            // Only a merge that adds something writes (and bumps updated_at).
            let current = tags ?? old.tags
            let merged = Self.mergeTags(current, addTags)
            if merged != current { tags = merged }
        }
        let now = Int64(Date().timeIntervalSince1970)
        var sets: [String] = []
        var binds: [SQLValue] = []
        if let title { sets.append("title=?"); binds.append(.text(title)) }
        if let detail { sets.append("detail=?"); binds.append(.text(detail)) }
        // The legacy link is not a column write: it edits the links (and logs, and bumps
        // updated_at, when one changed). Checks are done above, so this runs after them.
        if let link { try setLegacyLinkUnlocked(taskId: id, raw: link, author: author, log: true, bump: true) }
        if let branch { sets.append("branch=?"); binds.append(branch.map(SQLValue.text) ?? .null) }
        if let status {
            sets.append("status=?"); binds.append(.text(status.rawValue))
            let ts = Self.statusTimestampExprs(status, now: now)
            sets += ["started_at=\(ts.startedAt)", "completed_at=\(ts.completedAt)", "waiting_since=\(ts.waitingSince)"]
            binds += ts.binds
            // Leaving waiting (or any non-waiting status write) clears what it waited on.
            if status != .waiting { sets += ["waiting_on=NULL", "waiting_reason=NULL"] }
        }
        if let waitingOn { sets.append("waiting_on=?"); binds.append(.text(waitingOn.rawValue)) }
        if let waitingReason {
            sets.append("waiting_reason=?")
            binds.append(waitingReason.flatMap { $0.isEmpty ? nil : .text($0) } ?? .null)
        }
        if let priority { sets.append("priority=?"); binds.append(.text(priority.rawValue)) }
        if let dueDate { sets.append("due_date=?"); binds.append(dueDate.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null) }
        if let tags { sets.append("tags=?"); binds.append(.text(encodeTags(tags))) }
        if let recurrence {
            // Ignore a non-nil recurrence on a subtask (subtasks must not recur —
            // it would spawn a detached top-level dupe). Clearing (nil) is allowed.
            // The parent is the one this update leaves the task with.
            let parentAfter = newParent ?? old.parentId
            if !(parentAfter != nil && recurrence != nil) {
                sets.append("recurrence=?"); binds.append(recurrence.map(SQLValue.text) ?? .null)
            }
        }
        if let estimateSeconds { sets.append("estimate_seconds=?"); binds.append(.int(Int64(max(0, estimateSeconds)))) }
        if let newParent {
            sets.append("parent_id=?"); binds.append(newParent.map(SQLValue.int) ?? .null)
            // Last among its new siblings (sort_order runs across the whole project).
            sets.append("sort_order=(SELECT COALESCE(MAX(sort_order)+1,0) FROM tasks WHERE project_id=?)")
            binds.append(.int(old.projectId))
        }
        guard !sets.isEmpty else { return nil }
        sets.append("updated_at=?"); binds.append(.int(now))
        binds.append(.int(id))
        try runWrite("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id=?;", binds)

        // Recurrence: when a recurring, top-level task transitions INTO done, spawn the
        // next occurrence (fresh todo) with its due date advanced by the interval.
        // Effective recurrence: a value set in this same update wins, else the stored one.
        // `old` was read before the write, so only a genuine todo/in_progress/waiting/dropped
        // -> done transition spawns (the caller's BEGIN IMMEDIATE keeps that read current).
        // Dropping a recurring task ends the series: no next occurrence.
        let effectiveRecurrence: String?
        if let recurrence { effectiveRecurrence = recurrence } else { effectiveRecurrence = old.recurrence }
        if spawnRecurrence, status == .done, old.status != .done, old.parentId == nil,
           let rule = effectiveRecurrence, !rule.isEmpty,
           let nextDue = Self.advanceDueDate(from: old.dueDate ?? Date(), rule: rule) {
            let spawned = try createTaskUnlocked(
                projectId: old.projectId, title: old.title, detail: old.detail, link: nil,
                status: .todo, priority: old.priority, dueDate: nextDue, tags: old.tags, recurrence: rule,
                estimateSeconds: old.estimateSeconds
            )
            logEvent(spawned.id, "recurrence", "", rule)
            try copyLinksUnlocked(from: old.id, to: spawned.id)
            // Carry the completed task's checklist: clone each direct subtask as a
            // fresh todo under the new occurrence (title/detail/priority/tags/estimate).
            // spawned is known top-level, so skip the redundant per-subtask nesting check.
            for sub in subtasksUnlocked(old.id) {
                _ = try createTaskUnlocked(
                    projectId: spawned.projectId, title: sub.title, detail: sub.detail, link: nil,
                    status: .todo, priority: sub.priority, dueDate: nil, tags: sub.tags,
                    recurrence: nil, parentId: spawned.id, estimateSeconds: sub.estimateSeconds,
                    enforceNesting: false
                )
            }
        }

        // History: log discrete-field changes (skip free-text title/detail — autosave makes them noisy).
        var statusEventId: Int64?
        if let status, status != old.status { statusEventId = logEvent(id, "status", old.status.display, status.display) }
        // waiting_on is logged by raw value (user / external); waiting_reason is free text
        // (like title/detail) and is not logged.
        // Leaving waiting clears it, but the status row already says so: log only a new who.
        let newWaitingOn = (status.map { $0 != .waiting } ?? false) ? nil : (waitingOn ?? old.waitingOn)
        if let newWaitingOn, newWaitingOn != old.waitingOn {
            logEvent(id, "waiting on", old.waitingOn?.rawValue ?? "", newWaitingOn.rawValue)
        }
        if let priority, priority != old.priority { logEvent(id, "priority", old.priority.display, priority.display) }
        if let branch, branch != old.branch { logTypedEvent(id, "branch", old.branch ?? "", branch ?? "") }
        if let dueDate {
            let nv = dueDate.map(Self.shortDate) ?? ""
            let ov = old.dueDate.map(Self.shortDate) ?? ""
            if nv != ov { logEvent(id, "due date", ov, nv) }
        }
        if let tags, tags != old.tags {
            logEvent(id, "tags", old.tags.joined(separator: ", "), tags.joined(separator: ", "))
        }
        if let estimateSeconds, max(0, estimateSeconds) != old.estimateSeconds {
            let fmt: (Int) -> String = { $0 == 0 ? "none" : "\($0 / 60)m" }
            logEvent(id, "estimate", fmt(old.estimateSeconds), fmt(max(0, estimateSeconds)))
        }
        if let newParent {
            let code: (Int64?) -> String = { [self] in
                $0.flatMap { queryString("SELECT code FROM tasks WHERE id=?;", [.int($0)]) } ?? ""
            }
            logEvent(id, "parent", code(old.parentId), code(newParent))
        }
        return statusEventId
    }

    /// The one-level-nesting rule every way of giving a task a parent shares (create, the
    /// recurrence spawn, update): the parent exists and is itself top-level. moveTask's
    /// cascade and the recurrence subtask-clone only walk direct children, so a grandchild
    /// would silently orphan on those paths.
    private func requireTopLevelParentUnlocked(_ parentId: Int64) throws {
        guard let row = queryString("SELECT code || '|' || COALESCE(parent_id, '') FROM tasks WHERE id=?;", [.int(parentId)]) else {
            throw StoreError.notFound("task \(parentId)")
        }
        let parts = row.split(separator: "|", omittingEmptySubsequences: false)
        if parts.count > 1, !parts[1].isEmpty {
            throw StoreError.invalid("\(parts[0]) is a subtask; the parent must be a top-level task (one level of nesting)")
        }
    }

    /// Can `task` become a subtask of `parentId`? One level of nesting: the parent is a
    /// top-level task and the task has no subtasks of its own. Same project (move_task
    /// first), never itself, and the task must not recur: a recurring subtask would spawn
    /// a detached top-level copy. `recurrence` is the same update's recurrence write.
    private func checkNewParentUnlocked(_ task: TodoTask, _ parentId: Int64, recurrence: String??) throws {
        guard parentId != task.id else { throw StoreError.invalid("a task cannot be its own parent") }
        try requireTopLevelParentUnlocked(parentId)
        guard let parent = getTaskUnlocked(parentId) else { throw StoreError.notFound("task \(parentId)") }
        guard parent.projectId == task.projectId else {
            throw StoreError.invalid("\(parent.code) is in another project; move the task there first (move_task)")
        }
        guard subtasksUnlocked(task.id).isEmpty else {
            throw StoreError.invalid("\(task.code) has subtasks of its own, so it cannot become a subtask")
        }
        if let rule = recurrence ?? task.recurrence, !rule.isEmpty {
            throw StoreError.invalid("\(task.code) recurs and a subtask cannot; clear its recurrence first (recurrence null)")
        }
    }

    static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    public func deleteTask(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try runWrite("DELETE FROM tasks WHERE id=?;", [.int(id)])
    }

    /// Delete many tasks in a single BEGIN IMMEDIATE, all or nothing: every id is
    /// checked before any delete, so one missing task leaves every task in place.
    /// A selected subtask already removed by its parent's cascade is not an error.
    /// Returns how many tasks are gone, subtasks removed by the cascade included.
    @discardableResult
    public func bulkDeleteTasks(ids: [Int64]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            for id in ids where getTaskUnlocked(id) == nil { throw StoreError.notFound("task \(id)") }
            let before = queryInt("SELECT COUNT(*) FROM tasks;", []) ?? 0
            for id in ids { try runWrite("DELETE FROM tasks WHERE id=?;", [.int(id)]) }
            let after = queryInt("SELECT COUNT(*) FROM tasks;", []) ?? 0
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return Int(before - after)
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Duplicate a task. With no target it clones into the same project; with a
    /// target project id it copies there (original kept). The copy gets a fresh code.
    /// A duplicate within the same project is for reuse: a fresh todo with no
    /// start/completion times or waiting fields, so it never counts as another completion.
    /// A copy to another project carries the record over as is: status, waiting fields
    /// and started/completed times; a waiting copy is a new ask, so its waiting_since is
    /// now. App and MCP share this one rule. Copying into an archived project is refused;
    /// a duplicate within its own (even archived) project is not.
    @discardableResult
    public func duplicateTask(id: Int64, toProjectId: Int64? = nil) throws -> TodoTask {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            let copy = try duplicateTaskUnlocked(id: id, toProjectId: toProjectId)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return copy
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Duplicate many tasks, each within its own project, in a single BEGIN IMMEDIATE,
    /// all or nothing: a missing task leaves no copy behind. Same rule as `duplicateTask`
    /// with no target; the copies are returned in `ids` order.
    @discardableResult
    public func bulkDuplicateTasks(ids: [Int64]) throws -> [TodoTask] {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            let copies = try ids.map { try duplicateTaskUnlocked(id: $0, toProjectId: nil) }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return copies
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// `duplicateTask` without taking the lock or opening a transaction: the source is
    /// read, the target checked and the copy inserted against the caller's BEGIN IMMEDIATE.
    private func duplicateTaskUnlocked(id: Int64, toProjectId: Int64?) throws -> TodoTask {
        guard let t = getTaskUnlocked(id) else { throw StoreError.notFound("task \(id)") }
        let targetProject = toProjectId ?? t.projectId
        let keepStatus = targetProject != t.projectId
        if keepStatus { try requireActiveProjectUnlocked(targetProject) }
        // Within the same project a copy stays a subtask of the same parent; copying
        // to a different project would leave the child dangling (parent isn't moving),
        // so it becomes a top-level task instead.
        let newParentId: Int64? = (targetProject == t.projectId) ? t.parentId : nil
        // Clone all planning fields; effort resets to zero. With keepStatus, started/completed
        // follow the status rule seeded from the source (timestampsFrom), so the copy keeps
        // the original's times rather than being stamped today.
        // Links come along (all of them, in order); the working branch does not: it is the
        // state of the original's work, like its effort.
        let copy = try createTaskUnlocked(
            projectId: targetProject,
            title: t.title,
            detail: t.detail,
            link: nil,
            status: keepStatus ? t.status : .todo,
            waitingOn: keepStatus ? t.waitingOn : nil,
            waitingReason: keepStatus ? t.waitingReason : nil,
            priority: t.priority,
            dueDate: t.dueDate,
            tags: t.tags,
            recurrence: t.recurrence,
            parentId: newParentId,
            estimateSeconds: t.estimateSeconds,
            timestampsFrom: keepStatus ? t : nil
        )
        try copyLinksUnlocked(from: t.id, to: copy.id)
        return getTaskUnlocked(copy.id) ?? copy
    }

    /// Move a task to another project, placing it at the end of that project's list.
    /// The code is left unchanged so existing references stay valid. The target must not
    /// be archived (unless the task is already in it); checked inside BEGIN IMMEDIATE.
    public func moveTask(id: Int64, toProjectId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            try moveTaskUnlocked(id: id, toProjectId: toProjectId)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Move or copy many tasks to one project in a single BEGIN IMMEDIATE, all or
    /// nothing: each task goes through `moveTaskUnlocked` or `duplicateTaskUnlocked`, so
    /// a missing task or an archived target leaves every task as it was. `copy` follows
    /// `duplicateTask`'s rule; the copies are returned in `ids` order (none for a move).
    @discardableResult
    public func bulkMoveTasks(ids: [Int64], toProjectId: Int64, copy: Bool) throws -> [TodoTask] {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            var copies: [TodoTask] = []
            for id in ids {
                if copy { copies.append(try duplicateTaskUnlocked(id: id, toProjectId: toProjectId)) }
                else { try moveTaskUnlocked(id: id, toProjectId: toProjectId) }
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return copies
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    private func moveTaskUnlocked(id: Int64, toProjectId: Int64) throws {
        guard let old = getTaskUnlocked(id) else { throw StoreError.notFound("task \(id)") }
        if old.projectId != toProjectId { try requireActiveProjectUnlocked(toProjectId) }
        let oldCode = queryString("SELECT code FROM projects WHERE id=?;", [.int(old.projectId)]) ?? ""
        let newCode = queryString("SELECT code FROM projects WHERE id=?;", [.int(toProjectId)]) ?? ""
        let now = Int64(Date().timeIntervalSince1970)
        try runWrite(
            """
            UPDATE tasks
            SET project_id=?,
                sort_order=(SELECT COALESCE(MAX(sort_order)+1,0) FROM tasks WHERE project_id=?),
                updated_at=?
            WHERE id=?;
            """,
            [.int(toProjectId), .int(toProjectId), .int(now), .int(id)]
        )
        // Cascade the new project to direct subtasks so children follow the parent —
        // otherwise they keep the old project_id and vanish from both projects.
        try runWrite(
            "UPDATE tasks SET project_id=?, updated_at=? WHERE parent_id=?;",
            [.int(toProjectId), .int(now), .int(id)]
        )
        if oldCode != newCode { logEvent(id, "project", oldCode, newCode) }
    }

    /// Persist a new order for sibling tasks: the top-level tasks of one project, or the
    /// subtasks of one parent. `ids` (at least one, no repeats) must all exist and share one
    /// project and one parent; otherwise it throws and nothing changes. The given tasks go
    /// to the top (or the bottom) of their siblings, in the given order; siblings not given
    /// keep their relative order below (or above) them.
    ///
    /// sort_order runs across the whole project (subtasks included). Inside one BEGIN
    /// IMMEDIATE this re-reads the project's tasks by (sort_order, id), lets the siblings
    /// trade the places they already held, and writes a dense 0, 1, … over the project in
    /// one UPDATE, only for rows whose value changed. Other tasks keep their places, so a
    /// parent still carries its subtasks, and earlier ties (the old app drag wrote 0… over
    /// the open tasks only) are resolved. Status, priority, parent, project and updated_at
    /// never change: order is not a task edit. Returns the siblings in their new order —
    /// the board order (`TaskSort.board`) the app's list and board show.
    @discardableResult
    public func reorderTasks(ids: [Int64], place: TaskPlacement = .top) throws -> [TodoTask] {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            let siblings = try reorderTasksUnlocked(ids: ids, place: place)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return siblings
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    private func reorderTasksUnlocked(ids: [Int64], place: TaskPlacement) throws -> [TodoTask] {
        guard !ids.isEmpty else { throw StoreError.invalid("give at least one task to reorder") }
        var given: [TodoTask] = []
        var seen = Set<Int64>()
        for id in ids {
            guard let task = getTaskUnlocked(id) else { throw StoreError.notFound("task \(id)") }
            guard seen.insert(id).inserted else { throw StoreError.invalid("\(task.code) is listed twice") }
            given.append(task)
        }
        let first = given[0]
        if let other = given.first(where: { $0.projectId != first.projectId }) {
            throw StoreError.invalid("\(other.code) is not in the same project as \(first.code); reorder one project at a time")
        }
        if let other = given.first(where: { $0.parentId != first.parentId }) {
            throw StoreError.invalid("\(other.code) and \(first.code) are not siblings; reorder either top-level tasks "
                                     + "or the subtasks of one parent, not both")
        }
        let all = try readTasks("SELECT \(Self.taskCols) FROM tasks WHERE project_id=? ORDER BY sort_order, id;",
                                [.int(first.projectId)])
        let slots = all.indices.filter { all[$0].parentId == first.parentId }
        let rest = slots.map { all[$0] }.filter { !seen.contains($0.id) }
        let siblings = place == .top ? given + rest : rest + given
        var order = all
        for (slot, task) in zip(slots, siblings) { order[slot] = task }
        // Only rows whose position changed: an unchanged order writes nothing (no poll reload).
        let moved = order.enumerated().filter { $0.element.sortOrder != $0.offset }
            .map { (id: $0.element.id, order: $0.offset) }
        if !moved.isEmpty {
            let cases = Array(repeating: "WHEN ? THEN ?", count: moved.count).joined(separator: " ")
            let binds = moved.flatMap { [SQLValue.int($0.id), .int(Int64($0.order))] } + moved.map { SQLValue.int($0.id) }
            try runWrite("UPDATE tasks SET sort_order = CASE id \(cases) END WHERE id IN (\(Self.placeholders(moved.count)));",
                         binds)
        }
        return slots.indices.map { i in
            var task = siblings[i]
            task.sortOrder = slots[i]
            return task
        }
    }

    /// The one tag-merge rule: `existing` plus each trimmed, non-empty tag of `add`
    /// not already present, in order.
    private static func mergeTags(_ existing: [String], _ add: [String]) -> [String] {
        var merged = existing
        for tag in add.map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty && !merged.contains(tag) {
            merged.append(tag)
        }
        return merged
    }

    // MARK: - Links (1.5.0)
    //
    // A task has any number of typed links (`task_links`, oldest first) and one working
    // branch (`tasks.branch`). Its primary link — the first one that is not a branch name —
    // is mirrored into the legacy `tasks.link` column, which every link write keeps in
    // step: older binaries (and the legacy `link` field of create_task / update_task)
    // still read and write it as a URL. A legacy write means "the task's link is now X":
    // it replaces the primary link, or adds one (`setLegacyLinkUnlocked`);
    // `syncLegacyLinks` carries such writes in on every open.

    public static let maxLinkLength = 2048
    public static let maxBranchLength = 255
    private static let maxLinkLabelLength = 500

    /// A link's URL (or path, or branch name) as stored: trimmed, one line, at most
    /// `maxLinkLength` characters; a web URL loses its trailing slashes, so ".../pull/7/"
    /// and ".../pull/7" are the same link. Empty is an error.
    public static func normalizedLinkURL(_ raw: String) throws -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw StoreError.invalid("link url is empty") }
        guard !s.contains(where: \.isNewline) else { throw StoreError.invalid("link url must be a single line") }
        guard s.count <= maxLinkLength else { throw StoreError.invalid("link url is longer than \(maxLinkLength) characters") }
        if s.contains("://") { while s.hasSuffix("/") && !s.hasSuffix("://") { s.removeLast() } }
        return s
    }

    /// `normalizedLinkURL` for a value already in the legacy column, which an older build
    /// never checked: a value it rejects is kept trimmed rather than dropped. nil = empty.
    private static func lenientLinkURL(_ raw: String) -> String? {
        if let s = try? normalizedLinkURL(raw) { return s }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// A branch name as stored: trimmed, nil when empty (no branch). No whitespace or
    /// control characters (git allows neither), at most `maxBranchLength` characters.
    public static func normalizedBranch(_ raw: String?) throws -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard !s.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                                                  || CharacterSet.controlCharacters.contains($0) }) else {
            throw StoreError.invalid("branch must be a branch name, with no spaces")
        }
        guard s.count <= maxBranchLength else { throw StoreError.invalid("branch is longer than \(maxBranchLength) characters") }
        return s
    }

    /// An optional one-line label (a link's title or source): trimmed, nil when empty.
    private static func linkLabel(_ raw: String?, _ name: String) throws -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard !s.contains(where: \.isNewline) else { throw StoreError.invalid("\(name) must be a single line") }
        guard s.count <= maxLinkLabelLength else { throw StoreError.invalid("\(name) is longer than \(maxLinkLabelLength) characters") }
        return s
    }

    private static let linkCols = "id, task_id, kind, url, title, author, source, created_at"

    /// A task's links, oldest first.
    public func links(taskId: Int64) throws -> [TaskLink] {
        lock.lock(); defer { lock.unlock() }
        return try linksUnlocked(taskId)
    }

    /// The links of many tasks at once (chunked IN lists), by task id; a task with none
    /// has no entry. Throws on a read error rather than returning part of them.
    public func links(taskIds: [Int64]) throws -> [Int64: [TaskLink]] {
        lock.lock(); defer { lock.unlock() }
        var out: [Int64: [TaskLink]] = [:]
        for chunk in Self.chunked(Array(Set(taskIds))) {
            for link in try readLinks("SELECT \(Self.linkCols) FROM task_links WHERE task_id IN "
                                      + "(\(Self.placeholders(chunk.count))) ORDER BY task_id, id;", chunk.map { .int($0) }) {
                out[link.taskId, default: []].append(link)
            }
        }
        return out
    }

    /// Add a link to a task, in one BEGIN IMMEDIATE. The URL is stored once per task
    /// (`normalizedLinkURL`): adding one the task already has adds nothing and returns it
    /// with `created` false, after setting the `kind` and `title` given (nil keeps them).
    /// A new link without a kind gets `LinkKind.infer`. `source` is provenance kept with
    /// a new link (an importer's source key); an existing link keeps its own. Logged to
    /// the task's history and bumps its `updated_at` (an unchanged existing link does neither).
    @discardableResult
    public func addLink(taskId: Int64, url: String, kind: LinkKind? = nil, title: String? = nil,
                        author: NoteAuthor?, source: String? = nil) throws -> (link: TaskLink, created: Bool) {
        let url = try Self.normalizedLinkURL(url)
        let title = try Self.linkLabel(title, "title")
        let source = try Self.linkLabel(source, "source")
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            guard getTaskUnlocked(taskId) != nil else { throw StoreError.notFound("task \(taskId)") }
            let now = Int64(Date().timeIntervalSince1970)
            var result: (link: TaskLink, created: Bool)
            if var existing = try linksUnlocked(taskId).first(where: { $0.url == url }) {
                var sets: [String] = [], binds: [SQLValue] = []
                if let kind, kind != existing.kind { sets.append("kind=?"); binds.append(.text(kind.rawValue)); existing.kind = kind }
                if let title, title != existing.title { sets.append("title=?"); binds.append(.text(title)); existing.title = title }
                if !sets.isEmpty {
                    try runWrite("UPDATE task_links SET \(sets.joined(separator: ", ")) WHERE id=?;", binds + [.int(existing.id)])
                    try runWrite("UPDATE tasks SET updated_at=? WHERE id=?;", [.int(now), .int(taskId)])
                }
                result = (existing, false)
            } else {
                let link = try insertLinkUnlocked(taskId: taskId, url: url, kind: kind ?? LinkKind.infer(from: url),
                                                  title: title, author: author, source: source)
                logEvent(taskId, "link", "", url)
                try refreshLinkMirrorUnlocked(taskId, bump: true)
                result = (link, true)
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return result
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Remove a task's link by its URL (matched as `normalizedLinkURL` stores it). Logged
    /// to the history; bumps `updated_at`. Returns the removed link; none such is notFound.
    @discardableResult
    public func removeLink(taskId: Int64, url: String) throws -> TaskLink {
        let url = try Self.normalizedLinkURL(url)
        return try removeLink { [self] in
            guard getTaskUnlocked(taskId) != nil else { throw StoreError.notFound("task \(taskId)") }
            return try linksUnlocked(taskId).first { $0.url == url }
        }
    }

    /// Remove a link by its id; see `removeLink(taskId:url:)`. With `taskId`, a link on
    /// another task is an error and nothing is removed.
    @discardableResult
    public func removeLink(id: Int64, taskId: Int64? = nil) throws -> TaskLink {
        try removeLink { [self] in
            guard let link = try readLinks("SELECT \(Self.linkCols) FROM task_links WHERE id=?;", [.int(id)]).first else {
                return nil
            }
            if let taskId, link.taskId != taskId { throw StoreError.invalid("link \(id) is not on that task") }
            return link
        }
    }

    /// The removal both `removeLink`s share: `find` reads the link inside the BEGIN
    /// IMMEDIATE, so a link another process removed meanwhile is notFound, not removed twice.
    private func removeLink(find: () throws -> TaskLink?) throws -> TaskLink {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            guard let link = try find() else { throw StoreError.notFound("link") }
            try runWrite("DELETE FROM task_links WHERE id=?;", [.int(link.id)])
            logEvent(link.taskId, "link", link.url, "")
            try refreshLinkMirrorUnlocked(link.taskId, bump: true)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return link
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    private func linksUnlocked(_ taskId: Int64) throws -> [TaskLink] {
        try readLinks("SELECT \(Self.linkCols) FROM task_links WHERE task_id=? ORDER BY id;", [.int(taskId)])
    }

    private func readLinks(_ sql: String, _ binds: [SQLValue]) throws -> [TaskLink] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [TaskLink] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(TaskLink(
                id: sqlite3_column_int64(stmt, 0), taskId: sqlite3_column_int64(stmt, 1),
                kind: LinkKind(rawValue: colText(stmt, 2)) ?? .other, url: colText(stmt, 3),
                title: colTextOpt(stmt, 4), author: colTextOpt(stmt, 5).flatMap(NoteAuthor.init(rawValue:)),
                source: colTextOpt(stmt, 6), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    /// INSERT one link (the caller has checked the URL is not already on the task).
    private func insertLinkUnlocked(taskId: Int64, url: String, kind: LinkKind, title: String?,
                                    author: NoteAuthor?, source: String?) throws -> TaskLink {
        let now = Date()
        try runWrite("INSERT INTO task_links (task_id, kind, url, title, author, source, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
                     [.int(taskId), .text(kind.rawValue), .text(url), title.map(SQLValue.text) ?? .null,
                      author.map { .text($0.rawValue) } ?? .null, source.map(SQLValue.text) ?? .null,
                      .double(now.timeIntervalSince1970)])
        return TaskLink(id: lastInsertId(), taskId: taskId, kind: kind, url: url, title: title,
                        author: author, source: source, createdAt: now)
    }

    /// Set the legacy `tasks.link` to the task's primary link (NULL when it has none);
    /// `bump` also moves its `updated_at`.
    private func refreshLinkMirrorUnlocked(_ taskId: Int64, bump: Bool) throws {
        let first = "(SELECT url FROM task_links WHERE task_id=? AND kind <> '\(LinkKind.branch.rawValue)' ORDER BY id LIMIT 1)"
        if bump {
            try runWrite("UPDATE tasks SET link=\(first), updated_at=? WHERE id=?;",
                         [.int(taskId), .int(Int64(Date().timeIntervalSince1970)), .int(taskId)])
        } else {
            try runWrite("UPDATE tasks SET link=\(first) WHERE id=?;", [.int(taskId), .int(taskId)])
        }
    }

    /// A legacy single-link write ("the task's link is now `raw`"), inside the caller's
    /// lock and transaction. nil or empty removes the primary link (the first that is not
    /// a branch). Otherwise the primary link becomes `raw` in place (kind guessed again,
    /// title and source cleared; the same URL elsewhere in the list is folded into it), or
    /// `raw` is added when the task has none. So for a task with at most one link it is
    /// exactly the old single field.
    /// Returns whether a link changed; the mirror is refreshed either way.
    @discardableResult
    private func setLegacyLinkUnlocked(taskId: Int64, raw: String?, author: NoteAuthor?, log: Bool, bump: Bool) throws -> Bool {
        let primary = try linksUnlocked(taskId).first { $0.kind != .branch }
        let url = raw.flatMap(Self.lenientLinkURL)
        var changed = false
        if let url {
            if let first = primary {
                if first.url != url {
                    try runWrite("DELETE FROM task_links WHERE task_id=? AND url=?;", [.int(taskId), .text(url)])
                    try runWrite("UPDATE task_links SET url=?, kind=?, title=NULL, author=?, source=NULL, created_at=? WHERE id=?;",
                                 [.text(url), .text(LinkKind.infer(from: url).rawValue), author.map { .text($0.rawValue) } ?? .null,
                                  .double(Date().timeIntervalSince1970), .int(first.id)])
                    if log { logEvent(taskId, "link", first.url, url) }
                    changed = true
                }
            } else {
                _ = try insertLinkUnlocked(taskId: taskId, url: url, kind: LinkKind.infer(from: url),
                                           title: nil, author: author, source: nil)
                if log { logEvent(taskId, "link", "", url) }
                changed = true
            }
        } else if let first = primary {
            try runWrite("DELETE FROM task_links WHERE id=?;", [.int(first.id)])
            if log { logEvent(taskId, "link", first.url, "") }
            changed = true
        }
        try refreshLinkMirrorUnlocked(taskId, bump: bump && changed)
        return changed
    }

    /// Copy a task's links onto another (a duplicate, or a recurring task's next
    /// occurrence), in order, keeping kind, title, author and source.
    private func copyLinksUnlocked(from: Int64, to: Int64) throws {
        try runWrite("INSERT OR IGNORE INTO task_links (task_id, kind, url, title, author, source, created_at) "
                     + "SELECT ?, kind, url, title, author, source, ? FROM task_links WHERE task_id=? ORDER BY id;",
                     [.int(to), .double(Date().timeIntervalSince1970), .int(from)])
        try refreshLinkMirrorUnlocked(to, bump: false)
    }

    /// Carry legacy single links into `task_links`, on every open: the 1.5.0 migration of
    /// every existing `tasks.link`, then values an older binary still writes to the same
    /// file (it sets only the legacy column). Each such value goes through
    /// `setLegacyLinkUnlocked`, as the old field's write meant: it replaces the task's
    /// primary link, or becomes it. Not logged (the writer logged it, or it predates the
    /// table); author unknown (NULL). Only reads unless a task needs it (one NOT EXISTS
    /// scan); the writes run in one BEGIN IMMEDIATE that re-reads the list inside it, so
    /// the app and MCP server opening together carry each value once. On failure it rolls
    /// back and logs, and the next open retries. An older binary clearing the legacy
    /// column is not carried in: the next link write refills it from the primary link.
    private func syncLegacyLinks() {
        let pendingSQL = "SELECT id, link FROM tasks WHERE link IS NOT NULL AND trim(link) <> '' AND NOT EXISTS "
            + "(SELECT 1 FROM task_links l WHERE l.task_id = tasks.id AND l.url = tasks.link);"
        func pending() throws -> [(id: Int64, link: String)] {
            let stmt = try prepare(pendingSQL, [])
            defer { sqlite3_finalize(stmt) }
            var out: [(id: Int64, link: String)] = []
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                out.append((sqlite3_column_int64(stmt, 0), colText(stmt, 1)))
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
            return out
        }
        do {
            guard try !pending().isEmpty else { return }
            try beginImmediate()
            for row in try pending() {
                try setLegacyLinkUnlocked(taskId: row.id, raw: row.link, author: nil, log: false, bump: false)
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
        } catch {
            exec("ROLLBACK;")
            NSLog("QuestBits: legacy link sync failed: \(error)")
        }
    }

    // MARK: - Notes

    private static let noteCols = "id, task_id, ts, kind, text, author, session_id, history_id, question_id, edited_at"
    private static let qualifiedNoteCols = noteCols.components(separatedBy: ", ").map { "n.\($0)" }.joined(separator: ", ")
    private static let noteColCount = Int32(noteCols.components(separatedBy: ", ").count)

    /// Note text as stored: trimmed, and never empty.
    private static func noteBody(_ text: String) throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw StoreError.invalid("note text is empty") }
        return body
    }

    /// Append a note to a task: a single INSERT, never a read-modify-write of the task,
    /// so concurrent writers cannot lose each other's notes. The same transaction bumps
    /// the task's `updated_at` (a note is activity on the task), which doubles as the
    /// existence check. Not logged to task_history. Text is trimmed and must not be empty.
    /// Returns the note and the task's code.
    @discardableResult
    public func addNote(taskId: Int64, text: String, kind: NoteKind = .note, author: NoteAuthor,
                        sessionId: String? = nil) throws -> (note: TaskNote, taskCode: String) {
        let body = try Self.noteBody(text)
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            let note = try insertNoteUnlocked(taskId: taskId, text: body, kind: kind, author: author, sessionId: sessionId)
            let code = queryString("SELECT code FROM tasks WHERE id=?;", [.int(taskId)]) ?? ""
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return (note, code)
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// The note INSERT behind every writer (addNote, updateTask's note, questions), inside
    /// the caller's lock and transaction: bumps the task's `updated_at` (its existence
    /// check), then inserts. `text` is already `noteBody`-checked.
    private func insertNoteUnlocked(taskId: Int64, text: String, kind: NoteKind, author: NoteAuthor,
                                    sessionId: String?, statusEventId: Int64? = nil,
                                    questionId: Int64? = nil) throws -> TaskNote {
        // Full precision (REAL), so notes from one second still order by time; updated_at
        // keeps whole seconds like every other write of it.
        let now = Date()
        try runWrite("UPDATE tasks SET updated_at=? WHERE id=?;",
                     [.int(Int64(now.timeIntervalSince1970)), .int(taskId)])
        guard sqlite3_changes(db) == 1 else { throw StoreError.notFound("task \(taskId)") }
        let session = sessionId.flatMap { $0.isEmpty ? nil : $0 }
        try runWrite(
            "INSERT INTO task_notes (task_id, ts, kind, text, author, session_id, history_id, question_id) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
            [.int(taskId), .double(now.timeIntervalSince1970), .text(kind.rawValue), .text(text),
             .text(author.rawValue), session.map(SQLValue.text) ?? .null,
             statusEventId.map(SQLValue.int) ?? .null, questionId.map(SQLValue.int) ?? .null])
        return TaskNote(id: lastInsertId(), taskId: taskId, timestamp: now, kind: kind, text: text,
                        author: author, sessionId: session, statusEventId: statusEventId, questionId: questionId)
    }

    /// A task's notes, newest first; `limit` nil = all of them.
    public func notes(taskId: Int64, limit: Int? = nil) throws -> [TaskNote] {
        lock.lock(); defer { lock.unlock() }
        return try readNotes(
            "SELECT \(Self.noteCols) FROM task_notes WHERE task_id=? ORDER BY ts DESC, id DESC LIMIT ?;",
            [.int(taskId), .int(Int64(limit.map { max(0, $0) } ?? -1))])   // LIMIT -1 = no limit
    }

    public func note(id: Int64) throws -> TaskNote {
        lock.lock(); defer { lock.unlock() }
        guard let n = try readNotes("SELECT \(Self.noteCols) FROM task_notes WHERE id=?;", [.int(id)]).first else {
            throw StoreError.notFound("note \(id)")
        }
        return n
    }

    /// Replace the text of a note the user wrote (the app's edit). Agent notes, notes
    /// from before 1.4.0 (no author), and the record of an answer the agent acted on
    /// (a note tied to a question) cannot be edited. The replaced text is kept in
    /// task_note_edits; read inside one BEGIN IMMEDIATE so two edits never lose one.
    /// An unchanged text is a no-op. Returns the note as saved.
    @discardableResult
    public func editNote(id: Int64, text: String) throws -> TaskNote {
        let body = try Self.noteBody(text)
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            guard var note = try readNotes("SELECT \(Self.noteCols) FROM task_notes WHERE id=?;", [.int(id)]).first else {
                throw StoreError.notFound("note \(id)")
            }
            guard note.author == .user, note.questionId == nil else {
                throw StoreError.invalid("only your own notes can be edited")
            }
            if note.text != body {
                let now = Date()
                try runWrite("INSERT INTO task_note_edits (note_id, ts, text) VALUES (?, ?, ?);",
                             [.int(id), .double(now.timeIntervalSince1970), .text(note.text)])
                try runWrite("UPDATE task_notes SET text=?, edited_at=? WHERE id=?;",
                             [.text(body), .double(now.timeIntervalSince1970), .int(id)])
                try runWrite("UPDATE tasks SET updated_at=? WHERE id=?;",
                             [.int(Int64(now.timeIntervalSince1970)), .int(note.taskId)])
                note.text = body
                note.editedAt = now
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return note
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// A note's earlier texts, newest first (each was replaced at its timestamp).
    public func noteEdits(noteId: Int64) throws -> [NoteEdit] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT id, note_id, ts, text FROM task_note_edits WHERE note_id=? ORDER BY id DESC;",
                               [.int(noteId)])
        defer { sqlite3_finalize(stmt) }
        var out: [NoteEdit] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(NoteEdit(id: sqlite3_column_int64(stmt, 0), noteId: sqlite3_column_int64(stmt, 1),
                                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                                text: colText(stmt, 3)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    /// Notes whose text contains `query` (case-insensitive for ASCII, as SQLite's LIKE),
    /// newest first, across every project (archived ones too: past decisions stay
    /// findable), optionally one project and/or kind.
    public func searchNotes(query: String, projectId: Int64? = nil, kind: NoteKind? = nil,
                            limit: Int = 20) throws -> [NoteSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw StoreError.invalid("search query is empty") }
        lock.lock(); defer { lock.unlock() }
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        var sql = "SELECT \(Self.qualifiedNoteCols), t.code, t.title, p.code FROM task_notes n "
            + "JOIN tasks t ON t.id = n.task_id JOIN projects p ON p.id = t.project_id "
            + "WHERE n.text LIKE ? ESCAPE '\\'"
        var binds: [SQLValue] = [.text("%\(escaped)%")]
        if let projectId { sql += " AND t.project_id=?"; binds.append(.int(projectId)) }
        if let kind { sql += " AND n.kind=?"; binds.append(.text(kind.rawValue)) }
        sql += " ORDER BY n.ts DESC, n.id DESC LIMIT ?;"
        binds.append(.int(Int64(max(0, limit))))
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [NoteSearchHit] = []
        var rc = sqlite3_step(stmt)
        let c = Self.noteColCount
        while rc == SQLITE_ROW {
            out.append(NoteSearchHit(note: noteFromRow(stmt), taskCode: colText(stmt, c),
                                     taskTitle: colText(stmt, c + 1), projectCode: colText(stmt, c + 2)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    private func readNotes(_ sql: String, _ binds: [SQLValue]) throws -> [TaskNote] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [TaskNote] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(noteFromRow(stmt))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    /// A note from the first `noteCols` columns of a row.
    private func noteFromRow(_ stmt: OpaquePointer?) -> TaskNote {
        func int64Opt(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
        }
        return TaskNote(
            id: sqlite3_column_int64(stmt, 0),
            taskId: sqlite3_column_int64(stmt, 1),
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
            kind: NoteKind(rawValue: colText(stmt, 3)) ?? .note,
            text: colText(stmt, 4),
            author: colTextOpt(stmt, 5).flatMap(NoteAuthor.init(rawValue:)),
            sessionId: colTextOpt(stmt, 6),
            statusEventId: int64Opt(7),
            questionId: int64Opt(8),
            editedAt: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)))
    }

    // MARK: - Agent guides

    /// The current guide of a scope (`projectId` nil = the guide for every project): its
    /// newest version, or nil when none was ever saved.
    public func guide(projectId: Int64?) throws -> GuideVersion? {
        try guideHistory(projectId: projectId, limit: 1).first
    }

    /// A scope's versions, newest first (the first is the current guide).
    public func guideHistory(projectId: Int64?, limit: Int = 20) throws -> [GuideVersion] {
        lock.lock(); defer { lock.unlock() }
        return try guideVersionsUnlocked(projectId: projectId, limit: limit)
    }

    private func guideVersionsUnlocked(projectId: Int64?, limit: Int) throws -> [GuideVersion] {
        try readGuides("SELECT \(Self.guideCols) FROM guide_versions WHERE project_id IS ? ORDER BY id DESC LIMIT ?;",
                       [projectId.map(SQLValue.int) ?? .null, .int(Int64(max(0, limit)))])
    }

    /// Save a scope's guide as a new version; an unchanged text saves nothing and returns
    /// the current version. `mergeWindow` (the app's autosave): when the current version
    /// is the user's own, has no reason (a restore keeps its text) and was saved less than
    /// that long ago, it is updated in place, so one sitting of typing is one version.
    /// Agent saves are always a new version. `basedOn` (the app's editor): the version the
    /// text was edited from, nil for a scope with none; when another save came first, the
    /// save is refused with `GuideConflict`, so an open editor never overwrites it. Read
    /// and written in one BEGIN IMMEDIATE.
    @discardableResult
    public func saveGuide(projectId: Int64?, markdown: String, author: NoteAuthor, sessionId: String? = nil,
                          reason: String? = nil, mergeWindow: TimeInterval? = nil,
                          basedOn: Int64?? = .none) throws -> GuideVersion {
        let text = markdown.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let session = sessionId.flatMap { $0.isEmpty ? nil : $0 }
        let why = reason.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let scope: SQLValue = projectId.map(SQLValue.int) ?? .null
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            if let projectId, queryInt("SELECT id FROM projects WHERE id=?;", [.int(projectId)]) == nil {
                throw StoreError.notFound("project \(projectId)")
            }
            let current = try guideVersionsUnlocked(projectId: projectId, limit: 1).first
            if let basedOn, current?.id != basedOn, let current { throw GuideConflict(current: current) }
            let now = Date()
            var saved: GuideVersion
            if let current, current.markdown == text {
                saved = current
            } else if var current, let mergeWindow, author == .user, current.author == .user, current.reason == nil,
                      now.timeIntervalSince(current.timestamp) < mergeWindow {
                try runWrite("UPDATE guide_versions SET markdown=?, ts=? WHERE id=?;",
                             [.text(text), .double(now.timeIntervalSince1970), .int(current.id)])
                current.markdown = text
                current.timestamp = now
                saved = current
            } else {
                try runWrite(
                    "INSERT INTO guide_versions (project_id, ts, markdown, author, session_id, reason) VALUES (?, ?, ?, ?, ?, ?);",
                    [scope, .double(now.timeIntervalSince1970), .text(text), .text(author.rawValue),
                     session.map(SQLValue.text) ?? .null, why.map(SQLValue.text) ?? .null])
                saved = GuideVersion(id: lastInsertId(), projectId: projectId, timestamp: now, markdown: text,
                                     author: author, sessionId: session, reason: why)
            }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return saved
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    private static let guideCols = "id, project_id, ts, markdown, author, session_id, reason"

    private func readGuides(_ sql: String, _ binds: [SQLValue]) throws -> [GuideVersion] {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [GuideVersion] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(GuideVersion(
                id: sqlite3_column_int64(stmt, 0),
                projectId: sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                markdown: colText(stmt, 3),
                author: NoteAuthor(rawValue: colText(stmt, 4)) ?? .user,
                sessionId: colTextOpt(stmt, 5), reason: colTextOpt(stmt, 6)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    // MARK: - Questions (ask loop)

    private static let questionCols = "q.id, q.task_id, t.code, t.title, p.code, q.session_id, q.kind, q.prompt, "
        + "q.context, q.options, q.blocks_task, q.status, q.answer, q.answer_choice, q.cancel_reason, "
        + "q.asked_at, q.answered_at, q.resumed_at"
    private static let questionFrom = "FROM questions q JOIN tasks t ON t.id = q.task_id JOIN projects p ON p.id = t.project_id"

    /// Leave a question for the user on a task (ask_user). Checked before the write: a
    /// non-empty prompt; option labels non-empty and distinct, at most one recommended;
    /// choice needs 2–4 options, text takes 0–4 (suggestions), approve none (the draft to
    /// approve goes in `context`). In one BEGIN IMMEDIATE: the task must exist and be open;
    /// the question is inserted with a kind=question note; a blocking question moves the
    /// task to waiting on the user, its reason the question — except a task already waiting
    /// (on anyone), which keeps that wait and its reason. The task's project must be active.
    public func askQuestion(taskId: Int64, kind: QuestionKind, prompt: String, context: String = "",
                            options: [QuestionOption] = [], blocksTask: Bool = true,
                            sessionId: String? = nil) throws -> Question {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw StoreError.invalid("question is empty") }
        let options = options.map {
            QuestionOption(label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                           note: $0.note.trimmingCharacters(in: .whitespacesAndNewlines), recommended: $0.recommended)
        }
        if options.contains(where: { $0.label.isEmpty }) { throw StoreError.invalid("an option label is empty") }
        if Set(options.map { $0.label.lowercased() }).count != options.count {
            throw StoreError.invalid("option labels must be distinct")
        }
        if options.filter(\.recommended).count > 1 { throw StoreError.invalid("at most one option can be recommended") }
        switch kind {
        case .choice where !(2...4).contains(options.count):
            throw StoreError.invalid("a choice question needs 2 to 4 options")
        case .text where options.count > 4:
            throw StoreError.invalid("a text question takes at most 4 suggested options")
        case .approve where !options.isEmpty:
            throw StoreError.invalid("an approve question takes no options; put the draft in context")
        default: break
        }
        let optionsJSON = String(data: try JSONEncoder().encode(options), encoding: .utf8) ?? "[]"
        let session = sessionId.flatMap { $0.isEmpty ? nil : $0 }
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            guard let task = getTaskUnlocked(taskId) else { throw StoreError.notFound("task \(taskId)") }
            guard !task.status.isClosed else { throw StoreError.invalid("\(task.code) is \(task.status.rawValue); reopen it first") }
            // The app lists questions of active projects only: one asked here could not be answered.
            try requireActiveProjectUnlocked(task.projectId)
            // A blocking question parks the task on the user — unless it already waits
            // (on the user, or a third party): that wait, and its reason, stay as they are.
            let parks = blocksTask && task.status != .waiting
            try runWrite(
                "INSERT INTO questions (task_id, session_id, kind, prompt, context, options, blocks_task, status, asked_at, parked) "
                + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
                [.int(taskId), session.map(SQLValue.text) ?? .null, .text(kind.rawValue), .text(prompt),
                 .text(context.trimmingCharacters(in: .whitespacesAndNewlines)), .text(optionsJSON),
                 .int(blocksTask ? 1 : 0), .text(QuestionStatus.open.rawValue),
                 .double(Date().timeIntervalSince1970), .int(parks ? 1 : 0)])
            let qid = lastInsertId()
            var eventId: Int64?
            if parks {
                eventId = try applyTaskUpdateUnlocked(id: taskId, status: .waiting, waitingOn: .user,
                                                      waitingReason: .some(Self.questionReason(prompt)),
                                                      spawnRecurrence: false)
            }
            _ = try insertNoteUnlocked(taskId: taskId, text: prompt, kind: .question, author: .agent,
                                       sessionId: session, statusEventId: eventId, questionId: qid)
            let q = try questionUnlocked(qid)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return q
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// The user answers an open question (the app). `choice` is the 0-based option picked;
    /// `answer` the typed text, or the option's label when only an option was picked. When
    /// this was the task's last open blocking question and the task still waits on the
    /// user, it goes back to todo, to be picked up (get_answers) before new work.
    @discardableResult
    public func answerQuestion(id: Int64, answer: String, choice: Int? = nil) throws -> Question {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            let q = try questionUnlocked(id)
            guard q.status == .open else { throw StoreError.invalid("question \(id) is already \(q.status.rawValue)") }
            if let choice, !q.options.indices.contains(choice) {
                throw StoreError.invalid("question \(id) has no option \(choice + 1)")
            }
            var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, let choice { text = q.options[choice].label }
            guard !text.isEmpty else { throw StoreError.invalid("answer is empty") }
            try runWrite("UPDATE questions SET status=?, answer=?, answer_choice=?, answered_at=? WHERE id=?;",
                         [.text(QuestionStatus.answered.rawValue), .text(text),
                          choice.map { .int(Int64($0)) } ?? .null, .double(Date().timeIntervalSince1970), .int(id)])
            if q.blocksTask { try releaseTaskUnlocked(q.taskId) }
            let saved = try questionUnlocked(id)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return saved
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// The agent takes an answered question back up (resume_question): it becomes resumed,
    /// the answer is logged as a decision note by the user, and the task — unless closed,
    /// or still held by another open blocking question — moves to in progress.
    public func resumeQuestion(id: Int64, sessionId: String? = nil) throws -> (question: Question, task: TodoTask) {
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            let q = try questionUnlocked(id)
            switch q.status {
            case .answered: break
            case .open: throw StoreError.invalid("question \(id) is not answered yet")
            case .resumed, .cancelled: throw StoreError.invalid("question \(id) is already \(q.status.rawValue)")
            }
            try runWrite("UPDATE questions SET status=?, resumed_at=? WHERE id=?;",
                         [.text(QuestionStatus.resumed.rawValue), .double(Date().timeIntervalSince1970), .int(id)])
            _ = try insertNoteUnlocked(taskId: q.taskId, text: "\(q.prompt)\n→ \(q.answer ?? "")", kind: .decision,
                                       author: .user, sessionId: sessionId ?? q.sessionId, questionId: id)
            try startTaskUnlocked(q.taskId)
            let saved = try questionUnlocked(id)
            guard let task = getTaskUnlocked(q.taskId) else { throw StoreError.notFound("task \(q.taskId)") }
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return (saved, task)
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// The agent withdraws an open or answered question it no longer needs (it found the
    /// answer itself): cancelled, with a decision note by the agent saying why, and the
    /// task released as by resumeQuestion.
    @discardableResult
    public func cancelQuestion(id: Int64, reason: String, sessionId: String? = nil) throws -> Question {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        do {
            try beginImmediate()
            let q = try questionUnlocked(id)
            guard q.status == .open || q.status == .answered else {
                throw StoreError.invalid("question \(id) is already \(q.status.rawValue)")
            }
            try runWrite("UPDATE questions SET status=?, cancel_reason=? WHERE id=?;",
                         [.text(QuestionStatus.cancelled.rawValue), reason.isEmpty ? .null : .text(reason), .int(id)])
            let text = "Withdrew question: \(q.prompt)" + (reason.isEmpty ? "" : "\nReason: \(reason)")
            _ = try insertNoteUnlocked(taskId: q.taskId, text: text, kind: .decision, author: .agent,
                                       sessionId: sessionId ?? q.sessionId, questionId: id)
            if q.blocksTask {
                try releaseTaskUnlocked(q.taskId)
                try startTaskUnlocked(q.taskId)
            }
            let saved = try questionUnlocked(id)
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return saved
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Questions by status, oldest asked first. `activeOnly` leaves out archived projects
    /// (the app's question list and inbox); `projectId`, `taskId`, `sessionId` narrow it.
    public func questions(statuses: [QuestionStatus], projectId: Int64? = nil, taskId: Int64? = nil,
                          sessionId: String? = nil, activeOnly: Bool = false) throws -> [Question] {
        lock.lock(); defer { lock.unlock() }
        let (whereSQL, binds) = Self.questionFilter(statuses: statuses, projectId: projectId, taskId: taskId,
                                                    sessionId: sessionId, activeOnly: activeOnly)
        return try readQuestionsUnlocked(whereSQL + " ORDER BY q.asked_at, q.id", binds)
    }

    /// How many open and answered questions match, in active projects (the ones the app
    /// shows, so the ones that can be answered) — the cheap poll behind wait_for_answers.
    public func questionCounts(projectId: Int64? = nil, sessionId: String? = nil) throws
        -> (open: Int, answered: Int) {
        lock.lock(); defer { lock.unlock() }
        let (whereSQL, binds) = Self.questionFilter(statuses: [.open, .answered], projectId: projectId, taskId: nil,
                                                    sessionId: sessionId, activeOnly: true)
        let stmt = try prepare("SELECT q.status, COUNT(*) \(Self.questionFrom) \(whereSQL) GROUP BY q.status;", binds)
        defer { sqlite3_finalize(stmt) }
        var counts = (open: 0, answered: 0)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let n = Int(sqlite3_column_int64(stmt, 1))
            if colText(stmt, 0) == QuestionStatus.open.rawValue { counts.open = n } else { counts.answered = n }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return counts
    }

    public func question(id: Int64) throws -> Question {
        lock.lock(); defer { lock.unlock() }
        let q = try questionUnlocked(id)
        return q
    }

    private static func questionFilter(statuses: [QuestionStatus], projectId: Int64?, taskId: Int64?,
                                       sessionId: String?, activeOnly: Bool) -> (String, [SQLValue]) {
        var conds = ["q.status IN (\(placeholders(max(1, statuses.count))))"]
        var binds: [SQLValue] = statuses.isEmpty ? [.null] : statuses.map { .text($0.rawValue) }
        if let projectId { conds.append("t.project_id=?"); binds.append(.int(projectId)) }
        if let taskId { conds.append("q.task_id=?"); binds.append(.int(taskId)) }
        if let sessionId { conds.append("q.session_id=?"); binds.append(.text(sessionId)) }
        // Same rule as the task views (Store.activeProjectSQL; project_id is the task's).
        if activeOnly { conds.append(activeProjectSQL) }
        return ("WHERE " + conds.joined(separator: " AND "), binds)
    }

    /// Does the task still have an open question that blocks it?
    private func hasOpenBlockingQuestionUnlocked(_ taskId: Int64) -> Bool {
        queryInt("SELECT EXISTS(SELECT 1 FROM questions WHERE task_id=? AND status='open' AND blocks_task=1);",
                 [.int(taskId)]) == 1
    }

    static func questionReason(_ prompt: String) -> String {
        "Question: " + (prompt.count > 200 ? String(prompt.prefix(199)) + "…" : prompt)
    }

    /// Is the task waiting on the user because a question parked it — in this wait, not an
    /// earlier one? A wait the user set by hand (or set again after the question) is theirs.
    private func parkedByQuestionUnlocked(_ t: TodoTask) -> Bool {
        guard t.status == .waiting, t.waitingOn == .user, let since = t.waitingSince else { return false }
        // waiting_since is whole seconds, asked_at is not: compare from the start of that second.
        return queryInt("SELECT EXISTS(SELECT 1 FROM questions WHERE task_id=? AND parked=1 AND asked_at >= ?);",
                        [.int(t.id), .double(since.timeIntervalSince1970.rounded(.down))]) == 1
    }

    /// After a blocking question is answered or withdrawn, for a task a question parked:
    /// with no open blocking question left it goes back to todo; otherwise its reason names
    /// the oldest question still open. A wait someone else set is left alone.
    private func releaseTaskUnlocked(_ taskId: Int64) throws {
        guard let t = getTaskUnlocked(taskId), parkedByQuestionUnlocked(t) else { return }
        if let next = queryString(
            "SELECT prompt FROM questions WHERE task_id=? AND status='open' AND blocks_task=1 ORDER BY asked_at, id LIMIT 1;",
            [.int(taskId)]) {
            try runWrite("UPDATE tasks SET waiting_reason=? WHERE id=?;", [.text(Self.questionReason(next)), .int(taskId)])
        } else {
            try applyTaskUpdateUnlocked(id: taskId, status: .todo, spawnRecurrence: false)
        }
    }

    /// The agent is back on the task (resume / withdraw): a task still where a question left
    /// it — released to todo, or parked on the user by one — moves to in progress, unless an
    /// open blocking question still holds it. A task someone moved on is left alone.
    private func startTaskUnlocked(_ taskId: Int64) throws {
        guard !hasOpenBlockingQuestionUnlocked(taskId), let t = getTaskUnlocked(taskId),
              t.status == .todo || parkedByQuestionUnlocked(t) else { return }
        try applyTaskUpdateUnlocked(id: taskId, status: .inProgress, spawnRecurrence: false)
    }

    private func questionUnlocked(_ id: Int64) throws -> Question {
        guard let q = try readQuestionsUnlocked("WHERE q.id=?", [.int(id)]).first else {
            throw StoreError.notFound("question \(id)")
        }
        return q
    }

    private func readQuestionsUnlocked(_ whereSQL: String, _ binds: [SQLValue]) throws -> [Question] {
        let stmt = try prepare("SELECT \(Self.questionCols) \(Self.questionFrom) \(whereSQL);", binds)
        defer { sqlite3_finalize(stmt) }
        var out: [Question] = []
        var rc = sqlite3_step(stmt)
        func dateOpt(_ i: Int32) -> Date? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
        }
        while rc == SQLITE_ROW {
            let options = (try? JSONDecoder().decode([QuestionOption].self, from: Data(colText(stmt, 9).utf8))) ?? []
            out.append(Question(
                id: sqlite3_column_int64(stmt, 0), taskId: sqlite3_column_int64(stmt, 1),
                taskCode: colText(stmt, 2), taskTitle: colText(stmt, 3), projectCode: colText(stmt, 4),
                sessionId: colTextOpt(stmt, 5), kind: QuestionKind(rawValue: colText(stmt, 6)) ?? .text,
                prompt: colText(stmt, 7), context: colText(stmt, 8), options: options,
                blocksTask: sqlite3_column_int64(stmt, 10) != 0,
                status: QuestionStatus(rawValue: colText(stmt, 11)) ?? .open,
                answer: colTextOpt(stmt, 12),
                answerChoice: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 13)),
                cancelReason: colTextOpt(stmt, 14),
                askedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15)),
                answeredAt: dateOpt(16), resumedAt: dateOpt(17)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    // MARK: - Dependencies (blocked-by)

    /// The ids of tasks that `taskId` is blocked by (its depends-on list).
    public func dependencies(taskId: Int64) throws -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return dependenciesUnlocked(taskId)
    }

    /// Read the depends-on ids without taking the lock (for use inside locked scopes).
    private func dependenciesUnlocked(_ taskId: Int64) -> [Int64] {
        guard let stmt = try? prepare("SELECT depends_on_id FROM task_deps WHERE task_id=? ORDER BY depends_on_id;", [.int(taskId)]) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    /// Record that `taskId` is blocked by `dependsOnId`. Rejects self-dependency and
    /// any edge that would close a cycle (covers the obvious A→B / B→A case and
    /// deeper transitive loops). Duplicate edges are ignored. Returns whether the edge
    /// is new (false: it was already there).
    @discardableResult
    public func addDependency(taskId: Int64, dependsOnId: Int64) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard taskId != dependsOnId else {
            throw StoreError.step("a task cannot depend on itself")
        }
        // The reachability check + INSERT is a read-modify-write two processes can race
        // on, each adding a reciprocal edge to form a permanent 2-cycle. Serialize them
        // with BEGIN IMMEDIATE and re-check reachability inside the transaction.
        do {
            try beginImmediate()
            for id in [taskId, dependsOnId] where getTaskUnlocked(id) == nil {
                throw StoreError.notFound("task \(id)")
            }
            // If dependsOnId already (transitively) depends on taskId, adding
            // taskId→dependsOnId would create a cycle.
            if dependsReachesUnlocked(from: dependsOnId, to: taskId) {
                throw StoreError.step("adding this dependency would create a cycle")
            }
            try runWrite("INSERT OR IGNORE INTO task_deps (task_id, depends_on_id) VALUES (?, ?);", [.int(taskId), .int(dependsOnId)])
            let created = sqlite3_changes(db) == 1
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return created
        } catch {
            // ROLLBACK clears the transaction on any failure (including a BEGIN that hit an
            // already-open connection), so the shared connection is never left poisoned.
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Remove the blocked-by edge `taskId`→`dependsOnId` (no-op if absent). Returns
    /// whether there was one.
    @discardableResult
    public func removeDependency(taskId: Int64, dependsOnId: Int64) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try runWrite("DELETE FROM task_deps WHERE task_id=? AND depends_on_id=?;", [.int(taskId), .int(dependsOnId)])
        return sqlite3_changes(db) == 1
    }

    // MARK: - Relations (blocks / blocked by / relates / duplicates)

    /// The `task_relations` row that stores `kind` between `taskId` and `otherId`:
    /// relates is one row per pair (lower id first), duplicates points from the duplicate
    /// to the original. Not for the dependency kinds, which live in `task_deps`.
    private static func relationRow(_ taskId: Int64, _ otherId: Int64, _ kind: RelationKind)
        -> (task: Int64, other: Int64, kind: String) {
        switch kind {
        case .relates: return (min(taskId, otherId), max(taskId, otherId), "relates")
        case .duplicatedBy: return (otherId, taskId, "duplicates")
        default: return (taskId, otherId, "duplicates")
        }
    }

    /// Relate `taskId` to `otherId` (any two tasks, across projects). `blockedBy` and
    /// `blocks` add the dependency edge (`addDependency`, with its cycle guard), so they
    /// do block; `relates` and `duplicates` never block. A task cannot be related to
    /// itself, and two tasks cannot each be the duplicate of the other. Repeat-safe:
    /// returns false when the relation was already there.
    @discardableResult
    public func addRelation(taskId: Int64, otherId: Int64, kind: RelationKind) throws -> Bool {
        switch kind {
        case .blockedBy: return try addDependency(taskId: taskId, dependsOnId: otherId)
        case .blocks: return try addDependency(taskId: otherId, dependsOnId: taskId)
        case .relates, .duplicates, .duplicatedBy: break
        }
        guard taskId != otherId else { throw StoreError.step("a task cannot be related to itself") }
        let row = Self.relationRow(taskId, otherId, kind)
        lock.lock(); defer { lock.unlock() }
        do {
            // The reverse-duplicate check + INSERT is a read-modify-write another process
            // can race on: both inside one BEGIN IMMEDIATE.
            try beginImmediate()
            guard let dup = getTaskUnlocked(row.task) else { throw StoreError.notFound("task \(row.task)") }
            guard let original = getTaskUnlocked(row.other) else { throw StoreError.notFound("task \(row.other)") }
            if row.kind == "duplicates", (queryInt(
                "SELECT EXISTS(SELECT 1 FROM task_relations WHERE task_id=? AND other_id=? AND kind='duplicates');",
                [.int(row.other), .int(row.task)]) ?? 0) > 0 {
                throw StoreError.step("\(original.code) is already a duplicate of \(dup.code)")
            }
            try runWrite("INSERT OR IGNORE INTO task_relations (task_id, other_id, kind, created_at) VALUES (?, ?, ?, ?);",
                         [.int(row.task), .int(row.other), .text(row.kind), .double(Date().timeIntervalSince1970)])
            let created = sqlite3_changes(db) == 1
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return created
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Remove `kind` between `taskId` and `otherId` (the dependency kinds remove the
    /// edge). Relates is matched either way round. Returns whether there was one.
    @discardableResult
    public func removeRelation(taskId: Int64, otherId: Int64, kind: RelationKind) throws -> Bool {
        switch kind {
        case .blockedBy: return try removeDependency(taskId: taskId, dependsOnId: otherId)
        case .blocks: return try removeDependency(taskId: otherId, dependsOnId: taskId)
        case .relates, .duplicates, .duplicatedBy: break
        }
        let row = Self.relationRow(taskId, otherId, kind)
        lock.lock(); defer { lock.unlock() }
        try runWrite("DELETE FROM task_relations WHERE task_id=? AND other_id=? AND kind=?;",
                     [.int(row.task), .int(row.other), .text(row.kind)])
        return sqlite3_changes(db) == 1
    }

    /// Every relation of `taskId`, both directions, in one query: its dependencies
    /// (blocked by, open or closed), the tasks depending on it (blocks), related tasks and
    /// duplicates either way. Each group is ordered by task id (creation order).
    public func relatedTasks(taskId: Int64) throws -> RelatedTasks {
        lock.lock(); defer { lock.unlock() }
        let cols = "t.id, t.code, t.title, t.status, t.project_id"
        let stmt = try prepare("""
            SELECT 'blocked_by', \(cols) FROM task_deps d JOIN tasks t ON t.id = d.depends_on_id WHERE d.task_id = ?1
            UNION ALL SELECT 'blocks', \(cols) FROM task_deps d JOIN tasks t ON t.id = d.task_id WHERE d.depends_on_id = ?1
            UNION ALL SELECT 'relates', \(cols) FROM task_relations r
                JOIN tasks t ON t.id = CASE WHEN r.task_id = ?1 THEN r.other_id ELSE r.task_id END
                WHERE r.kind = 'relates' AND (r.task_id = ?1 OR r.other_id = ?1)
            UNION ALL SELECT 'duplicates', \(cols) FROM task_relations r JOIN tasks t ON t.id = r.other_id
                WHERE r.kind = 'duplicates' AND r.task_id = ?1
            UNION ALL SELECT 'duplicated_by', \(cols) FROM task_relations r JOIN tasks t ON t.id = r.task_id
                WHERE r.kind = 'duplicates' AND r.other_id = ?1
            ORDER BY 1, 2;
            """, [.int(taskId)])
        defer { sqlite3_finalize(stmt) }
        var out = RelatedTasks()
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let kind = RelationKind(rawValue: colText(stmt, 0)) {
                out.byKind[kind, default: []].append(RelatedTask(
                    id: sqlite3_column_int64(stmt, 1), code: colText(stmt, 2), title: colText(stmt, 3),
                    status: TaskStatus(rawValue: colText(stmt, 4)) ?? .todo,
                    projectId: sqlite3_column_int64(stmt, 5)))
            }
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    /// For each open task that blocks at least one open task, how many it blocks (the
    /// `blockingEdgeSQL` rule) — one query, for the list's "blocks others" mark.
    public func blockingCounts() throws -> [Int64: Int] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(
            "SELECT d.depends_on_id, COUNT(*) FROM \(Self.depEdgesSQL) WHERE \(Self.blockingEdgeSQL) GROUP BY d.depends_on_id;", [])
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: Int] = [:]
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out[sqlite3_column_int64(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        return out
    }

    /// SQL list of the closed status values (`TaskStatus.isClosed`), e.g. `('done','dropped')`.
    private static let closedStatusSQL = sqlList(TaskStatus.allCases.filter(\.isClosed).map(\.rawValue))

    /// Every dependency edge `d`, joined to its task `a` and the task it depends on `b`.
    /// The blocked predicates below are written against these aliases.
    private static let depEdgesSQL =
        "task_deps d JOIN tasks a ON a.id = d.task_id JOIN tasks b ON b.id = d.depends_on_id"

    /// The dependency `b` is still open.
    private static let openDependencySQL = "b.status NOT IN \(closedStatusSQL)"

    /// The one blocked rule: an edge blocks only while both the task `a` and its
    /// dependency `b` are still open. A task is blocked iff it has at least one such
    /// edge. Every blocked computation (isBlocked, blockedTaskIds, taskRelations) uses this.
    private static let blockingEdgeSQL = "(a.status NOT IN \(closedStatusSQL) AND \(openDependencySQL))"

    /// True if `taskId` is open and at least one of its dependencies is still open.
    public func isBlocked(taskId: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isBlockedUnlocked(taskId)
    }

    /// A WHERE-clause predicate that is true when the task row aliased `taskAlias` has a
    /// dependency still open (indexed on task_deps.task_id). For an open task this is
    /// exactly "blocked"; `AND NOT \(hasOpenDependencySQL("t"))` keeps a task query to
    /// unblocked tasks without a per-task lookup. `taskAlias` is an internal SQL alias,
    /// never user input.
    static func hasOpenDependencySQL(_ taskAlias: String) -> String {
        "EXISTS(SELECT 1 FROM task_deps d JOIN tasks b ON b.id = d.depends_on_id "
        + "WHERE d.task_id = \(taskAlias).id AND \(openDependencySQL))"
    }

    private func isBlockedUnlocked(_ taskId: Int64) -> Bool {
        (queryInt(
            "SELECT EXISTS(SELECT 1 FROM \(Self.depEdgesSQL) WHERE d.task_id=? AND \(Self.blockingEdgeSQL));",
            [.int(taskId)]) ?? 0) > 0
    }

    /// Ids of all tasks currently blocked (see `blockingEdgeSQL`) — one query for the UI.
    public func blockedTaskIds() throws -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(
            "SELECT DISTINCT d.task_id FROM \(Self.depEdgesSQL) WHERE \(Self.blockingEdgeSQL);", [])
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
        return out
    }

    /// Which of `ids` have at least one dependency still open, whatever their own
    /// status — unlike `blockedTaskIds`, a closed task counts too. For guarding a move
    /// back to an active status (e.g. reopening a done task into In Progress).
    public func idsWithOpenDependency(_ ids: [Int64]) throws -> Set<Int64> {
        lock.lock(); defer { lock.unlock() }
        var out: Set<Int64> = []
        for chunk in Self.chunked(Array(Set(ids))) {
            let stmt = try prepare(
                "SELECT DISTINCT d.task_id FROM \(Self.depEdgesSQL) "
                + "WHERE d.task_id IN (\(Self.placeholders(chunk.count))) AND \(Self.openDependencySQL);",
                chunk.map { .int($0) })
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                out.insert(sqlite3_column_int64(stmt, 0))
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        }
        return out
    }

    /// Depends-on codes, parent codes and blocked flags for a batch of tasks, read with
    /// a couple of set queries (chunked IN lists) instead of N per-task lookups.
    /// Throws on a read error rather than returning partial relations.
    public func taskRelations(for tasks: [TodoTask]) throws -> TaskRelations {
        lock.lock(); defer { lock.unlock() }
        var rel = TaskRelations()
        // Same blocked rule as isBlockedUnlocked (blockingEdgeSQL), evaluated per edge.
        for chunk in Self.chunked(tasks.map(\.id)) {
            let stmt = try prepare(
                "SELECT d.task_id, b.code, \(Self.blockingEdgeSQL), b.id FROM \(Self.depEdgesSQL) "
                + "WHERE d.task_id IN (\(Self.placeholders(chunk.count))) ORDER BY d.task_id, d.depends_on_id;",
                chunk.map { .int($0) })
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                let tid = sqlite3_column_int64(stmt, 0)
                let code = colText(stmt, 1)
                rel.dependsOnCodes[tid, default: []].append(code)
                if sqlite3_column_int64(stmt, 2) != 0 {
                    rel.blockedIds.insert(tid)
                    rel.blockedBy[tid, default: []].append((id: sqlite3_column_int64(stmt, 3), code: code))
                }
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        }
        for chunk in Self.chunked(Array(Set(tasks.compactMap(\.parentId)))) {
            let stmt = try prepare(
                "SELECT id, code FROM tasks WHERE id IN (\(Self.placeholders(chunk.count)));",
                chunk.map { .int($0) })
            defer { sqlite3_finalize(stmt) }
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                rel.parentCodes[sqlite3_column_int64(stmt, 0)] = colText(stmt, 1)
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else { throw StoreError.step(errmsg()) }
        }
        return rel
    }

    /// Split ids into batches small enough for SQLite's bound-parameter limit.
    private static func chunked(_ ids: [Int64], size: Int = 500) -> [[Int64]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    /// A parenthesised SQL list of quoted literals, e.g. `('done','Done')`. Only for
    /// fixed internal values (status names) — never user input.
    private static func sqlList(_ values: [String]) -> String {
        "(" + values.map { "'\($0)'" }.joined(separator: ",") + ")"
    }

    /// Does `from` reach `to` by following depends-on edges transitively? (cycle guard)
    private func dependsReachesUnlocked(from: Int64, to: Int64) -> Bool {
        var seen: Set<Int64> = []
        var stack: [Int64] = [from]
        while let cur = stack.popLast() {
            if cur == to { return true }
            if !seen.insert(cur).inserted { continue }
            stack.append(contentsOf: dependenciesUnlocked(cur))
        }
        return false
    }

    private func taskFromRow(_ stmt: OpaquePointer?) -> TodoTask {
        // Columns: id, code, project_id, title, detail, link, status, priority, due_date, tags,
        //          started_at, completed_at, effort_seconds, created_at, updated_at, sort_order, recurrence, parent_id, estimate_seconds,
        //          waiting_on, waiting_reason, waiting_since, branch
        func date(_ i: Int32) -> Date? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
        }
        func int64Opt(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
        }
        let status = TaskStatus(rawValue: colText(stmt, 6)) ?? .todo
        return TodoTask(
            id: sqlite3_column_int64(stmt, 0),
            code: colText(stmt, 1),
            projectId: sqlite3_column_int64(stmt, 2),
            title: colText(stmt, 3),
            detail: colText(stmt, 4),
            link: colTextOpt(stmt, 5),
            status: status,
            waitingOn: colTextOpt(stmt, 19).flatMap(WaitingOn.init(rawValue:)),
            waitingReason: colTextOpt(stmt, 20),
            // Only a waiting task has one, even if an older build left a stale stamp.
            waitingSince: status == .waiting ? date(21) : nil,
            priority: Priority(rawValue: colText(stmt, 7)) ?? .none,
            dueDate: date(8),
            tags: decodeTags(colText(stmt, 9)),
            recurrence: colTextOpt(stmt, 16),
            startedAt: date(10),
            completedAt: date(11),
            effortSeconds: Int(sqlite3_column_int64(stmt, 12)),
            estimateSeconds: Int(sqlite3_column_int64(stmt, 18)),
            parentId: int64Opt(17),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14)),
            sortOrder: Int(sqlite3_column_int64(stmt, 15)),
            branch: colTextOpt(stmt, 22)
        )
    }

    /// Advance a due date by one recurrence interval using the current calendar.
    /// Returns nil for an unrecognized rule.
    static func advanceDueDate(from date: Date, rule: String) -> Date? {
        let cal = Calendar.current
        let comp: DateComponents
        switch rule {
        case "daily":   comp = DateComponents(day: 1)
        case "weekly":  comp = DateComponents(day: 7)
        case "monthly": comp = DateComponents(month: 1)
        default:        return nil
        }
        return cal.date(byAdding: comp, to: date)
    }

    // Tags are stored as a comma-separated string.
    private func encodeTags(_ tags: [String]) -> String {
        tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
    }
    private func decodeTags(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Task templates

    /// Create a reusable task template.
    @discardableResult
    public func createTemplate(name: String, title: String, detail: String = "",
                               priority: Priority = .none, tags: [String] = [],
                               estimateSeconds: Int = 0) throws -> TaskTemplate {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        try runWrite(
            "INSERT INTO task_templates (name, title, detail, priority, tags, estimate_seconds, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
            [.text(name), .text(title), .text(detail), .text(priority.rawValue),
             .text(encodeTags(tags)), .int(Int64(max(0, estimateSeconds))),
             .int(Int64(now.timeIntervalSince1970))]
        )
        let id = lastInsertId()
        return TaskTemplate(id: id, name: name, title: title, detail: detail,
                            priority: priority, tags: tags,
                            estimateSeconds: max(0, estimateSeconds), createdAt: now)
    }

    public func listTemplates() throws -> [TaskTemplate] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(
            "SELECT id, name, title, detail, priority, tags, estimate_seconds, created_at FROM task_templates ORDER BY name COLLATE NOCASE, id;", [])
        defer { sqlite3_finalize(stmt) }
        var out: [TaskTemplate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TaskTemplate(
                id: sqlite3_column_int64(stmt, 0),
                name: colText(stmt, 1),
                title: colText(stmt, 2),
                detail: colText(stmt, 3),
                priority: Priority(rawValue: colText(stmt, 4)) ?? .none,
                tags: decodeTags(colText(stmt, 5)),
                estimateSeconds: Int(sqlite3_column_int64(stmt, 6)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
            ))
        }
        return out
    }

    public func deleteTemplate(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try runWrite("DELETE FROM task_templates WHERE id=?;", [.int(id)])
    }

    /// Spawn a real task from a template into the given project. Reuses createTask
    /// so the task gets a fresh code and a "created" history entry. Composes
    /// listTemplates/createTask (each locks) — must NOT hold the lock here.
    @discardableResult
    public func instantiateTemplate(id: Int64, intoProjectId projectId: Int64) throws -> TodoTask {
        guard let tpl = try listTemplates().first(where: { $0.id == id }) else {
            throw StoreError.notFound("template \(id)")
        }
        return try createTask(
            projectId: projectId,
            title: tpl.title,
            detail: tpl.detail,
            priority: tpl.priority,
            tags: tpl.tags,
            estimateSeconds: tpl.estimateSeconds
        )
    }

    // MARK: - Focus sessions & stats

    public func recordFocusSession(startedAt: Date, endedAt: Date, focusSeconds: Int) throws {
        lock.lock(); defer { lock.unlock() }
        try runWrite(
            "INSERT INTO focus_sessions (started_at, ended_at, focus_seconds) VALUES (?, ?, ?);",
            [.int(Int64(startedAt.timeIntervalSince1970)), .int(Int64(endedAt.timeIntervalSince1970)), .int(Int64(focusSeconds))]
        )
    }

    public func dailyStats(for date: Date = Date()) throws -> DailyStats {
        lock.lock(); defer { lock.unlock() }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let stmt = try prepare(
            "SELECT COUNT(*), COALESCE(SUM(focus_seconds),0) FROM focus_sessions WHERE started_at >= ? AND started_at < ?;",
            [.int(Int64(start.timeIntervalSince1970)), .int(Int64(end.timeIntervalSince1970))]
        )
        defer { sqlite3_finalize(stmt) }
        var count = 0, total = 0
        if sqlite3_step(stmt) == SQLITE_ROW {
            count = Int(sqlite3_column_int64(stmt, 0))
            total = Int(sqlite3_column_int64(stmt, 1))
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"
        return DailyStats(date: fmt.string(from: start), completedPomodoros: count, totalFocusSeconds: total)
    }

    /// Per-day activity for the last `days` calendar days (oldest first, includes today):
    /// focus seconds, completed pomodoros (focus sessions), and tasks completed that day.
    /// Rows are bucketed by local start-of-day, matching `dailyStats`.
    public func dailyStatsSeries(days: Int = 7) throws -> [DayStat] {
        lock.lock(); defer { lock.unlock() }
        let n = max(1, days)
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"

        // Build day buckets oldest → newest.
        let todayStart = cal.startOfDay(for: Date())
        var labels: [String] = []
        var focus: [String: (secs: Int, count: Int)] = [:]
        var done: [String: Int] = [:]
        for offset in stride(from: n - 1, through: 0, by: -1) {
            guard let start = cal.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            labels.append(fmt.string(from: start))
        }
        guard let rangeStart = cal.date(byAdding: .day, value: -(n - 1), to: todayStart),
              let rangeEnd = cal.date(byAdding: .day, value: 1, to: todayStart) else {
            return labels.map { DayStat(date: $0, focusSeconds: 0, pomodoros: 0, tasksCompleted: 0) }
        }
        let lo = SQLValue.int(Int64(rangeStart.timeIntervalSince1970))
        let hi = SQLValue.int(Int64(rangeEnd.timeIntervalSince1970))

        // Focus sessions in range → bucket by started_at's local day.
        if let stmt = try? prepare(
            "SELECT started_at, focus_seconds FROM focus_sessions WHERE started_at >= ? AND started_at < ?;", [lo, hi]) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let day = cal.startOfDay(for: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)))
                let key = fmt.string(from: day)
                var e = focus[key] ?? (0, 0)
                e.secs += Int(sqlite3_column_int64(stmt, 1))
                e.count += 1
                focus[key] = e
            }
            sqlite3_finalize(stmt)
        }

        // Tasks completed in range → bucket by completed_at's local day. Exclude subtasks
        // (parent_id IS NOT NULL) so the dashboard reflects real top-level throughput, not
        // individual checklist ticks. Recurrence occurrences are top-level, so still count.
        if let stmt = try? prepare(
            "SELECT completed_at FROM tasks WHERE completed_at IS NOT NULL AND parent_id IS NULL AND completed_at >= ? AND completed_at < ?;", [lo, hi]) {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let day = cal.startOfDay(for: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)))
                let key = fmt.string(from: day)
                done[key, default: 0] += 1
            }
            sqlite3_finalize(stmt)
        }

        return labels.map { key in
            let f = focus[key] ?? (0, 0)
            return DayStat(date: key, focusSeconds: f.secs, pomodoros: f.count, tasksCompleted: done[key] ?? 0)
        }
    }

    /// Total accrued effort per project (all projects, highest first; zero-effort projects included).
    public func effortByProject() throws -> [ProjectEffort] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(
            """
            SELECT p.id, p.code, p.name, COALESCE(SUM(t.effort_seconds), 0) AS eff
            FROM projects p
            LEFT JOIN tasks t ON t.project_id = p.id
            GROUP BY p.id, p.code, p.name
            ORDER BY eff DESC, p.name;
            """, [])
        defer { sqlite3_finalize(stmt) }
        var out: [ProjectEffort] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(ProjectEffort(
                projectId: sqlite3_column_int64(stmt, 0),
                code: colText(stmt, 1),
                name: colText(stmt, 2),
                effortSeconds: Int(sqlite3_column_int64(stmt, 3))
            ))
        }
        return out
    }

    // MARK: - Settings (pomodoro durations)

    public func loadSettings() throws -> PomodoroSettings {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT value FROM settings WHERE key='pomodoro';", [])
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW,
           let data = colText(stmt, 0).data(using: .utf8),
           let s = try? JSONDecoder().decode(PomodoroSettings.self, from: data) {
            return s
        }
        return .standard
    }

    /// Write a consistent single-file copy of the database (checkpoints WAL first).
    public func backup(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: dbURL, to: url)
    }

    public func saveSettings(_ s: PomodoroSettings) throws {
        lock.lock(); defer { lock.unlock() }
        let json = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? "{}"
        try runWrite("INSERT INTO settings (key, value) VALUES ('pomodoro', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;", [.text(json)])
    }
}

// MARK: - Column readers

private func colText(_ stmt: OpaquePointer?, _ i: Int32) -> String {
    guard let c = sqlite3_column_text(stmt, i) else { return "" }
    return String(cString: c)
}

private func colTextOpt(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
    guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
    return String(cString: c)
}

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}
