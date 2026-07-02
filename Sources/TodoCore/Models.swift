import Foundation

/// Progress state for a task. Persisted as the raw string value.
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress = "in_progress"
    case done

    public var display: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        }
    }
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

    public init(id: Int64, code: String, name: String, detail: String, createdAt: Date, sortOrder: Int) {
        self.id = id
        self.code = code
        self.name = name
        self.detail = detail
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }
}

/// A task belongs to a project. `detail` holds free-form notes; `link` an optional URL.
public struct TodoTask: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64
    public var code: String          // short human handle, e.g. "GEN-3"
    public var projectId: Int64
    public var title: String
    public var detail: String
    public var link: String?
    public var status: TaskStatus
    public var priority: Priority
    public var dueDate: Date?
    public var tags: [String]
    public var recurrence: String?   // nil = non-recurring; "daily" | "weekly" | "monthly"
    public var startedAt: Date?      // first time it went In Progress
    public var completedAt: Date?    // when it went Done
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
