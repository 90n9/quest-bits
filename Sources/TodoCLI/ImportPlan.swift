import Foundation

/// One source item of an import and what it would do: the manifest row a reviewer reads,
/// and (for `create`/`update`) the write the apply makes.
struct ImportItem {
    enum State: String, CaseIterable {
        case create, update             // would write
        case noop                       // the target already is as the item wants
        case applied                    // in the ledger: written by an earlier run
        case conflict, drifted, error   // would not write: the target or the source disagrees
        case unresolved                 // a source item with no mapping, or one needing a decision
        case matched, retained, skip    // dispositions that write nothing

        var writes: Bool { self == .create || self == .update }
    }

    enum Op {
        case repoPath(projectId: Int64, path: String)
        case milestone(projectId: Int64, name: String, detail: String, acceptance: String)
        case milestoneTask(taskId: Int64, projectId: Int64, milestone: String)
        case note(taskId: Int64, kind: NoteKind, text: String)
        case link(taskId: Int64, url: String, kind: LinkKind?, title: String?)
        case branch(taskId: Int64, branch: String)
        case relation(taskId: Int64, otherId: Int64, kind: RelationKind)
        case page(projectId: Int64, kind: PageKind, title: String, body: String, taskIds: [Int64],
                  outcome: String?, decidedOn: String?, source: String)
    }

    var key: String
    var project: String
    var kind: String
    var state: State
    var target: String
    var summary: String
    var before: String? = nil
    var after: String? = nil
    var payload: String? = nil
    var source: String? = nil
    var reason: String? = nil
    var op: Op? = nil

    /// The source and the intended write as one hash: the apply writes an item only when
    /// the reviewed plan has the same key with the same fingerprint.
    var fingerprint: String {
        ImportSources.sha256([key, kind, target, before ?? "", after ?? "", payload ?? ""].joined(separator: "\u{1f}"))
    }

    var json: [String: Any] {
        var o: [String: Any] = ["key": key, "project": project, "kind": kind, "state": state.rawValue,
                                "target": target, "summary": summary, "fingerprint": fingerprint]
        if let before { o["before"] = before }
        if let after { o["after"] = after }
        if let payload { o["payload"] = payload }
        if let source { o["source"] = source }
        if let reason { o["reason"] = reason }
        return o
    }
}

/// Builds the item list from the mapping, the sources and the database as they are now.
/// Reads only: nothing here writes the database or any source.
struct ImportPlanner {
    let config: ImportConfig
    let store: Store
    let files: [String: ImportSources.File]
    let workState: ImportSources.WorkStateDB?
    let ledger: [String: ImportLedgerEntry]
    let importedOn: String

    private var projects: [Project] = []
    private var tasksByCode: [String: TodoTask] = [:]
    private var subtasks: [Int64: [TodoTask]] = [:]
    private var items: [ImportItem] = []
    /// What earlier items in this plan will write, so a later item sees it (a milestone
    /// made above, a branch set by another item for the same task).
    private var pendingBranch: [Int64: String] = [:]

    init(config: ImportConfig, store: Store, files: [String: ImportSources.File],
         workState: ImportSources.WorkStateDB?, ledger: [String: ImportLedgerEntry], importedOn: String) {
        self.config = config; self.store = store; self.files = files
        self.workState = workState; self.ledger = ledger; self.importedOn = importedOn
    }

    mutating func plan() throws -> [ImportItem] {
        projects = try store.listProjects(includeArchived: true)
        for p in projects {
            for t in try store.listTasks(projectId: p.id) {
                tasksByCode[t.code.uppercased()] = t
                if let parent = t.parentId { subtasks[parent, default: []].append(t) }
            }
        }
        planProjectCoverage()
        planSourceFiles()
        for map in config.projects {
            guard let p = project(map.code) else {
                add(ImportItem(key: key(map.code, "project", map.code), project: map.code, kind: "project", state: .error,
                               target: "project \(map.code)", summary: "no project with this code in the database"))
                continue
            }
            try planProject(map, p)
        }
        if let ws = config.workState { try planWorkState(ws) }
        return items
    }

    // MARK: - Helpers

    private func key(_ project: String, _ kind: String, _ id: String) -> String {
        "\(config.namespace):\(project)/\(kind)/\(id)"
    }

    private func project(_ code: String) -> Project? {
        projects.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    private func task(_ code: String) -> TodoTask? { tasksByCode[code.uppercased()] }

    /// Adds an item; one that would write but is already in the ledger becomes `applied`.
    private mutating func add(_ item: ImportItem) {
        var item = item
        if item.state.writes, ledger[item.key] != nil {
            item.state = .applied
            item.reason = [item.reason, "already in the import ledger"].compactMap { $0 }.joined(separator: "; ")
        }
        items.append(item)
    }

    /// The quoted source text for a ref, and its locator line; or the error why not.
    private func quote(_ ref: ImportConfig.SourceRef?) -> (quote: ImportSources.Quote?, label: String?, error: String?) {
        guard let ref else { return (nil, nil, nil) }
        guard let file = files[ref.file] else { return (nil, nil, "unknown source file key \(ref.file)") }
        let name = (file.path as NSString).lastPathComponent
        do {
            let q = try ImportSources.resolve(ref, in: file)
            let lines = q.firstLine == q.lastLine ? "L\(q.firstLine)" : "L\(q.firstLine)–\(q.lastLine)"
            return (q, "\(file.config.project) \(name) \(lines) (text sha256 \(ImportSources.sha256(q.text).prefix(12)))", nil)
        } catch let CLIError.failure(message) {
            return (nil, "\(file.config.project) \(name)", message)
        } catch {
            return (nil, "\(file.config.project) \(name)", "\(error)")
        }
    }

    /// The text an imported note or page carries: the mapping's own text, the quoted
    /// source, and a provenance line (the import is the agent's; the original's author is
    /// not known unless the source says).
    private func importedText(_ text: String?, _ q: ImportSources.Quote?, _ label: String?) -> String {
        var parts: [String] = []
        if let text, !text.isEmpty { parts.append(text) }
        if let q { parts.append(Fmt.quote(GateRedactor.redact(q.text))) }
        if let label { parts.append("Source: \(label), as read on \(importedOn). Imported by an agent (questbits import); original author unknown.") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Coverage

    private mutating func planProjectCoverage() {
        for p in projects {
            let mapped = config.projects.contains { $0.code.caseInsensitiveCompare(p.code) == .orderedSame }
            let skip = config.outOfScopeProjects.first { $0.code.caseInsensitiveCompare(p.code) == .orderedSame }
            let status = p.isArchived ? " (archived)" : ""
            if mapped {
                add(ImportItem(key: key(p.code, "project", p.code), project: p.code, kind: "project", state: .matched,
                               target: "project \(p.code)", summary: "\(p.name)\(status): mapped below"))
            } else if let skip {
                add(ImportItem(key: key(p.code, "project", p.code), project: p.code, kind: "project", state: .skip,
                               target: "project \(p.code)", summary: "\(p.name)\(status): left out", reason: skip.reason))
            } else {
                add(ImportItem(key: key(p.code, "project", p.code), project: p.code, kind: "project", state: .unresolved,
                               target: "project \(p.code)", summary: "\(p.name)\(status): not in the mapping",
                               reason: "every project needs a mapping or an out_of_scope_projects entry"))
            }
        }
    }

    private mutating func planSourceFiles() {
        for f in config.sources {
            let file = files[f.key]
            var state: ImportItem.State = f.disposition == "retained" ? .retained : .matched
            var reason = f.reason
            if let error = file?.error {
                state = .conflict
                reason = error
            } else if let want = f.sha256, let have = file?.sha256, want != have {
                state = .drifted
                reason = [reason, "file changed since the mapping was written (sha256 \(want.prefix(12)) → \(have.prefix(12)))"]
                    .compactMap { $0 }.joined(separator: "; ")
            }
            let lines = file?.lines.count ?? 0
            let modified = file?.modified.map(Fmt.iso) ?? "?"
            add(ImportItem(key: key(f.project, "source", f.key), project: f.project, kind: "source_file", state: state,
                           target: f.path, summary: "\(f.disposition): \(lines) lines, modified \(modified)",
                           source: "sha256 \(file?.sha256 ?? "?")", reason: reason))
        }
    }

    // MARK: - One project

    private mutating func planProject(_ map: ImportConfig.ProjectMap, _ p: Project) throws {
        if let raw = map.repoPath { planRepoPath(raw, p) }
        for m in map.milestones { planMilestone(m, p) }
        for n in map.notes { planNote(n, p) }
        for l in map.links { planLink(l, p) }
        for b in map.branches { planBranch(b, p) }
        for r in map.relations { try planRelation(r, p) }
        for pg in map.pages { try planPage(pg, p) }
        for d in map.dispositions { planDisposition(d, p) }
    }

    private mutating func planRepoPath(_ raw: String, _ p: Project) {
        var item = ImportItem(key: key(p.code, "repo_path", p.code), project: p.code, kind: "repo_path", state: .noop,
                              target: "project \(p.code)", summary: "repo folder", before: p.repoPath ?? "(none)")
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            item.after = "(none)"
            if p.repoPath != nil {
                item.state = .conflict
                item.reason = "the mapping says this project has no folder, but it has one: left as it is"
            } else {
                item.reason = "no repo folder (by decision); nothing to set"
            }
            return add(item)
        }
        let path: String
        do {
            guard let normalized = try Store.normalizedRepoPath(raw) else { return }
            path = normalized
        } catch {
            item.state = .error
            item.reason = "\(error)"
            return add(item)
        }
        item.after = path
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) || !isDir.boolValue {
            item.state = .conflict
            item.reason = "folder not found"
        } else if let current = p.repoPath {
            if Store.resolvedPath(current) == Store.resolvedPath(path) {
                item.state = .noop
            } else {
                item.state = .conflict
                item.reason = "the project already has another folder: left as it is"
            }
        } else if let other = projects.first(where: { $0.id != p.id && !$0.isArchived
                                                      && $0.repoPath.map(Store.resolvedPath) == Store.resolvedPath(path) }) {
            item.state = .conflict
            item.reason = "project \(other.code) already has this folder"
        } else {
            item.state = .update
            item.op = .repoPath(projectId: p.id, path: path)
        }
        add(item)
    }

    private mutating func planMilestone(_ m: ImportConfig.MilestoneMap, _ p: Project) {
        let mKey = key(p.code, "milestone", m.key)
        let existing = (try? store.milestones(projectId: p.id))?.first { $0.name.caseInsensitiveCompare(m.name) == .orderedSame }
        let (q, label, qError) = quote(m.source)
        let detail = importedText(m.detail, q, label)
        var item = ImportItem(key: mKey, project: p.code, kind: "milestone", state: .create,
                              target: "milestone \(m.name)", summary: "milestone \"\(m.name)\"",
                              after: m.name, payload: "Detail:\n\(detail)\n\nAcceptance:\n\(m.acceptance ?? "")",
                              source: label, reason: m.reason)
        if let qError {
            item.state = .conflict
            item.reason = [m.reason, qError].compactMap { $0 }.joined(separator: "; ")
        } else if let existing {
            item.state = .noop
            item.before = existing.name
            item.reason = [m.reason, "a milestone of this name exists (#\(existing.id)): reused as it is, detail not changed"]
                .compactMap { $0 }.joined(separator: "; ")
        } else {
            item.before = "(none)"
            item.op = .milestone(projectId: p.id, name: m.name, detail: detail, acceptance: m.acceptance ?? "")
        }
        add(item)
        // The tasks it gets, each its own item (a conflict on one never blocks the rest).
        var codes: [String] = []
        for code in m.tasks {
            codes.append(code)
            if m.withSubtasks == true, let t = task(code) {
                codes += (subtasks[t.id] ?? []).sorted { $0.id < $1.id }.map(\.code)
            }
        }
        var seen = Set<String>()
        for code in codes where seen.insert(code.uppercased()).inserted {
            var ti = ImportItem(key: key(p.code, "milestone_task", "\(m.key)/\(code.uppercased())"), project: p.code,
                                kind: "milestone_task", state: .update, target: code.uppercased(),
                                summary: "into milestone \"\(m.name)\"", after: m.name)
            guard let t = task(code), t.projectId == p.id else {
                ti.state = .error
                ti.reason = "no task \(code) in \(p.code)"
                add(ti)
                continue
            }
            ti.summary += " — \(Fmt.oneLine(t.title, max: 70)) [\(t.status.rawValue)]"
            let current = t.milestoneId.flatMap { id in (try? store.milestone(id: id))?.name }
            ti.before = current ?? "(none)"
            if item.state == .conflict || item.state == .error {
                ti.state = .conflict
                ti.reason = "its milestone item is not applied"
            } else if let current {
                if current.caseInsensitiveCompare(m.name) == .orderedSame {
                    ti.state = .noop
                } else {
                    ti.state = .conflict
                    ti.reason = "already in milestone \"\(current)\": never moved by the import"
                }
            } else {
                ti.op = .milestoneTask(taskId: t.id, projectId: p.id, milestone: m.name)
            }
            add(ti)
        }
    }

    private mutating func planNote(_ n: ImportConfig.NoteMap, _ p: Project) {
        let (q, label, qError) = quote(n.source)
        var item = ImportItem(key: key(p.code, "note", n.key), project: p.code, kind: "note", state: .create,
                              target: n.task.uppercased(), summary: "note (\(n.kind ?? "note"))",
                              source: label, reason: n.reason)
        guard let t = task(n.task), t.projectId == p.id else {
            item.state = .error
            item.reason = "no task \(n.task) in \(p.code)"
            return add(item)
        }
        item.summary += " on \(t.code) [\(t.status.rawValue)] \(Fmt.oneLine(t.title, max: 60))"
        guard let kind = NoteKind(rawValue: n.kind ?? "note") else {
            item.state = .error
            item.reason = "unknown note kind \(n.kind ?? "")"
            return add(item)
        }
        if let qError {
            item.state = .conflict
            item.reason = [n.reason, qError].compactMap { $0 }.joined(separator: "; ")
            return add(item)
        }
        let text = importedText(n.text, q, label)
        item.payload = text
        item.op = .note(taskId: t.id, kind: kind, text: text)
        add(item)
    }

    private mutating func planLink(_ l: ImportConfig.LinkMap, _ p: Project) {
        var item = ImportItem(key: key(p.code, "link", l.key), project: p.code, kind: "link", state: .create,
                              target: l.task.uppercased(), summary: "link", after: l.url, reason: l.reason)
        guard let t = task(l.task), t.projectId == p.id else {
            item.state = .error
            item.reason = "no task \(l.task) in \(p.code)"
            return add(item)
        }
        planLinkWrite(&item, t, url: l.url, kind: l.kind.flatMap(LinkKind.init(rawValue:)), title: l.title)
        add(item)
    }

    /// A link item's state: noop when the task already has the URL.
    private func planLinkWrite(_ item: inout ImportItem, _ t: TodoTask, url: String, kind: LinkKind?, title: String?) {
        do {
            let normalized = try Store.normalizedLinkURL(url)
            let existing = try store.links(taskId: t.id)
            item.after = "\(kind?.rawValue ?? LinkKind.infer(from: normalized).rawValue) \(normalized)"
            if existing.contains(where: { $0.url == normalized }) {
                item.state = .noop
            } else {
                item.op = .link(taskId: t.id, url: normalized, kind: kind, title: title)
            }
        } catch {
            item.state = .error
            item.reason = "\(error)"
        }
    }

    private mutating func planBranch(_ b: ImportConfig.BranchMap, _ p: Project) {
        var item = ImportItem(key: key(p.code, "branch", b.key), project: p.code, kind: "branch", state: .update,
                              target: b.task.uppercased(), summary: "working branch", after: b.branch, reason: b.reason)
        guard let t = task(b.task), t.projectId == p.id else {
            item.state = .error
            item.reason = "no task \(b.task) in \(p.code)"
            return add(item)
        }
        let current = pendingBranch[t.id] ?? t.branch
        item.before = current ?? "(none)"
        if current == b.branch {
            item.state = .noop
        } else if current != nil {
            item.state = .conflict
            item.reason = "the task has another branch: never replaced by the import"
        } else {
            item.op = .branch(taskId: t.id, branch: b.branch)
            pendingBranch[t.id] = b.branch
        }
        add(item)
    }

    private mutating func planRelation(_ r: ImportConfig.RelationMap, _ p: Project) throws {
        var item = ImportItem(key: key(p.code, "relation", r.key), project: p.code, kind: "relation", state: .create,
                              target: r.task.uppercased(), summary: "\(r.kind) \(r.other.uppercased())",
                              after: "\(r.task.uppercased()) \(r.kind) \(r.other.uppercased())", reason: r.reason)
        guard let t = task(r.task), let o = task(r.other), t.projectId == p.id else {
            item.state = .error
            item.reason = "unknown task \(r.task) or \(r.other)"
            return add(item)
        }
        guard let kind = RelationKind(rawValue: r.kind) else {
            item.state = .error
            item.reason = "unknown relation kind \(r.kind)"
            return add(item)
        }
        let related = try store.relatedTasks(taskId: t.id)
        if related[kind].contains(where: { $0.id == o.id }) {
            item.state = .noop
        } else {
            item.op = .relation(taskId: t.id, otherId: o.id, kind: kind)
        }
        add(item)
    }

    private mutating func planPage(_ pg: ImportConfig.PageMap, _ p: Project) throws {
        let pKey = key(p.code, "page", pg.key)
        let (q, label, qError) = quote(pg.source)
        var item = ImportItem(key: pKey, project: p.code, kind: "page", state: .create,
                              target: "wiki \(pg.kind ?? "note") \"\(pg.title)\"", summary: "wiki page",
                              after: pg.title, source: label, reason: pg.reason)
        guard let kind = PageKind(rawValue: pg.kind ?? "note") else {
            item.state = .error
            item.reason = "unknown page kind \(pg.kind ?? "")"
            return add(item)
        }
        var taskIds: [Int64] = []
        for code in pg.tasks ?? [] {
            guard let t = task(code) else {
                item.state = .error
                item.reason = "no task \(code)"
                return add(item)
            }
            taskIds.append(t.id)
        }
        if let qError {
            item.state = .conflict
            item.reason = [pg.reason, qError].compactMap { $0 }.joined(separator: "; ")
            return add(item)
        }
        let body = importedText(pg.body, q, label)
        item.payload = body
        if !(pg.tasks ?? []).isEmpty { item.summary += " (tasks \((pg.tasks ?? []).map { $0.uppercased() }.joined(separator: ", ")))" }
        if try store.pages(projectId: p.id).contains(where: { $0.provenance.key == pKey }) {
            item.state = .noop
            item.reason = "a page with this source key exists: never rewritten"
        } else {
            item.op = .page(projectId: p.id, kind: kind, title: pg.title, body: body, taskIds: taskIds,
                            outcome: pg.outcome, decidedOn: pg.decidedOn, source: label ?? "")
        }
        add(item)
    }

    private mutating func planDisposition(_ d: ImportConfig.Disposition, _ p: Project) {
        let state = ImportItem.State(rawValue: d.disposition) ?? .error
        let (q, label, qError) = quote(d.source)
        var item = ImportItem(key: key(p.code, "item", d.key), project: p.code, kind: "disposition",
                              state: [.matched, .retained, .skip, .unresolved, .conflict].contains(state) ? state : .error,
                              target: (d.tasks ?? []).map { $0.uppercased() }.joined(separator: ", "),
                              summary: d.key, payload: q.map { Fmt.quote($0.text) }, source: label, reason: d.reason)
        if item.state == .error { item.reason = "unknown disposition \(d.disposition); " + d.reason }
        if let qError { item.state = .conflict; item.reason = d.reason + "; " + qError }
        for code in d.tasks ?? [] where task(code) == nil {
            item.state = .error
            item.reason = "no task \(code); " + d.reason
        }
        add(item)
    }

    // MARK: - work_state

    private mutating func planWorkState(_ ws: ImportConfig.WorkState) throws {
        guard let db = workState else { return }
        for l in try db.lists() {
            let configured = ws.lists.contains { $0.project == l.project && $0.list == l.list }
            let skip = ws.outOfScope.first { ($0.project == "*" || $0.project == l.project) && $0.list == l.list }
            let name = "\(l.project)/\(l.list)"
            var item = ImportItem(key: "\(config.namespace):ws/list/\(name)", project: "work_state", kind: "loop_list",
                                  state: .matched, target: name, summary: "\(l.count) events, newest entry \(l.maxId)")
            if configured {
                item.reason = "mapped below"
            } else if let skip {
                item.state = .skip
                item.reason = skip.reason
            } else {
                item.state = .unresolved
                item.reason = "list not in the mapping"
            }
            add(item)
        }
        for list in ws.lists { try planLoopList(list, db) }
    }

    private mutating func planLoopList(_ list: ImportConfig.LoopList, _ db: ImportSources.WorkStateDB) throws {
        let events = try db.events(project: list.project, list: list.list)
        // Split into items: an event belongs to the item its group_by field names, or to
        // the last item when it does not set the field.
        var order: [String] = []
        var byLabel: [String: [ImportSources.Event]] = [:]
        var current = list.groupBy == nil ? "*" : "(no \(list.groupBy!))"
        for e in events {
            if let field = list.groupBy, let label = e.fields[field] as? String { current = label }
            if byLabel[current] == nil { order.append(current) }
            byLabel[current, default: []].append(e)
        }
        let listName = "\(list.project)/\(list.list)"
        for label in order {
            let evs = byLabel[label] ?? []
            let base = "\(config.namespace):ws/\(listName)@\(evs.first?.id ?? 0)"
            let ids = evs.map(\.id)
            let span = "\(evs.first?.createdAt ?? "") → \(evs.last?.createdAt ?? "")"
            let skip = list.skipItems.first { $0.label == label }
            guard let mapped = list.items.first(where: { $0.label == label }) else {
                add(ImportItem(key: base, project: list.target, kind: "loop_item", state: skip == nil ? .unresolved : .skip,
                               target: listName, summary: "item \"\(label)\" · events \(Self.idList(ids))",
                               source: span, reason: skip?.reason ?? "item not in the mapping"))
                continue
            }
            var drift: String?
            let want = Set(mapped.events), have = Set(ids)
            if !mapped.events.isEmpty && want != have {
                let added = have.subtracting(want).sorted(), gone = want.subtracting(have).sorted()
                drift = "events changed since review:"
                    + (added.isEmpty ? "" : " new \(Self.idList(added))") + (gone.isEmpty ? "" : " missing \(Self.idList(gone))")
            }
            add(ImportItem(key: base, project: list.target, kind: "loop_item", state: drift == nil ? .matched : .drifted,
                           target: listName, summary: "item \"\(label)\" · events \(Self.idList(ids)) → \(mapped.tasks.joined(separator: ", "))",
                           source: span, reason: [mapped.reason, drift].compactMap { $0 }.joined(separator: "; ")))
            planLoopWrites(list, mapped, label: label, events: evs, base: base, drift: drift)
        }
        for item in list.items where byLabel[item.label] == nil {
            add(ImportItem(key: "\(config.namespace):ws/\(listName)/missing/\(ImportSources.sha256(item.label).prefix(10))",
                           project: list.target, kind: "loop_item", state: .error, target: listName,
                           summary: "item \"\(item.label)\" is in the mapping but not in the list"))
        }
    }

    private mutating func planLoopWrites(_ list: ImportConfig.LoopList, _ m: ImportConfig.LoopItem, label: String,
                                         events: [ImportSources.Event], base: String, drift: String?) {
        let listName = "\(list.project)/\(list.list)"
        var tasks: [TodoTask] = []
        for code in m.tasks {
            guard let t = task(code), let p = project(list.target), t.projectId == p.id else {
                add(ImportItem(key: "\(base)/task/\(code.uppercased())", project: list.target, kind: "loop_item",
                               state: .error, target: code, summary: "no task \(code) in \(list.target)"))
                continue
            }
            tasks.append(t)
        }
        let finish = { (item: inout ImportItem) in
            if let drift, item.state.writes || item.state == .noop {
                item.state = .drifted
                item.reason = drift
                item.op = nil
            }
        }
        let source = "work_state \(listName) entries \(Self.idList(events.map(\.id)))"
        switch m.history {
        case "note":
            for t in tasks {
                let text = loopHistory(list, label: label, events: events, tasks: tasks, for: t, reason: m.reason)
                var item = ImportItem(key: "\(base)/note/\(t.code)", project: list.target, kind: "note", state: .create,
                                      target: t.code, summary: "history note on \(t.code) [\(t.status.rawValue)]",
                                      payload: text, source: source)
                item.op = .note(taskId: t.id, kind: .note, text: text)
                finish(&item)
                add(item)
            }
        case "page":
            let text = loopHistory(list, label: label, events: events, tasks: tasks, for: nil, reason: m.reason)
            let title = "Imported loop: \(list.list)" + (label == "*" ? "" : " · \(Fmt.oneLine(label, max: 80))")
            var item = ImportItem(key: "\(base)/page", project: list.target, kind: "page", state: .create,
                                  target: "wiki note \"\(title)\"",
                                  summary: "history page (tasks \(tasks.map(\.code).joined(separator: ", ")))",
                                  after: title, payload: text, source: source)
            if let p = project(list.target) {
                if (try? store.pages(projectId: p.id))?.contains(where: { $0.provenance.key == item.key }) == true {
                    item.state = .noop
                } else {
                    item.op = .page(projectId: p.id, kind: .note, title: title, body: text, taskIds: tasks.map(\.id),
                                    outcome: nil, decidedOn: nil, source: source)
                }
            }
            finish(&item)
            add(item)
        default:
            break
        }
        if m.links {
            let urls = Self.ordered(events.compactMap { ($0.fields["work_product"] as? String) }
                .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") })
            for t in tasks {
                for url in urls {
                    var item = ImportItem(key: "\(base)/link/\(t.code)/\(ImportSources.sha256(url).prefix(10))",
                                          project: list.target, kind: "link", state: .create, target: t.code,
                                          summary: "link from item \"\(Fmt.oneLine(label, max: 50))\"", source: source)
                    planLinkWrite(&item, t, url: url, kind: nil, title: Fmt.oneLine("\(list.list): \(label)", max: 200))
                    finish(&item)
                    add(item)
                }
            }
        }
        let branches = Self.ordered(events.compactMap { ($0.fields["branch"] as? String) }.filter { !$0.isEmpty })
        guard m.branch != "none", !branches.isEmpty else { return }
        for t in tasks {
            let current = pendingBranch[t.id] ?? t.branch
            if m.branch == "set", branches.count == 1, current == nil || current == branches[0] {
                var item = ImportItem(key: "\(base)/branch/\(t.code)", project: list.target, kind: "branch",
                                      state: current == nil ? .update : .noop, target: t.code, summary: "working branch",
                                      before: current ?? "(none)", after: branches[0], source: source)
                if current == nil {
                    item.op = .branch(taskId: t.id, branch: branches[0])
                    pendingBranch[t.id] = branches[0]
                }
                finish(&item)
                add(item)
                continue
            }
            // Several branches, or the task has another one: each becomes a branch link.
            for b in branches where b != current {
                var item = ImportItem(key: "\(base)/branch-link/\(t.code)/\(ImportSources.sha256(b).prefix(10))",
                                      project: list.target, kind: "link", state: .create, target: t.code,
                                      summary: "branch link (task branch stays \(current ?? "(none)"))", source: source)
                planLinkWrite(&item, t, url: b, kind: .branch, title: nil)
                finish(&item)
                add(item)
            }
        }
    }

    /// One note/page body for a work item: what it was, its last value of each field, and
    /// every event in order as written (values redacted, as for any text that may hold a
    /// secret). Source times are the source's; the note's own time is the import's.
    private func loopHistory(_ list: ImportConfig.LoopList, label: String, events: [ImportSources.Event], tasks: [TodoTask],
                             for task: TodoTask?, reason: String?) -> String {
        let listName = "\(list.project)/\(list.list)"
        var last: [String: String] = [:]
        for e in events { for (k, v) in e.fields { last[k] = Self.value(v) } }
        var lines = ["Imported from claude-mem work_state \(listName), item \"\(label)\" "
                     + "(entries \(Self.idList(events.map(\.id))), \(events.first?.createdAt ?? "") → \(events.last?.createdAt ?? ""))."]
        let others = tasks.filter { $0.id != task?.id }.map(\.code)
        if task != nil, !others.isEmpty { lines.append("The same item also covers \(others.joined(separator: ", ")).") }
        if task == nil, !tasks.isEmpty { lines.append("Tasks: \(tasks.map(\.code).joined(separator: ", ")).") }
        if let reason, !reason.isEmpty { lines.append("Mapping: \(reason)") }
        let state = ["status", "work_product", "merged", "merge_commit", "branch"].compactMap { k in last[k].map { "\(k) \($0)" } }
        if !state.isEmpty { lines.append("Last state in the log: " + state.joined(separator: " · ") + ". The log is history: it does not change this task's status.") }
        lines.append("")
        lines.append("Events (source time, fields as written):")
        for e in events {
            // The group_by field is the item's label, already said above.
            let keys = e.fields.keys.filter { $0 != list.groupBy }.sorted { a, b in
                a == "status" ? true : b == "status" ? false : a < b
            }
            let parts = keys.map { "\($0): \(Fmt.oneLine(Self.value(e.fields[$0] as Any), max: 1_500))" }
            lines.append("- \(e.createdAt) (entry \(e.id)) · " + parts.joined(separator: " · "))
        }
        lines.append("")
        lines.append("Imported on \(importedOn) by an agent (questbits import); the log's author and session are not recorded.")
        return GateRedactor.redact(lines.joined(separator: "\n"))
    }

    private static func value(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let s = v as? String { return s }
        return GateCall.jsonText(v)
    }

    private static func ordered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    static func idList(_ ids: [Int64]) -> String { ids.map(String.init).joined(separator: ", ") }
}
