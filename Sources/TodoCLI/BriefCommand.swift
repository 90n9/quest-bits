import Foundation

/// `questbits brief [--path <dir>]`: what an agent starting a session in a folder should know,
/// as short markdown lines (not JSON): the project the folder maps to (find_project's rule),
/// its guide, the work in progress, what waits on the user, the next tasks in board order,
/// open milestones and the wiki. Prints nothing and exits 0 when the folder maps to no
/// project (or there is no database), so a session-start hook stays silent outside projects.
enum BriefCommand {
    static let command = CLICommand(
        name: "brief",
        usage: "brief [--path <dir>] [--next <n>]",
        summary: "Short markdown brief of the project a folder belongs to (silent when none).",
        details: """
        --path <dir>  folder to look up (default: the current directory); the project whose
                      repo folder holds it most specifically, as find_project picks it
        --next <n>    how many next tasks to list (default 5, 0 = none)
        """,
        options: ["path", "next"],
        run: { try run($0, $1) })

    static let defaultNext = 5
    static let listCap = 10          // in progress / waiting lines shown before "…and N more"
    static let milestoneCap = 5
    static let decisionCap = 3
    static let guideCap = 3_000      // characters of the project guide; the work comes after it

    static func run(_ args: CLIArgs, _ ctx: CLIContext) throws -> Int32 {
        guard args.positionals.isEmpty else { throw CLIError.usage("unexpected argument '\(args.positionals[0])'") }
        var next = defaultNext
        if let raw = args.value("next") {
            guard let n = Int(raw), n >= 0 else { throw CLIError.usage("--next must be a number ≥ 0") }
            next = n
        }
        let path = ctx.absolutePath(args.value("path") ?? ctx.cwd)
        guard ctx.databaseExists else { return 0 }
        let text = try ctx.withStore { store -> String in
            guard let project = Store.bestProject(for: path, among: try store.listProjects(includeArchived: false))
            else { return "" }
            return try render(project, store: store, next: next)
        }
        if !text.isEmpty { ctx.write(text) }
        return 0
    }

    static func render(_ p: Project, store: Store, next: Int) throws -> String {
        let open = try store.listTasks(matching: TaskFilter(
            projectId: p.id, statuses: [.inProgress, .waiting, .todo], sort: .board))
        let rel = try store.taskRelations(for: open)
        let inProgress = open.filter { $0.status == .inProgress }
        let waitingOnUser = open.filter { $0.status == .waiting && $0.waitingOn == .user }
        let waitingOther = open.filter { $0.status == .waiting && $0.waitingOn != .user }
        let todo = open.filter { $0.status == .todo }
        let ready = todo.filter { !rel.blockedIds.contains($0.id) }

        var out: [String] = ["# QuestBits project \(p.code) · \(p.name)"]
        if let folder = p.repoPath { out.append("Folder: \(folder)") }
        var parts = ["\(inProgress.count) in progress", "\(waitingOnUser.count) waiting on you"]
        if !waitingOther.isEmpty { parts.append("\(waitingOther.count) waiting on others") }
        parts.append("\(todo.count) todo")
        out.append("Open: " + Fmt.count(open.count, "task") + " (" + parts.joined(separator: ", ") + ")")

        if let guide = try store.guide(projectId: p.id),
           !guide.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += ["", "## Project guide", guideExcerpt(guide.markdown, code: p.code)]
        }
        section(&out, "In progress", inProgress, rel)
        section(&out, "Waiting on you", waitingOnUser, rel)
        if next > 0 && !ready.isEmpty {
            out += ["", "## Next (board order)"]
            out += ready.prefix(next).map { "- " + Fmt.taskLine($0, rel) }
            let blocked = todo.count - ready.count
            let more = ready.count - min(next, ready.count)
            if more > 0 || blocked > 0 {
                out.append("- …" + [more > 0 ? "\(more) more ready" : nil, blocked > 0 ? "\(blocked) blocked" : nil]
                    .compactMap { $0 }.joined(separator: ", "))
            }
        }
        out += try milestones(p, store: store)
        out += try wiki(p, store: store)
        out += ["", "Details: get_task <code>; wiki: search_pages / get_page (QuestBits MCP)."]
        return out.joined(separator: "\n") + "\n"
    }

    /// The project guide, cut at a line boundary after `guideCap` characters so a long guide
    /// never pushes the work out of a session-start hook's context (capped by Claude Code).
    static func guideExcerpt(_ markdown: String, code: String) -> String {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > guideCap else { return text }
        var kept = String(text.prefix(guideCap))
        if let lastBreak = kept.lastIndex(of: "\n") { kept = String(kept[..<lastBreak]) }
        return kept + "\n…the guide goes on: get_guide \(code) has all of it."
    }

    private static func section(_ out: inout [String], _ title: String, _ tasks: [TodoTask], _ rel: TaskRelations) {
        guard !tasks.isEmpty else { return }
        out += ["", "## \(title)"]
        out += tasks.prefix(listCap).map { "- " + Fmt.taskLine($0, rel) }
        if tasks.count > listCap { out.append("- …\(tasks.count - listCap) more") }
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
