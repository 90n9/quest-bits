import Foundation

/// Progress state for a task. Persisted as the raw string value.
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress = "in_progress"
    case waiting     // parked on someone — see `WaitingOn`; still open
    case done
    case dropped     // abandoned: closed like done, but not a completion (history kept)

    public var display: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .waiting: return "Waiting"
        case .done: return "Done"
        case .dropped: return "Dropped"
        }
    }

    /// A closed task is finished with: it is never reported blocked, and as a
    /// dependency it no longer blocks anything. Only `done` is a completion
    /// (`completed_at`, stats, recurrence); `dropped` closes without completing.
    public var isClosed: Bool {
        switch self {
        case .todo, .inProgress, .waiting: return false
        case .done, .dropped: return true
        }
    }

    /// Entering this status means work has begun, so `started_at` is stamped
    /// (once) if it is still empty. Waiting and dropped do not stamp (a task can wait,
    /// or be dropped, before anyone starts it), but like every status they never clear
    /// an existing start.
    public var impliesStarted: Bool {
        switch self {
        case .todo, .waiting, .dropped: return false
        case .inProgress, .done: return true
        }
    }

    /// Sort position in filtered task lists (`Store.listTasks(matching:)`): active work
    /// first, then the backlog, then closed. Separate from `allCases`, whose order drives
    /// board columns and pickers.
    public var listRank: Int {
        switch self {
        case .inProgress: return 0
        case .waiting: return 1
        case .todo: return 2
        case .done: return 3
        case .dropped: return 4
        }
    }
}

/// Who a `waiting` task is waiting on. Persisted as the raw string value; set only
/// while the task is waiting (see `Store.waitingViolation`).
public enum WaitingOn: String, Codable, CaseIterable, Sendable {
    case user       // the human has to decide or act
    case external   // a third party: a reply, a review, a deploy
}

/// Task priority. `none` = unset.
public enum Priority: String, Codable, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high

    public var display: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// A project groups tasks together.
public struct Project: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var code: String          // short human handle, e.g. "GEN"
    public var name: String
    public var detail: String        // description — context for humans + AI
    public var createdAt: Date
    public var sortOrder: Int
    public var archivedAt: Date?     // nil = active; archived projects keep their code reserved
    /// The folder the project's work lives in (a repo or a workspace of several), stored
    /// absolute with ~ expanded; nil = no folder (find_project never maps a path to it).
    public var repoPath: String?

    public var isArchived: Bool { archivedAt != nil }

    public init(id: Int64, code: String, name: String, detail: String, createdAt: Date, sortOrder: Int,
                archivedAt: Date? = nil, repoPath: String? = nil) {
        self.id = id
        self.code = code
        self.name = name
        self.detail = detail
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.archivedAt = archivedAt
        self.repoPath = repoPath
    }
}

/// A task belongs to a project. `detail` holds the task's spec (progress goes in
/// `TaskNote`s, appended without rewriting the task). `link` is the URL of its primary
/// `TaskLink`, the first that is not a branch (the legacy single link, kept in step by
/// the store); `branch` the git
/// branch the work is on now, nil when none. `milestoneId` is the project milestone the task
/// counts toward (another grouping than its parent), nil when none.
public struct TodoTask: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var code: String          // short human handle, e.g. "GEN-3"
    public var projectId: Int64
    public var title: String
    public var detail: String
    public var link: String?
    public var status: TaskStatus
    public var waitingOn: WaitingOn?   // set iff status == .waiting
    public var waitingReason: String?  // optional note while waiting
    public var waitingSince: Date?     // when it last entered waiting; set iff status == .waiting
    public var priority: Priority
    public var dueDate: Date?
    public var tags: [String]
    public var recurrence: String?   // nil = non-recurring; "daily" | "weekly" | "monthly"
    public var startedAt: Date?      // first time it went In Progress (or straight to Done)
    public var completedAt: Date?    // when it went Done; cleared on reopen
    public var effortSeconds: Int    // time tracked by the Pomodoro timer of builds before 1.5.0
    public var estimateSeconds: Int  // planned effort; 0 = unset (compared to effortSeconds)
    public var parentId: Int64?      // nil = top-level; else the parent task (one level of nesting)
    public var createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Int
    public var branch: String?
    public var milestoneId: Int64?
    public var claim: TaskClaim?     // the session working on it (next_task / claim_task), live or expired

    public init(
        id: Int64,
        code: String,
        projectId: Int64,
        title: String,
        detail: String,
        link: String?,
        status: TaskStatus,
        waitingOn: WaitingOn? = nil,
        waitingReason: String? = nil,
        waitingSince: Date? = nil,
        priority: Priority = .none,
        dueDate: Date? = nil,
        tags: [String] = [],
        recurrence: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        effortSeconds: Int = 0,
        estimateSeconds: Int = 0,
        parentId: Int64? = nil,
        createdAt: Date,
        updatedAt: Date,
        sortOrder: Int,
        branch: String? = nil,
        milestoneId: Int64? = nil,
        claim: TaskClaim? = nil
    ) {
        self.id = id
        self.code = code
        self.projectId = projectId
        self.title = title
        self.detail = detail
        self.link = link
        self.status = status
        self.waitingOn = waitingOn
        self.waitingReason = waitingReason
        self.waitingSince = waitingSince
        self.priority = priority
        self.dueDate = dueDate
        self.tags = tags
        self.recurrence = recurrence
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.effortSeconds = effortSeconds
        self.estimateSeconds = estimateSeconds
        self.parentId = parentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.branch = branch
        self.milestoneId = milestoneId
        self.claim = claim
    }
}

/// Cross-task references for a batch of tasks, resolved to codes in bulk
/// (see `Store.taskRelations(for:)`) so serializers avoid per-task lookups.
public struct TaskRelations: Sendable {
    public var dependsOnCodes: [Int64: [String]] = [:]  // task id → codes it depends on
    public var parentCodes: [Int64: String] = [:]       // parent task id → its code
    public var blockedIds: Set<Int64> = []              // open tasks with >=1 open dependency (closed tasks never)
    public var blockedBy: [Int64: [(id: Int64, code: String)]] = [:]  // task id → the open dependencies blocking it
    public var milestoneNames: [Int64: String] = [:]    // milestone id → its name

    public init() {}
}

/// Which tasks `Store.listTasks(matching:)` returns. Every set field narrows the list;
/// nil means no constraint on that field. Without a `projectId` or `parentId`, tasks of
/// archived projects are left out unless `includeArchived`; naming a project or parent
/// lists it whether archived or not.
public struct TaskFilter: Sendable {
    public var projectId: Int64?
    public var statuses: [TaskStatus]?   // any of these; nil = every status
    public var tag: String?              // has this tag (whole tag, case-insensitive)
    public var parentId: Int64?          // direct subtasks of this task
    public var includeArchived: Bool     // cross-project lists: also tasks of archived projects
    public var sort: TaskSort            // status groups first (default), or the saved board order only
    public var milestone: MilestoneFilter?   // in this milestone, or in none

    public init(projectId: Int64? = nil, statuses: [TaskStatus]? = nil, tag: String? = nil, parentId: Int64? = nil,
                includeArchived: Bool = false, sort: TaskSort = .status, milestone: MilestoneFilter? = nil) {
        self.projectId = projectId
        self.statuses = statuses
        self.tag = tag
        self.parentId = parentId
        self.includeArchived = includeArchived
        self.sort = sort
        self.milestone = milestone
    }
}

/// `TaskFilter.milestone`: tasks of one milestone (by id, or by name in any project, the
/// name compared case-insensitively), or tasks in no milestone.
public enum MilestoneFilter: Hashable, Sendable {
    case id(Int64)
    case named(String)
    case unassigned
}

/// How `Store.listTasks(matching:)` orders its result.
public enum TaskSort: String, CaseIterable, Sendable {
    /// By status (`TaskStatus.listRank`), then the flat board order: projects in sidebar
    /// order, then each project's sort_order.
    case status
    /// The saved order the app shows, status ignored: projects in sidebar order; in each
    /// project its top-level tasks by sort_order, each one followed by its own subtasks
    /// by sort_order (see `Store.reorderTasks`).
    case board
}

/// Where `Store.reorderTasks` puts the tasks it is given among their siblings.
public enum TaskPlacement: String, CaseIterable, Sendable {
    case top, bottom
}

/// A reusable task template: preset fields that spawn a real task on demand.
public struct TaskTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var name: String            // template handle, e.g. "Bug report"
    public var title: String           // title applied to spawned tasks
    public var detail: String
    public var priority: Priority
    public var tags: [String]
    public var estimateSeconds: Int    // planned effort carried onto spawned tasks (0 = unset)
    public var createdAt: Date

    public init(id: Int64, name: String, title: String, detail: String = "",
                priority: Priority = .none, tags: [String] = [],
                estimateSeconds: Int = 0, createdAt: Date) {
        self.id = id
        self.name = name
        self.title = title
        self.detail = detail
        self.priority = priority
        self.tags = tags
        self.estimateSeconds = estimateSeconds
        self.createdAt = createdAt
    }
}

/// An entry in a task's change history.
public struct TaskEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var taskId: Int64
    public var timestamp: Date
    public var field: String          // "status", "priority", "created", …
    public var oldValue: String
    public var newValue: String
    /// Where the change came from, and the agent's session (`ChangeOrigin`); nil on rows
    /// from before 1.5.0 (unknown).
    public var source: ChangeSource?
    public var agentSessionId: String?
    public var sessionLabel: String?

    public init(id: Int64, taskId: Int64, timestamp: Date, field: String, oldValue: String, newValue: String,
                source: ChangeSource? = nil, agentSessionId: String? = nil, sessionLabel: String? = nil) {
        self.id = id
        self.taskId = taskId
        self.timestamp = timestamp
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.source = source
        self.agentSessionId = agentSessionId
        self.sessionLabel = sessionLabel
    }
}

/// What a task note records. Persisted as the raw string value (the `task_notes.kind`
/// CHECK constraint lists the same values).
public enum NoteKind: String, Codable, CaseIterable, Sendable {
    case note       // findings, anything else — the default
    case progress   // an update while the work is under way
    case decision   // a choice made, why, and the options not taken
    case summary    // closing a task: what was done, files/PRs, what is left
    case review     // review feedback or a verification result
    case question   // written by ask_user only; the question itself lives in `questions`

    public var display: String {
        switch self {
        case .note: return "Note"
        case .progress: return "Progress"
        case .decision: return "Decision"
        case .summary: return "Summary"
        case .review: return "Review"
        case .question: return "Question"
        }
    }

    /// Kinds a person or agent may write directly (question comes from ask_user).
    public static var writable: [NoteKind] { allCases.filter { $0 != .question } }
}

/// Who wrote a note. nil on notes from before 1.4.0, which did not record it.
public enum NoteAuthor: String, Codable, CaseIterable, Sendable {
    case user, agent

    public var display: String { self == .user ? "You" : "Agent" }
}

/// What a task link points at. Persisted as the raw value; `task_links.kind` has no
/// CHECK, so a new kind needs no table rebuild (the store validates it).
public enum LinkKind: String, Codable, CaseIterable, Sendable {
    case pr        // a pull / merge request
    case design    // a design or artifact (Figma, claude.ai artifact)
    case doc       // a document on the web (Google Docs, Notion, Confluence)
    case file      // a local file or folder
    case branch    // a git branch name: an earlier or extra branch (the working one is TodoTask.branch)
    case other

    public var display: String {
        switch self {
        case .pr: return "Pull request"
        case .design: return "Design"
        case .doc: return "Doc"
        case .file: return "File"
        case .branch: return "Branch"
        case .other: return "Link"
        }
    }

    /// The kind a link gets when none is given, guessed from its text. `branch` is never
    /// guessed: a bare "feat/x" reads as `other` unless the caller says so.
    public static func infer(from url: String) -> LinkKind {
        let s = url.lowercased()
        if (s.contains("github.com/") && s.contains("/pull/"))
            || s.contains("/merge_requests/") || (s.contains("bitbucket.org/") && s.contains("/pull-requests/")) {
            return .pr
        }
        if s.contains("claude.ai/artifact") || s.contains("claude.ai/code/artifact") || s.contains("figma.com/") {
            return .design
        }
        if s.contains("docs.google.com/") || s.contains("notion.so") || s.contains("notion.site")
            || s.contains("atlassian.net/wiki") || s.contains("confluence") {
            return .doc
        }
        if s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("file://") { return .file }
        return .other
    }
}

/// One of a task's links (`task_links`), oldest first: the first that is not a branch is
/// its primary link, the legacy single `link`. A URL is stored once per task; the same URL may sit on many tasks (one
/// PR covering several). `author` is nil on links carried over from the legacy column;
/// `source` is free-form provenance (e.g. an importer's source key), nil when not given.
public struct TaskLink: Identifiable, Codable, Hashable, Sendable {
    public let id: Int64
    public let taskId: Int64
    public var kind: LinkKind
    public var url: String
    public var title: String?
    public var author: NoteAuthor?
    public var source: String?
    public var createdAt: Date

    public init(id: Int64, taskId: Int64, kind: LinkKind, url: String, title: String? = nil,
                author: NoteAuthor? = nil, source: String? = nil, createdAt: Date) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.url = url
        self.title = title
        self.author = author
        self.source = source
        self.createdAt = createdAt
    }
}

/// How one task relates to another, seen from the first task. `blockedBy` / `blocks` are
/// the dependency graph (`task_deps`, the same edges add_dependency writes, cycle-guarded);
/// `relates` and `duplicates` / `duplicatedBy` are `task_relations` rows and never block.
/// `relates` is one undirected row; `duplicates` is directed (the duplicate → the original).
public enum RelationKind: String, Codable, CaseIterable, Sendable {
    case blockedBy = "blocked_by"   // this task depends on the other
    case blocks                     // the other task depends on this one
    case relates                    // related, both ways
    case duplicates                 // this task is a duplicate of the other
    case duplicatedBy = "duplicated_by"   // the other task is a duplicate of this one

    public var display: String {
        switch self {
        case .blockedBy: return "Blocked by"
        case .blocks: return "Blocks"
        case .relates: return "Related"
        case .duplicates: return "Duplicates"
        case .duplicatedBy: return "Duplicated by"
        }
    }

    /// True for the two kinds stored as dependencies.
    public var isDependency: Bool { self == .blockedBy || self == .blocks }
}

/// The other end of a relation: enough to show and open it, across projects.
public struct RelatedTask: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let code: String
    public let title: String
    public let status: TaskStatus
    public let projectId: Int64

    public init(id: Int64, code: String, title: String, status: TaskStatus, projectId: Int64) {
        self.id = id
        self.code = code
        self.title = title
        self.status = status
        self.projectId = projectId
    }
}

/// Every relation of one task, grouped by kind (`Store.relatedTasks(taskId:)`), each group
/// oldest task first. A kind with none has no entry.
public struct RelatedTasks: Hashable, Sendable {
    public var byKind: [RelationKind: [RelatedTask]] = [:]

    public init() {}

    public subscript(kind: RelationKind) -> [RelatedTask] { byKind[kind] ?? [] }
    public var isEmpty: Bool { byKind.values.allSatisfy(\.isEmpty) }
}

/// A named stage of a project ("Phase 2 Hide", "v1.5.0") that tasks count toward: a
/// grouping beside parent/subtask, never in place of it (a task's parent and its milestone
/// are independent). `acceptance` is the exit criteria, kept apart from the tasks: a
/// milestone closes only when someone closes it (`closedAt`), never because its tasks are
/// done. `done` / `total` count its tasks, subtasks included, dropped ones left out of
/// both; `open` counts the tasks not yet closed.
public struct Milestone: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let projectId: Int64
    public var name: String
    public var detail: String
    public var acceptance: String
    public var sortOrder: Int
    public var targetDate: Date?
    public var closedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var done: Int
    public var total: Int
    public var open: Int

    public var isClosed: Bool { closedAt != nil }

    public init(id: Int64, projectId: Int64, name: String, detail: String = "", acceptance: String = "",
                sortOrder: Int = 0, targetDate: Date? = nil, closedAt: Date? = nil,
                createdAt: Date, updatedAt: Date, done: Int = 0, total: Int = 0, open: Int = 0) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.detail = detail
        self.acceptance = acceptance
        self.sortOrder = sortOrder
        self.targetDate = targetDate
        self.closedAt = closedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.done = done
        self.total = total
        self.open = open
    }
}

/// A milestone-like prefix at the start of a task title, as older lists wrote stages before
/// milestones existed: "P2.1 · Hide the dock" → prefix "P2.1", title "Hide the dock". Only a
/// hint for an importer (`Store.titleMilestoneHint`): it never sets a milestone by itself.
public struct MilestoneHint: Hashable, Sendable {
    public let prefix: String
    public let title: String

    public init(prefix: String, title: String) {
        self.prefix = prefix
        self.title = title
    }
}

/// One saved version of an agent guide (Store.saveGuide). `projectId` nil is the guide
/// for every project. The newest version of a scope is its guide.
public struct GuideVersion: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let projectId: Int64?
    public var timestamp: Date
    public var markdown: String
    public let author: NoteAuthor
    public let sessionId: String?
    public let reason: String?

    public init(id: Int64, projectId: Int64?, timestamp: Date, markdown: String, author: NoteAuthor,
                sessionId: String?, reason: String?) {
        self.id = id; self.projectId = projectId; self.timestamp = timestamp; self.markdown = markdown
        self.author = author; self.sessionId = sessionId; self.reason = reason
    }
}

/// Store.saveGuide refused a save made from an older version: `current` came first.
public struct GuideConflict: Error, CustomStringConvertible {
    public let current: GuideVersion
    public var description: String { "the guide changed (version \(current.id)) since it was opened" }
}

// MARK: - Project wiki (1.5.0)

/// What a wiki page of a project holds. Persisted as the raw value; `project_pages.kind`
/// has no CHECK, so a new kind needs no table rebuild (the store validates it). The
/// project's guide is not a page: it stays in `guide_versions` (get_guide / update_guide).
public enum PageKind: String, Codable, CaseIterable, Sendable {
    case decision   // a choice made for the project: when (decidedOn), what (outcome), why (body)
    case note       // anything else worth keeping: findings, how-tos, a running log

    public var display: String { self == .decision ? "Decision" : "Note" }
    public var plural: String { self == .decision ? "Decisions" : "Notes" }
}

/// Where an imported page came from, kept apart from who wrote it (`ProjectPage.author` is
/// the actor that wrote the row: an importer is the agent). Every field is nil when not
/// known; none of them changes who may edit the page. `key` is the source item's stable
/// identity: a page with the same key in the project is not created twice.
public struct PageProvenance: Hashable, Sendable {
    public var source: String?           // free-form locator, e.g. "PLAN.md#Decisions"
    public var key: String?              // stable source identity (an importer's source_key)
    public var author: String?           // who wrote the original, as the source says
    public var session: String?          // the session that wrote the original
    public var timestamp: Date?          // when the original was written

    public init(source: String? = nil, key: String? = nil, author: String? = nil,
                session: String? = nil, timestamp: Date? = nil) {
        self.source = source; self.key = key; self.author = author
        self.session = session; self.timestamp = timestamp
    }

    public var isEmpty: Bool { self == PageProvenance() }
}

/// One row of the importer's ledger (`import_ledger`): a source item that
/// `questbits import --apply` wrote. `sourceKey` is the item's stable identity, so a rerun
/// skips it; `target` the row written ("task:12", "milestone:3"); `fingerprint` the source
/// and intended write as reviewed; `inverse` (JSON) what undoing that write would take.
public struct ImportLedgerEntry: Hashable, Sendable {
    public var sourceKey: String
    public var runId: String
    public var action: String
    public var target: String
    public var fingerprint: String
    public var inverse: String
    public var appliedAt: Date

    public init(sourceKey: String, runId: String, action: String, target: String = "",
                fingerprint: String = "", inverse: String = "{}", appliedAt: Date = Date()) {
        self.sourceKey = sourceKey; self.runId = runId; self.action = action; self.target = target
        self.fingerprint = fingerprint; self.inverse = inverse; self.appliedAt = appliedAt
    }
}

/// A wiki page of one project (`project_pages`): a decision or a note, markdown `body`.
/// A decision also has `decidedOn` (yyyy-MM-dd) and `outcome` (what was decided; the body
/// says why); notes have neither. `tasks` are the tasks it refers to, in any project.
/// `version` goes up on every change: an edit made from an older version is refused
/// (`PageConflict`), so two writers never overwrite each other unseen.
public struct ProjectPage: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let projectId: Int64
    public var kind: PageKind
    public var title: String
    public var body: String
    public var outcome: String?
    public var decidedOn: String?
    public var tasks: [RelatedTask]
    public var version: Int
    public let author: NoteAuthor
    public let sessionId: String?
    public let provenance: PageProvenance
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: Int64, projectId: Int64, kind: PageKind, title: String, body: String = "",
                outcome: String? = nil, decidedOn: String? = nil, tasks: [RelatedTask] = [], version: Int = 1,
                author: NoteAuthor, sessionId: String? = nil, provenance: PageProvenance = PageProvenance(),
                createdAt: Date, updatedAt: Date) {
        self.id = id; self.projectId = projectId; self.kind = kind; self.title = title; self.body = body
        self.outcome = outcome; self.decidedOn = decidedOn; self.tasks = tasks; self.version = version
        self.author = author; self.sessionId = sessionId; self.provenance = provenance
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// One change to a page (`page_history`), like a task's history row: `field` is created,
/// title, kind, outcome, decided_on, body or tasks; body rows keep the whole old and new text.
public struct PageEvent: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let pageId: Int64
    public let timestamp: Date
    public let field: String
    public let oldValue: String
    public let newValue: String
    public let author: NoteAuthor?
    public let sessionId: String?

    public init(id: Int64, pageId: Int64, timestamp: Date, field: String, oldValue: String, newValue: String,
                author: NoteAuthor?, sessionId: String?) {
        self.id = id; self.pageId = pageId; self.timestamp = timestamp; self.field = field
        self.oldValue = oldValue; self.newValue = newValue; self.author = author; self.sessionId = sessionId
    }
}

/// A page search hit: the page (body included), its project's code, and an excerpt around
/// the first match.
public struct PageSearchHit: Hashable, Sendable {
    public let page: ProjectPage
    public let projectCode: String
    public let snippet: String
}

/// `Store.searchPages`: matching pages (best first with FTS5, else newest first), matching
/// decision notes of tasks (newest first), and whether the FTS5 index answered.
public struct PageSearchResult: Sendable {
    public let pages: [PageSearchHit]
    public let decisionNotes: [NoteSearchHit]
    public let usedFTS: Bool
}

/// Store.updatePage refused an edit made from an older version: `current` came first.
public struct PageConflict: Error, CustomStringConvertible {
    public let current: ProjectPage
    public var description: String {
        "page \(current.id) changed (now version \(current.version)) since it was read; read it again and redo the edit"
    }
}

/// A timestamped entry in a task's log. Notes are inserted, never rewritten by
/// another writer, so concurrent writers never overwrite each other (unlike appending
/// to `detail`). The one exception: the user may edit their own note in the app, and
/// every replaced text is kept as a `NoteEdit`.
public struct TaskNote: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var taskId: Int64
    public var timestamp: Date
    public var kind: NoteKind
    public var text: String
    public var author: NoteAuthor?
    public var sessionId: String?
    public var statusEventId: Int64?   // the task_history row of the status change it came with
    public var questionId: Int64?      // the question it records (kind question, or its answer)
    public var editedAt: Date?         // last edit; nil = never edited

    public init(id: Int64, taskId: Int64, timestamp: Date, kind: NoteKind, text: String,
                author: NoteAuthor? = nil, sessionId: String? = nil, statusEventId: Int64? = nil,
                questionId: Int64? = nil, editedAt: Date? = nil) {
        self.id = id
        self.taskId = taskId
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.author = author
        self.sessionId = sessionId
        self.statusEventId = statusEventId
        self.questionId = questionId
        self.editedAt = editedAt
    }
}

/// A note's earlier text, kept when the user edited it: `text` was replaced at `timestamp`.
public struct NoteEdit: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var noteId: Int64
    public var timestamp: Date
    public var text: String

    public init(id: Int64, noteId: Int64, timestamp: Date, text: String) {
        self.id = id
        self.noteId = noteId
        self.timestamp = timestamp
        self.text = text
    }
}

/// A note to write together with a task update (in the same transaction), e.g. the
/// optional summary when closing a task.
public struct NoteDraft: Sendable {
    public var text: String
    public var kind: NoteKind
    public var author: NoteAuthor
    public var sessionId: String?

    public init(text: String, kind: NoteKind, author: NoteAuthor, sessionId: String? = nil) {
        self.text = text
        self.kind = kind
        self.author = author
        self.sessionId = sessionId
    }
}

/// A search hit: the note plus where it lives.
public struct NoteSearchHit: Hashable, Sendable {
    public var note: TaskNote
    public var taskCode: String
    public var taskTitle: String
    public var projectCode: String
}

// MARK: - Questions (ask loop)

/// How a question is answered: pick an option, type text, or approve / edit a draft.
/// `disagree` is the other way round: the user disagrees with a decision an agent recorded
/// (Store.disagree), so it is born answered, with the user's reason as the answer, for the
/// agent to pick up like any answer (get_answers, resume_question). Agents cannot ask one.
public enum QuestionKind: String, Codable, CaseIterable, Sendable {
    case choice, text, approve, disagree

    /// The kinds ask_user takes.
    public static var askable: [QuestionKind] { allCases.filter { $0 != .disagree } }
}

/// open → answered (in the app) → resumed (the agent picked the answer up);
/// open or answered → cancelled (the agent no longer needs it).
public enum QuestionStatus: String, Codable, CaseIterable, Sendable {
    case open, answered, resumed, cancelled
}

public struct QuestionOption: Codable, Hashable, Sendable {
    public var label: String
    public var note: String
    public var recommended: Bool

    public init(label: String, note: String = "", recommended: Bool = false) {
        self.label = label
        self.note = note
        self.recommended = recommended
    }
}

/// A question an agent left on a task for the user. `taskCode`, `taskTitle` and
/// `projectCode` are read from the task and its project (a moved task keeps its
/// questions); they are not stored on the question.
public struct Question: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var taskId: Int64
    public var taskCode: String
    public var taskTitle: String
    public var projectCode: String
    public var sessionId: String?
    public var kind: QuestionKind
    public var prompt: String
    public var context: String
    public var options: [QuestionOption]
    public var blocksTask: Bool
    public var status: QuestionStatus
    public var answer: String?
    public var answerChoice: Int?       // 0-based option index, when an option was picked
    public var cancelReason: String?
    public var askedAt: Date
    public var answeredAt: Date?
    public var resumedAt: Date?
    /// The Claude Code session it was asked from (AgentSession.id), when the MCP server
    /// knew it; `sessionId` is the agent's own label.
    public var agentSessionId: String?
    /// A disagreement's decision note (task_notes.id); nil on every other kind.
    public var aboutNoteId: Int64?

    public init(id: Int64, taskId: Int64, taskCode: String, taskTitle: String, projectCode: String,
                sessionId: String?, kind: QuestionKind, prompt: String, context: String,
                options: [QuestionOption], blocksTask: Bool, status: QuestionStatus,
                answer: String?, answerChoice: Int?, cancelReason: String?,
                askedAt: Date, answeredAt: Date?, resumedAt: Date?, agentSessionId: String? = nil,
                aboutNoteId: Int64? = nil) {
        self.id = id
        self.taskId = taskId
        self.taskCode = taskCode
        self.taskTitle = taskTitle
        self.projectCode = projectCode
        self.sessionId = sessionId
        self.kind = kind
        self.prompt = prompt
        self.context = context
        self.options = options
        self.blocksTask = blocksTask
        self.status = status
        self.answer = answer
        self.answerChoice = answerChoice
        self.cancelReason = cancelReason
        self.askedAt = askedAt
        self.answeredAt = answeredAt
        self.resumedAt = resumedAt
        self.agentSessionId = agentSessionId
        self.aboutNoteId = aboutNoteId
    }
}

/// Tasks completed on a single day (the MCP `daily_stats` tool).
public struct DailyStats: Codable, Hashable, Sendable {
    public var date: String          // yyyy-MM-dd, local
    public var tasksCompleted: Int   // top-level tasks whose completed_at falls on that day
    public var subtasksCompleted: Int

    public init(date: String, tasksCompleted: Int, subtasksCompleted: Int) {
        self.date = date
        self.tasksCompleted = tasksCompleted
        self.subtasksCompleted = subtasksCompleted
    }
}

/// Per-day aggregated activity for the stats dashboard (one row per calendar day).
public struct DayStat: Identifiable, Codable, Hashable, Sendable {
    public var date: String          // yyyy-MM-dd, local
    public var tasksCompleted: Int   // tasks whose completed_at falls on that day

    public var id: String { date }

    public init(date: String, tasksCompleted: Int) {
        self.date = date
        self.tasksCompleted = tasksCompleted
    }
}

/// Task counts of one project (subtasks included), for the sidebar's open count and
/// progress bar. Dropped tasks are neither left to do nor done (`progressTotal`).
public struct ProjectCounts: Hashable, Sendable {
    public var open = 0             // todo, in progress, waiting (not `isClosed`)
    public var done = 0
    public var waitingOnUser = 0    // waiting tasks that wait on the user
    public var inProgress = 0

    /// The work still counted toward progress: `done` out of this.
    public var progressTotal: Int { open + done }

    public init() {}

    /// Counts per project id for `tasks`, in one pass. A project with no tasks has no entry.
    public static func byProject(_ tasks: [TodoTask]) -> [Int64: ProjectCounts] {
        var out: [Int64: ProjectCounts] = [:]
        for t in tasks {
            if !t.status.isClosed { out[t.projectId, default: ProjectCounts()].open += 1 }
            if t.status == .done { out[t.projectId, default: ProjectCounts()].done += 1 }
            if t.status == .inProgress { out[t.projectId, default: ProjectCounts()].inProgress += 1 }
            if t.status == .waiting && t.waitingOn == .user {
                out[t.projectId, default: ProjectCounts()].waitingOnUser += 1
            }
        }
        return out
    }
}

/// App preferences stored in the `settings` table under key `app`. Builds before 1.5.0
/// kept the notification flags inside the Pomodoro timer's blob (key `pomodoro`); that
/// row is left as it was and read only as a fallback until the first save.
public struct AppSettings: Codable, Hashable, Sendable {
    public var notificationsEnabled: Bool   // due-date reminders
    public var soundEnabled: Bool
    /// Notify when something new waits on the user: a task an agent set waiting on them,
    /// a new question (the gate's approvals too), a session needing them at the terminal.
    public var agentNotificationsEnabled: Bool

    public static let standard = AppSettings()

    public init(notificationsEnabled: Bool = true, soundEnabled: Bool = true, agentNotificationsEnabled: Bool = true) {
        self.notificationsEnabled = notificationsEnabled
        self.soundEnabled = soundEnabled
        self.agentNotificationsEnabled = agentNotificationsEnabled
    }

    // Migration-safe decoding: flags missing from a saved blob (or the old `pomodoro`
    // blob, which has more keys) fall back to the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        agentNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentNotificationsEnabled) ?? true
    }
}
