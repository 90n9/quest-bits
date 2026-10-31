import Foundation

/// Everything export and show write about one task, read in full: every note (with the
/// earlier texts of edited ones), the whole change history, links, relations and questions.
/// Notes and history are oldest first, as a log reads.
struct TaskSnapshot {
    let task: TodoTask
    let notes: [TaskNote]
    let noteEdits: [Int64: [NoteEdit]]      // note id → its earlier texts, newest first
    let history: [TaskEvent]
    let links: [TaskLink]
    let related: RelatedTasks
    let questions: [Question]

    /// `questions` nil reads the task's own; export passes the project's, grouped once.
    static func read(_ task: TodoTask, store: Store, questions: [Question]?) throws -> TaskSnapshot {
        let notes = Array(try store.notes(taskId: task.id).reversed())
        var edits: [Int64: [NoteEdit]] = [:]
        for n in notes where n.editedAt != nil { edits[n.id] = try store.noteEdits(noteId: n.id) }
        return TaskSnapshot(
            task: task, notes: notes, noteEdits: edits,
            history: Array(try store.taskHistory(taskId: task.id).reversed()),
            links: try store.links(taskId: task.id),
            related: try store.relatedTasks(taskId: task.id),
            questions: try questions ?? store.questions(statuses: QuestionStatus.allCases, taskId: task.id))
    }

    var relationCount: Int { RelationKind.allCases.reduce(0) { $0 + related[$1].count } }
}

/// One project, read in full for export: its guide with every earlier version, milestones
/// (closed ones too), every task in board order (any status) as a `TaskSnapshot`, and its
/// wiki pages with their history.
struct ProjectSnapshot {
    let project: Project
    let guides: [GuideVersion]             // newest first; the first is the current guide
    let milestones: [Milestone]
    let tasks: [TaskSnapshot]
    let rel: TaskRelations
    let pages: [ProjectPage]
    let pageHistory: [Int64: [PageEvent]]  // page id → its events, oldest first

    static let unlimited = 1_000_000

    static func read(_ p: Project, store: Store) throws -> ProjectSnapshot {
        let tasks = try store.listTasks(matching: TaskFilter(projectId: p.id, sort: .board))
        let questions = Dictionary(grouping: try store.questions(statuses: QuestionStatus.allCases, projectId: p.id),
                                   by: \.taskId)
        let pages = try store.pages(projectId: p.id)
        var history: [Int64: [PageEvent]] = [:]
        for page in pages { history[page.id] = Array(try store.pageHistory(pageId: page.id, limit: unlimited).reversed()) }
        return ProjectSnapshot(
            project: p,
            guides: try store.guideHistory(projectId: p.id, limit: unlimited),
            milestones: try store.milestones(projectId: p.id, includeClosed: true),
            tasks: try tasks.map { try TaskSnapshot.read($0, store: store, questions: questions[$0.id] ?? []) },
            rel: try store.taskRelations(for: tasks),
            pages: pages,
            pageHistory: history)
    }

    /// What the export holds, to check it against the database (QUE-22's "export ครบ").
    var counts: [(key: String, value: Int)] {
        let byStatus = Dictionary(grouping: tasks, by: \.task.status)
        return [
            ("tasks", tasks.count),
            ("tasks_open", tasks.filter { !$0.task.status.isClosed }.count),
            ("tasks_done", byStatus[.done]?.count ?? 0),
            ("tasks_dropped", byStatus[.dropped]?.count ?? 0),
            ("notes", tasks.reduce(0) { $0 + $1.notes.count }),
            ("note_edits", tasks.reduce(0) { $0 + $1.noteEdits.values.reduce(0) { $0 + $1.count } }),
            ("history_events", tasks.reduce(0) { $0 + $1.history.count }),
            ("links", tasks.reduce(0) { $0 + $1.links.count }),
            ("relation_entries", tasks.reduce(0) { $0 + $1.relationCount }),   // each end counts
            ("questions", tasks.reduce(0) { $0 + $1.questions.count }),
            ("milestones", milestones.count),
            ("wiki_pages", pages.count),
            ("wiki_history_events", pageHistory.values.reduce(0) { $0 + $1.count }),
            ("guide_versions", guides.count)
        ]
    }

    /// The attachment paths (`attachments/<name>`) the task details link to, each once.
    var attachmentPaths: [String] {
        var seen = Set<String>()
        return tasks.flatMap { Self.attachmentPaths(in: $0.task.detail) }.filter { seen.insert($0).inserted }
    }

    static func attachmentPaths(in markdown: String) -> [String] {
        guard markdown.contains(Store.attachmentPrefix) else { return [] }
        let pattern = #"\]\((\#(NSRegularExpression.escapedPattern(for: Store.attachmentPrefix))[^)\s]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).compactMap { m in
            Range(m.range(at: 1), in: markdown).map { String(markdown[$0]) }
        }
    }
}
