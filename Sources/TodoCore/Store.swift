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
        // The kind list is fixed in the table's CHECK: a new NoteKind needs a table rebuild.
        exec("""
        CREATE TABLE IF NOT EXISTS task_notes (
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            ts      REAL NOT NULL,
            kind    TEXT NOT NULL DEFAULT 'note' CHECK(kind IN ('note','decision','review')),
            text    TEXT NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_notes_task_ts ON task_notes(task_id, ts);")

        // --- Additive migration: archived projects (NULL = active) ---
        if !columnExists("projects", "archived_at") { exec("ALTER TABLE projects ADD COLUMN archived_at REAL;") }

        // --- Data repair: status-derived fields (every open; touches only rows that need it) ---
        repairStatusFields()
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
    public func createProject(name: String, detail: String = "") throws -> Project {
        lock.lock(); defer { lock.unlock() }
        // The code pick, the end-of-list sort_order and the INSERT are one read-modify-write
        // the app and MCP server can race on (both picking the same code).
        do {
            try beginImmediate()
            let now = Date()
            let code = uniqueProjectCode(from: name)
            guard let sortOrder = queryInt("SELECT \(Self.nextProjectSortOrderSQL);", []) else { throw StoreError.step(errmsg()) }
            try runWrite(
                "INSERT INTO projects (name, code, detail, task_seq, created_at, sort_order) VALUES (?, ?, ?, 0, ?, ?);",
                [.text(name), .text(code), .text(detail), .int(Int64(now.timeIntervalSince1970)), .int(sortOrder)]
            )
            let id = lastInsertId()
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return Project(id: id, code: code, name: name, detail: detail, createdAt: now, sortOrder: Int(sortOrder))
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
    private static let projectCols = "id, code, name, detail, created_at, sort_order, archived_at"

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
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
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

    public func renameProject(id: Int64, name: String) throws {
        try updateProject(id: id, name: name)
    }

    public func deleteProject(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try runWrite("DELETE FROM projects WHERE id=?;", [.int(id)])
    }

    /// Resolve a project id from its code (case-insensitive). Locks internally.
    public func projectId(forCode code: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return queryInt("SELECT id FROM projects WHERE code=? COLLATE NOCASE;", [.text(code)])
    }

    // MARK: - Tasks

    /// Canonical task column list (order must match `taskFromRow`).
    private static let taskCols = "id, code, project_id, title, detail, link, status, priority, due_date, tags, started_at, completed_at, effort_seconds, created_at, updated_at, sort_order, recurrence, parent_id, estimate_seconds, waiting_on, waiting_reason, waiting_since"
    /// `taskCols` qualified with `tasks.`, for queries that join another table.
    private static let qualifiedTaskCols = taskCols.components(separatedBy: ", ").map { "tasks.\($0)" }.joined(separator: ", ")
    /// How many columns `taskCols` selects: the index of a column a query adds after them.
    private static let taskColCount = Int32(taskCols.components(separatedBy: ", ").count)

    @discardableResult
    public func createTask(projectId: Int64, title: String, detail: String = "", link: String? = nil,
                           status: TaskStatus = .todo, waitingOn: WaitingOn? = nil, waitingReason: String? = nil,
                           priority: Priority = .none,
                           dueDate: Date? = nil, tags: [String] = [], recurrence: String? = nil,
                           parentId: Int64? = nil, estimateSeconds: Int = 0) throws -> TodoTask {
        lock.lock(); defer { lock.unlock() }
        // The task_seq bump, its read-back and the INSERT are one read-modify-write the
        // app and MCP server can race on (both reading the same seq → duplicate codes).
        do {
            try beginImmediate()
            try requireActiveProjectUnlocked(projectId)
            let task = try createTaskUnlocked(projectId: projectId, title: title, detail: detail, link: link,
                                              status: status, waitingOn: waitingOn, waitingReason: waitingReason,
                                              priority: priority, dueDate: dueDate, tags: tags,
                                              recurrence: recurrence, parentId: parentId, estimateSeconds: estimateSeconds)
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
        if enforceNesting, let parentId {
            let parentOfParent = queryString("SELECT parent_id FROM tasks WHERE id=?;", [.int(parentId)])
            if parentOfParent != nil {
                throw StoreError.step("cannot nest a subtask under another subtask (one level of nesting only)")
            }
        }
        // A subtask must not recur: on completion a recurring task spawns a fresh
        // top-level occurrence, so a recurring subtask would leak a detached duplicate.
        // Force recurrence to nil whenever this task has a parent.
        let effectiveRecurrence = parentId == nil ? recurrence : nil
        // Next per-project sequence number → task code.
        try runWrite("UPDATE projects SET task_seq = task_seq + 1 WHERE id=?;", [.int(projectId)])
        let seq = queryInt("SELECT task_seq FROM projects WHERE id=?;", [.int(projectId)]) ?? 1
        let pcode = queryString("SELECT code FROM projects WHERE id=?;", [.int(projectId)]) ?? "PRJ"
        let code = "\(pcode)-\(seq)"
        let due: SQLValue = dueDate.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null
        let nowSecs = Int64(now.timeIntervalSince1970)
        let secs: (Date?) -> SQLValue = { $0.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null }
        // started_at/completed_at/waiting_since come from the shared status rule, evaluated
        // over a one-row "prior" table (the source's status + timestamps, or an empty todo).
        // The prior waiting_since is always NULL: a waiting copy is a new ask, waiting from now.
        let ts = Self.statusTimestampExprs(status, now: nowSecs)
        try runWrite(
            """
            INSERT INTO tasks (project_id, code, title, detail, link, status, waiting_on, waiting_reason, priority, due_date, tags, recurrence, parent_id, estimate_seconds, started_at, completed_at, waiting_since, created_at, updated_at, sort_order)
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(ts.startedAt), \(ts.completedAt), \(ts.waitingSince), ?, ?, (SELECT COALESCE(MAX(sort_order)+1,0) FROM tasks WHERE project_id=?)
            FROM (SELECT ? AS status, ? AS started_at, ? AS completed_at, NULL AS waiting_since);
            """,
            [.int(projectId), .text(code), .text(title), .text(detail), link.map(SQLValue.text) ?? .null,
             .text(status.rawValue), waitingOn.map { .text($0.rawValue) } ?? .null, reason.map(SQLValue.text) ?? .null,
             .text(priority.rawValue), due, .text(encodeTags(tags)),
             effectiveRecurrence.map(SQLValue.text) ?? .null, parentId.map(SQLValue.int) ?? .null,
             .int(Int64(max(0, estimateSeconds)))]
            + ts.binds
            + [.int(nowSecs), .int(nowSecs), .int(projectId),
               .text((source?.status ?? .todo).rawValue), secs(source?.startedAt), secs(source?.completedAt)]
        )
        let id = lastInsertId()
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
        return try readTasks(
            "SELECT \(Self.qualifiedTaskCols) FROM tasks \(Self.projectJoinSQL) \(whereSQL) "
            + "ORDER BY \(Self.statusRankSQL), \(Self.boardOrderSQL);", binds)
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

    /// Append a change-history row (caller already holds the lock).
    private func logEvent(_ taskId: Int64, _ field: String, _ old: String, _ new: String) {
        try? runWrite(
            "INSERT INTO task_history (task_id, ts, field, old_value, new_value) VALUES (?, ?, ?, ?, ?);",
            [.int(taskId), .int(Int64(Date().timeIntervalSince1970)), .text(field), .text(old), .text(new)]
        )
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
    public func updateTask(id: Int64, title: String? = nil, detail: String? = nil, link: String?? = nil,
                           status: TaskStatus? = nil, priority: Priority? = nil,
                           dueDate: Date?? = nil, tags: [String]? = nil, recurrence: String?? = nil,
                           estimateSeconds: Int? = nil,
                           waitingOn: WaitingOn? = nil, waitingReason: String?? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let apply = { [self] (spawnRecurrence: Bool) in
            try applyTaskUpdateUnlocked(
                id: id, title: title, detail: detail, link: link, status: status, priority: priority,
                dueDate: dueDate, tags: tags, recurrence: recurrence, estimateSeconds: estimateSeconds,
                waitingOn: waitingOn, waitingReason: waitingReason, spawnRecurrence: spawnRecurrence)
        }
        // Writes that depend on the stored row run inside BEGIN IMMEDIATE, re-read there:
        // any status write (its history row names the status it replaced, a move to done
        // may spawn the next occurrence — two processes could each spawn one), and the
        // waiting rule depends on whether the task is already waiting.
        let needsTransaction = status != nil || Self.setsWaitingFields(waitingOn, waitingReason)
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
            // write failure — a rejected or missing task is reported as is.
            guard status == .done, let e = error as? StoreError, case .step = e else { throw error }
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
                                waitingReason: String?? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let apply = { [self] (spawnRecurrence: Bool) in
            try beginImmediate()
            for id in ids {
                do {
                    try applyTaskUpdateUnlocked(id: id, status: status, priority: priority, dueDate: dueDate,
                                                addTags: addTags, waitingOn: waitingOn, waitingOnDefault: waitingOnDefault,
                                                waitingReason: waitingReason, spawnRecurrence: spawnRecurrence)
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
    /// caller's transaction the check, write and log see one consistent row.
    private func applyTaskUpdateUnlocked(id: Int64, title: String? = nil, detail: String? = nil, link: String?? = nil,
                                         status: TaskStatus? = nil, priority: Priority? = nil,
                                         dueDate: Date?? = nil, tags: [String]? = nil, addTags: [String]? = nil,
                                         recurrence: String?? = nil, estimateSeconds: Int? = nil,
                                         waitingOn: WaitingOn? = nil, waitingOnDefault: WaitingOn? = nil,
                                         waitingReason: String?? = nil, spawnRecurrence: Bool) throws {
        guard let old = getTaskUnlocked(id) else { throw StoreError.notFound("task \(id)") }
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
        if let link { sets.append("link=?"); binds.append(link.map(SQLValue.text) ?? .null) }
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
            if !(old.parentId != nil && recurrence != nil) {
                sets.append("recurrence=?"); binds.append(recurrence.map(SQLValue.text) ?? .null)
            }
        }
        if let estimateSeconds { sets.append("estimate_seconds=?"); binds.append(.int(Int64(max(0, estimateSeconds)))) }
        guard !sets.isEmpty else { return }
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
                projectId: old.projectId, title: old.title, detail: old.detail, link: old.link,
                status: .todo, priority: old.priority, dueDate: nextDue, tags: old.tags, recurrence: rule,
                estimateSeconds: old.estimateSeconds
            )
            logEvent(spawned.id, "recurrence", "", rule)
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
        if let status, status != old.status { logEvent(id, "status", old.status.display, status.display) }
        // waiting_on is logged by raw value (user / external); waiting_reason is free text
        // (like title/detail) and is not logged.
        // Leaving waiting clears it, but the status row already says so: log only a new who.
        let newWaitingOn = (status.map { $0 != .waiting } ?? false) ? nil : (waitingOn ?? old.waitingOn)
        if let newWaitingOn, newWaitingOn != old.waitingOn {
            logEvent(id, "waiting on", old.waitingOn?.rawValue ?? "", newWaitingOn.rawValue)
        }
        if let priority, priority != old.priority { logEvent(id, "priority", old.priority.display, priority.display) }
        if let link {
            let nv = link ?? ""
            if nv != (old.link ?? "") { logEvent(id, "link", old.link ?? "", nv) }
        }
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
        return try createTaskUnlocked(
            projectId: targetProject,
            title: t.title,
            detail: t.detail,
            link: t.link,
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

    /// Persist a new ordering for a project's tasks (ids in desired order).
    public func reorderTasks(orderedIds: [Int64]) throws {
        lock.lock(); defer { lock.unlock() }
        for (i, id) in orderedIds.enumerated() {
            try runWrite("UPDATE tasks SET sort_order=? WHERE id=?;", [.int(Int64(i)), .int(id)])
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

    // MARK: - Notes

    /// Append a note to a task: a single INSERT, never a read-modify-write of the task,
    /// so concurrent writers cannot lose each other's notes. The same transaction bumps
    /// the task's `updated_at` (a note is activity on the task), which doubles as the
    /// existence check. Not logged to task_history. Text is trimmed and must not be empty.
    /// Returns the note and the task's code.
    @discardableResult
    public func addNote(taskId: Int64, text: String, kind: NoteKind = .note) throws -> (note: TaskNote, taskCode: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw StoreError.invalid("note text is empty") }
        lock.lock(); defer { lock.unlock() }
        // Full precision (REAL), so notes from one second still order by time; updated_at
        // keeps whole seconds like every other write of it.
        let now = Date()
        do {
            try beginImmediate()
            try runWrite("UPDATE tasks SET updated_at=? WHERE id=?;",
                         [.int(Int64(now.timeIntervalSince1970)), .int(taskId)])
            guard sqlite3_changes(db) == 1 else { throw StoreError.notFound("task \(taskId)") }
            try runWrite("INSERT INTO task_notes (task_id, ts, kind, text) VALUES (?, ?, ?, ?);",
                         [.int(taskId), .double(now.timeIntervalSince1970), .text(kind.rawValue), .text(body)])
            let note = TaskNote(id: lastInsertId(), taskId: taskId, timestamp: now, kind: kind, text: body)
            let code = queryString("SELECT code FROM tasks WHERE id=?;", [.int(taskId)]) ?? ""
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
            return (note, code)
        } catch {
            exec("ROLLBACK;")
            throw error
        }
    }

    /// A task's notes, newest first; `limit` nil = all of them.
    public func notes(taskId: Int64, limit: Int? = nil) throws -> [TaskNote] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(
            "SELECT id, task_id, ts, kind, text FROM task_notes WHERE task_id=? ORDER BY ts DESC, id DESC LIMIT ?;",
            [.int(taskId), .int(Int64(limit.map { max(0, $0) } ?? -1))]   // LIMIT -1 = no limit
        )
        defer { sqlite3_finalize(stmt) }
        var out: [TaskNote] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(TaskNote(
                id: sqlite3_column_int64(stmt, 0),
                taskId: sqlite3_column_int64(stmt, 1),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                kind: NoteKind(rawValue: colText(stmt, 3)) ?? .note,
                text: colText(stmt, 4)
            ))
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
    /// deeper transitive loops). Duplicate edges are ignored.
    public func addDependency(taskId: Int64, dependsOnId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        guard taskId != dependsOnId else {
            throw StoreError.step("a task cannot depend on itself")
        }
        // The reachability check + INSERT is a read-modify-write two processes can race
        // on, each adding a reciprocal edge to form a permanent 2-cycle. Serialize them
        // with BEGIN IMMEDIATE and re-check reachability inside the transaction.
        do {
            try beginImmediate()
            // If dependsOnId already (transitively) depends on taskId, adding
            // taskId→dependsOnId would create a cycle.
            if dependsReachesUnlocked(from: dependsOnId, to: taskId) {
                throw StoreError.step("adding this dependency would create a cycle")
            }
            try runWrite("INSERT OR IGNORE INTO task_deps (task_id, depends_on_id) VALUES (?, ?);", [.int(taskId), .int(dependsOnId)])
            if exec("COMMIT;") != SQLITE_OK { throw StoreError.step("commit failed: \(errmsg())") }
        } catch {
            // ROLLBACK clears the transaction on any failure (including a BEGIN that hit an
            // already-open connection), so the shared connection is never left poisoned.
            exec("ROLLBACK;")
            throw error
        }
    }

    /// Remove the blocked-by edge `taskId`→`dependsOnId` (no-op if absent).
    public func removeDependency(taskId: Int64, dependsOnId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        try runWrite("DELETE FROM task_deps WHERE task_id=? AND depends_on_id=?;", [.int(taskId), .int(dependsOnId)])
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
        //          waiting_on, waiting_reason, waiting_since
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
            sortOrder: Int(sqlite3_column_int64(stmt, 15))
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
