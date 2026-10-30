import Foundation
import IOKit.pwr_mgt

/// Minimal MCP server speaking JSON-RPC 2.0 over stdio (newline-delimited JSON).
/// Implements: initialize, tools/list, tools/call, notifications/cancelled. No external SDK.
///
/// Requests are handled one at a time on the reading thread, except wait_for_answers,
/// which runs on its own thread: it can wait for hours, and meanwhile the client keeps
/// calling other tools (Claude Code moves a call that runs past two minutes to a
/// background task) and may cancel it. Output lines are serialized by `writeLock`.
final class MCPServer: @unchecked Sendable {
    private let store: Store
    private let writeLock = NSLock()
    // The latest wait for each request key (`requestKey`), and the waits the client
    // cancelled. Each wait has its own token, so a request id the client reuses while an
    // earlier, cancelled wait is still winding down never mixes the two up.
    private let waitLock = NSLock()
    private var activeWaits: [String: UUID] = [:]
    private var cancelledWaits = Set<UUID>()

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
        // Read newline-delimited JSON-RPC messages from stdin. EOF (the client is gone)
        // ends the process, and with it any wait still running.
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

    /// What the server tells the client's model up front (MCP `instructions`): when to use
    /// QuestBits at all, and to call get_guide for the rest (AgentGuide).
    static let instructions = AgentGuide.instructions

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any], "prompts": [:] as [String: Any]],
                "serverInfo": ["name": "todo-mcp", "version": AgentGuide.version],
                "instructions": Self.instructions
            ])
        case "notifications/initialized":
            break // notification, no response
        case "notifications/cancelled":
            // The client gave up on a request (Esc, TaskStop, its own timeout). Only a wait
            // runs long enough to be cancelled; anything else has already answered.
            if let params = msg["params"] as? [String: Any], let rid = params["requestId"] {
                let key = Self.requestKey(rid)
                waitLock.lock()
                if let token = activeWaits[key] { cancelledWaits.insert(token) }
                waitLock.unlock()
            }
        case "tools/list":
            respond(id: id, result: ["tools": Self.toolDefinitions])
        case "prompts/list":
            respond(id: id, result: ["prompts": Self.promptDefinitions])
        case "prompts/get":
            let params = msg["params"] as? [String: Any] ?? [:]
            let args = params["arguments"] as? [String: Any] ?? [:]
            switch params["name"] as? String {
            case AgentGuide.workPrompt:
                guard let code = (args["code"] as? String)?.trimmingCharacters(in: .whitespaces), !code.isEmpty else {
                    return respondError(id: id, code: -32602, message: "missing argument: code (the task's code, e.g. QUE-3)")
                }
                respondPrompt(id: id, description: "Work on QuestBits task \(code)", text: AgentGuide.workPromptText(code: code))
            case AgentGuide.resumePrompt:
                respondPrompt(id: id, description: "Pick up answers to your QuestBits questions", text: AgentGuide.resumePromptText)
            default:
                respondError(id: id, code: -32602, message: "unknown prompt: \(params["name"] as? String ?? "")")
            }
        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            if params["name"] as? String == "wait_for_answers" {
                startWait(id: id, params: params)
            } else {
                handleToolCall(id: id, params: params)
            }
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
            respondText(id: id, text)
        } catch {
            respondToolError(id: id, error)
        }
    }

    /// MCP prompts advertised via prompts/list; Claude Code offers them as
    /// /mcp__<server>__<name> commands (the app shows them with a copy button).
    static let promptDefinitions: [[String: Any]] = [
        ["name": AgentGuide.workPrompt,
         "description": "Work on a QuestBits task: read its guide and the task, pick up answers, then do it.",
         "arguments": [["name": "code", "description": "the task's code, e.g. QUE-3", "required": true]]],
        ["name": AgentGuide.resumePrompt,
         "description": "Pick up the user's answers to your QuestBits questions and carry on.",
         "arguments": [] as [[String: Any]]],
    ]

    private func respondPrompt(id: Any?, description: String, text: String) {
        respond(id: id, result: [
            "description": description,
            "messages": [["role": "user", "content": ["type": "text", "text": text]]],
        ])
    }

    private func respondText(id: Any?, _ text: String) {
        respond(id: id, result: ["content": [["type": "text", "text": text]]])
    }

    /// Tool-level error surfaced to the model via isError flag.
    private func respondToolError(id: Any?, _ error: Error) {
        respond(id: id, result: [
            "content": [["type": "text", "text": "Error: \(error)"]],
            "isError": true
        ])
    }

    /// A request id as a set key: ids are JSON numbers or strings, so 2 and "2" differ.
    private static func requestKey(_ id: Any?) -> String {
        if let s = id as? String { return "s:" + s }
        if let n = id as? NSNumber { return "n:" + n.stringValue }
        return "?"
    }

    // MARK: - wait_for_answers

    static let defaultWaitMinutes = 240
    static let maxWaitMinutes = 1440
    static let waitPollSeconds = 2.5
    static let waitProgressSeconds = 60.0

    /// Validate the arguments here (a bad one answers at once), then wait on a thread
    /// of its own so the reader keeps handling other calls and the cancellation.
    private func startWait(id: Any?, params: [String: Any]) {
        let args = params["arguments"] as? [String: Any] ?? [:]
        let filter: (projectId: Int64?, sessionId: String?)
        let minutes: Int
        do {
            filter = try questionFilterArgs(args)
            minutes = try limitArg(args, "max_minutes", default: Self.defaultWaitMinutes, max: Self.maxWaitMinutes)
        } catch {
            respondToolError(id: id, error)
            return
        }
        let token = (params["_meta"] as? [String: Any])?["progressToken"]
        let key = Self.requestKey(id), waitId = UUID()
        waitLock.lock(); activeWaits[key] = waitId; waitLock.unlock()
        Thread.detachNewThread { [self] in
            waitForAnswers(id: id, key: key, waitId: waitId, token: token, projectId: filter.projectId,
                           sessionId: filter.sessionId, minutes: minutes)
        }
    }

    /// Poll the database (reads only, no write lock) every few seconds until an answer
    /// matches, the time is up, or the client cancels. A progress notification each
    /// minute keeps the client's idle timeout from firing (Claude Code aborts a stdio
    /// call after 30 silent minutes). A power assertion keeps the Mac from idle sleep
    /// meanwhile: asleep, nothing is answered, and on wake the client counts the sleep
    /// as silence. A closed lid still sleeps. A cancelled wait sends no response.
    private func waitForAnswers(id: Any?, key: String, waitId: UUID, token: Any?, projectId: Int64?,
                                sessionId: String?, minutes: Int) {
        var assertion: IOPMAssertionID = 0
        let asserted = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "QuestBits is waiting for your answers" as CFString, &assertion) == kIOReturnSuccess
        defer {
            if asserted { IOPMAssertionRelease(assertion) }
            waitLock.lock()
            if activeWaits[key] == waitId { activeWaits[key] = nil }
            cancelledWaits.remove(waitId)
            waitLock.unlock()
        }
        let start = Date()
        let deadline = start.addingTimeInterval(TimeInterval(minutes * 60))
        var lastProgress = start
        var progress = 0
        while true {
            waitLock.lock(); let cancelled = cancelledWaits.contains(waitId); waitLock.unlock()
            if cancelled { return }
            do {
                let (open, answered) = try store.questionCounts(projectId: projectId, sessionId: sessionId)
                // Done: an answer is in, nothing is left to wait for, or the time is up.
                if answered > 0 || open == 0 || Date() >= deadline {
                    respondText(id: id, try answersJSON(projectId: projectId, sessionId: sessionId,
                                                        waitedSeconds: Int(Date().timeIntervalSince(start))))
                    return
                }
                if let token, Date().timeIntervalSince(lastProgress) >= Self.waitProgressSeconds {
                    progress += 1
                    lastProgress = Date()
                    let waited = Int(lastProgress.timeIntervalSince(start)) / 60
                    write(["jsonrpc": "2.0", "method": "notifications/progress",
                           "params": ["progressToken": token, "progress": progress,
                                      "message": "waiting for answers: \(open) open, \(waited) min so far"]])
                }
            } catch {
                respondToolError(id: id, error)
                return
            }
            Thread.sleep(forTimeInterval: Self.waitPollSeconds)
        }
    }

    /// get_answers / wait_for_answers output: the answered questions (oldest first) and
    /// how many are still open, for the same project / session filter. Only active projects
    /// count, as in the app: a question in an archived project cannot be answered there.
    private func answersJSON(projectId: Int64?, sessionId: String?, waitedSeconds: Int? = nil) throws -> String {
        let answered = try store.questions(statuses: [.answered], projectId: projectId, sessionId: sessionId,
                                           activeOnly: true)
        let open = try store.questionCounts(projectId: projectId, sessionId: sessionId).open
        var d: [String: Any] = ["answered": answered.map(questionDict), "open": open]
        if let waitedSeconds { d["waited_minutes"] = waitedSeconds / 60 }
        return try jsonString(d)
    }

    /// `project_id`/`project_code` and `session` for the question tools; all optional.
    private func questionFilterArgs(_ args: [String: Any]) throws -> (projectId: Int64?, sessionId: String?) {
        let pid = given(args, "project_id", "project_code")
            ? try resolveProjectId(args, idKey: "project_id", codeKey: "project_code") : nil
        return (pid, try sessionArg(args))
    }

    // MARK: - Tool implementations

    private func invoke(tool: String, args: [String: Any]) throws -> String {
        switch tool {
        case "list_projects":
            let includeArchived = try boolArg(args, "include_archived") ?? false
            return try jsonString(store.listProjects(includeArchived: includeArchived).map(projectDict))

        case "create_project":
            let name = try requireString(args, "name")
            let desc = args["description"] as? String ?? ""
            var template: GuideTemplate?
            if let raw = args["guide_template"], !(raw is NSNull) {
                guard let s = raw as? String, let t = GuideTemplate(rawValue: s) else {
                    throw MCPError.invalidArg("guide_template must be one of: "
                        + GuideTemplate.allCases.map(\.rawValue).joined(separator: ", "))
                }
                template = t
            }
            let p = try store.createProject(name: name, detail: desc, code: args["code"] as? String,
                                            guideTemplate: template,
                                            author: .agent, sessionId: try sessionArg(args))
            var d = projectDict(p)
            if let template { d["guide_template"] = template.rawValue }
            return try jsonString(d)

        case "rename_project":
            try store.renameProject(id: try resolveProjectId(args, idKey: "id", codeKey: "code"), name: try requireString(args, "name"))
            return "renamed"

        case "update_project":
            let pid = try resolveProjectId(args, idKey: "id", codeKey: "code")
            // The code first: a refused code leaves the name and description unchanged too.
            var newCode: String?
            if let raw = args["new_code"], !(raw is NSNull) {
                guard let s = raw as? String else { throw MCPError.invalidArg("new_code must be a string") }
                newCode = try store.setProjectCode(id: pid, code: s)
            }
            try store.updateProject(id: pid, name: args["name"] as? String, detail: args["description"] as? String)
            return newCode.map { "updated; the project's code is now \($0) (its tasks keep their codes)" } ?? "updated"

        case "archive_project", "unarchive_project":
            let archive = tool == "archive_project"
            let result = try store.setProjectArchived(id: try resolveProjectId(args, idKey: "id", codeKey: "code"),
                                                      archived: archive)
            var dict = projectDict(result.project)
            // Archiving keeps open tasks open; say how many, as the app's confirmation does.
            if archive && result.openTasks > 0 { dict["open_tasks"] = result.openTasks }
            return try jsonString(dict)

        case "delete_project":
            try store.deleteProject(id: try resolveProjectId(args, idKey: "id", codeKey: "code"))
            return "deleted"

        case "list_tasks":
            // Every argument is validated before the query; an explicit null means not given.
            let compact: Bool
            switch args["view"] {
            case nil, is NSNull: compact = true
            case let v as String where v == "compact" || v == "full": compact = v == "compact"
            default: throw MCPError.invalidArg("view must be \"compact\" or \"full\"")
            }
            var filter = TaskFilter(statuses: try parseStatusFilter(args["status"]),
                                    includeArchived: try boolArg(args, "include_archived") ?? false)
            if given(args, "project_id", "project_code") {
                filter.projectId = try resolveProjectId(args, idKey: "project_id", codeKey: "project_code")
            }
            if given(args, "parent_id", "parent_code") {
                filter.parentId = try resolveTaskId(args, idKey: "parent_id", codeKey: "parent_code")
            }
            if given(args, "tag") {
                guard let tag = (args["tag"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !tag.isEmpty, !tag.contains(",") else {
                    throw MCPError.invalidArg("tag must be a single non-empty tag")
                }
                filter.tag = tag
            }
            return try jsonString(readTaskDicts(store.listTasks(matching: filter), compact: compact))

        case "get_task":
            let limit = try notesLimitArg(args)
            let task = try store.getTask(id: try resolveTaskId(args))
            var d = try readTaskDicts([task])[0]
            if limit > 0 {
                // One extra row tells whether older notes were left out.
                let notes = try store.notes(taskId: task.id, limit: limit + 1)
                if !notes.isEmpty { d["notes"] = notes.prefix(limit).map(noteDict) }
                if notes.count > limit { d["more_notes"] = true }
            }
            // Images in the detail are stored as attachments/<name>; give their files, so an
            // agent can open them.
            let files = attachmentFiles(in: task.detail)
            if !files.isEmpty { d["attachments"] = files }
            // Questions still in play: open (waiting on the user) or answered (to resume).
            let questions = try store.questions(statuses: [.open, .answered], taskId: task.id)
            if !questions.isEmpty { d["questions"] = questions.map(questionDict) }
            return try jsonString(d)

        case "inbox":
            // Compact: what to answer and since when. waiting_on only when external tasks
            // are included (otherwise every item waits on the user).
            let includeExternal = try boolArg(args, "include_external") ?? false
            // Open questions by task, so an item says what it asks.
            let open = Dictionary(grouping: try store.questions(statuses: [.open], activeOnly: true), by: \.taskId)
            return try jsonString(store.inbox(includeExternal: includeExternal).map { item in
                let t = item.task
                var d: [String: Any] = ["code": taskHandle(code: t.code, id: t.id), "title": t.title,
                                        "project": item.projectCode,
                                        "waiting_since": iso(t.waitingSince ?? t.updatedAt)]
                if includeExternal, let on = t.waitingOn { d["waiting_on"] = on.rawValue }
                if let reason = t.waitingReason, !reason.isEmpty { d["waiting_reason"] = reason }
                if let qs = open[t.id] { d["questions"] = qs.map { ["id": $0.id, "question": $0.prompt] as [String: Any] } }
                return d
            })

        case "add_note":
            // Store.addNote trims and rejects empty text.
            guard let text = args["text"] as? String else { throw MCPError.missingArg("text") }
            // Always the agent: only the user, in the app, writes (and edits) as the user.
            let added = try store.addNote(taskId: try resolveTaskId(args), text: text, kind: try parseNoteKind(args["kind"]),
                                          author: .agent, sessionId: try sessionArg(args))
            var d: [String: Any] = ["note_id": added.note.id, "task": taskHandle(code: added.taskCode, id: added.note.taskId),
                                    "ts": iso(added.note.timestamp)]
            if added.note.kind != .note { d["kind"] = added.note.kind.rawValue }
            return try jsonString(d)

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
                status: try statusArg(args) ?? .todo,
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
            // A subtask must not recur — reject a non-nil recurrence on a task that is a
            // subtask after this update (a parent_code null in it makes it top-level).
            let parent = try parentArg(args)
            if let rec = args["recurrence"] as? String, !rec.isEmpty,
               try parent ?? store.getTask(id: id).parentId != nil {
                throw MCPError.invalidArg("a subtask cannot recur; recurrence is only valid on top-level tasks")
            }
            let status = try statusArg(args)
            let note = try updateNoteArg(args, status: status)
            try store.updateTask(
                id: id,
                title: args["title"] as? String,
                detail: args["detail"] as? String,
                link: linkArg,
                status: status,
                priority: parsePriority(args["priority"]),
                dueDate: dueArg,
                tags: parseTags(args["tags"]),
                recurrence: recurArg,
                estimateSeconds: parseMinutes(args["estimate_minutes"]).map { $0 * 60 },
                waitingOn: try parseWaitingOn(args["waiting_on"]),
                waitingReason: try waitingReasonArg(args),
                parentId: parent,
                note: note
            )
            return try jsonString(taskDict(store.getTask(id: id)))

        case "delete_task":
            try store.deleteTask(id: try resolveTaskId(args))
            return "deleted"

        case "duplicate_task":
            // Optional target project (id or code): clone in place (a fresh todo), or copy
            // to another project (status and times kept) — Store.duplicateTask's rule.
            let toPid: Int64? = (args["to_project_id"] != nil || args["to_project_code"] != nil)
                ? try resolveProjectId(args, idKey: "to_project_id", codeKey: "to_project_code")
                : nil
            let copy = try store.duplicateTask(id: try resolveTaskId(args), toProjectId: toPid)
            return try jsonString(taskDict(copy))

        case "move_task":
            let tid = try resolveTaskId(args)
            let toPid = try resolveProjectId(args, idKey: "to_project_id", codeKey: "to_project_code")
            try store.moveTask(id: tid, toProjectId: toPid)
            return try jsonString(taskDict(store.getTask(id: tid)))

        case "bulk_update_tasks":
            let ids = try resolveTaskIds(args)
            let dueArg: Date??
            if args.keys.contains("due_date") { dueArg = .some(parseDate(args["due_date"])) } else { dueArg = .none }
            // One transaction for the whole batch: any bad task leaves every task unchanged.
            try store.bulkUpdateTasks(
                ids: ids, status: try statusArg(args), priority: parsePriority(args["priority"]),
                dueDate: dueArg, addTags: parseTags(args["add_tags"]),
                waitingOn: try parseWaitingOn(args["waiting_on"]), waitingReason: try waitingReasonArg(args),
                parentId: try parentArg(args))
            return "updated \(ids.count) tasks"

        case "bulk_move_tasks":
            let ids = try resolveTaskIds(args)
            let toPid = try resolveProjectId(args, idKey: "to_project_id", codeKey: "to_project_code")
            let copy = try boolArg(args, "copy") ?? false
            // One transaction for the whole batch: a missing task or an archived target
            // leaves every task where it was.
            try store.bulkMoveTasks(ids: ids, toProjectId: toPid, copy: copy)
            return "\(copy ? "copied" : "moved") \(ids.count) tasks"

        case "bulk_delete_tasks":
            let ids = try resolveTaskIds(args)
            // One transaction for the whole batch: an unknown task leaves every task in place.
            let deleted = try store.bulkDeleteTasks(ids: ids)
            return "deleted \(deleted) tasks"

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

        case "search_notes":
            guard let query = args["query"] as? String else { throw MCPError.missingArg("query") }
            let pid = given(args, "project_id", "project_code")
                ? try resolveProjectId(args, idKey: "project_id", codeKey: "project_code") : nil
            let kind: NoteKind? = given(args, "kind") ? try parseNoteKind(args["kind"], allowQuestion: true) : nil
            let limit = try limitArg(args, "limit", default: 20, max: 100)
            return try jsonString(store.searchNotes(query: query, projectId: pid, kind: kind, limit: limit).map { hit in
                var d = noteDict(hit.note)
                d["task"] = taskHandle(code: hit.taskCode, id: hit.note.taskId)
                d["title"] = hit.taskTitle
                d["project"] = hit.projectCode
                return d
            })

        case "get_note_history":
            let noteId = try requireInt(args, "note_id")
            let note = try store.note(id: noteId)
            var d = noteDict(note)
            d["edits"] = try store.noteEdits(noteId: noteId).map { ["replaced_at": iso($0.timestamp), "text": $0.text] }
            return try jsonString(d)

        case "ask_user":
            guard let prompt = args["question"] as? String else { throw MCPError.missingArg("question") }
            let kind = try questionKindArg(args)
            let options = try questionOptionsArg(args)
            let q = try store.askQuestion(
                taskId: try resolveTaskId(args), kind: kind, prompt: prompt,
                context: args["context"] as? String ?? "", options: options,
                blocksTask: try boolArg(args, "blocks_task") ?? true, sessionId: try sessionArg(args))
            var d = questionDict(q)
            if q.blocksTask { d["task_status"] = TaskStatus.waiting.rawValue }
            return try jsonString(d)

        case "get_answers":
            let filter = try questionFilterArgs(args)
            return try answersJSON(projectId: filter.projectId, sessionId: filter.sessionId)

        case "resume_question":
            let resumed = try store.resumeQuestion(id: try requireInt(args, "id"), sessionId: try sessionArg(args))
            var d = questionDict(resumed.question)
            d["task_status"] = resumed.task.status.rawValue
            return try jsonString(d)

        case "cancel_question":
            let q = try store.cancelQuestion(id: try requireInt(args, "id"), reason: args["reason"] as? String ?? "",
                                             sessionId: try sessionArg(args))
            return try jsonString(questionDict(q))

        case "get_guide":
            return try guideText(projectId: try guideProjectArg(args))

        case "update_guide":
            let pid = try guideScopeArg(args)
            // "" is a valid guide: it clears it (requireString would refuse it).
            guard let markdown = args["markdown"] as? String else { throw MCPError.missingArg("markdown") }
            let saved = try store.saveGuide(projectId: pid, markdown: markdown, author: .agent,
                                            sessionId: try sessionArg(args), reason: args["reason"] as? String)
            return try jsonString(["version": saved.id, "scope": try scopeName(pid), "ts": iso(saved.timestamp)])

        case "get_guide_history":
            let pid = try guideScopeArg(args)
            let versions = try store.guideHistory(projectId: pid, limit: Int(try limitArg(args, "limit", default: 5, max: 50)))
            return try jsonString(["scope": try scopeName(pid), "versions": versions.map(guideVersionDict)])

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
        var d: [String: Any] = ["id": p.id, "code": p.code, "name": p.name, "description": p.detail,
                                "created_at": iso(p.createdAt)]
        if let a = p.archivedAt { d["archived_at"] = iso(a) }
        // Images in the description, as for a task's detail.
        let files = attachmentFiles(in: p.detail)
        if !files.isEmpty { d["attachments"] = files }
        return d
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

    /// The serializer for read-only tools (list_tasks, get_task): nothing was written, so
    /// a failed relations read fails the call rather than returning tasks that silently
    /// lack their parent, dependencies or blocked state. `compact` is list_tasks' default
    /// view — only what an agent needs to pick a task; get_task has the rest.
    private func readTaskDicts(_ tasks: [TodoTask], compact: Bool = false) throws -> [[String: Any]] {
        let rel = try store.taskRelations(for: tasks)
        return tasks.map { compact ? compactTaskDict($0, rel) : taskDict($0, rel) }
    }

    /// How output refers to another task: its code, or its numeric id if it has no code.
    private func taskHandle(code: String?, id: Int64) -> Any {
        if let code, !code.isEmpty { return code }
        return id
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
        if let since = t.waitingSince { d["waiting_since"] = iso(since) }
        if !t.detail.isEmpty { d["detail"] = t.detail }
        if let link = t.link, !link.isEmpty { d["link"] = link }
        if t.priority != Priority.none { d["priority"] = t.priority.rawValue }
        if let due = t.dueDate { d["due_date"] = iso(due) }
        if !t.tags.isEmpty { d["tags"] = t.tags }
        if let rec = t.recurrence, !rec.isEmpty { d["recurrence"] = rec }
        if let pid = t.parentId {
            // Fall back to the numeric id so a subtask never looks top-level.
            let parent = taskHandle(code: rel.parentCodes[pid], id: pid)
            d[parent is String ? "parent" : "parent_id"] = parent
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

    /// The compact list shape: code, title, status, plus priority, parent, blocked_by
    /// (the open dependencies blocking it), tags, due_date and waiting_on only when set.
    /// No detail or timestamps; ids only where a task has no code (`taskHandle`).
    private func compactTaskDict(_ t: TodoTask, _ rel: TaskRelations) -> [String: Any] {
        var d: [String: Any] = ["code": t.code, "title": t.title, "status": t.status.rawValue]
        if t.code.isEmpty { d["id"] = t.id }
        if t.priority != Priority.none { d["priority"] = t.priority.rawValue }
        if let pid = t.parentId {
            let parent = taskHandle(code: rel.parentCodes[pid], id: pid)
            d[parent is String ? "parent" : "parent_id"] = parent
        }
        if let deps = rel.blockedBy[t.id], !deps.isEmpty {
            d["blocked_by"] = deps.map { taskHandle(code: $0.code, id: $0.id) }
        }
        if !t.tags.isEmpty { d["tags"] = t.tags }
        if let due = t.dueDate { d["due_date"] = iso(due) }
        if let on = t.waitingOn { d["waiting_on"] = on.rawValue }
        return d
    }

    /// Absolute paths of the attachment files a detail's markdown links to (images or
    /// links whose target starts with attachments/), in order, each once, existing files only.
    private func attachmentFiles(in markdown: String) -> [String] {
        guard markdown.contains(Store.attachmentPrefix) else { return [] }
        let pattern = #"\]\((\#(NSRegularExpression.escapedPattern(for: Store.attachmentPrefix))[^)\s]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        return re.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: markdown), let file = store.attachmentFile(String(markdown[r])),
                  FileManager.default.fileExists(atPath: file.path), seen.insert(file.path).inserted else { return nil }
            return file.path
        }
    }

    /// A note in get_task and search: id, ts and text, plus kind unless it is the default
    /// (note), and author, session, edited_at and question when known.
    private func noteDict(_ n: TaskNote) -> [String: Any] {
        var d: [String: Any] = ["id": n.id, "ts": iso(n.timestamp), "text": n.text]
        if n.kind != .note { d["kind"] = n.kind.rawValue }
        if let author = n.author { d["author"] = author.rawValue }
        if let session = n.sessionId { d["session"] = session }
        if let edited = n.editedAt { d["edited_at"] = iso(edited) }
        if let q = n.questionId { d["question_id"] = q }
        return d
    }

    /// A question as the question tools return it. Options are numbered from 1, as the
    /// user picks them; empty and default fields are omitted.
    private func questionDict(_ q: Question) -> [String: Any] {
        var d: [String: Any] = ["id": q.id, "task": taskHandle(code: q.taskCode, id: q.taskId),
                                "project": q.projectCode, "question": q.prompt, "kind": q.kind.rawValue,
                                "status": q.status.rawValue, "asked_at": iso(q.askedAt)]
        if !q.context.isEmpty { d["context"] = q.context }
        if !q.options.isEmpty {
            d["options"] = q.options.map { o -> [String: Any] in
                var od: [String: Any] = ["label": o.label]
                if !o.note.isEmpty { od["note"] = o.note }
                if o.recommended { od["recommended"] = true }
                return od
            }
        }
        if !q.blocksTask { d["blocks_task"] = false }
        if let s = q.sessionId { d["session"] = s }
        if let a = q.answer { d["answer"] = a }
        if let c = q.answerChoice { d["choice"] = c + 1 }
        if let r = q.cancelReason { d["cancel_reason"] = r }
        if let t = q.answeredAt { d["answered_at"] = iso(t) }
        if let t = q.resumedAt { d["resumed_at"] = iso(t) }
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

    // MARK: - Guides

    /// get_guide's markdown: the built-in guide, the user's guide for every project, and
    /// the project's guide when `projectId` is given; a part never saved is left out.
    private func guideText(projectId: Int64?) throws -> String {
        var parts = ["# QuestBits guide (built-in, \(AgentGuide.version))\n\n\(AgentGuide.builtIn)"]
        func add(_ title: String, _ v: GuideVersion?) {
            guard let v, !v.markdown.isEmpty else { return }
            var by = v.author == .user ? "the user" : "an agent"
            if let s = v.sessionId { by += " (session \(s))" }
            parts.append("# \(title) (version \(v.id), \(iso(v.timestamp)) by \(by))\n\n\(v.markdown)")
        }
        add("The user's guide, all projects", try store.guide(projectId: nil))
        if let projectId { add("Project \(try scopeName(projectId)) guide", try store.guide(projectId: projectId)) }
        return parts.joined(separator: "\n\n")
    }

    /// get_guide's project: from a task (`id`, or `code` naming a task) or a project
    /// (`project_id`/`project_code`, or `code` naming a project); none = no project part.
    private func guideProjectArg(_ args: [String: Any]) throws -> Int64? {
        if given(args, "project_id", "project_code") {
            return try resolveProjectId(args, idKey: "project_id", codeKey: "project_code")
        }
        if let code = args["code"] as? String, !given(args, "id"),
           store.taskId(forCode: code) == nil, let pid = store.projectId(forCode: code) {
            return pid
        }
        guard given(args, "id", "code") else { return nil }
        return try store.getTask(id: try resolveTaskId(args)).projectId
    }

    /// update_guide / get_guide_history scope: `global` true (nil) or one project, not both.
    private func guideScopeArg(_ args: [String: Any]) throws -> Int64? {
        let global = try boolArg(args, "global") ?? false
        let project = given(args, "project_id", "project_code")
        guard global != project else {
            throw MCPError.invalidArg("give either global: true or project_id/project_code")
        }
        return project ? try resolveProjectId(args, idKey: "project_id", codeKey: "project_code") : nil
    }

    private func scopeName(_ projectId: Int64?) throws -> String {
        guard let projectId else { return "global" }
        guard let code = store.projectCode(id: projectId) else { throw StoreError.notFound("project \(projectId)") }
        return code
    }

    private func guideVersionDict(_ v: GuideVersion) -> [String: Any] {
        var d: [String: Any] = ["version": v.id, "ts": iso(v.timestamp), "author": v.author.rawValue, "markdown": v.markdown]
        if let s = v.sessionId { d["session"] = s }
        if let r = v.reason { d["reason"] = r }
        return d
    }

    /// update_task / bulk_update_tasks `parent_code` / `parent_id`: absent = leave alone,
    /// null = make it a top-level task, a task = make it a subtask of that task.
    private func parentArg(_ args: [String: Any]) throws -> Int64?? {
        let present = ["parent_id", "parent_code"].filter { args.keys.contains($0) }
        guard !present.isEmpty else { return .none }
        if present.allSatisfy({ args[$0] is NSNull }) { return .some(nil) }
        return .some(try resolveTaskId(args, idKey: "parent_id", codeKey: "parent_code"))
    }

    /// Resolve a list of task ids from `ids` (array of int) and/or `codes` (array of string).
    /// Like `resolveTaskId`, an unknown code (or an id that is not a number) is an error
    /// naming it, never skipped, so the bulk tools stay all or nothing. An unknown numeric
    /// id is left to the store, which reports it inside the batch. A task named twice (by
    /// id and by code, or repeated) is kept once, in first-seen order.
    private func resolveTaskIds(_ args: [String: Any]) throws -> [Int64] {
        var ids: [Int64] = []
        if let arr = args["ids"] as? [Any] {
            for v in arr {
                if let n = v as? NSNumber { ids.append(n.int64Value) }
                else if let s = v as? String, let n = Int64(s) { ids.append(n) }
                else { throw MCPError.invalidArg("ids: \(v) is not a task id") }
            }
        }
        if let arr = args["codes"] as? [String] {
            for c in arr {
                guard let id = store.taskId(forCode: c) else { throw StoreError.notFound("task \(c)") }
                ids.append(id)
            }
        }
        guard !ids.isEmpty else { throw MCPError.missingArg("ids or codes") }
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Resolve a task id from either `id` (int) or `code` (string handle like "GEN-3").
    private func resolveTaskId(_ args: [String: Any]) throws -> Int64 {
        try resolveTaskId(args, idKey: "id", codeKey: "code")
    }

    /// Resolve a task id from arbitrary `<idKey>` (int) or `<codeKey>` (string code).
    private func resolveTaskId(_ args: [String: Any], idKey: String, codeKey: String) throws -> Int64 {
        if let n = args[idKey] as? NSNumber { return n.int64Value }
        if let s = args[idKey] as? String, let n = Int64(s) { return n }
        if let code = args[codeKey] as? String {
            guard let id = store.taskId(forCode: code) else { throw StoreError.notFound("task \(code)") }
            return id
        }
        throw MCPError.missingArg("\(idKey) or \(codeKey)")
    }

    /// Resolve a project id from `<idKey>` (int) or `<codeKey>` (string code).
    private func resolveProjectId(_ args: [String: Any], idKey: String, codeKey: String) throws -> Int64 {
        if let n = args[idKey] as? NSNumber { return n.int64Value }
        if let s = args[idKey] as? String, let n = Int64(s) { return n }
        if let code = args[codeKey] as? String {
            guard let id = store.projectId(forCode: code) else { throw StoreError.notFound("project \(code)") }
            return id
        }
        throw MCPError.missingArg("\(idKey) or \(codeKey)")
    }

    /// A boolean argument: absent or null = nil. Only JSON true/false count — numbers
    /// such as 0 or 1 are rejected, not read as a boolean.
    private func boolArg(_ args: [String: Any], _ key: String) throws -> Bool? {
        guard let v = args[key], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw MCPError.invalidArg("\(key) must be true or false")
        }
        return n.boolValue
    }

    /// `status` for create/update: absent or null = not given; otherwise a known status
    /// (a typo is an error, not a silent todo or no-op).
    private func statusArg(_ args: [String: Any]) throws -> TaskStatus? {
        guard let v = args["status"], !(v is NSNull) else { return nil }
        guard let s = v as? String, let st = TaskStatus(rawValue: s) else {
            throw MCPError.invalidArg("status must be one of: \(TaskStatus.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return st
    }

    /// True if any of `keys` is present with a non-null value.
    private func given(_ args: [String: Any], _ keys: String...) -> Bool {
        keys.contains { k in args[k].map { !($0 is NSNull) } ?? false }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private func iso(_ d: Date) -> String {
        Self.isoFormatter.string(from: d)
    }

    /// list_tasks `status`: a status or an array of them; "all" means every status.
    /// Absent or null = the open statuses (not `isClosed`). Unknown values are an error.
    private func parseStatusFilter(_ v: Any?) throws -> [TaskStatus]? {
        guard let v, !(v is NSNull) else { return TaskStatus.allCases.filter { !$0.isClosed } }
        let names: [String]
        if let s = v as? String { names = [s] }
        else if let arr = v as? [String], !arr.isEmpty { names = arr }
        else { throw MCPError.invalidArg("status must be a status, an array of statuses, or \"all\"") }
        if names.contains("all") { return nil }
        return try names.map { name in
            guard let st = TaskStatus(rawValue: name) else {
                throw MCPError.invalidArg("unknown status \"\(name)\"; use one of: "
                    + (TaskStatus.allCases.map(\.rawValue) + ["all"]).joined(separator: ", "))
            }
            return st
        }
    }

    /// `waiting_on`: absent or null = not given; otherwise it must be a known value.
    private func parseWaitingOn(_ v: Any?) throws -> WaitingOn? {
        guard let v, !(v is NSNull) else { return nil }
        guard let s = v as? String, let on = WaitingOn(rawValue: s) else {
            throw MCPError.invalidArg("waiting_on must be one of: \(WaitingOn.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return on
    }

    /// A note `kind`: absent or null = note; otherwise a kind an agent may write
    /// (question only as a search filter — ask_user writes those notes).
    private func parseNoteKind(_ v: Any?, allowQuestion: Bool = false) throws -> NoteKind {
        guard let v, !(v is NSNull) else { return .note }
        let kinds = allowQuestion ? NoteKind.allCases : NoteKind.writable
        guard let s = v as? String, let kind = NoteKind(rawValue: s), kinds.contains(kind) else {
            throw MCPError.invalidArg("kind must be one of: \(kinds.map(\.rawValue).joined(separator: ", "))")
        }
        return kind
    }

    /// update_task `note` (+ `note_kind`, `session`): absent or null = no note. The kind
    /// defaults to summary when the update closes the task, else note.
    private func updateNoteArg(_ args: [String: Any], status: TaskStatus?) throws -> NoteDraft? {
        guard given(args, "note") else {
            if given(args, "note_kind") { throw MCPError.invalidArg("note_kind needs a note") }
            return nil
        }
        guard let text = args["note"] as? String else { throw MCPError.invalidArg("note must be a string") }
        let kind = given(args, "note_kind") ? try parseNoteKind(args["note_kind"])
            : (status?.isClosed == true ? .summary : .note)
        return NoteDraft(text: text, kind: kind, author: .agent, sessionId: try sessionArg(args))
    }

    /// `session`: an optional label for the agent session (absent, null or "" = none).
    private func sessionArg(_ args: [String: Any]) throws -> String? {
        guard let v = args["session"], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw MCPError.invalidArg("session must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// ask_user `kind`: choice (default), text or approve.
    private func questionKindArg(_ args: [String: Any]) throws -> QuestionKind {
        guard given(args, "kind") else { return .choice }
        guard let s = args["kind"] as? String, let k = QuestionKind(rawValue: s) else {
            throw MCPError.invalidArg("kind must be one of: \(QuestionKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return k
    }

    /// ask_user `options` (strings or {label, note}) and `recommended` (1-based number, or
    /// an option's label). The store checks the counts and labels.
    private func questionOptionsArg(_ args: [String: Any]) throws -> [QuestionOption] {
        var options: [QuestionOption] = []
        if given(args, "options") {
            guard let arr = args["options"] as? [Any] else { throw MCPError.invalidArg("options must be an array") }
            for v in arr {
                if let s = v as? String { options.append(QuestionOption(label: s)) }
                else if let o = v as? [String: Any], let label = o["label"] as? String {
                    options.append(QuestionOption(label: label, note: o["note"] as? String ?? ""))
                } else {
                    throw MCPError.invalidArg("each option must be a string or {label, note}")
                }
            }
        }
        guard given(args, "recommended") else { return options }
        guard !options.isEmpty else { throw MCPError.invalidArg("recommended needs options") }
        let index: Int
        if let n = args["recommended"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            guard (1...options.count).contains(n.intValue) else {
                throw MCPError.invalidArg("recommended must be an option number from 1 to \(options.count)")
            }
            index = n.intValue - 1
        } else if let s = args["recommended"] as? String,
                  let i = options.firstIndex(where: { $0.label.caseInsensitiveCompare(s.trimmingCharacters(in: .whitespaces)) == .orderedSame }) {
            index = i
        } else {
            throw MCPError.invalidArg("recommended must be an option number (from 1) or an option's label")
        }
        options[index].recommended = true
        return options
    }

    /// An optional integer limit from 1 to `max`; absent or null = `default`.
    private func limitArg(_ args: [String: Any], _ key: String, default def: Int, max: Int) throws -> Int {
        guard given(args, key) else { return def }
        guard let n = try? requireInt(args, key), (1...Int64(max)).contains(n) else {
            throw MCPError.invalidArg("\(key) must be an integer from 1 to \(max)")
        }
        return Int(n)
    }

    private static let defaultNotesLimit = 5
    private static let maxNotesLimit = 100

    /// get_task `notes_limit`: absent or null = the default; 0 = no notes; at most the max.
    /// Parsed like the other integer arguments (a number or a numeric string).
    private func notesLimitArg(_ args: [String: Any]) throws -> Int {
        guard given(args, "notes_limit") else { return Self.defaultNotesLimit }
        guard let n = try? requireInt(args, "notes_limit"), (0...Int64(Self.maxNotesLimit)).contains(n) else {
            throw MCPError.invalidArg("notes_limit must be an integer from 0 to \(Self.maxNotesLimit)")
        }
        return Int(n)
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
        // One line at a time: a wait's thread writes too.
        writeLock.lock(); defer { writeLock.unlock() }
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
