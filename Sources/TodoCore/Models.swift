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

    public var isArchived: Bool { archivedAt != nil }

    public init(id: Int64, code: String, name: String, detail: String, createdAt: Date, sortOrder: Int,
                archivedAt: Date? = nil) {
        self.id = id
        self.code = code
        self.name = name
        self.detail = detail
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.archivedAt = archivedAt
    }
}

/// A task belongs to a project. `detail` holds the task's spec (progress goes in
/// `TaskNote`s, appended without rewriting the task); `link` an optional URL.
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
    public var effortSeconds: Int    // focused time accrued while In Progress + timer running
    public var estimateSeconds: Int  // planned effort; 0 = unset (compared to effortSeconds)
    public var parentId: Int64?      // nil = top-level; else the parent task (one level of nesting)
    public var createdAt: Date
    public var updatedAt: Date
    public var sortOrder: Int

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
        sortOrder: Int
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
    }
}

/// Cross-task references for a batch of tasks, resolved to codes in bulk
/// (see `Store.taskRelations(for:)`) so serializers avoid per-task lookups.
public struct TaskRelations: Sendable {
    public var dependsOnCodes: [Int64: [String]] = [:]  // task id → codes it depends on
    public var parentCodes: [Int64: String] = [:]       // parent task id → its code
    public var blockedIds: Set<Int64> = []              // open tasks with >=1 open dependency (closed tasks never)
    public var blockedBy: [Int64: [(id: Int64, code: String)]] = [:]  // task id → the open dependencies blocking it

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

    public init(projectId: Int64? = nil, statuses: [TaskStatus]? = nil, tag: String? = nil, parentId: Int64? = nil,
                includeArchived: Bool = false) {
        self.projectId = projectId
        self.statuses = statuses
        self.tag = tag
        self.parentId = parentId
        self.includeArchived = includeArchived
    }
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

    public init(id: Int64, taskId: Int64, timestamp: Date, field: String, oldValue: String, newValue: String) {
        self.id = id
        self.taskId = taskId
        self.timestamp = timestamp
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
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
public enum QuestionKind: String, Codable, CaseIterable, Sendable {
    case choice, text, approve
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

    public init(id: Int64, taskId: Int64, taskCode: String, taskTitle: String, projectCode: String,
                sessionId: String?, kind: QuestionKind, prompt: String, context: String,
                options: [QuestionOption], blocksTask: Bool, status: QuestionStatus,
                answer: String?, answerChoice: Int?, cancelReason: String?,
                askedAt: Date, answeredAt: Date?, resumedAt: Date?) {
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
    }
}

/// One completed focus session, for daily stats.
public struct FocusSession: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var startedAt: Date
    public var endedAt: Date
    public var focusSeconds: Int

    public init(id: Int64, startedAt: Date, endedAt: Date, focusSeconds: Int) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusSeconds = focusSeconds
    }
}

/// Aggregated stats for a single day.
public struct DailyStats: Codable, Hashable, Sendable {
    public var date: String          // yyyy-MM-dd, local
    public var completedPomodoros: Int
    public var totalFocusSeconds: Int

    public init(date: String, completedPomodoros: Int, totalFocusSeconds: Int) {
        self.date = date
        self.completedPomodoros = completedPomodoros
        self.totalFocusSeconds = totalFocusSeconds
    }
}

/// Per-day aggregated activity for the stats dashboard (one row per calendar day).
public struct DayStat: Identifiable, Codable, Hashable, Sendable {
    public var date: String          // yyyy-MM-dd, local
    public var focusSeconds: Int     // focused time logged that day
    public var pomodoros: Int        // completed focus sessions that day
    public var tasksCompleted: Int   // tasks whose completed_at falls on that day

    public var id: String { date }

    public init(date: String, focusSeconds: Int, pomodoros: Int, tasksCompleted: Int) {
        self.date = date
        self.focusSeconds = focusSeconds
        self.pomodoros = pomodoros
        self.tasksCompleted = tasksCompleted
    }
}

/// Effort accrued against a single project, for the dashboard's per-project chart.
public struct ProjectEffort: Identifiable, Codable, Hashable, Sendable {
    public var projectId: Int64
    public var code: String
    public var name: String
    public var effortSeconds: Int

    public var id: Int64 { projectId }

    public init(projectId: Int64, code: String, name: String, effortSeconds: Int) {
        self.projectId = projectId
        self.code = code
        self.name = name
        self.effortSeconds = effortSeconds
    }
}

/// Task counts of one project (subtasks included), for the sidebar's open count and
/// progress bar. Dropped tasks are neither left to do nor done (`progressTotal`).
public struct ProjectCounts: Hashable, Sendable {
    public var open = 0             // todo, in progress, waiting (not `isClosed`)
    public var done = 0
    public var waitingOnUser = 0    // waiting tasks that wait on the user

    /// The work still counted toward progress: `done` out of this.
    public var progressTotal: Int { open + done }

    public init() {}

    /// Counts per project id for `tasks`, in one pass. A project with no tasks has no entry.
    public static func byProject(_ tasks: [TodoTask]) -> [Int64: ProjectCounts] {
        var out: [Int64: ProjectCounts] = [:]
        for t in tasks {
            if !t.status.isClosed { out[t.projectId, default: ProjectCounts()].open += 1 }
            if t.status == .done { out[t.projectId, default: ProjectCounts()].done += 1 }
            if t.status == .waiting && t.waitingOn == .user {
                out[t.projectId, default: ProjectCounts()].waitingOnUser += 1
            }
        }
        return out
    }
}

/// User-configurable pomodoro durations (seconds) + behavior flags.
public struct PomodoroSettings: Codable, Hashable, Sendable {
    public var focusSeconds: Int
    public var shortBreakSeconds: Int
    public var longBreakSeconds: Int
    public var roundsBeforeLongBreak: Int

    // Behavior flags (added later — decoded with defaults for old saved blobs).
    public var notificationsEnabled: Bool
    public var soundEnabled: Bool
    public var autoAdvance: Bool          // auto-start the next phase
    public var countBreaksAsEffort: Bool  // accrue effort during breaks too

    public static let standard = PomodoroSettings(
        focusSeconds: 25 * 60,
        shortBreakSeconds: 5 * 60,
        longBreakSeconds: 15 * 60,
        roundsBeforeLongBreak: 4
    )

    public init(focusSeconds: Int, shortBreakSeconds: Int, longBreakSeconds: Int, roundsBeforeLongBreak: Int,
                notificationsEnabled: Bool = true, soundEnabled: Bool = true,
                autoAdvance: Bool = true, countBreaksAsEffort: Bool = false) {
        self.focusSeconds = focusSeconds
        self.shortBreakSeconds = shortBreakSeconds
        self.longBreakSeconds = longBreakSeconds
        self.roundsBeforeLongBreak = roundsBeforeLongBreak
        self.notificationsEnabled = notificationsEnabled
        self.soundEnabled = soundEnabled
        self.autoAdvance = autoAdvance
        self.countBreaksAsEffort = countBreaksAsEffort
    }

    // Migration-safe decoding: flags missing from older JSON fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusSeconds = try c.decode(Int.self, forKey: .focusSeconds)
        shortBreakSeconds = try c.decode(Int.self, forKey: .shortBreakSeconds)
        longBreakSeconds = try c.decode(Int.self, forKey: .longBreakSeconds)
        roundsBeforeLongBreak = try c.decode(Int.self, forKey: .roundsBeforeLongBreak)
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        autoAdvance = try c.decodeIfPresent(Bool.self, forKey: .autoAdvance) ?? true
        countBreaksAsEffort = try c.decodeIfPresent(Bool.self, forKey: .countBreaksAsEffort) ?? false
    }
}
