import Foundation

// MARK: - Decisions agents made on their own (QUE-39)

/// A decision note (add_note kind decision) with where it lives, whether the user has seen
/// it, and the user's disagreements with it. An agent's own decision is one with no
/// question behind it: the answer an agent resumed is the user's decision, and a withdrawn
/// question's note says why it was withdrawn.
public struct AgentDecision: Identifiable, Hashable, Sendable {
    public var note: TaskNote
    public var taskCode: String
    public var taskTitle: String
    public var taskStatus: TaskStatus
    public var projectId: Int64
    public var projectCode: String
    /// When the user marked it seen (or disagreed with it); nil = new.
    public var reviewedAt: Date?
    /// The Claude Code session it was written from, when the MCP server knew it.
    public var agentSessionId: String?
    /// The user's disagreements with it (questions of kind disagree), newest first.
    public var disagreements: [Question]

    public var id: Int64 { note.id }
    public var isNew: Bool { reviewedAt == nil }
    /// A disagreement the agent has not picked up yet (answered, not resumed).
    public var pendingDisagreement: Question? { disagreements.first { $0.status == .answered || $0.status == .open } }

    public init(note: TaskNote, taskCode: String, taskTitle: String, taskStatus: TaskStatus, projectId: Int64,
                projectCode: String, reviewedAt: Date?, agentSessionId: String?, disagreements: [Question] = []) {
        self.note = note
        self.taskCode = taskCode
        self.taskTitle = taskTitle
        self.taskStatus = taskStatus
        self.projectId = projectId
        self.projectCode = projectCode
        self.reviewedAt = reviewedAt
        self.agentSessionId = agentSessionId
        self.disagreements = disagreements
    }
}

/// Whose decisions to list: an agent's own (the default), the user's (answers an agent
/// resumed, notes the user wrote), or both.
public enum DecisionAuthor: String, CaseIterable, Sendable {
    case agent, user, any
}

/// Which decisions `Store.decisions` reads. `from`/`to` keep notes with from <= ts < to.
/// `includeArchived` false leaves out archived projects (the app's page).
public struct DecisionFilter: Hashable, Sendable {
    public var projectId: Int64?
    public var from: Date?
    public var to: Date?
    public var author: DecisionAuthor
    public var newOnly: Bool
    public var disagreedOnly: Bool
    public var includeArchived: Bool
    public var limit: Int

    public init(projectId: Int64? = nil, from: Date? = nil, to: Date? = nil, author: DecisionAuthor = .agent,
                newOnly: Bool = false, disagreedOnly: Bool = false, includeArchived: Bool = false, limit: Int = 200) {
        self.projectId = projectId
        self.from = from
        self.to = to
        self.author = author
        self.newOnly = newOnly
        self.disagreedOnly = disagreedOnly
        self.includeArchived = includeArchived
        self.limit = limit
    }
}

/// What `Store.disagree` did: the disagreement (an answered question of kind disagree),
/// the task it went on — a new task when the decision's task was already closed — and
/// whether it was already there (the same reason sent again).
public struct DisagreeResult: Sendable {
    public var question: Question
    public var createdTask: TodoTask?
    public var existing: Bool
}

extension Store {
    /// Decisions recorded before this window, when the Decisions page first came (1.5.0),
    /// were marked seen then: the page starts with the last week's as new.
    static let decisionsNewWindow: TimeInterval = 7 * 24 * 3600

    /// One line of a decision for a prompt or title: its first non-empty line, cut at `max`.
    static func decisionExcerpt(_ text: String, max: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > max ? String(line.prefix(max - 1)) + "…" : line
    }
}
