import Foundation

/// Installs QuestBits' Claude Code hooks into ~/.claude/settings.json, and removes them.
/// Only the Settings buttons call it: hooks are never installed at launch.
///
/// The hooks are the rows of `rows`: each becomes one matcher group under its event,
/// `{"matcher": ..., "hooks": [{"type": "command", "command": ..., "timeout": ...}]}`,
/// whose command runs the bundled CLI by its full path (quoted: the dev bundle's path has
/// a space). Later steps add a row; installing again then adds it in place.
///
/// Each command first checks that the CLI is still there (`[ -x '<cli>' ] || exit 0`): when
/// the app was moved, trashed or is being rebuilt, the hook does nothing (exit 0, no output:
/// Claude Code's normal flow) instead of failing — a failing gate blocks every Bash and MCP
/// call in every folder. The gate's command also turns a crash of the CLI into "ask".
///
/// Ownership: every command this flavor writes ends with the shell comment `marker`
/// (`# questbits-hook:prod` or `# questbits-hook:dev`; `sh -c` ignores it). A handler
/// whose command ends with this flavor's marker is ours, wherever the app bundle was when
/// it was written; anything else (the user's hooks, the other flavor's, other settings)
/// is never changed. Installing removes our handlers and writes the current rows where the
/// first of them stood, so an upgrade (new bundle path, new rows) updates in place.
///
/// Writing: the file is parsed first and left alone when it is not a JSON object (or its
/// `hooks` is malformed); the old contents are copied to a timestamped backup beside it;
/// the new file is written to a temporary file and renamed over the old one, after a
/// re-read shows nobody changed it meanwhile. A settings.json that is a symlink stays a
/// symlink: its destination file is the one rewritten.
enum HookInstaller {
    #if DEV_BUILD
    static let flavor = "dev"
    #else
    static let flavor = "prod"
    #endif
    static var marker: String { "# questbits-hook:\(flavor)" }

    /// One hook: the Claude Code event, its matcher (nil = no matcher key: the event has
    /// none, or every occurrence), the CLI arguments, the timeout in seconds, and
    /// `onFailure` ("block": a crash, timeout or bad output stops the tool call instead of
    /// letting it run; Claude Code 2.1.295+, older versions ignore the key). `askOnCrash`:
    /// the command prints a PreToolUse "ask" when the CLI exits with an error.
    struct Row: Equatable {
        let event: String
        let matcher: String?
        let arguments: String
        let timeout: Int
        var onFailure: String? = nil
        var askOnCrash = false
    }

    /// What Install writes. SessionStart `compact` (after an auto or manual compaction) has
    /// a row of its own: it brings back the session's claimed tasks before the brief. Keep
    /// timeouts short: a hook that times out is cancelled, never blocking — except the gate
    /// (PreToolUse, QUE-36): it runs on every call of a tool that runs a shell command
    /// (Bash, Monitor, PowerShell) and every MCP call (the matcher is a regex, anchored so
    /// BashOutput and the like stay out). It decides on its own errors itself (ask), answers
    /// ask by itself before its timeout, and its command asks when the CLI crashes; when even
    /// that fails the call is blocked, never let through. A missing CLI is no decision. Notification (QUE-37): the types that mean the session
    /// waits for the user at its terminal (SessionAttention.needsUser), and the two that
    /// mean an MCP form was answered; auth_success and the others stay out.
    static let rows: [Row] = [
        Row(event: "SessionStart", matcher: "startup|resume|clear|fork", arguments: "hook session-start --brief", timeout: 10),
        Row(event: "SessionStart", matcher: "compact", arguments: "hook session-start --after-compact", timeout: 10),
        Row(event: "UserPromptSubmit", matcher: nil, arguments: "hook user-prompt-submit", timeout: 5),
        Row(event: "Stop", matcher: nil, arguments: "hook stop", timeout: 5),
        Row(event: "SessionEnd", matcher: nil, arguments: "hook session-end", timeout: 5),
        Row(event: "PreToolUse", matcher: "^(Bash|Monitor|PowerShell|mcp__.*)$", arguments: "hook pre-tool-use",
            timeout: 15, onFailure: "block", askOnCrash: true),
        Row(event: "Notification", matcher: notificationMatcher, arguments: "hook notification", timeout: 5)
    ]

    static let notificationMatcher = "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog"
        + "|agent_needs_input|elicitation_complete|elicitation_response"

    enum Status: Equatable {
        case notInstalled
        case installed                // our handlers are exactly the current rows
        case outdated                 // some of ours, but another bundle path or other rows
        case unreadable(String)       // settings.json is not JSON we can safely edit
    }

    enum InstallError: Error, CustomStringConvertible {
        case noBundledCLI
        case invalid(String)
        case changedMeanwhile
        case io(String)

        var description: String {
            switch self {
            case .noBundledCLI: return "This build has no questbits CLI in its bundle."
            case .invalid(let m): return m
            case .changedMeanwhile: return "settings.json changed while QuestBits was writing it. Try again."
            case .io(let m): return m
            }
        }
    }

    /// One command handler as it sits in settings.json.
    struct Handler: Equatable, Comparable {
        let event: String
        let matcher: String?
        let command: String
        let timeout: Int?
        var onFailure: String? = nil

        static func < (a: Handler, b: Handler) -> Bool {
            (a.event, a.matcher ?? "", a.command, a.timeout ?? -1, a.onFailure ?? "")
                < (b.event, b.matcher ?? "", b.command, b.timeout ?? -1, b.onFailure ?? "")
        }
    }

    static func settingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("settings.json")
    }

    // MARK: - Pure merge (no files)

    /// `'path'` for sh: single quotes, any single quote inside written as '\''.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What the gate's command prints when the CLI exits with an error (a crash).
    static let crashAsk = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","#
        + #""permissionDecisionReason":"QuestBits gate failed to run, so it asks here instead."}}"#

    /// `[ -x 'cli' ] || exit 0; exec 'cli' <arguments> # marker`. With `askOnCrash` the CLI's
    /// output is passed on when it exits 0, else `crashAsk` is printed.
    static func command(cli: String, _ row: Row, marker: String = marker) -> String {
        let q = shellQuote(cli)
        let check = "[ -x \(q) ] || exit 0; "
        guard row.askOnCrash else { return check + "exec \(q) \(row.arguments) \(marker)" }
        return check + "out=$(\(q) \(row.arguments)) && { [ -z \"$out\" ] || printf '%s\\n' \"$out\"; exit 0; }; "
            + "printf '%s\\n' \(shellQuote(crashAsk)) \(marker)"
    }

    /// The CLI path a command of ours runs: its first single-quoted word (`shellQuote`).
    static func cliPath(inCommand command: String) -> String? {
        let c = Array(command)
        guard var i = c.firstIndex(of: "'") else { return nil }
        var out = ""
        i += 1
        while i < c.count {
            if c[i] != "'" { out.append(c[i]); i += 1; continue }
            // '\'' inside: a quote, and the quoted word goes on.
            if i + 3 < c.count, c[i + 1] == "\\", c[i + 2] == "'", c[i + 3] == "'" { out.append("'"); i += 4; continue }
            return out
        }
        return nil
    }

    /// The CLI paths our handlers run that are no longer an executable file (the app was
    /// moved or deleted since they were written).
    static func missingCLIs(in root: [String: Any], marker: String = marker) -> [String] {
        var seen = Set<String>()
        return owned(in: root, marker: marker).compactMap { cliPath(inCommand: $0.command) }
            .filter { seen.insert($0).inserted && !FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func missingCLIs(settings: URL = settingsURL()) -> [String] {
        (try? missingCLIs(in: read(targetURL(settings)).root)) ?? []
    }

    /// Why hooks must not point at `cli`, or nil: a translocated copy (macOS runs a
    /// quarantined app from a random read-only folder) or a read-only volume (the DMG).
    static func unsafeLocation(_ cli: String) -> String? {
        if cli.contains("/AppTranslocation/") {
            return "macOS is running QuestBits from a temporary copy. Move QuestBits.app to Applications, open it from there, then install the hooks."
        }
        let readOnly = (try? URL(fileURLWithPath: cli).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
        if readOnly == true {
            return "QuestBits is running from a read-only disk (the disk image?). Copy it to Applications, open it from there, then install the hooks."
        }
        return nil
    }

    static func desired(cli: String, rows: [Row] = rows, marker: String = marker) -> [Handler] {
        rows.map { Handler(event: $0.event, matcher: $0.matcher, command: command(cli: cli, $0, marker: marker),
                           timeout: $0.timeout, onFailure: $0.onFailure) }
    }

    static func isOurs(_ handler: Any, marker: String) -> Bool {
        guard let h = handler as? [String: Any], let cmd = h["command"] as? String else { return false }
        return cmd.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(marker)
    }

    /// The `hooks` object, or an error when it is there but not an object.
    private static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        guard let raw = root["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else { throw InstallError.invalid("\"hooks\" in settings.json is not an object.") }
        return hooks
    }

    /// Our handlers in `root`, in file order.
    static func owned(in root: [String: Any], marker: String = marker) -> [Handler] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        var out: [Handler] = []
        for event in hooks.keys.sorted() {
            for group in hooks[event] as? [Any] ?? [] {
                guard let g = group as? [String: Any], let list = g["hooks"] as? [Any] else { continue }
                let matcher = (g["matcher"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                for h in list where isOurs(h, marker: marker) {
                    let d = h as! [String: Any]
                    out.append(Handler(event: event, matcher: matcher, command: d["command"] as! String,
                                       timeout: (d["timeout"] as? NSNumber)?.intValue,
                                       onFailure: d["onFailure"] as? String))
                }
            }
        }
        return out
    }

    /// With no CLI (a build without one), hooks of ours are always `.outdated`: they can
    /// still be uninstalled.
    static func status(of root: [String: Any], cli: String?, rows: [Row] = rows, marker: String = marker) -> Status {
        if root["hooks"] != nil && !(root["hooks"] is [String: Any]) {
            return .unreadable("\"hooks\" in settings.json is not an object.")
        }
        let have = owned(in: root, marker: marker)
        if have.isEmpty { return .notInstalled }
        guard let cli else { return .outdated }
        return have.sorted() == desired(cli: cli, rows: rows, marker: marker).sorted() ? .installed : .outdated
    }

    /// `root` without our handlers. A group left with no handlers goes, an event left with
    /// no groups goes, and `hooks` goes when that empties it. `firstIndex` is where each
    /// event's first removed group stood, so a re-install puts the new groups there.
    static func removingOurs(from root: [String: Any], marker: String = marker) throws
        -> (root: [String: Any], firstIndex: [String: Int]) {
        var hooks = try hooksObject(root)
        var firstIndex: [String: Int] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { continue }   // not ours to judge
            var kept: [Any] = []
            var removedAny = false
            for group in groups {
                guard var g = group as? [String: Any], let list = g["hooks"] as? [Any] else { kept.append(group); continue }
                let remaining = list.filter { !isOurs($0, marker: marker) }
                if remaining.count == list.count { kept.append(group); continue }
                removedAny = true
                if firstIndex[event] == nil { firstIndex[event] = kept.count }
                if !remaining.isEmpty {
                    g["hooks"] = remaining
                    kept.append(g)
                }
            }
            guard removedAny else { continue }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        var out = root
        if !firstIndex.isEmpty { out["hooks"] = hooks.isEmpty ? nil : hooks }
        return (out, firstIndex)
    }

    /// `root` with our handlers replaced by the current rows (one group per row).
    static func installing(into root: [String: Any], cli: String, rows: [Row] = rows, marker: String = marker) throws -> [String: Any] {
        var (out, firstIndex) = try removingOurs(from: root, marker: marker)
        var hooks = try hooksObject(out)
        for event in uniqued(rows.map(\.event)) {
            if hooks[event] != nil && !(hooks[event] is [Any]) {
                throw InstallError.invalid("\"hooks.\(event)\" in settings.json is not a list.")
            }
            var groups = hooks[event] as? [Any] ?? []
            let new: [Any] = rows.filter { $0.event == event }.map { row in
                var handler: [String: Any] = ["type": "command",
                                              "command": command(cli: cli, row, marker: marker),
                                              "timeout": row.timeout]
                if let f = row.onFailure { handler["onFailure"] = f }
                var group: [String: Any] = ["hooks": [handler]]
                if let m = row.matcher { group["matcher"] = m }
                return group
            }
            groups.insert(contentsOf: new, at: min(firstIndex[event] ?? groups.count, groups.count))
            hooks[event] = groups
        }
        out["hooks"] = hooks
        return out
    }

    private static func uniqued(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { seen.insert($0).inserted }
    }

    // MARK: - Files

    /// The file to read and rewrite: settings.json itself, or the file its symlink points to.
    static func targetURL(_ settings: URL) throws -> URL {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: settings.path),
              attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return settings }
        let resolved = settings.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: resolved.path), resolved.path != settings.path else {
            throw InstallError.invalid("\(settings.path) is a link to a missing file.")
        }
        return resolved
    }

    /// The file's bytes (nil when there is none) and its top-level object.
    static func read(_ url: URL) throws -> (data: Data?, root: [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, [:]) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw InstallError.io("Could not read \(url.path): \(error.localizedDescription)")
        }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (data, [:])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let root = obj as? [String: Any] else {
            throw InstallError.invalid("\(url.path) is not a JSON object, so it was left alone. Fix it and try again.")
        }
        return (data, root)
    }

    static func status(settings: URL = settingsURL(), cli: String?) -> Status {
        do {
            return status(of: try read(try targetURL(settings)).root, cli: cli)
        } catch {
            return .unreadable("\(error)")
        }
    }

    /// Writes the current rows (a no-op when they are already there). Returns the backup
    /// made of the previous file, nil when nothing was written or there was no file.
    @discardableResult
    static func install(settings: URL = settingsURL(), cli: String, now: Date = Date()) throws -> URL? {
        try rewrite(settings, now: now) { root in
            status(of: root, cli: cli) == .installed ? nil : try installing(into: root, cli: cli)
        }
    }

    /// Removes this flavor's handlers (a no-op when there are none).
    @discardableResult
    static func uninstall(settings: URL = settingsURL(), now: Date = Date()) throws -> URL? {
        try rewrite(settings, now: now) { root in
            owned(in: root).isEmpty ? nil : try removingOurs(from: root).root
        }
    }

    /// Read, transform (nil = leave the file alone), back up, write atomically.
    private static func rewrite(_ settings: URL, now: Date, _ transform: ([String: Any]) throws -> [String: Any]?) throws -> URL? {
        let fm = FileManager.default
        let target = try targetURL(settings)
        let (before, root) = try read(target)
        guard let updated = try transform(root) else { return nil }
        var out: Data
        do {
            out = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw InstallError.io("Could not encode settings.json: \(error.localizedDescription)")
        }
        out.append(0x0A)

        let dir = target.deletingLastPathComponent()
        var backup: URL?
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let before { backup = try writeBackup(before, beside: settings, now: now) }
        } catch let e as InstallError { throw e } catch {
            throw InstallError.io("Could not back up settings.json: \(error.localizedDescription)")
        }

        // Someone (Claude Code, the user) wrote the file since we read it: don't clobber that.
        let current = fm.fileExists(atPath: target.path) ? try? Data(contentsOf: target) : nil
        guard current == before else { throw InstallError.changedMeanwhile }

        let perms = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        let temp = dir.appendingPathComponent(".\(target.lastPathComponent).questbits-\(UUID().uuidString).tmp")
        do {
            try writeNew(out, to: temp)
            if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: temp.path) }
            guard rename(temp.path, target.path) == 0 else {
                throw InstallError.io("Could not replace \(target.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? fm.removeItem(at: temp)
            if let e = error as? InstallError { throw e }
            throw InstallError.io("Could not write \(target.path): \(error.localizedDescription)")
        }
        return backup
    }

    /// `settings.json.questbits-<flavor>-backup-<yyyyMMdd-HHmmss>` beside settings.json
    /// (beside the link when it is one), readable by the owner only; `-2`, `-3`… when taken.
    static func writeBackup(_ data: Data, beside settings: URL, now: Date) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(settings.lastPathComponent).questbits-\(flavor)-backup-\(f.string(from: now))"
        let dir = settings.deletingLastPathComponent()
        var url = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try writeNew(data, to: url)
        return url
    }

    /// Creates `url` (it must not exist) readable by the owner only from the start —
    /// settings.json can hold API keys — and writes `data` to it.
    static func writeNew(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else {
            throw InstallError.io("Could not create \(url.path): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw InstallError.io("Could not write \(url.path): \(error.localizedDescription)")
        }
    }
}
