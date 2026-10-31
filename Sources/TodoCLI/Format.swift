import Foundation

/// Text helpers shared by the commands.
enum Fmt {
    private static let isoFormatter = ISO8601DateFormatter()   // UTC, as the MCP server writes dates

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

    /// A calendar day (due dates, milestone targets: stored as local midnight).
    static func day(_ d: Date) -> String { dayFormatter.string(from: d) }

    /// "[in_progress/high]", "[todo]", "[waiting:user]".
    static func statusTag(_ t: TodoTask) -> String {
        var s = t.status.rawValue
        if let on = t.waitingOn { s += ":" + on.rawValue }
        if t.priority != .none { s += "/" + t.priority.rawValue }
        return "[\(s)]"
    }

    /// One task as a line: "QUE-20 [in_progress/high] Title — blocked by QUE-35; branch feat/x".
    static func taskLine(_ t: TodoTask, _ rel: TaskRelations, titleWidth: Int = 120) -> String {
        var extras: [String] = []
        if let blockers = rel.blockedBy[t.id], !blockers.isEmpty {
            extras.append("blocked by " + blockers.map(\.code).joined(separator: ", "))
        }
        if let reason = t.waitingReason, !reason.isEmpty { extras.append(oneLine(reason, max: 120)) }
        if let branch = t.branch { extras.append("branch " + branch) }
        if let due = t.dueDate { extras.append("due " + day(due)) }
        let head = "\(t.code) \(statusTag(t)) \(oneLine(t.title, max: titleWidth))"
        return extras.isEmpty ? head : head + " — " + extras.joined(separator: "; ")
    }

    /// `s` on one line (newlines become spaces), cut to `max` characters with an ellipsis.
    static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// User-written markdown as a blockquote, so its own headings never break the outline
    /// of an export around it.
    static func quote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
    }

    /// Text set off inside a markdown list item (indented two spaces, as a quote).
    static func indentedQuote(_ text: String) -> String {
        quote(text).split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  " + $0 }.joined(separator: "\n")
    }

    /// "1 decision", "2 notes".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }

    /// Pretty, key-sorted JSON (slashes unescaped) with a trailing newline.
    static func json(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
