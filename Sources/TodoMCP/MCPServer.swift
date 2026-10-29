import Foundation

/// Minimal MCP server speaking JSON-RPC 2.0 over stdio (newline-delimited JSON).
/// Implements: initialize, tools/list, tools/call. No external SDK.
final class MCPServer {
    private let store: Store

    init() {
        do {
            // Allow overriding the DB location (testing, alternate vaults).
            if let path = ProcessInfo.processInfo.environment["TODO_DB_PATH"], !path.isEmpty {
                store = try Store(url: URL(fileURLWithPath: path))
            } else {
                store = try Store()
            }
        } catch {
            FileHandle.standardError.write("todo-mcp: failed to open store: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    func run() {
        // Read newline-delimited JSON-RPC messages from stdin.
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            handle(msg)
        }
    }

    // MARK: - Dispatch

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "todo-mcp", "version": "1.0.0"]
            ])
        case "notifications/initialized":
            break // notification, no response
        case "tools/list":
            respond(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            handleToolCall(id: id, params: msg["params"] as? [String: Any] ?? [:])
        default:
            if id != nil {
                respondError(id: id, code: -32601, message: "method not found: \(method)")
            }
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try invoke(tool: name, args: args)
            respond(id: id, result: [
                "content": [["type": "text", "text": text]]
            ])
        } catch {
            // Tool-level error surfaced to the model via isError flag.
            respond(id: id, result: [
                "content": [["type": "text", "text": "Error: \(error)"]],
                "isError": true
            ])
        }
    }

    // MARK: - Tool implementations

    private func invoke(tool: String, args: [String: Any]) throws -> String {
        switch tool {
        case "list_projects":
            return try jsonString(store.listProjects().map(projectDict))

        case "create_project":
            let name = try requireString(args, "name")
            let desc = args["description"] as? String ?? ""
            return try jsonString(projectDict(store.createProject(name: name, detail: desc)))

        case "rename_project":
            try store.renameProject(id: try resolveProjectId(args, idKey: "id", codeKey: "code"), name: try requireString(args, "name"))
            return "renamed"

        case "update_project":
            try store.updateProject(
                id: try resolveProjectId(args, idKey: "id", codeKey: "code"),
                name: args["name"] as? String,
                detail: args["description"] as? String
            )
            return "updated"

        case "delete_project":
            try store.deleteProject(id: try resolveProjectId(args, idKey: "id", codeKey: "code"))
            return "deleted"

        case "list_tasks":
            let pid: Int64?
            if args["project_id"] != nil || args["project_code"] != nil {
                pid = try resolveProjectId(args, idKey: "project_id", codeKey: "project_code")
            } else {
                pid = nil
            }
            return try jsonString(taskDicts(store.listTasks(projectId: pid)))

        case "get_task":
            return try jsonString(taskDict(store.getTask(id: try resolveTaskId(args))))

        case "create_task":
            // Optional parent (subtask). If given and no project is specified,
            // the subtask inherits the parent's project.
            let parentId: Int64? = (args["parent_id"] != nil || args["parent_code"] != nil)
                ? try resolveTaskId(args, idKey: "parent_id", codeKey: "parent_code")
                : nil
            // Enforce the one-level nesting invariant: a subtask cannot itself be a
            // parent. The SwiftUI path enforces this (SubtaskRow has no "+ subtask");
            // guard the MCP path too so agents can't create unreachable grandchildren.
            if let parentId, try store.getTask(id: parentId).parentId != nil {
                throw MCPError.invalidArg("parent must be a top-level task; subtasks support only one level of nesting")
            }
            // A subtask must not recur — on completion a recurring task spawns a fresh
            // top-level occurrence, so a recurring subtask would leak a detached dupe.
            if parentId != nil, let rec = args["recurrence"] as? String, !rec.isEmpty {
                throw MCPError.invalidArg("a subtask cannot recur; recurrence is only valid on top-level tasks")
            }
            let projectId: Int64
            if args["project_id"] != nil || args["project_code"] != nil {
                projectId = try resolveProjectId(args, idKey: "project_id", codeKey: "project_code")
            } else if let parentId {
                projectId = try store.getTask(id: parentId).projectId
            } else {
                projectId = try resolveProjectId(args, idKey: "project_id", codeKey: "project_code")
            }
            let task = try store.createTask(
                projectId: projectId,
                title: try requireString(args, "title"),
                detail: args["detail"] as? String ?? "",
                link: args["link"] as? String,
                status: parseStatus(args["status"]) ?? .todo,
                waitingOn: try parseWaitingOn(args["waiting_on"]),
                waitingReason: try waitingReasonArg(args) ?? nil,
                priority: parsePriority(args["priority"]) ?? .none,
                dueDate: parseDate(args["due_date"]),
                tags: parseTags(args["tags"]) ?? [],
                recurrence: args["recurrence"] as? String,
                parentId: parentId,
                estimateSeconds: (parseMinutes(args["estimate_minutes"]) ?? 0) * 60
            )
            return try jsonString(taskDict(task))

        case "update_task":
            let id = try resolveTaskId(args)
            // link uses double-optional: key absent (.none) = leave alone;
            // key present (.some) = set to the string, or clear if JSON null.
            let linkArg: String??
            if args.keys.contains("link") {
                linkArg = .some(args["link"] as? String)
            } else {
                linkArg = .none
            }
            // due_date same double-optional semantics: present+null clears it.
            let dueArg: Date??
            if args.keys.contains("due_date") {
                dueArg = .some(parseDate(args["due_date"]))
            } else {
                dueArg = .none
            }
            // recurrence double-optional: present+null clears it, absent leaves alone.
            let recurArg: String??
            if args.keys.contains("recurrence") {
                recurArg = .some(args["recurrence"] as? String)
            } else {
                recurArg = .none
            }
            // A subtask must not recur — reject a non-nil recurrence on a subtask.
            if let rec = args["recurrence"] as? String, !rec.isEmpty,
               try store.getTask(id: id).parentId != nil {
                throw MCPError.invalidArg("a subtask cannot recur; recurrence is only valid on top-level tasks")
            }
            try store.updateTask(
                id: id,
                title: args["title"] as? String,
                detail: args["detail"] as? String,
                link: linkArg,
                status: parseStatus(args["status"]),
                priority: parsePriority(args["priority"]),
                dueDate: dueArg,
                tags: parseTags(args["tags"]),
                recurrence: recurArg,
                estimateSeconds: parseMinutes(args["estimate_minutes"]).map { $0 * 60 },
                waitingOn: try parseWaitingOn(args["waiting_on"]),
                waitingReason: try waitingReasonArg(args)
            )
            return try jsonString(taskDict(store.getTask(id: id)))

        case "delete_task":
            try store.deleteTask(id: try resolveTaskId(args))
            return "deleted"

        case "duplicate_task":
            // Optional target project (id or code): clone in place, or copy elsewhere.
            let toPid: Int64? = (args["to_project_id"] != nil || args["to_project_code"] != nil)
                ? try resolveProjectId(args, idKey: "to_project_id", codeKey: "to_project_code")
                : nil
            let copy = try store.duplicateTask(id: try resolveTaskId(args), toProjectId: toPid)
            return try jsonString(taskDict(copy))

        case "move_task":
            let tid = try resolveTaskId(args)
            try store.moveTask(id: tid, toProjectId: try resolveProjectId(args, idKey: "to_project_id", codeKey: "to_project_code"))
            return try jsonString(taskDict(store.getTask(id: tid)))

        case "bulk_update_tasks":
            let ids = try resolveTaskIds(args)
            let dueArg: Date??
            if args.keys.contains("due_date") { dueArg = .some(parseDate(args["due_date"])) } else { dueArg = .none }
            // One transaction for the whole batch: any bad task leaves every task unchanged.
            try store.bulkUpdateTasks(
                ids: ids, status: parseStatus(args["status"]), priority: parsePriority(args["priority"]),
                dueDate: dueArg, addTags: parseTags(args["add_tags"]),
                waitingOn: try parseWaitingOn(args["waiting_on"]), waitingReason: try waitingReasonArg(args))
            return "updated \(ids.count) tasks"

        case "bulk_move_tasks":
            let ids = try resolveTaskIds(args)
            let toPid = try resolveProjectId(args, idKey: "to_project_id", codeKey: "to_project_code")
            let copy = (args["copy"] as? Bool) ?? false
            for id in ids {
                if copy { _ = try store.duplicateTask(id: id, toProjectId: toPid, keepStatus: true) }
                else { try store.moveTask(id: id, toProjectId: toPid) }
            }
            return "\(copy ? "copied" : "moved") \(ids.count) tasks"

        case "bulk_delete_tasks":
            let ids = try resolveTaskIds(args)
            for id in ids { try store.deleteTask(id: id) }
            return "deleted \(ids.count) tasks"

        case "get_task_history":
            let id = try resolveTaskId(args)
            let events = try store.taskHistory(taskId: id).map { e -> [String: Any] in
                ["timestamp": iso(e.timestamp), "field": e.field, "old": e.oldValue, "new": e.newValue]
            }
            return try jsonString(events)

        case "add_dependency":
            let tid = try resolveTaskId(args)
            let dep = try resolveTaskId(args, idKey: "depends_on_id", codeKey: "depends_on_code")
            try store.addDependency(taskId: tid, dependsOnId: dep)
            return try jsonString(taskDict(store.getTask(id: tid)))

        case "remove_dependency":
            let tid = try resolveTaskId(args)
            let dep = try resolveTaskId(args, idKey: "depends_on_id", codeKey: "depends_on_code")
            try store.removeDependency(taskId: tid, dependsOnId: dep)
            return try jsonString(taskDict(store.getTask(id: tid)))

        case "list_templates":
            return try jsonString(store.listTemplates().map(templateDict))

        case "create_template":
            let tpl = try store.createTemplate(
                name: try requireString(args, "name"),
                title: try requireString(args, "title"),
                detail: args["detail"] as? String ?? "",
                priority: parsePriority(args["priority"]) ?? .none,
                tags: parseTags(args["tags"]) ?? [],
                estimateSeconds: (parseMinutes(args["estimate_minutes"]) ?? 0) * 60
            )
            return try jsonString(templateDict(tpl))

        case "new_task_from_template":
            let templateId = try requireInt(args, "template_id")
            let pid = try resolveProjectId(args, idKey: "project_id", codeKey: "project_code")
            let task = try store.instantiateTemplate(id: templateId, intoProjectId: pid)
            return try jsonString(taskDict(task))

        case "daily_stats":
            let stats = try store.dailyStats()
            return try jsonString([
                "date": stats.date,
                "completed_pomodoros": stats.completedPomodoros,
                "total_focus_minutes": stats.totalFocusSeconds / 60
            ] as [String: Any])

        default:
            throw MCPError.unknownTool(tool)
        }
    }

    // MARK: - Serialization helpers

    private func projectDict(_ p: Project) -> [String: Any] {
        ["id": p.id, "code": p.code, "name": p.name, "description": p.detail, "created_at": iso(p.createdAt)]
    }

    /// The shared task serializer behind every tool that returns tasks. Other tasks are
    /// referenced by code (`parent`, `depends_on`), and null, empty or default-valued
    /// fields are omitted — `status` is always present, `blocked` only when true.
    /// Relations are resolved once for the whole batch, not per task. Never throws:
    /// mutating tools serialize after their write has committed, so a failed relations
    /// read degrades the output (numeric `parent_id`, no deps) instead of failing the call.
    private func taskDicts(_ tasks: [TodoTask]) -> [[String: Any]] {
        let rel = (try? store.taskRelations(for: tasks)) ?? TaskRelations()
        return tasks.map { taskDict($0, rel) }
    }

    private func taskDict(_ t: TodoTask) -> [String: Any] {
        taskDicts([t])[0]
    }

    private func taskDict(_ t: TodoTask, _ rel: TaskRelations) -> [String: Any] {
        var d: [String: Any] = [
            "id": t.id,
            "code": t.code,
            "project_id": t.projectId,
            "title": t.title,
            "status": t.status.rawValue,
            "created_at": iso(t.createdAt),
            "updated_at": iso(t.updatedAt)
        ]
        if let on = t.waitingOn { d["waiting_on"] = on.rawValue }
        if let reason = t.waitingReason, !reason.isEmpty { d["waiting_reason"] = reason }
        if !t.detail.isEmpty { d["detail"] = t.detail }
        if let link = t.link, !link.isEmpty { d["link"] = link }
        if t.priority != Priority.none { d["priority"] = t.priority.rawValue }
        if let due = t.dueDate { d["due_date"] = iso(due) }
        if !t.tags.isEmpty { d["tags"] = t.tags }
        if let rec = t.recurrence, !rec.isEmpty { d["recurrence"] = rec }
        if let pid = t.parentId {
            // Fall back to the numeric id so a subtask never looks top-level.
            if let code = rel.parentCodes[pid], !code.isEmpty { d["parent"] = code } else { d["parent_id"] = pid }
        }
        if let deps = rel.dependsOnCodes[t.id], !deps.isEmpty { d["depends_on"] = deps }
        if rel.blockedIds.contains(t.id) { d["blocked"] = true }
        if let started = t.startedAt { d["started_at"] = iso(started) }
        if let completed = t.completedAt { d["completed_at"] = iso(completed) }
        // Whole minutes as before, but a non-zero sub-minute value shows as 1, not omitted.
        if t.effortSeconds > 0 { d["effort_minutes"] = max(1, t.effortSeconds / 60) }
        if t.estimateSeconds > 0 { d["estimate_minutes"] = max(1, t.estimateSeconds / 60) }
        return d
    }

    private func templateDict(_ t: TaskTemplate) -> [String: Any] {
        [
            "id": t.id,
            "name": t.name,
            "title": t.title,
            "detail": t.detail,
            "priority": t.priority.rawValue,
            "tags": t.tags,
            "estimate_minutes": t.estimateSeconds / 60,
            "estimate_seconds": t.estimateSeconds,
            "created_at": iso(t.createdAt)
        ]
    }

    private func parseDate(_ v: Any?) -> Date? {
        if let n = v as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = v as? String, !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // avoid Buddhist/other calendars
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: s)
    }

    /// Parse an integer minutes argument (accepts JSON number or numeric string). nil if absent/invalid.
    private func parseMinutes(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return max(0, n.intValue) }
        if let s = v as? String, let n = Int(s) { return max(0, n) }
        return nil
    }

    private func parseTags(_ v: Any?) -> [String]? {
        if let arr = v as? [String] { return arr }
        if let s = v as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return nil
    }

    private func parsePriority(_ v: Any?) -> Priority? {
        guard let s = v as? String else { return nil }
        return Priority(rawValue: s)
    }

    /// Resolve a list of task ids from `ids` (array of int) and/or `codes` (array of string).
    private func resolveTaskIds(_ args: [String: Any]) throws -> [Int64] {
        var ids: [Int64] = []
        if let arr = args["ids"] as? [Any] {
            for v in arr {
                if let n = v as? NSNumber { ids.append(n.int64Value) }
                else if let s = v as? String, let n = Int64(s) { ids.append(n) }
            }
        }
        if let arr = args["codes"] as? [String] {
            for c in arr { if let id = store.taskId(forCode: c) { ids.append(id) } }
        }
        guard !ids.isEmpty else { throw MCPError.missingArg("ids or codes") }
        return ids
    }

    /// Resolve a task id from either `id` (int) or `code` (string handle like "GEN-3").
    private func resolveTaskId(_ args: [String: Any]) throws -> Int64 {
        try resolveTaskId(args, idKey: "id", codeKey: "code")
    }

    /// Resolve a task id from arbitrary `<idKey>` (int) or `<codeKey>` (string code).
    private func resolveTaskId(_ args: [String: Any], idKey: String, codeKey: String) throws -> Int64 {
        if let n = args[idKey] as? NSNumber { return n.int64Value }
        if let s = args[idKey] as? String, let n = Int64(s) { return n }
        if let code = args[codeKey] as? String, let id = store.taskId(forCode: code) { return id }
        throw MCPError.missingArg("\(idKey) or \(codeKey)")
    }

    /// Resolve a project id from `<idKey>` (int) or `<codeKey>` (string code).
    private func resolveProjectId(_ args: [String: Any], idKey: String, codeKey: String) throws -> Int64 {
        if let n = args[idKey] as? NSNumber { return n.int64Value }
        if let s = args[idKey] as? String, let n = Int64(s) { return n }
        if let code = args[codeKey] as? String, let id = store.projectId(forCode: code) { return id }
        throw MCPError.missingArg("\(idKey) or \(codeKey)")
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    private func parseStatus(_ v: Any?) -> TaskStatus? {
        guard let s = v as? String else { return nil }
        return TaskStatus(rawValue: s)
    }

    /// `waiting_on`: absent or null = not given; otherwise it must be a known value.
    private func parseWaitingOn(_ v: Any?) throws -> WaitingOn? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s = v as? String, let on = WaitingOn(rawValue: s) else {
            throw MCPError.invalidArg("waiting_on must be one of: \(WaitingOn.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return on
    }

    /// `waiting_reason` double-optional: absent leaves it alone, present+null clears it.
    /// Any other non-string value is rejected rather than read as a clear.
    private func waitingReasonArg(_ args: [String: Any]) throws -> String?? {
        guard let v = args["waiting_reason"] else { return .none }
        if v is NSNull { return .some(nil) }
        guard let s = v as? String else { throw MCPError.invalidArg("waiting_reason must be a string or null") }
        return .some(s)
    }

    private func requireString(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw MCPError.missingArg(key) }
        return v
    }

    private func requireInt(_ args: [String: Any], _ key: String) throws -> Int64 {
        if let n = args[key] as? NSNumber { return n.int64Value }
        if let s = args[key] as? String, let n = Int64(s) { return n }
        throw MCPError.missingArg(key)
    }

    private func jsonString(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - JSON-RPC output

    private func respond(id: Any?, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func respondError(id: Any?, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var s = String(data: data, encoding: .utf8) else { return }
        s += "\n"
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }
}

enum MCPError: Error, CustomStringConvertible {
    case missingArg(String)
    case invalidArg(String)
    case unknownTool(String)
    var description: String {
        switch self {
        case .missingArg(let k): return "missing or invalid argument: \(k)"
        case .invalidArg(let m): return "invalid argument: \(m)"
        case .unknownTool(let t): return "unknown tool: \(t)"
        }
    }
}
