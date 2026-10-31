import Foundation

// MARK: - Task claims (next_task / claim_task, 1.5.0)

/// Who takes, renews or gives back a claim: the Claude Code session the call comes from
/// when it is known (`MCPServer.agentSessionId`), else the free-text `session` label the
/// agent passed. `id` is what `tasks.claimed_by` stores and what ownership is checked on.
public struct ClaimHolder: Hashable, Sendable {
    public var id: String
    public var label: String?

    public init(id: String, label: String? = nil) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.label = (trimmed?.isEmpty ?? true) || trimmed == id ? nil : trimmed
    }

    /// The Claude Code session this holder is: `id` when it is a session id, else the
    /// session id inside the label (`<id>/<suffix>`), else nil.
    var sessionId: String? { AgentSession.sessionId(in: id) ?? AgentSession.sessionId(in: label) }

    /// Whether claim `c` is this holder's. The same agent can claim under its label (no
    /// session recorded yet) and call again under its session id once a hook recorded the
    /// session, or the other way round, so a stored id that differs is not enough to say
    /// "another session": when both sides name a Claude Code session, the sessions decide;
    /// otherwise the claim is this holder's when its holder or label is this holder's id
    /// or label.
    public func holds(_ c: TaskClaim) -> Bool {
        if c.holder == id { return true }
        let theirs = AgentSession.sessionId(in: c.holder) ?? AgentSession.sessionId(in: c.label)
        if let mine = sessionId, let theirs { return mine == theirs }
        let names = Set([id, label].compactMap { $0 })
        return names.contains(c.holder) || c.label.map(names.contains) == true
    }
}

/// A task's claim: which session works on it, and until when the claim holds without
/// another heartbeat. A claim whose `expiresAt` has passed is expired: the task may be
/// taken over, but until then its holder can still renew it (nobody else has it).
public struct TaskClaim: Codable, Hashable, Sendable {
    public var holder: String        // Claude Code session id, or the agent's session label
    public var label: String?        // the session label the holder passed, when not `holder`
    public var claimedAt: Date
    public var heartbeatAt: Date     // last renewal (claim, heartbeat, or a write to the task)
    public var expiresAt: Date       // heartbeatAt + Store.claimTTL; sooner when the session ended

    public init(holder: String, label: String?, claimedAt: Date, heartbeatAt: Date, expiresAt: Date) {
        self.holder = holder; self.label = label; self.claimedAt = claimedAt
        self.heartbeatAt = heartbeatAt; self.expiresAt = expiresAt
    }

    public func isLive(at now: Date = Date()) -> Bool { expiresAt > now }

    /// "session 1a2b3c4d" (a Claude Code session, short id), or the label in quotes.
    public var holderName: String { Self.holderName(holder) }

    public static func holderName(_ holder: String) -> String {
        AgentSession.sessionId(in: holder) == holder ? "session \(holder.prefix(8))" : "“\(holder)”"
    }

    /// "Claimed by session 1a2b3c4d · 3 min ago" (the last heartbeat), or
    /// "Claim expired · session 1a2b3c4d · 40 min ago" once it no longer holds.
    public func summary(now: Date = Date()) -> String {
        let ago = Self.ago(heartbeatAt, now: now)
        return isLive(at: now) ? "Claimed by \(holderName) · \(ago)" : "Claim expired · \(holderName) · \(ago)"
    }

    /// "just now", "3 min ago", "2 h ago", "4 d ago".
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 48 * 3600 { return "\(Int(s / 3600)) h ago" }
        return "\(Int(s / 86400)) d ago"
    }
}

/// What a claim attempt did. `previous` is the claim it replaced on a takeover (an
/// expired claim of another session), so the new holder can see whose work it continues.
public struct ClaimResult: Sendable {
    public enum Outcome: String, Sendable {
        case claimed        // the task had no claim
        case renewed        // the caller already held it (live or expired): renewed
        case tookOver = "took_over"   // another session's claim had expired: taken over
        case unclaimed      // next_task without claim: the task was only looked up
    }
    public var task: TodoTask
    public var outcome: Outcome
    public var previous: TaskClaim?

    public init(task: TodoTask, outcome: Outcome, previous: TaskClaim?) {
        self.task = task; self.outcome = outcome; self.previous = previous
    }
}

/// Why next_task found nothing in scope: open tasks it passed over, by reason.
public struct NextTaskSkips: Hashable, Sendable {
    public var claimed = 0      // todo with a live claim of another session
    public var blocked = 0      // todo with an open dependency (or under a blocked/waiting parent)
    public var waiting = 0      // waiting on the user or someone else
    public var inProgress = 0   // in progress, unclaimed or with a live claim (being worked on)
    public init() {}
}

/// Who changes a task, for the claim rule on status changes (`Store.updateTask`): the
/// user in the app may change any task; an agent may not change the status of a task
/// another session holds a live claim on (nil holder: an agent whose session is unknown).
public enum ClaimActor: Sendable {
    case user
    case agent(ClaimHolder?)
}
