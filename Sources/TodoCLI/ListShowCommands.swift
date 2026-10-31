import Foundation

/// `questbits list`: the projects, or with a project code, its tasks in board order.
enum ListCommand {
    static let command = CLICommand(
        name: "list",
        usage: "list [<project>] [--all] [--status <s,...>] [--archived]",
        summary: "List projects, or one project's tasks in board order.",
        details: """
        Without a project: every active project with its open counts and folder
        (--archived adds archived projects).
        With a project code: its tasks in board order, subtasks indented under their parent.
          --all            every status (default: the open ones: todo, in_progress, waiting)
          --status <s,...> only these statuses (todo, in_progress, waiting, done, dropped)
        """,
        options: ["status"],
        flags: ["all", "archived"],
        run: { try run($0, $1) })

    static func run(_ args: CLIArgs, _ ctx: CLIContext) throws -> Int32 {
        guard args.positionals.count <= 1 else { throw CLIError.usage("expected at most one project code") }
        try ctx.requireDatabase()
        let statuses = try statusFilter(args)
        let text = try ctx.withStore { store -> String in
            if let code = args.positionals.first {
                return try tasks(code: code, statuses: statuses, store: store)
            }
            return try projects(includeArchived: args.has("archived"), store: store)
        }
        ctx.write(text)
        return 0
    }

    private static func statusFilter(_ args: CLIArgs) throws -> [TaskStatus]? {
        let names = args.list("status")
        if !names.isEmpty {
            return try names.map { name in
                guard let s = TaskStatus(rawValue: name) else {
                    throw CLIError.usage("unknown status '\(name)' (use: "
                        + TaskStatus.allCases.map(\.rawValue).joined(separator: ", ") + ")")
                }
                return s
            }
        }
        return args.has("all") ? nil : TaskStatus.allCases.filter { !$0.isClosed }
    }

    private static func projects(includeArchived: Bool, store: Store) throws -> String {
        let projects = try store.listProjects(includeArchived: includeArchived)
        guard !projects.isEmpty else { return "No projects.\n" }
        let width = projects.map(\.code.count).max() ?? 0
        return try projects.map { p -> String in
            let c = try store.openTaskCounts(projectId: p.id)
            var line = p.code.padding(toLength: width, withPad: " ", startingAt: 0) + "  \(p.name)"
            if p.isArchived { line += " [archived]" }
            line += " — \(c.open) open (\(c.inProgress) in progress, \(c.waitingOnUser) waiting on you)"
            if let folder = p.repoPath { line += " — \(folder)" }
            return line
        }.joined(separator: "\n") + "\n"
    }

    private static func tasks(code: String, statuses: [TaskStatus]?, store: Store) throws -> String {
        guard let pid = store.projectId(forCode: code) else { throw CLIError.failure("no project with code \(code)") }
        let tasks = try store.listTasks(matching: TaskFilter(projectId: pid, statuses: statuses, sort: .board))
        guard !tasks.isEmpty else { return "No tasks.\n" }
        let rel = try store.taskRelations(for: tasks)
        let listed = Set(tasks.map(\.id))
        // A subtask is indented only when its parent is in the list too.
        return tasks.map { t in
            (t.parentId.map(listed.contains) == true ? "  " : "") + Fmt.taskLine(t, rel)
        }.joined(separator: "\n") + "\n"
    }
}

/// `questbits show <code>`: one task in full, as markdown (or JSON): every field, links,
/// relations, questions, every note and the change history — the same section `export` writes.
enum ShowCommand {
    static let command = CLICommand(
        name: "show",
        usage: "show <task-code> [--format md|json]",
        summary: "Show one task in full: fields, links, relations, questions, all notes, history.",
        details: "--format md (default) or json (the task as export's JSON writes it).",
        options: ["format"],
        run: { try run($0, $1) })

    static func run(_ args: CLIArgs, _ ctx: CLIContext) throws -> Int32 {
        guard args.positionals.count == 1, let code = args.positionals.first else {
            throw CLIError.usage("expected one task code, e.g. QUE-20")
        }
        let format = args.value("format") ?? "md"
        guard format == "md" || format == "json" else { throw CLIError.usage("--format must be md or json") }
        try ctx.requireDatabase()
        let text = try ctx.withStore { store -> String in
            guard let id = store.taskId(forCode: code) else {
                if store.projectId(forCode: code) != nil {
                    throw CLIError.failure("\(code) is a project; use `list \(code)` or `export --project \(code)`")
                }
                throw CLIError.failure("no task with code \(code)")
            }
            let task = try store.getTask(id: id)
            let rel = try store.taskRelations(for: [task])
            let snapshot = try TaskSnapshot.read(task, store: store, questions: nil)
            if format == "json" { return try Fmt.json(ExportJSON.task(snapshot, rel)) }
            return ExportMarkdown.task(snapshot, rel, headingLevel: 1) + "\n"
        }
        ctx.write(text)
        return 0
    }
}
