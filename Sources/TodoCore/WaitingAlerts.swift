import Foundation

// MARK: - Notifying what newly waits on the user (QUE-26)

/// One thing that started waiting on the user since the last read, for a notification.
public struct WaitingArrival: Hashable, Sendable {
    /// What it is, by id (the app maps it to the Waiting on you page's selection).
    public enum Item: Hashable, Sendable {
        case session(String)
        case question(Int64)
        case task(Int64)
    }

    public var item: Item
    public var title: String
    public var body: String

    public init(item: Item, title: String, body: String) { self.item = item; self.title = title; self.body = body }
}

/// Finds what newly waits on the user by diffing each `WaitingOnYou` read against the ones
/// before it. The app keeps one and feeds it every read (`arrivals(in:readAt:...)`):
/// - The first read is the baseline: what already waits when the app starts is never
///   announced.
/// - An item is announced once. Its key is the session id plus its `attention_at`, the
///   question id, or the task id plus its `waiting_since`, so a session that needs the user
///   again, or a task that waits again after it left waiting, is new; the same wait is not.
/// - Only an item whose own time (attention_at, asked_at, waiting_since) is at most
///   `slack` older than the previous read is new. Older ones came into view through the
///   user's own act (a project unarchived, a question answered that hid a waiting task).
/// - A task counts only when an agent set it waiting (`setByAgent`): not the user in the
///   app, a CLI command or an import.
public struct WaitingWatch: Sendable {
    private var known: Set<String> = []
    private var baselined = false
    private var lastRead: Date?

    /// How much older than the previous read an item's time may be and still be new: the
    /// DB rounds some times to whole seconds, and a write lands between two reads.
    public static let slack: TimeInterval = 60
    /// Above this many remembered keys, keep only those still waiting.
    static let knownLimit = 2_000

    public init() {}

    /// What in `waiting` is new since the reads before it, in the page's order (sessions,
    /// questions, tasks). `readAt` is when this read started. `setByAgent` is asked only
    /// about new tasks; `isGate` only about new questions.
    public mutating func arrivals(in waiting: WaitingOnYou, readAt: Date,
                                  projectCode: (Int64?) -> String = { _ in "" },
                                  isGate: (Question) -> Bool = { _ in false },
                                  setByAgent: (InboxTask) -> Bool = { _ in true }) -> [WaitingArrival] {
        let previous = lastRead
        lastRead = readAt
        let keys = Self.keys(waiting)
        guard baselined else {
            baselined = true
            known = Set(keys)
            return []
        }
        let cutoff = (previous ?? readAt).addingTimeInterval(-Self.slack)
        var out: [WaitingArrival] = []
        for s in waiting.sessions {
            guard remember(Self.key(s)), let a = s.attention, a.at >= cutoff else { continue }
            out.append(Self.arrival(s, projectCode: projectCode(s.projectId)))
        }
        for q in waiting.questions {
            guard remember(Self.key(q)), q.askedAt >= cutoff else { continue }
            out.append(Self.arrival(q, gate: isGate(q)))
        }
        for t in waiting.tasks {
            guard remember(Self.key(t)), t.since >= cutoff, setByAgent(t) else { continue }
            out.append(Self.arrival(t))
        }
        if known.count > Self.knownLimit { known = Set(keys) }
        return out
    }

    /// Adds `key` to what was seen; true when it was not seen before.
    private mutating func remember(_ key: String) -> Bool { known.insert(key).inserted }

    static func keys(_ w: WaitingOnYou) -> [String] {
        w.sessions.map(key) + w.questions.map(key) + w.tasks.map(key)
    }
    static func key(_ s: AgentSession) -> String { "s:\(s.id):\(s.attention?.at.timeIntervalSince1970 ?? 0)" }
    static func key(_ q: Question) -> String { "q:\(q.id)" }
    static func key(_ t: InboxTask) -> String { "t:\(t.id):\(t.since.timeIntervalSince1970)" }

    // MARK: Who set a task waiting

    /// Whether an agent set the task waiting, from its history (newest first, as
    /// `Store.taskHistory` returns it): the newest row that made it wait ("waiting on", or
    /// a status change to Waiting) was not written by the app, a CLI command or an import.
    /// No such row (history is best-effort) or no source (an older binary wrote it): the
    /// MCP server is the likely writer, so yes.
    public static func setByAgent(history: [TaskEvent]) -> Bool {
        let row = history.first { $0.field == "waiting on" || ($0.field == "status" && $0.newValue == TaskStatus.waiting.display) }
        switch row?.source {
        case .app?, .cli?, .importer?: return false
        case .mcp?, .hook?, nil: return true
        }
    }

    // MARK: Text

    /// The longest body line kept (characters).
    public static let bodyLimit = 120

    static func arrival(_ s: AgentSession, projectCode: String) -> WaitingArrival {
        let who = projectCode.isEmpty ? "Claude Code" : "\(projectCode) · Claude Code"
        return WaitingArrival(item: .session(s.id), title: "\(who) needs you",
                              body: s.attention?.headline ?? "Needs you at the terminal")
    }

    static func arrival(_ q: Question, gate: Bool) -> WaitingArrival {
        let title: String
        if gate { title = "\(q.taskCode) · Gate: approve a tool call?" }
        else if q.kind == .approve { title = "\(q.taskCode) · An agent asks for your approval" }
        else { title = "\(q.taskCode) · An agent asks you" }
        return WaitingArrival(item: .question(q.id), title: title, body: line(q.prompt))
    }

    static func arrival(_ t: InboxTask) -> WaitingArrival {
        let reason = line(t.task.waitingReason ?? "")
        return WaitingArrival(item: .task(t.id), title: "\(t.task.code) is waiting on you",
                              body: reason.isEmpty ? line(t.task.title) : reason)
    }

    /// `text` redacted (GateRedactor), on one line and cut to `bodyLimit`.
    public static func line(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let clean = GateRedactor.redact(flat)
        return clean.count <= bodyLimit ? clean : String(clean.prefix(bodyLimit - 1)) + "…"
    }

    /// One notification for the arrivals of one read: the item's own text when there is
    /// one, else a count with the first few titles. Clicking it opens `arrivals.first`.
    public static func notice(_ arrivals: [WaitingArrival]) -> (title: String, body: String)? {
        guard let first = arrivals.first else { return nil }
        guard arrivals.count > 1 else { return (first.title, first.body) }
        let shown = 3
        var lines = arrivals.prefix(shown).map(\.title)
        if arrivals.count > shown { lines.append("and \(arrivals.count - shown) more") }
        return ("\(arrivals.count) things are waiting on you", lines.joined(separator: "\n"))
    }
}
