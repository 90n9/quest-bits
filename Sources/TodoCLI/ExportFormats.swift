import Foundation

/// A project snapshot as markdown: readable, every record included (user text set off as
/// quotes so its headings never break the outline). Timestamps are UTC ISO-8601 and the
/// file carries no export time, so exporting unchanged data again gives the same file.
enum ExportMarkdown {
    static func project(_ s: ProjectSnapshot) -> String {
        let p = s.project
        var out: [String] = ["# \(p.code) · \(p.name)", ""]
        out.append("- Code: \(p.code)")
        if let folder = p.repoPath { out.append("- Folder: \(folder)") }
        if let archived = p.archivedAt { out.append("- Archived: \(Fmt.iso(archived))") }
        out.append("- Created: \(Fmt.iso(p.createdAt))")
        out.append("- Counts: " + s.counts.map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \($0.value)" }
            .joined(separator: " · "))
        if !p.detail.isEmpty { out += ["", "## Description", "", Fmt.quote(p.detail)] }
        out += guides(s.guides)
        out += milestones(s.milestones)
        out += ["", "## Tasks (\(s.tasks.count), board order)"]
        for t in s.tasks { out += ["", task(t, s.rel, headingLevel: 3)] }
        out += wiki(s)
        return out.joined(separator: "\n") + "\n"
    }

    private static func guides(_ versions: [GuideVersion]) -> [String] {
        guard let current = versions.first else { return [] }
        var out = ["", "## Guide", "", guideLine(current), "", Fmt.quote(current.markdown)]
        if versions.count > 1 {
            out += ["", "### Earlier guide versions (\(versions.count - 1))"]
            for g in versions.dropFirst() { out += ["", "#### " + guideLine(g), "", Fmt.quote(g.markdown)] }
        }
        return out
    }

    private static func guideLine(_ g: GuideVersion) -> String {
        var parts = ["Version \(g.id)", Fmt.iso(g.timestamp), g.author.rawValue]
        if let s = g.sessionId { parts.append("session \(s)") }
        if let r = g.reason, !r.isEmpty { parts.append("reason: \(Fmt.oneLine(r, max: 200))") }
        return parts.joined(separator: " · ")
    }

    private static func milestones(_ list: [Milestone]) -> [String] {
        guard !list.isEmpty else { return [] }
        var out = ["", "## Milestones (\(list.count))"]
        for m in list {
            out += ["", "### \(m.name) (\(m.isClosed ? "closed" : "open"))", ""]
            out.append("- Tasks: \(m.done)/\(m.total) done, \(m.open) open")
            if let t = m.targetDate { out.append("- Target: \(Fmt.day(t))") }
            if let c = m.closedAt { out.append("- Closed: \(Fmt.iso(c))") }
            out.append("- Created: \(Fmt.iso(m.createdAt)) · updated \(Fmt.iso(m.updatedAt))")
            if !m.detail.isEmpty { out += ["", "Description:", "", Fmt.quote(m.detail)] }
            if !m.acceptance.isEmpty { out += ["", "Acceptance:", "", Fmt.quote(m.acceptance)] }
        }
        return out
    }

    /// One task with everything recorded on it. `headingLevel` is its title's level (show uses 1).
    static func task(_ s: TaskSnapshot, _ rel: TaskRelations, headingLevel: Int) -> String {
        let t = s.task
        let h = String(repeating: "#", count: headingLevel)
        let sub = String(repeating: "#", count: headingLevel + 1)
        var out = ["\(h) \(t.code) · \(t.title)", ""]
        out += fields(t, rel)
        if !t.detail.isEmpty { out += ["", "\(sub) Detail", "", Fmt.quote(t.detail)] }
        if !s.links.isEmpty {
            out += ["", "\(sub) Links (\(s.links.count))", ""]
            out += s.links.map(linkLine)
        }
        if !s.related.isEmpty {
            out += ["", "\(sub) Relations", ""]
            for kind in RelationKind.allCases where !s.related[kind].isEmpty {
                out.append("- \(kind.display): " + s.related[kind].map { "\($0.code) (\($0.status.rawValue))" }
                    .joined(separator: ", "))
            }
        }
        if !s.questions.isEmpty {
            out += ["", "\(sub) Questions (\(s.questions.count))", ""]
            out += s.questions.map(question)
        }
        if !s.notes.isEmpty {
            out += ["", "\(sub) Notes (\(s.notes.count), oldest first)", ""]
            out += s.notes.map { note($0, edits: s.noteEdits[$0.id] ?? []) }
        }
        if !s.history.isEmpty {
            out += ["", "\(sub) History (\(s.history.count), oldest first)", ""]
            out += s.history.map { event(Fmt.iso($0.timestamp), $0.field, $0.oldValue, $0.newValue, by: nil) }
        }
        return out.joined(separator: "\n")
    }

    private static func fields(_ t: TodoTask, _ rel: TaskRelations) -> [String] {
        var out = ["- Status: \(t.status.rawValue)"]
        if let on = t.waitingOn {
            var w = "- Waiting on: \(on.rawValue)"
            if let since = t.waitingSince { w += " since \(Fmt.iso(since))" }
            if let reason = t.waitingReason, !reason.isEmpty { w += " — \(Fmt.oneLine(reason, max: 500))" }
            out.append(w)
        }
        if let blockers = rel.blockedBy[t.id], !blockers.isEmpty {
            out.append("- Blocked by (open): " + blockers.map(\.code).joined(separator: ", "))
        }
        if t.priority != .none { out.append("- Priority: \(t.priority.rawValue)") }
        if let pid = t.parentId { out.append("- Parent: \(rel.parentCodes[pid] ?? "#\(pid)")") }
        if let mid = t.milestoneId { out.append("- Milestone: \(rel.milestoneNames[mid] ?? "#\(mid)")") }
        if !t.tags.isEmpty { out.append("- Tags: " + t.tags.joined(separator: ", ")) }
        if let due = t.dueDate { out.append("- Due: \(Fmt.day(due))") }
        if let r = t.recurrence, !r.isEmpty { out.append("- Recurrence: \(r)") }
        if t.estimateSeconds > 0 { out.append("- Estimate: \(minutes(t.estimateSeconds))") }
        if t.effortSeconds > 0 { out.append("- Effort: \(minutes(t.effortSeconds))") }
        if let b = t.branch { out.append("- Branch: \(b)") }
        if let c = t.claim { out.append("- Claim: \(c.summary()) (expires \(Fmt.iso(c.expiresAt)))") }
        if let l = t.link, !l.isEmpty { out.append("- Link: \(l)") }
        var times = ["created \(Fmt.iso(t.createdAt))", "updated \(Fmt.iso(t.updatedAt))"]
        if let s = t.startedAt { times.append("started \(Fmt.iso(s))") }
        if let c = t.completedAt { times.append("completed \(Fmt.iso(c))") }
        out.append("- Times: " + times.joined(separator: " · "))
        return out
    }

    private static func minutes(_ seconds: Int) -> String { "\(max(1, seconds / 60)) min" }

    private static func linkLine(_ l: TaskLink) -> String {
        var line = "- [\(l.kind.rawValue)] \(l.url)"
        if let title = l.title, !title.isEmpty { line += " — \(title)" }
        var meta = [Fmt.iso(l.createdAt)]
        if let a = l.author { meta.append("by \(a.rawValue)") }
        if let src = l.source { meta.append("source \(src)") }
        return line + " (" + meta.joined(separator: ", ") + ")"
    }

    private static func question(_ q: Question) -> String {
        var head = ["#\(q.id)", q.kind.rawValue, q.status.rawValue]
        if !q.blocksTask { head.append("does not block the task") }
        var meta = ["asked \(Fmt.iso(q.askedAt))"]
        if let s = q.sessionId { meta.append("session \(s)") }
        var out = ["- " + head.joined(separator: " · ") + " — " + meta.joined(separator: ", "),
                   Fmt.indentedQuote(q.prompt)]
        if !q.context.isEmpty { out += ["  Context:", Fmt.indentedQuote(q.context)] }
        for (i, o) in q.options.enumerated() {
            var line = "  \(i + 1). \(o.label)"
            if !o.note.isEmpty { line += " — \(o.note)" }
            if o.recommended { line += " (recommended)" }
            out.append(line)
        }
        if let a = q.answer {
            var line = "  Answer"
            if let t = q.answeredAt { line += " (\(Fmt.iso(t)))" }
            if let c = q.answerChoice { line += ", option \(c + 1)" }
            out += [line + ":", Fmt.indentedQuote(a)]
        }
        if let t = q.resumedAt { out.append("  Resumed: \(Fmt.iso(t))") }
        if let r = q.cancelReason { out.append("  Cancelled: \(Fmt.oneLine(r, max: 500))") }
        return out.joined(separator: "\n")
    }

    private static func note(_ n: TaskNote, edits: [NoteEdit]) -> String {
        var meta = [Fmt.iso(n.timestamp), n.kind.rawValue]
        if let a = n.author { meta.append(a.rawValue) }
        if let s = n.sessionId { meta.append("session \(s)") }
        if let q = n.questionId { meta.append("question #\(q)") }
        if let e = n.editedAt { meta.append("edited \(Fmt.iso(e))") }
        var out = ["- " + meta.joined(separator: " · "), Fmt.indentedQuote(n.text)]
        for e in edits { out += ["  Earlier text (replaced \(Fmt.iso(e.timestamp))):", Fmt.indentedQuote(e.text)] }
        return out.joined(separator: "\n")
    }

    /// A history row. Short single-line values stay on the line; long or multi-line ones
    /// (a detail or body edit) follow in full as quotes.
    private static func event(_ ts: String, _ field: String, _ old: String, _ new: String, by: String?) -> String {
        let head = "- \(ts) · \(field)" + (by.map { " · \($0)" } ?? "")
        let short = { (v: String) in v.count <= 120 && !v.contains("\n") }
        if short(old) && short(new) {
            return head + ": " + (old.isEmpty ? "∅" : old) + " → " + (new.isEmpty ? "∅" : new)
        }
        var out = [head + ":"]
        out += ["  Before:", old.isEmpty ? "  ∅" : Fmt.indentedQuote(old)]
        out += ["  After:", new.isEmpty ? "  ∅" : Fmt.indentedQuote(new)]
        return out.joined(separator: "\n")
    }

    private static func wiki(_ s: ProjectSnapshot) -> [String] {
        guard !s.pages.isEmpty else { return [] }
        var out = ["", "## Wiki (\(s.pages.count) pages)"]
        for page in s.pages {
            out += ["", "### \(page.kind.display): \(page.title)", ""]
            if let d = page.decidedOn { out.append("- Decided on: \(d)") }
            if let o = page.outcome, !o.isEmpty { out.append("- Outcome: \(Fmt.oneLine(o, max: 1000))") }
            var meta = ["version \(page.version)", "by \(page.author.rawValue)"]
            if let sid = page.sessionId { meta.append("session \(sid)") }
            meta += ["created \(Fmt.iso(page.createdAt))", "updated \(Fmt.iso(page.updatedAt))"]
            out.append("- Page: #\(page.id) · " + meta.joined(separator: " · "))
            if !page.tasks.isEmpty {
                out.append("- Tasks: " + page.tasks.map { "\($0.code) (\($0.status.rawValue))" }.joined(separator: ", "))
            }
            if let prov = provenance(page.provenance) { out.append("- Source: " + prov) }
            if !page.body.isEmpty { out += ["", Fmt.quote(page.body)] }
            let events = s.pageHistory[page.id] ?? []
            if !events.isEmpty {
                out += ["", "#### History (\(events.count), oldest first)", ""]
                out += events.map { event(Fmt.iso($0.timestamp), $0.field, $0.oldValue, $0.newValue,
                                          by: $0.author?.rawValue) }
            }
        }
        return out
    }

    private static func provenance(_ p: PageProvenance) -> String? {
        guard !p.isEmpty else { return nil }
        var parts: [String] = []
        if let v = p.source { parts.append(v) }
        if let v = p.key { parts.append("key \(v)") }
        if let v = p.author { parts.append("author \(v)") }
        if let v = p.session { parts.append("session \(v)") }
        if let v = p.timestamp { parts.append("written \(Fmt.iso(v))") }
        return parts.joined(separator: " · ")
    }
}

/// A project snapshot as JSON: the machine-checkable form, same field names as the MCP
/// tools (get_task, get_page, list_milestones), nothing left out or shortened.
enum ExportJSON {
    static func project(_ s: ProjectSnapshot) -> [String: Any] {
        let p = s.project
        var d: [String: Any] = ["code": p.code, "name": p.name, "id": p.id, "created_at": Fmt.iso(p.createdAt),
                                "sort_order": p.sortOrder]
        if !p.detail.isEmpty { d["description"] = p.detail }
        if let f = p.repoPath { d["repo_path"] = f }
        if let a = p.archivedAt { d["archived_at"] = Fmt.iso(a) }
        d["counts"] = Dictionary(uniqueKeysWithValues: s.counts.map { ($0.key, $0.value) })
        d["guide_versions"] = s.guides.map(guide)
        d["milestones"] = s.milestones.map(milestone)
        d["tasks"] = s.tasks.map { task($0, s.rel) }
        d["wiki"] = s.pages.map { page($0, history: s.pageHistory[$0.id] ?? []) }
        return d
    }

    static func guide(_ g: GuideVersion) -> [String: Any] {
        var d: [String: Any] = ["version": g.id, "ts": Fmt.iso(g.timestamp), "markdown": g.markdown,
                                "author": g.author.rawValue]
        if let s = g.sessionId { d["session"] = s }
        if let r = g.reason { d["reason"] = r }
        return d
    }

    private static func milestone(_ m: Milestone) -> [String: Any] {
        var d: [String: Any] = ["id": m.id, "name": m.name, "done": m.done, "total": m.total, "open": m.open,
                                "sort_order": m.sortOrder, "created_at": Fmt.iso(m.createdAt),
                                "updated_at": Fmt.iso(m.updatedAt)]
        if !m.detail.isEmpty { d["description"] = m.detail }
        if !m.acceptance.isEmpty { d["acceptance"] = m.acceptance }
        if let t = m.targetDate { d["target_date"] = Fmt.iso(t) }
        if let c = m.closedAt { d["closed_at"] = Fmt.iso(c) }
        return d
    }

    static func task(_ s: TaskSnapshot, _ rel: TaskRelations) -> [String: Any] {
        let t = s.task
        var d: [String: Any] = ["id": t.id, "code": t.code, "title": t.title, "status": t.status.rawValue,
                                "sort_order": t.sortOrder, "created_at": Fmt.iso(t.createdAt),
                                "updated_at": Fmt.iso(t.updatedAt)]
        if !t.detail.isEmpty { d["detail"] = t.detail }
        if let on = t.waitingOn { d["waiting_on"] = on.rawValue }
        if let r = t.waitingReason, !r.isEmpty { d["waiting_reason"] = r }
        if let since = t.waitingSince { d["waiting_since"] = Fmt.iso(since) }
        if rel.blockedIds.contains(t.id) { d["blocked"] = true }
        if t.priority != .none { d["priority"] = t.priority.rawValue }
        if let pid = t.parentId { d["parent"] = rel.parentCodes[pid] ?? String(pid) }
        if let mid = t.milestoneId {
            d["milestone_id"] = mid
            if let name = rel.milestoneNames[mid] { d["milestone"] = name }
        }
        if !t.tags.isEmpty { d["tags"] = t.tags }
        if let due = t.dueDate { d["due_date"] = Fmt.iso(due) }
        if let r = t.recurrence, !r.isEmpty { d["recurrence"] = r }
        if t.estimateSeconds > 0 { d["estimate_seconds"] = t.estimateSeconds }
        if t.effortSeconds > 0 { d["effort_seconds"] = t.effortSeconds }
        if let b = t.branch { d["branch"] = b }
        if let c = t.claim {
            var cd: [String: Any] = ["holder": c.holder, "claimed_at": Fmt.iso(c.claimedAt),
                                     "heartbeat_at": Fmt.iso(c.heartbeatAt), "expires_at": Fmt.iso(c.expiresAt)]
            if let label = c.label { cd["label"] = label }
            d["claim"] = cd
        }
        if let l = t.link, !l.isEmpty { d["link"] = l }
        if let s = t.startedAt { d["started_at"] = Fmt.iso(s) }
        if let c = t.completedAt { d["completed_at"] = Fmt.iso(c) }
        if !s.links.isEmpty { d["links"] = s.links.map(link) }
        if !s.related.isEmpty { d["relations"] = relations(s.related) }
        if !s.questions.isEmpty { d["questions"] = s.questions.map(question) }
        if !s.notes.isEmpty { d["notes"] = s.notes.map { note($0, edits: s.noteEdits[$0.id] ?? []) } }
        if !s.history.isEmpty {
            d["history"] = s.history.map { e -> [String: Any] in
                ["id": e.id, "ts": Fmt.iso(e.timestamp), "field": e.field, "old": e.oldValue, "new": e.newValue]
            }
        }
        return d
    }

    private static func link(_ l: TaskLink) -> [String: Any] {
        var d: [String: Any] = ["id": l.id, "kind": l.kind.rawValue, "url": l.url, "created_at": Fmt.iso(l.createdAt)]
        if let title = l.title { d["title"] = title }
        if let author = l.author { d["author"] = author.rawValue }
        if let source = l.source { d["source"] = source }
        return d
    }

    private static func relations(_ r: RelatedTasks) -> [String: Any] {
        var d: [String: Any] = [:]
        for kind in RelationKind.allCases where !r[kind].isEmpty {
            d[kind.rawValue] = r[kind].map { ["code": $0.code, "title": $0.title, "status": $0.status.rawValue] }
        }
        return d
    }

    private static func question(_ q: Question) -> [String: Any] {
        var d: [String: Any] = ["id": q.id, "question": q.prompt, "kind": q.kind.rawValue,
                                "status": q.status.rawValue, "blocks_task": q.blocksTask,
                                "asked_at": Fmt.iso(q.askedAt)]
        if !q.context.isEmpty { d["context"] = q.context }
        if !q.options.isEmpty {
            d["options"] = q.options.map { o -> [String: Any] in
                var od: [String: Any] = ["label": o.label]
                if !o.note.isEmpty { od["note"] = o.note }
                if o.recommended { od["recommended"] = true }
                return od
            }
        }
        if let s = q.sessionId { d["session"] = s }
        if let a = q.answer { d["answer"] = a }
        if let c = q.answerChoice { d["choice"] = c + 1 }
        if let r = q.cancelReason { d["cancel_reason"] = r }
        if let t = q.answeredAt { d["answered_at"] = Fmt.iso(t) }
        if let t = q.resumedAt { d["resumed_at"] = Fmt.iso(t) }
        return d
    }

    private static func note(_ n: TaskNote, edits: [NoteEdit]) -> [String: Any] {
        var d: [String: Any] = ["id": n.id, "ts": Fmt.iso(n.timestamp), "kind": n.kind.rawValue, "text": n.text]
        if let a = n.author { d["author"] = a.rawValue }
        if let s = n.sessionId { d["session"] = s }
        if let q = n.questionId { d["question_id"] = q }
        if let e = n.statusEventId { d["status_event_id"] = e }
        if let e = n.editedAt { d["edited_at"] = Fmt.iso(e) }
        if !edits.isEmpty {
            d["earlier_texts"] = edits.map { ["replaced_at": Fmt.iso($0.timestamp), "text": $0.text] }
        }
        return d
    }

    private static func page(_ p: ProjectPage, history: [PageEvent]) -> [String: Any] {
        var d: [String: Any] = ["id": p.id, "kind": p.kind.rawValue, "title": p.title, "body": p.body,
                                "version": p.version, "author": p.author.rawValue,
                                "created_at": Fmt.iso(p.createdAt), "updated_at": Fmt.iso(p.updatedAt)]
        if let v = p.decidedOn { d["decided_on"] = v }
        if let v = p.outcome { d["outcome"] = v }
        if let v = p.sessionId { d["session"] = v }
        if !p.tasks.isEmpty {
            d["tasks"] = p.tasks.map { ["code": $0.code, "title": $0.title, "status": $0.status.rawValue] }
        }
        let prov = p.provenance
        if let v = prov.source { d["source"] = v }
        if let v = prov.key { d["source_key"] = v }
        if let v = prov.author { d["source_author"] = v }
        if let v = prov.session { d["source_session"] = v }
        if let v = prov.timestamp { d["source_timestamp"] = Fmt.iso(v) }
        if !history.isEmpty {
            d["history"] = history.map { e -> [String: Any] in
                var h: [String: Any] = ["id": e.id, "ts": Fmt.iso(e.timestamp), "field": e.field,
                                        "old": e.oldValue, "new": e.newValue]
                if let a = e.author { h["author"] = a.rawValue }
                if let s = e.sessionId { h["session"] = s }
                return h
            }
        }
        return d
    }
}
