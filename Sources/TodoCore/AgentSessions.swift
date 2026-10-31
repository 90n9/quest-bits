import Foundation
import Darwin

// MARK: - Agent sessions (Claude Code sessions, recorded by hooks)

/// What a Claude Code session is doing, as the hooks and the MCP server last saw it.
/// running: started, or the user sent a prompt, or it called QuestBits; waiting: it is in
/// wait_for_answers; idle: its turn ended (Stop) and it sits at the prompt, so it sees an
/// answer only when it runs again; ended: SessionEnd, or its process is gone.
public enum SessionState: String, Codable, CaseIterable, Sendable {
    case running, waiting, idle, ended
}

/// One Claude Code session (`id` is Claude Code's session_id). The questbits CLI records
/// it from hook events on stdin (`questbits hook …`); the MCP server keeps `lastSeen` fresh
/// while the session calls QuestBits. Nothing from the conversation is stored: no prompt,
/// no reply, no transcript content (only the transcript file's path).
public struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var cwd: String
    public var projectId: Int64?        // the project `cwd` mapped to at start (find_project's rule)
    public var transcriptPath: String?
    public var source: String?          // SessionStart source: startup | resume | clear | compact | fork
    public var state: SessionState
    public var startedAt: Date
    public var lastSeen: Date           // last hook event or QuestBits call (heartbeat)
    public var lastEvent: String?       // what set lastSeen: session_start, prompt, stop, session_end, mcp, wait
    public var endedAt: Date?
    public var endReason: String?       // SessionEnd reason, or superseded / process_exited
    public var pid: Int32?              // the Claude Code process, as the hook found it
    public var pidStartedAt: Date?      // that process's start (tells it from a reused pid)
    public var attention: SessionAttention?  // it needs the user at its terminal (Notification hook)

    public init(id: String, cwd: String, projectId: Int64?, transcriptPath: String?, source: String?,
                state: SessionState, startedAt: Date, lastSeen: Date, lastEvent: String?,
                endedAt: Date?, endReason: String?, pid: Int32?, pidStartedAt: Date?,
                attention: SessionAttention? = nil) {
        self.id = id; self.cwd = cwd; self.projectId = projectId; self.transcriptPath = transcriptPath
        self.source = source; self.state = state; self.startedAt = startedAt; self.lastSeen = lastSeen
        self.lastEvent = lastEvent; self.endedAt = endedAt; self.endReason = endReason
        self.pid = pid; self.pidStartedAt = pidStartedAt; self.attention = attention
    }

    /// How long after the last sign of life a running or waiting session still counts as
    /// live. wait_for_answers touches the session every minute, so 6 minutes of silence
    /// means it is no longer waiting (or the Mac slept).
    public static let freshSeconds: TimeInterval = 6 * 60

    /// The Claude Code session id inside a `session` label: the label itself, or the first
    /// UUID in it (an agent may add a suffix, e.g. "<id>/QUE-3" for a subagent). Lowercased.
    public static func sessionId(in label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        guard let r = label.range(of: pattern, options: .regularExpression) else { return nil }
        return label[r].lowercased()
    }

    /// What the app says about the session now. `processAlive` is the check of `pid`
    /// (`ClaudeProcess.isRunning`): nil when unknown. Silence alone never proves the end:
    /// a quiet session reads as `.quiet`, not `.ended`.
    public func status(now: Date = Date(), processAlive: Bool?) -> SessionStatus {
        if state == .ended { return .ended(endReason) }
        if processAlive == false { return .ended("process_exited") }
        let fresh = now.timeIntervalSince(lastSeen) <= Self.freshSeconds
        switch state {
        case .waiting where fresh: return .waiting
        case .running where fresh: return .working
        case .idle: return .idle
        default: return .quiet(processOpen: processAlive == true)
        }
    }

    /// `claude --resume <id>`, run from the session's folder (Claude Code looks the session
    /// up there first), for the user to paste into a terminal.
    public var resumeCommand: String {
        let resume = "claude --resume \(id)"
        guard !cwd.isEmpty else { return resume }
        return "cd \(Self.shellQuoted(cwd)) && \(resume)"
    }

    /// `s` in single quotes for sh/zsh (a ' inside becomes '\'').
    public static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A session that needs the user at its terminal: Claude Code's Notification hook said it
/// waits for a permission answer, for input, or on an MCP server's form (QUE-37). Only for
/// sessions whose folder belongs to a project. `kind` is Claude Code's notification_type;
/// `message` its notification text, redacted (GateRedactor) and cut, since a permission
/// message can quote a command. The next sign that the session went on clears it: a prompt,
/// a Stop, a SessionStart or SessionEnd, a QuestBits MCP call, or a Bash/MCP tool call
/// (the gate's PreToolUse hook); a finished MCP form clears an elicitation. Background
/// heartbeats of wait_for_answers do not clear it.
public struct SessionAttention: Codable, Hashable, Sendable {
    public var kind: String
    public var message: String
    public var at: Date

    public init(kind: String, message: String, at: Date) { self.kind = kind; self.message = message; self.at = at }

    /// The notification types that mean "the user must act at the terminal".
    public static let needsUser: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog",
                                                "elicitation_url_dialog", "agent_needs_input"]
    /// The notification types that mean an MCP form (elicitation) was answered.
    public static let resolvesElicitation: Set<String> = ["elicitation_complete", "elicitation_response"]

    /// The longest message kept (characters).
    public static let messageLimit = 300

    /// `text` redacted (GateRedactor), on one line and cut to `messageLimit`.
    public static func storedMessage(_ text: String?) -> String {
        let flat = (text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let clean = GateRedactor.redact(flat)
        return clean.count <= messageLimit ? clean : String(clean.prefix(messageLimit - 1)) + "…"
    }

    /// What the app says it waits for.
    public var headline: String {
        switch kind {
        case "permission_prompt": return "Needs your permission at the terminal"
        case "idle_prompt": return "Waiting for your input at the terminal"
        case "elicitation_dialog": return "An MCP server asks for input at the terminal"
        case "elicitation_url_dialog": return "An MCP server asks you to open a link at the terminal"
        case "agent_needs_input": return "A background agent needs input at the terminal"
        default: return "Needs you at the terminal"
        }
    }
}

/// `AgentSession.status`: what the app shows on a question's card and in the sessions list.
public enum SessionStatus: Hashable, Sendable {
    case waiting                    // in wait_for_answers, seen in the last 6 minutes
    case working                    // running, seen in the last 6 minutes
    case idle                       // its turn ended; open at its terminal, or closed without a word
    case quiet(processOpen: Bool)   // running or waiting but silent for 6+ minutes: unknown
    case ended(String?)             // SessionEnd (reason), or its process is gone

    public var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }

    /// Whether offering `claude --resume` makes sense: not while the session is live, and
    /// not while its process is known to be open (resuming would run it twice).
    public var resumable: Bool {
        switch self {
        case .ended: return true
        case .quiet(let open): return !open
        case .waiting, .working, .idle: return false
        }
    }
}

/// A hook event or QuestBits call to record on a session (`Store.recordSession`).
public struct SessionEvent: Sendable {
    public enum Kind: String, Sendable {
        case start = "session_start"   // SessionStart: create or revive, running
        case prompt                    // UserPromptSubmit: running
        case stop                      // Stop: idle
        case end = "session_end"       // SessionEnd: ended
        case mcp                       // a QuestBits MCP call: running (a waiting session stays waiting)
        case wait                      // wait_for_answers is waiting: waiting
        case waitDone = "wait_done"    // wait_for_answers returned: running, if it was waiting
        case notify = "notification"   // Notification: sets or clears `attention` (project sessions only)

        /// Whether this event shows the session went on, so a "needs you at the terminal"
        /// item is over. wait / wait_done are not: a wait runs in the background while a
        /// permission prompt may still be open.
        public var clearsAttention: Bool {
            switch self {
            case .start, .prompt, .stop, .end, .mcp: return true
            case .wait, .waitDone, .notify: return false
            }
        }
    }
    public var kind: Kind
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var source: String?
    public var endReason: String?
    public var process: ClaudeProcess?
    public var notificationType: String?    // Notification: Claude Code's notification_type
    public var message: String?             // Notification: its text (stored redacted)
    public var at: Date

    public init(_ kind: Kind, sessionId: String, cwd: String? = nil, transcriptPath: String? = nil,
                source: String? = nil, endReason: String? = nil, process: ClaudeProcess? = nil,
                notificationType: String? = nil, message: String? = nil, at: Date = Date()) {
        self.kind = kind; self.sessionId = sessionId; self.cwd = cwd; self.transcriptPath = transcriptPath
        self.source = source; self.endReason = endReason; self.process = process
        self.notificationType = notificationType; self.message = message; self.at = at
    }

    /// Hook events create the session when it is missing (a hook installed mid-session);
    /// SessionEnd and MCP calls only change a session a hook recorded. A Notification
    /// creates one only in a project's folder.
    public var createsSession: Bool {
        switch kind {
        case .start, .prompt, .stop, .notify: return true
        case .end, .mcp, .wait, .waitDone: return false
        }
    }

    public var clearsAttention: Bool { kind.clearsAttention }
}

// MARK: - The Claude Code process

/// The Claude Code process a hook command or the MCP server runs under, identified by pid
/// and start time (a pid alone can be reused). Hooks run through a shell, the MCP server
/// directly, so this is the nearest ancestor that is not a shell or wrapper.
public struct ClaudeProcess: Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date) { self.pid = pid; self.startedAt = startedAt }

    static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh",
                                        "env", "nice", "nohup", "timeout", "gtimeout"]

    /// The nearest ancestor of this process that is not a shell (nil when none is found).
    public static func host() -> ClaudeProcess? {
        var pid = getppid()
        for _ in 0..<6 {
            guard pid > 1, let info = bsdInfo(pid) else { return nil }
            if !wrappers.contains(info.name) { return ClaudeProcess(pid: pid, startedAt: info.started) }
            pid = info.ppid
        }
        return nil
    }

    /// Whether the process `pid` still runs and is the one that started at `startedAt`
    /// (within a second). nil when there is no pid to check.
    public static func isRunning(pid: Int32?, startedAt: Date?) -> Bool? {
        guard let pid, pid > 0 else { return nil }
        guard let info = bsdInfo(pid) else { return false }
        guard let startedAt else { return true }
        return abs(info.started.timeIntervalSince(startedAt)) < 1
    }

    private static func bsdInfo(_ pid: Int32) -> (name: String, ppid: Int32, started: Date)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
        return (name, Int32(bitPattern: info.pbi_ppid), started)
    }
}
