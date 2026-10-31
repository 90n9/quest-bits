import Foundation

/// `questbits brief [--path <dir>]`: what an agent starting a session in a folder should know,
/// as short markdown lines (not JSON): the project the folder maps to (find_project's rule),
/// its guide, the work in progress, what waits on the user, the next tasks as next_task
/// offers them, open milestones and the wiki. Prints nothing and exits 0 when the folder maps
/// to no project (or there is no database), so a session-start hook stays silent outside projects.
///
/// `--session <id>` puts that Claude Code session's own work first (`sessionWork`): the
/// tasks it claimed, their latest decisions and notes, its open questions, and the ask loop
/// in short. The SessionStart hook prints the same after a compaction (`hook session-start
/// --after-compact`), when what the session was doing has just been summarised away.
enum BriefCommand {
    static let command = CLICommand(
        name: "brief",
        usage: "brief [--path <dir>] [--next <n>] [--session <id>]",
        summary: "Short markdown brief of the project a folder belongs to (silent when none).",
        details: """
        --path <dir>  folder to look up (default: the current directory); the project whose
                      repo folder holds it most specifically, as find_project picks it
        --next <n>    how many next tasks to list (default 5, 0 = none), in the order
                      next_task offers them
        --session <id>  a Claude Code session id: first its claimed tasks (latest decisions and
                      notes, open questions) and the ask loop, then a shorter project brief;
                      what the SessionStart hook prints after a compaction
        """,
        options: ["path", "next", "session"],
        run: { try run($0, $1) })

    static let defaultNext = 5
    static let listCap = 10          // in progress / waiting lines shown before "…and N more"
    static let milestoneCap = 5
    static let decisionCap = 3
    static let guideCap = 3_000      // characters of the project guide; the work comes after it
    static let shortGuideCap = 1_500 // the guide after a session's own work (--session, after compact)
    static let shortNext = 3
    static let claimedCap = 3        // claimed tasks shown in full at most (within workBudget)
    static let decisionNotes = 5     // per claimed task: latest decisions, and latest other notes
    static let otherNotes = 3
    static let noteWidth = 240
    static let workBudget = 4_500    // characters of a session's work in full; the brief follows it

    static func run(_ args: CLIArgs, _ ctx: CLIContext) throws -> Int32 {
        guard args.positionals.isEmpty else { throw CLIError.usage("unexpected argument '\(args.positionals[0])'") }
        var next = defaultNext
        if let raw = args.value("next") {
            guard let n = Int(raw), n >= 0 else { throw CLIError.usage("--next must be a number ≥ 0") }
            next = n
        }
        let path = ctx.absolutePath(args.value("path") ?? ctx.cwd)
        let session = args.value("session").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if let session, session.isEmpty { throw CLIError.usage("--session needs a session id") }
        guard ctx.databaseExists else { return 0 }
        let text = try ctx.withStore { store -> String in
            let project = Store.bestProject(for: path, among: try store.listProjects(includeArchived: false))
            if let session {
                return try sessionBrief(session, project: project, store: store,
                                        next: args.value("next") == nil ? shortNext : next)
            }
            guard let project else { return "" }
            return try render(project, store: store, next: next)
        }
        if !text.isEmpty { ctx.write(text) }
        return 0
    }

    /// `--session`: the session's own work, then the project brief with a shorter guide;
    /// empty when the session holds no claim, asked nothing open, and the folder has no project.
    static func sessionBrief(_ sessionId: String, project: Project?, store: Store, next: Int) throws -> String {
        let work = try sessionWork(sessionId, store: store, idleHint: project != nil)
        guard let project else { return work }
        let brief = try render(project, store: store, next: next, holderId: sessionId, guideCap: shortGuideCap)
        return work.isEmpty ? brief : work + "\n" + brief
    }

    static func render(_ p: Project, store: Store, next: Int, holderId: String? = nil,
                       guideCap: Int = guideCap) throws -> String {
        let open = try store.listTasks(matching: TaskFilter(
            projectId: p.id, statuses: [.inProgress, .waiting, .todo], sort: .board))
        let rel = try store.taskRelations(for: open)
        let inProgress = open.filter { $0.status == .inProgress }
        let waitingOnUser = open.filter { $0.status == .waiting && $0.waitingOn == .user }
        let waitingOther = open.filter { $0.status == .waiting && $0.waitingOn != .user }
        let todo = open.filter { $0.status == .todo }

        var out: [String] = ["# QuestBits project \(p.code) · \(p.name)"]
        if let folder = p.repoPath { out.append("Folder: \(folder)") }
        var parts = ["\(inProgress.count) in progress", "\(waitingOnUser.count) waiting on you"]
        if !waitingOther.isEmpty { parts.append("\(waitingOther.count) waiting on others") }
        parts.append("\(todo.count) todo")
        out.append("Open: " + Fmt.count(open.count, "task") + " (" + parts.joined(separator: ", ") + ")")

        if let guide = try store.guide(projectId: p.id),
           !guide.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += ["", "## Project guide", guideExcerpt(guide.markdown, code: p.code, cap: guideCap)]
        }
        section(&out, "In progress", inProgress, rel)
        section(&out, "Waiting on you", waitingOnUser, rel)
        out += try disagreements(p, store: store)
        if next > 0 {
            out += try nextSection(p, store: store, next: next, holderId: holderId, rel: rel)
        }
        out += try milestones(p, store: store)
        out += try wiki(p, store: store)
        out += ["", "Details: get_task <code>; wiki: search_pages / get_page (QuestBits MCP)."]
        return out.joined(separator: "\n") + "\n"
    }

    /// The project guide, cut at a line boundary after `guideCap` characters so a long guide
    /// never pushes the work out of a session-start hook's context (capped by Claude Code).
    static func guideExcerpt(_ markdown: String, code: String, cap: Int = guideCap) -> String {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > cap else { return text }
        var kept = String(text.prefix(cap))
        if let lastBreak = kept.lastIndex(of: "\n") { kept = String(kept[..<lastBreak]) }
        return kept + "\n…the guide goes on: get_guide \(code) has all of it."
    }

    /// The tasks next_task would offer, in its order and by its rule (`Store.nextTasks`,
    /// read-only: nothing is claimed), so the brief and next_task agree. `holderId`: the
    /// session the brief is for, whose own claimed todo tasks stay eligible.
    private static func nextSection(_ p: Project, store: Store, next: Int, holderId: String?,
                                    rel: TaskRelations) throws -> [String] {
        let ready = try store.nextTasks(projectId: p.id, holderId: holderId)
        let skips = try store.nextTaskSkips(projectId: p.id, holderId: holderId)
        var out = ["", "## Next (board order, as next_task offers them)"]
        out += ready.prefix(next).map { "- " + Fmt.taskLine($0, rel) }
        let more = ready.count - min(next, ready.count)
        let rest = [more > 0 ? "\(more) more ready" : nil,
                    skips.blocked > 0 ? "\(skips.blocked) blocked" : nil,
                    skips.claimed > 0 ? Fmt.count(skips.claimed, "claimed by another session",
                                                  "claimed by other sessions") : nil].compactMap { $0 }
        if ready.isEmpty && rest.isEmpty { return [] }
        if ready.isEmpty {
            out.append("- none ready" + (rest.isEmpty ? "" : ": " + rest.joined(separator: ", ")))
        } else if !rest.isEmpty {
            out.append("- …" + rest.joined(separator: ", "))
        }
        return out
    }

    private static func section(_ out: inout [String], _ title: String, _ tasks: [TodoTask], _ rel: TaskRelations) {
        guard !tasks.isEmpty else { return }
        out += ["", "## \(title)"]
        out += tasks.prefix(listCap).map { "- " + Fmt.taskLine($0, rel) }
        if tasks.count > listCap { out.append("- …\(tasks.count - listCap) more") }
    }

    /// The user's disagreements with agents' decisions that no agent has picked up yet
    /// (QUE-39), so whichever session starts here sees them.
    private static func disagreements(_ p: Project, store: Store) throws -> [String] {
        let pending = try store.questions(statuses: [.answered], projectId: p.id).filter { $0.kind == .disagree }
        guard !pending.isEmpty else { return [] }
        var out = ["", "## The user disagrees (reconsider before new work)"]
        out += pending.prefix(listCap).map { "- \($0.taskCode): " + questionLine($0) }
        if pending.count > listCap { out.append("- …\(pending.count - listCap) more: get_answers") }
        return out
    }

    private static func milestones(_ p: Project, store: Store) throws -> [String] {
        let open = try store.milestones(projectId: p.id, includeClosed: false)
        guard !open.isEmpty else { return [] }
        var out = ["", "## Milestones"]
        for m in open.prefix(milestoneCap) {
            var line = "- \(m.name): \(m.done)/\(m.total) done"
            if let target = m.targetDate { line += ", target \(Fmt.day(target))" }
            out.append(line)
        }
        if open.count > milestoneCap { out.append("- …\(open.count - milestoneCap) more") }
        return out
    }

    private static func wiki(_ p: Project, store: Store) throws -> [String] {
        let counts = try store.pageCounts(projectId: p.id)
        let decisions = counts[.decision] ?? 0, notes = counts[.note] ?? 0
        guard decisions + notes > 0 else { return [] }
        var out = ["", "## Wiki", Fmt.count(decisions, "decision") + ", " + Fmt.count(notes, "note") + "."]
        let latest = try store.pages(projectId: p.id, kind: .decision).prefix(decisionCap)
        if !latest.isEmpty {
            out.append("Latest decisions:")
            for page in latest {
                var line = "- " + [page.decidedOn, page.title].compactMap { $0 }.joined(separator: " ")
                if let outcome = page.outcome, !outcome.isEmpty { line += ": " + Fmt.oneLine(outcome, max: 140) }
                out.append(line)
            }
        }
        return out
    }
}
