import Foundation

// MARK: - Waiting on you (the app's inbox)

/// Everything that needs the user now, across projects: the app's "Waiting on you" page
/// and its count (the sidebar badge; the menu bar and notifications reuse `count`).
/// Three kinds, each the longest waiting first:
/// - sessions: open Claude Code sessions that wait for the user at their terminal
///   (`Store.sessionsNeedingUser`), leaving out those whose process is known to be gone;
/// - questions: open questions agents asked (ask_user, and the gate's approvals) in
///   projects not archived;
/// - tasks: tasks waiting on the user (`Store.inbox`, the MCP `inbox` tool's list) that no
///   open question covers — a task parked by a question is answered through its question,
///   so it is listed (and counted) once.
public struct WaitingOnYou: Hashable, Sendable {
    public var sessions: [AgentSession] = []
    public var questions: [Question] = []
    public var tasks: [InboxTask] = []

    public init() {}

    /// Build from the parts as read (questions open and in active projects, the inbox's
    /// tasks, the sessions needing the user). `processAlive` checks a session's Claude Code
    /// process (default `ClaudeProcess.isRunning`; nil = unknown keeps the session).
    public init(questions: [Question], tasks: [InboxTask], sessions: [AgentSession],
                processAlive: (AgentSession) -> Bool? = { ClaudeProcess.isRunning(pid: $0.pid, startedAt: $0.pidStartedAt) }) {
        let asked = Set(questions.map(\.taskId))
        self.questions = questions
        self.tasks = tasks.filter { !asked.contains($0.task.id) }
        self.sessions = sessions.filter { processAlive($0) != false }
    }

    /// How many things wait on the user: one per session, question and task listed.
    public var count: Int { sessions.count + questions.count + tasks.count }
    public var isEmpty: Bool { count == 0 }
}

/// A task in the inbox with its project's code.
public struct InboxTask: Hashable, Sendable, Identifiable {
    public var task: TodoTask
    public var projectCode: String
    public var id: Int64 { task.id }

    public init(task: TodoTask, projectCode: String) { self.task = task; self.projectCode = projectCode }

    /// Since when it waits: `waiting_since`, or `updated_at` for a row an older build set
    /// waiting without it (the inbox's own order).
    public var since: Date { task.waitingSince ?? task.updatedAt }
}

extension Store {
    /// What waits on the user now (`WaitingOnYou`), read in one go: open questions in
    /// active projects, the inbox's tasks, and the sessions needing the user.
    public func waitingOnYou() throws -> WaitingOnYou {
        WaitingOnYou(questions: try questions(statuses: [.open], activeOnly: true),
                     tasks: try inbox().map { InboxTask(task: $0.task, projectCode: $0.projectCode) },
                     sessions: try sessionsNeedingUser())
    }
}
