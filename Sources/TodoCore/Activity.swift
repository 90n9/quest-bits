import Foundation

// MARK: - Where a change came from

/// The process a write came from, recorded with each change (`task_history.source`, and
/// `task_notes.source` / `page_history.source`). NULL on rows written before 1.5.0, or by
/// an older binary: unknown. Persisted as the raw value.
public enum ChangeSource: String, Codable, CaseIterable, Sendable {
    case app            // the QuestBits app: the user
    case mcp            // the MCP server: an agent's tool call
    case cli            // a questbits CLI command run by hand (none writes yet)
    case hook           // a questbits hook command Claude Code ran (the gate, session hooks)
    case importer = "import"   // questbits import --apply

    public var display: String {
        switch self {
        case .app: return "App"
        case .mcp: return "MCP"
        case .cli: return "CLI"
        case .hook: return "Hook"
        case .importer: return "Import"
        }
    }
}

/// What `Store` records with each change it writes (`Store.origin`): the source, and the
/// agent's session when known — its Claude Code session id (`AgentSession.id`, QUE-35)
/// and the `session` label it passed.
public struct ChangeOrigin: Hashable, Sendable {
    public var source: ChangeSource
    public var agentSessionId: String?
    public var sessionLabel: String?

    public init(_ source: ChangeSource, agentSessionId: String? = nil, sessionLabel: String? = nil) {
        self.source = source
        self.agentSessionId = agentSessionId.flatMap { $0.isEmpty ? nil : $0 }
        self.sessionLabel = sessionLabel.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Activity feed

/// Who did something in the feed: the user (the app, or a note they wrote), an agent
/// (over MCP or through a hook, with its session when known), a CLI command, an import,
/// or unknown (rows from before sources were recorded).
public enum ActivityActor: Hashable, Sendable {
    case user
    case agent(sessionId: String?, label: String?)
    case cli
    case importer
    case unknown

    /// Who wrote a row: by its source when recorded, else by a note's or page's author.
    static func of(source: ChangeSource?, author: NoteAuthor?, sessionId: String?, label: String?) -> ActivityActor {
        switch source {
        case .app?: return .user
        case .mcp?, .hook?: return .agent(sessionId: sessionId, label: label)
        case .cli?: return .cli
        case .importer?: return .importer
        case nil:
            switch author {
            case .user?: return .user
            case .agent?: return .agent(sessionId: sessionId, label: label)
            case nil: return .unknown
            }
        }
    }

    public var isAgent: Bool { if case .agent = self { return true } else { return false } }

    /// "You", "Agent", "CLI", "Import", or "Unknown" (the session goes on its own line).
    public var display: String {
        switch self {
        case .user: return "You"
        case .agent: return "Agent"
        case .cli: return "CLI"
        case .importer: return "Import"
        case .unknown: return "Unknown"
        }
    }

    /// Its session in short: the label when given (and not just the session id), else
    /// "session" and the id's first 8.
    public var sessionDisplay: String? {
        guard case .agent(let sid, let label) = self else { return nil }
        if let label, label != sid { return label }
        return sid.map { "session \($0.prefix(8))" }
    }

    /// Entries with the same key are the same actor's (`ActivityGroup.group`): an agent by
    /// its Claude Code session when known, else by its label.
    public var groupKey: String {
        switch self {
        case .user: return "user"
        case .agent(let sid, let label): return "agent:" + (sid ?? label ?? "")
        case .cli: return "cli"
        case .importer: return "import"
        case .unknown: return "unknown"
        }
    }
}

/// What a feed entry is about: a task, or a wiki page.
public enum ActivitySubject: Hashable, Sendable {
    case task(id: Int64, code: String, title: String)
    case page(id: Int64, title: String, kind: PageKind)

    public var taskId: Int64? { if case .task(let id, _, _) = self { return id } else { return nil } }
}

/// One entry of the feed (`Store.activity`): a task change (task_history), a note
/// (task_notes) or a wiki page change (page_history). Long values arrive cut to
/// `Store.activityValueLimit` characters.
public struct ActivityEvent: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case change, note, page }

    public var kind: Kind
    public var rowId: Int64
    public var timestamp: Date
    public var projectId: Int64
    public var projectCode: String
    public var subject: ActivitySubject
    /// The changed field ("status", "created", …); a note's kind; a page's field.
    public var field: String
    public var oldValue: String
    public var newValue: String
    public var source: ChangeSource?
    public var actor: ActivityActor

    public var id: String { "\(kind.rawValue)-\(rowId)" }

    public init(kind: Kind, rowId: Int64, timestamp: Date, projectId: Int64, projectCode: String,
                subject: ActivitySubject, field: String, oldValue: String, newValue: String,
                source: ChangeSource?, actor: ActivityActor) {
        self.kind = kind
        self.rowId = rowId
        self.timestamp = timestamp
        self.projectId = projectId
        self.projectCode = projectCode
        self.subject = subject
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.source = source
        self.actor = actor
    }

    /// A short English line for the entry: "Status: To Do → In Progress", "Decision note:
    /// …", "Page edited: body".
    public var summary: String {
        switch kind {
        case .note:
            let kindName = NoteKind(rawValue: field)?.display ?? "Note"
            return "\(kindName == "Note" ? "Note" : kindName + " note"): \(Self.oneLine(newValue))"
        case .page:
            switch field {
            case "created": return "Page created"
            case "body": return "Page edited"
            default: return "Page \(TaskEvent.label(forField: field).lowercased()): " + Self.change(oldValue, newValue)
            }
        case .change:
            switch field {
            case "created": return "Created"
            default: return "\(TaskEvent.label(forField: field)): " + Self.change(oldValue, newValue)
            }
        }
    }

    private static func change(_ old: String, _ new: String) -> String {
        let o = oneLine(old), n = oneLine(new)
        if n.isEmpty { return o.isEmpty ? "cleared" : "\(o) removed" }
        return o.isEmpty ? n : "\(o) → \(n)"
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Entries in a row of the feed: the run of entries one actor wrote on one subject, one
/// after the other, newest first (`ActivityGroup.group`).
public struct ActivityGroup: Identifiable, Hashable, Sendable {
    public var events: [ActivityEvent]   // newest first; never empty

    public var id: String { events[0].id }
    public var latest: Date { events[0].timestamp }
    public var earliest: Date { events[events.count - 1].timestamp }
    public var subject: ActivitySubject { events[0].subject }
    public var actor: ActivityActor { events[0].actor }
    public var projectId: Int64 { events[0].projectId }
    public var projectCode: String { events[0].projectCode }

    /// The entries newest first as rows: consecutive entries (nothing else in between) on
    /// the same subject by the same actor, each within `gap` of the next and on the same
    /// day, collapse into one row.
    public static func group(_ events: [ActivityEvent], gap: TimeInterval = 30 * 60,
                             calendar: Calendar = .current) -> [ActivityGroup] {
        var out: [ActivityGroup] = []
        for e in events {
            if let last = out.last?.events.last, last.subject == e.subject, last.actor.groupKey == e.actor.groupKey,
               last.timestamp.timeIntervalSince(e.timestamp) <= gap,
               calendar.isDate(last.timestamp, inSameDayAs: e.timestamp) {
                out[out.count - 1].events.append(e)
            } else {
                out.append(ActivityGroup(events: [e]))
            }
        }
        return out
    }
}

extension TaskEvent {
    /// The app's label for a history field ("status" → "Status").
    public static func label(forField field: String) -> String {
        switch field {
        case "created": return "Created"
        case "status": return "Status"
        case "waiting on": return "Waiting on"
        case "priority": return "Priority"
        case "due date": return "Due date"
        case "tags": return "Tags"
        case "link": return "Link"
        case "estimate": return "Estimate"
        case "project": return "Moved project"
        case "blocked by": return "Blocked by"
        case "relates to": return "Relates to"
        case "duplicate of": return "Duplicate of"
        case "decided_on": return "Decided on"
        default: return field.capitalized
        }
    }
}
