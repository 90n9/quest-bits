import Foundation
import SQLite3

// SQLite wants this when binding Swift strings (transient → it copies the bytes).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .open(let m): return "sqlite open failed: \(m)"
        case .prepare(let m): return "sqlite prepare failed: \(m)"
        case .step(let m): return "sqlite step failed: \(m)"
        case .notFound(let m): return "not found: \(m)"
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
    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("TodoApp", isDirectory: true)
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

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
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

    /// A project code unique among existing projects (appends 2, 3, … on clash).
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
        let now = Date()
        let code = uniqueProjectCode(from: name)
        try runWrite(
            "INSERT INTO projects (name, code, detail, task_seq, created_at, sort_order) VALUES (?, ?, ?, 0, ?, (SELECT COALESCE(MAX(sort_order)+1,0) FROM projects));",
            [.text(name), .text(code), .text(detail), .int(Int64(now.timeIntervalSince1970))]
        )
        let id = lastInsertId()
        return Project(id: id, code: code, name: name, detail: detail, createdAt: now, sortOrder: 0)
    }

    public func listProjects() throws -> [Project] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT id, code, name, detail, created_at, sort_order FROM projects ORDER BY sort_order, id;", [])
        defer { sqlite3_finalize(stmt) }
        var out: [Project] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Project(
                id: sqlite3_column_int64(stmt, 0),
                code: colText(stmt, 1),
                name: colText(stmt, 2),
                detail: colText(stmt, 3),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                sortOrder: Int(sqlite3_column_int64(stmt, 5))
            ))
        }
        return out
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
    private static let taskCols = "id, code, project_id, title, detail, link, status, priority, due_date, tags, started_at, completed_at, effort_seconds, created_at, updated_at, sort_order"

    @discardableResult
    public func createTask(projectId: Int64, title: String, detail: String = "", link: String? = nil,
                           status: TaskStatus = .todo, priority: Priority = .none,
                           dueDate: Date? = nil, tags: [String] = []) throws -> TodoTask {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        // Next per-project sequence number → task code.
        try runWrite("UPDATE projects SET task_seq = task_seq + 1 WHERE id=?;", [.int(projectId)])
        let seq = queryInt("SELECT task_seq FROM projects WHERE id=?;", [.int(projectId)]) ?? 1
        let pcode = queryString("SELECT code FROM projects WHERE id=?;", [.int(projectId)]) ?? "PRJ"
        let code = "\(pcode)-\(seq)"
        let due: SQLValue = dueDate.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null
        try runWrite(
            """
            INSERT INTO tasks (project_id, code, title, detail, link, status, priority, due_date, tags, created_at, updated_at, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort_order)+1,0) FROM tasks WHERE project_id=?));
            """,
            [.int(projectId), .text(code), .text(title), .text(detail), link.map(SQLValue.text) ?? .null,
             .text(status.rawValue), .text(priority.rawValue), due, .text(encodeTags(tags)),
             .int(Int64(now.timeIntervalSince1970)), .int(Int64(now.timeIntervalSince1970)), .int(projectId)]
        )
        let id = lastInsertId()
        logEvent(id, "created", "", title)
        if status != .todo { logEvent(id, "status", "todo", status.rawValue) }
        return TodoTask(id: id, code: code, projectId: projectId, title: title, detail: detail, link: link,
                        status: status, priority: priority, dueDate: dueDate, tags: tags,
                        createdAt: now, updatedAt: now, sortOrder: 0)
    }

    public func listTasks(projectId: Int64? = nil) throws -> [TodoTask] {
        lock.lock(); defer { lock.unlock() }
        let sql: String
        let binds: [SQLValue]
        if let pid = projectId {
            sql = "SELECT \(Self.taskCols) FROM tasks WHERE project_id=? ORDER BY sort_order, id;"
            binds = [.int(pid)]
        } else {
            sql = "SELECT \(Self.taskCols) FROM tasks ORDER BY project_id, sort_order, id;"
            binds = []
        }
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        var out: [TodoTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(taskFromRow(stmt)) }
        return out
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

    /// Ids of all tasks currently In Progress (across projects) — for effort accrual.
    public func inProgressTaskIds() throws -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT id FROM tasks WHERE status='in_progress';", [])
        defer { sqlite3_finalize(stmt) }
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(sqlite3_column_int64(stmt, 0)) }
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

    public func updateTask(id: Int64, title: String? = nil, detail: String? = nil, link: String?? = nil,
                           status: TaskStatus? = nil, priority: Priority? = nil,
                           dueDate: Date?? = nil, tags: [String]? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let old = getTaskUnlocked(id)
        let now = Int64(Date().timeIntervalSince1970)
        var sets: [String] = []
        var binds: [SQLValue] = []
        if let title { sets.append("title=?"); binds.append(.text(title)) }
        if let detail { sets.append("detail=?"); binds.append(.text(detail)) }
        if let link { sets.append("link=?"); binds.append(link.map(SQLValue.text) ?? .null) }
        if let status {
            sets.append("status=?"); binds.append(.text(status.rawValue))
            // Auto timestamps on transition.
            if status == .inProgress { sets.append("started_at=COALESCE(started_at, ?)"); binds.append(.int(now)) }
            if status == .done { sets.append("completed_at=?"); binds.append(.int(now)) }
        }
        if let priority { sets.append("priority=?"); binds.append(.text(priority.rawValue)) }
        if let dueDate { sets.append("due_date=?"); binds.append(dueDate.map { .int(Int64($0.timeIntervalSince1970)) } ?? .null) }
        if let tags { sets.append("tags=?"); binds.append(.text(encodeTags(tags))) }
        guard !sets.isEmpty else { return }
        sets.append("updated_at=?"); binds.append(.int(now))
        binds.append(.int(id))
        try runWrite("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id=?;", binds)

        // History: log discrete-field changes (skip free-text title/detail — autosave makes them noisy).
        if let old {
            if let status, status != old.status { logEvent(id, "status", old.status.display, status.display) }
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

    /// Duplicate a task. With no target it clones into the same project; with a
    /// target project id it copies there (original kept). The copy gets a fresh code.
    /// Composes getTask/createTask (each takes the lock) — must NOT hold the lock here.
    @discardableResult
    public func duplicateTask(id: Int64, toProjectId: Int64? = nil) throws -> TodoTask {
        let t = try getTask(id: id)
        return try createTask(
            projectId: toProjectId ?? t.projectId,
            title: t.title,
            detail: t.detail,
            link: t.link,
            status: t.status
        )
    }

    /// Move a task to another project, placing it at the end of that project's list.
    /// The code is left unchanged so existing references stay valid.
    public func moveTask(id: Int64, toProjectId: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        let oldCode = getTaskUnlocked(id).flatMap { queryString("SELECT code FROM projects WHERE id=?;", [.int($0.projectId)]) } ?? ""
        let newCode = queryString("SELECT code FROM projects WHERE id=?;", [.int(toProjectId)]) ?? ""
        try runWrite(
            """
            UPDATE tasks
            SET project_id=?,
                sort_order=(SELECT COALESCE(MAX(sort_order)+1,0) FROM tasks WHERE project_id=?),
                updated_at=?
            WHERE id=?;
            """,
            [.int(toProjectId), .int(toProjectId), .int(Int64(Date().timeIntervalSince1970)), .int(id)]
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

    /// Merge tags into a task (keeps existing, adds new uniquely). Composes get/update.
    public func addTags(toTaskId id: Int64, tags: [String]) throws {
        let t = try getTask(id: id)
        var merged = t.tags
        for tag in tags.map({ $0.trimmingCharacters(in: .whitespaces) }) where !tag.isEmpty && !merged.contains(tag) {
            merged.append(tag)
        }
        try updateTask(id: id, tags: merged)
    }

    private func taskFromRow(_ stmt: OpaquePointer?) -> TodoTask {
        // Columns: id, code, project_id, title, detail, link, status, priority, due_date, tags,
        //          started_at, completed_at, effort_seconds, created_at, updated_at, sort_order
        func date(_ i: Int32) -> Date? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, i))
        }
        return TodoTask(
            id: sqlite3_column_int64(stmt, 0),
            code: colText(stmt, 1),
            projectId: sqlite3_column_int64(stmt, 2),
            title: colText(stmt, 3),
            detail: colText(stmt, 4),
            link: colTextOpt(stmt, 5),
            status: TaskStatus(rawValue: colText(stmt, 6)) ?? .todo,
            priority: Priority(rawValue: colText(stmt, 7)) ?? .none,
            dueDate: date(8),
            tags: decodeTags(colText(stmt, 9)),
            startedAt: date(10),
            completedAt: date(11),
            effortSeconds: Int(sqlite3_column_int64(stmt, 12)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14)),
            sortOrder: Int(sqlite3_column_int64(stmt, 15))
        )
    }

    // Tags are stored as a comma-separated string.
    private func encodeTags(_ tags: [String]) -> String {
        tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
    }
    private func decodeTags(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
    case text(String)
    case null
}
