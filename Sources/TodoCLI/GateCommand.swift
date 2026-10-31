import Foundation

/// `questbits hook pre-tool-use`: the QuestBits gate (QUE-36), a Claude Code PreToolUse
/// hook. Reads the hook's JSON on stdin (session_id, cwd, tool_name, tool_input) and
/// answers on stdout with Claude Code's decision JSON, or nothing:
///
///   nothing (exit 0)  no rule matches, or cwd is in no project's repo folder: Claude Code's
///                     normal permission flow decides (the gate acts only in projects).
///                     ("defer" is not used: Claude Code honors it only with -p, where it
///                     ends the turn; interactively it is ignored with a warning.)
///   deny              a rule matches: an approve question is waiting in QuestBits; the
///                     reason tells the agent its id and to retry the same call once approved.
///   allow             only for a call that exactly matches an approval the user gave in
///                     this session within 24 hours and that was not used yet (used now).
///   ask               anything went wrong (bad JSON, no database, a database error) on a
///                     call a default rule matches, or one that cannot be checked: Claude Code
///                     asks in the terminal. Never allow on an error. The gate also answers
///                     ask by itself when it has not decided within `watchdogSeconds` (well
///                     under the hook's timeout, where Claude Code would block the call), and
///                     the installed hook command answers ask when this binary crashes
///                     (HookInstaller): an error never becomes a silent allow or a hard block.
///
/// The raw tool input is never written anywhere: the question holds a redacted copy
/// (GateRedactor) and gate_requests a SHA-256 of the exact call (GateCall.inputHash).
/// Debug output (QUESTBITS_HOOK_DEBUG=1) names the step that failed, never the input.
enum GateCommand {
    enum Decision {
        case none
        case allow(String)
        case deny(String)
        case ask(String)
    }

    /// The hook's timeout is 15 s (HookInstaller); answer ask well before it.
    static let watchdogSeconds = 10.0

    /// Whoever answers first — the decision or the watchdog — writes stdout; the other does not.
    final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    static func run(_ ctx: CLIContext, home: String = NSHomeDirectory()) -> Int32 {
        let started = Date()
        let answer = Answer()
        DispatchQueue.global().asyncAfter(deadline: .now() + watchdogSeconds) {
            if answer.take(), let out = output(.ask(askReason("it took too long (the database may be busy)"))) {
                FileHandle.standardOutput.write(Data((out + "\n").utf8))
            }
            debug("the watchdog ended the hook")
            _exit(0)
        }
        let input = ctx.readStdin()
        let decision = decide(input: input, ctx: ctx, home: home)
        guard answer.take() else { while true { sleep(1) } }    // the watchdog answered and exits
        if let out = output(decision) { ctx.write(out + "\n") }
        clearAttention(input: input, ctx: ctx, at: started)
        return 0
    }

    /// A tool call means the session went on: clear its "needs you at the terminal" item
    /// (SessionAttention) raised before this call. Read-only unless there is one; any
    /// error is ignored (the decision is already out).
    static func clearAttention(input: Data, ctx: CLIContext, at: Date) {
        guard ctx.databaseExists,
              let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let sid = (json["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sid.isEmpty,
              let attention = try? ctx.withStore({ try $0.agentSession(id: sid)?.attention }),
              attention.at <= at
        else { return }
        do {
            _ = try ctx.withWritableStore(ChangeOrigin(.hook, agentSessionId: sid)) { try $0.clearSessionAttention(id: sid, at: at) }
        } catch {
            debug("the session's attention could not be cleared")
        }
    }

    static func output(_ decision: Decision) -> String? {
        let (kind, reason): (String, String)
        switch decision {
        case .none: return nil
        case .allow(let r): (kind, reason) = ("allow", r)
        case .deny(let r): (kind, reason) = ("deny", r)
        case .ask(let r): (kind, reason) = ("ask", r)
        }
        let obj: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse",
                                                         "permissionDecision": kind,
                                                         "permissionDecisionReason": reason]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            // Cannot happen with string values; never fall through to allow.
            return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"QuestBits gate: internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decide(input: Data, ctx: CLIContext, home: String) -> Decision {
        guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let tool = json["tool_name"] as? String, !tool.isEmpty else {
            debug("the event JSON has no tool_name")
            return .ask(askReason("its hook input could not be read"))
        }
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let cwd = (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] ?? ctx.cwd

        // The defaults first, without the database: what to say if it cannot be read.
        let defaultsOnly = GateClassifier(rules: GateRule.defaults, repoRoot: nil, cwd: cwd, home: home)
        let byDefault = defaultsOnly.classify(toolName: tool, input: toolInput)
        func fallback(_ why: String) -> Decision {
            debug(why)
            return byDefault.isRisky ? .ask(askReason(why)) : .none
        }
        guard ctx.databaseExists else { return fallback("no QuestBits database") }

        // Which project (read-only).
        let mapped: Project?
        do {
            mapped = try ctx.withStore { store -> Project? in
                guard Store.isAbsolute(cwd) else { return nil }
                return try store.findProject(path: cwd)
            }
        } catch {
            return fallback("the QuestBits database could not be read")
        }
        guard let project = mapped else { return .none }       // not a project: normal flow

        // Its own rules. Unreadable: the defaults still apply, now with the repo folder known.
        let own: [String]
        do {
            own = try ctx.withStore { try $0.gateRules(projectId: project.id) }
        } catch {
            debug("the project's gate rules could not be read")
            let v = GateClassifier(rules: GateRule.defaults, repoRoot: project.repoPath, cwd: cwd, home: home)
                .classify(toolName: tool, input: toolInput)
            return v.isRisky ? .ask(askReason("the project's gate rules could not be read")) : .none
        }

        let classifier = GateClassifier(rules: GateRule.defaults + GateRule.parseAll(own),
                                        repoRoot: project.repoPath, cwd: cwd, home: home)
        let findings = classifier.findings(toolName: tool, input: toolInput)
        guard let first = findings.first else { return .none }
        let (rule, detail) = (first.rule, first.detail)

        guard let sid = (json["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sid.isEmpty else {
            debug("no session_id")
            return .ask(askReason("the call has no Claude Code session id to tie an approval to"))
        }
        let record = Store.GateCallRecord(
            sessionId: sid, projectId: project.id, toolName: tool,
            inputHash: GateCall.inputHash(toolName: tool, input: toolInput),
            rule: rule,
            prompt: "Allow: " + GateCall.headline(toolName: tool, input: toolInput),
            context: context(tool: tool, input: toolInput, cwd: cwd, project: project, findings: findings,
                             session: sid))
        do {
            let outcome = try ctx.withWritableStore(ChangeOrigin(.hook, agentSessionId: sid)) { try $0.gateRequest(record) }
            return decision(outcome, rule: rule, detail: detail, session: sid)
        } catch {
            debug("the gate request could not be written")
            return .ask(askReason("QuestBits could not record the request (\(rule))"))
        }
    }

    static func decision(_ outcome: Store.GateOutcome, rule: String, detail: String, session: String) -> Decision {
        switch outcome {
        case .allowed(let q):
            return .allow("QuestBits: the user approved this exact call (question \(q.id)); it is allowed this once.")
        case .refused(let q):
            let answer = (q.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = answer.count > 600 ? String(answer.prefix(599)) + "…" : answer
            return .deny("""
                QuestBits gate: the user did not approve this call (question \(q.id) on \(q.taskCode)). \
                Their answer: "\(shown)". Follow that answer; do not run this call another way. \
                Trying the exact same call again asks the user again.
                """)
        case .pending(let q):
            return .deny(denyText(q, rule: rule, detail: detail, session: session, again: true, expired: false))
        case .asked(let q, let expired):
            return .deny(denyText(q, rule: rule, detail: detail, session: session, again: false, expired: expired))
        }
    }

    static func denyText(_ q: Question, rule: String, detail: String, session: String, again: Bool, expired: Bool) -> String {
        let lead = again
            ? "QuestBits gate: this call is still waiting for the user's approval (question \(q.id) on \(q.taskCode))."
            : "QuestBits gate: this call needs the user's approval, so it was not run. "
              + (expired ? "The earlier approval is more than 24 hours old. " : "")
              + "Asked in QuestBits as question \(q.id) (approve) on \(q.taskCode)."
        return lead + " Rule: \(rule) (\(detail)). "
            + "Keep working on other things; do not try to run it another way. "
            + "get_answers or wait_for_answers with session \"\(session)\" shows the answer. "
            + "Once it is approved, retry exactly the same call: it will be allowed once, in this session, within 24 hours. "
            + "If the user answers with something else, follow that answer."
    }

    static func askReason(_ why: String) -> String {
        "QuestBits gate could not check this call (\(why)), so it asks here instead."
    }

    /// What the user reads under the question: the whole call (redacted, never cut), where,
    /// every rule it falls under, and what redaction hid. The app shows it as plain text.
    static func context(tool: String, input: [String: Any], cwd: String, project: Project,
                        findings: [GateFinding], session: String) -> String {
        let isShell = GateCall.isShellTool(tool) && input["command"] is String
        let raw = GateCall.rawText(toolName: tool, input: input)
        var head = isShell ? (tool == "Bash" ? "Command" : "\(tool) command") : "Tool \(tool)"
        if raw.count > GateCall.longCall {
            head += " (long: \(raw.count) characters; read it to the end before approving)"
        }
        let shown = findings.prefix(20).map { "- \($0.rule): \($0.detail)" }
        let more = findings.count > 20 ? ["- and \(findings.count - 20) more"] : []
        var notes: [String] = []
        let hidden = GateRedactor.hidden(in: raw)
        if hidden.any || input.keys.contains(where: GateRedactor.isSecretName) {
            notes.append("Parts that look like secrets are shown as ***. Approve covers the call as it is, including those parts.")
        }
        if hidden.code {
            notes.append("A hidden part holds $(…), backticks or <(…): it runs a command you cannot see here. Use Edit… instead of Approve unless you know what it runs.")
        }
        return """
        \(head):
        \(GateCall.display(toolName: tool, input: input))

        Folder: \(GateRedactor.redact(cwd)) (project \(project.code))
        \(findings.count == 1 ? "Rule" : "Rules"):
        \((shown + more).joined(separator: "\n"))
        \(notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n") + "\n")
        Claude Code session: \(session)

        Approve lets this exact call run once, in this session, within 24 hours. Edit… sends your text back to the agent instead.
        """
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["QUESTBITS_HOOK_DEBUG"] == "1" else { return }
        CLI.printErr("\(CLI.programName) hook pre-tool-use: \(message)")
    }
}
