import Foundation

/// A Claude Code session's own work, for `brief --session <id>` and the SessionStart hook
/// after a compaction (`hook session-start --after-compact`): the summary Claude Code keeps
/// loses the details an agent needs to carry on, so they come back from QuestBits.
///
///   # QuestBits: this session's work
///   ## QUE-38 [in_progress] Title — Claimed by session 1a2b3c4d · 3 min ago
///   Part of QUE-2 Title
///   Latest decisions: / Latest notes: / Questions:   (newest first, one line each)
///   ## Other claimed tasks                           (past `claimedCap` or `workBudget`)
///   ## Questions on other tasks                      (asked from this session)
///   ## Ask loop                                      (the rules, in short)
///
/// Claims are found by the session id (`Store.claimedTasks(holderId:)`), the holder the MCP
/// server records for a session it knows; questions by the session the MCP server saw them
/// come from, or the session label (the id, or `<id>/<suffix>` from a subagent).
extension BriefCommand {
    /// The section, or "" when the session holds no claim and has no open question (and
    /// `idleHint` is false; with it, a short line says how to take work).
    static func sessionWork(_ sessionId: String, store: Store, idleHint: Bool) throws -> String {
        let sid = sessionId.lowercased()
        let claimed = try store.claimedTasks(holderId: sid)
        let claimedIds = Set(claimed.map(\.id))
        let asked = try store.questions(statuses: [.open, .answered]).filter { q in
            claimedIds.contains(q.taskId) || q.agentSessionId == sid || isOwnLabel(q.sessionId, sid)
        }
        if claimed.isEmpty && asked.isEmpty && !idleHint { return "" }

        var out = ["# QuestBits: this session's work"]
        if claimed.isEmpty {
            out.append("This session holds no claim. Take work with next_task (claim: true) or claim_task.")
        }
        let rel = try store.taskRelations(for: claimed)
        // In full while they fit `workBudget` (the first always), so the ask loop and the
        // project brief after them stay inside the hook's cap; the rest get one line each.
        var used = out.joined(separator: "\n").count + askLoop.joined(separator: "\n").count
        var shown = Set<Int64>()
        for t in claimed.prefix(claimedCap) {
            let block = try taskBlock(t, rel, asked.filter { $0.taskId == t.id }, store: store)
            let size = block.joined(separator: "\n").count
            if !shown.isEmpty && used + size > workBudget { break }
            out += block
            used += size
            shown.insert(t.id)
        }
        let rest = claimed.filter { !shown.contains($0.id) }
        if !rest.isEmpty {
            out += ["", "## Other claimed tasks"]
            out += rest.map { "- " + Fmt.taskLine($0, rel) }
        }
        let elsewhere = asked.filter { !shown.contains($0.taskId) }
        if !elsewhere.isEmpty {
            out += ["", "## Questions on other tasks"]
            out += elsewhere.prefix(listCap).map { "- \($0.taskCode): " + questionLine($0) }
            if elsewhere.count > listCap { out.append("- …\(elsewhere.count - listCap) more: get_answers") }
        }
        out += ["", "## Ask loop"] + askLoop
        return out.joined(separator: "\n") + "\n"
    }

    static var askLoop: [String] {
        [
            "- Before new work, call get_answers with your session; act on answered questions first "
                + "(resume_question, then do what the answer says).",
            "- When the user must decide: ask_user with 2–4 options and the one you recommend, then keep working; "
                + "never end your turn just to wait.",
            "- Record decisions you make yourself with add_note (kind decision). A claim holds "
                + "\(Int(Store.claimTTL / 60)) min after its last heartbeat or write to the task.",
            "- Push, release, posting or anything irreversible: ask and wait for the answer."
        ]
    }

    /// One claimed task: its line, its parent, its latest decisions and other notes, and
    /// its open or answered questions.
    private static func taskBlock(_ t: TodoTask, _ rel: TaskRelations, _ questions: [Question],
                                  store: Store) throws -> [String] {
        var out = ["", "## " + Fmt.taskLine(t, rel)]
        if let pid = t.parentId, let parent = try? store.getTask(id: pid) {
            out.append("Part of \(parent.code) \(Fmt.oneLine(parent.title, max: 100))")
        }
        let notes = try store.notes(taskId: t.id, limit: 50).filter { $0.kind != .question }
        let decisions = notes.filter { $0.kind == .decision }.prefix(decisionNotes)
        let others = notes.filter { $0.kind != .decision }.prefix(otherNotes)
        if !decisions.isEmpty {
            out.append("Latest decisions:")
            out += decisions.map { "- \(TaskClaim.ago($0.timestamp)): " + Fmt.oneLine($0.text, max: noteWidth) }
        }
        if !others.isEmpty {
            out.append("Latest notes:")
            out += others.map { n in
                let kind = n.kind == .note ? "" : n.kind.rawValue + ", "
                return "- \(kind)\(TaskClaim.ago(n.timestamp)): " + Fmt.oneLine(n.text, max: noteWidth)
            }
        }
        if !questions.isEmpty {
            out.append("Questions:")
            out += questions.map { "- " + questionLine($0) }
        }
        return out
    }

    /// "#12 open: prompt (asked 5 min ago)", or "#13 answered “…”: resume_question 13, then act on it";
    /// a disagreement: "#14 The user disagrees with your decision: “…” Why: “…”: resume_question 14, …".
    static func questionLine(_ q: Question) -> String {
        let prompt = Fmt.oneLine(q.prompt, max: 160)
        guard q.status == .answered else {
            return "#\(q.id) open: \(prompt) (asked \(TaskClaim.ago(q.askedAt)))"
        }
        if q.kind == .disagree {
            return "#\(q.id) \(prompt) Why: “\(Fmt.oneLine(q.answer ?? "", max: 200))”: "
                + "resume_question \(q.id), then reconsider and record what you do"
        }
        let picked = q.answerChoice.flatMap { q.options.indices.contains($0) ? q.options[$0].label : nil }
        let answer = [picked, q.answer.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · ")
        return "#\(q.id) answered: \(prompt) → “\(Fmt.oneLine(answer, max: 200))”: resume_question \(q.id), then act on it"
    }

    /// Whether a question's session label is this session's: the id, or `<id>/<suffix>`.
    private static func isOwnLabel(_ label: String?, _ sid: String) -> Bool {
        guard let label = label?.lowercased() else { return false }
        return label == sid || label.hasPrefix(sid + "/")
    }
}
