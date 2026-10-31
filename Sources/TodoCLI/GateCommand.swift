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
///                     asks in the terminal. Never allow on an error.
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

    static func run(_ ctx: CLIContext, home: String = NSHomeDirectory()) -> Int32 {
        let decision = decide(input: ctx.readStdin(), ctx: ctx, home: home)
        if let out = output(decision) { ctx.write(out + "\n") }
        return 0
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

        // Which project (read-only), and its own rules.
        let mapped: (project: Project, rules: [String])?
        do {
            mapped = try ctx.withStore { store -> (Project, [String])? in
                guard Store.isAbsolute(cwd), let p = try store.findProject(path: cwd) else { return nil }
                return (p, try store.gateRules(projectId: p.id))
            }
        } catch {
            return fallback("the QuestBits database could not be read")
        }
        guard let (project, own) = mapped else { return .none }       // not a project: normal flow

        let classifier = GateClassifier(rules: GateRule.defaults + GateRule.parseAll(own),
                                        repoRoot: project.repoPath, cwd: cwd, home: home)
        guard case let .risky(rule, detail) = classifier.classify(toolName: tool, input: toolInput) else { return .none }

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
            context: context(tool: tool, input: toolInput, cwd: cwd, project: project, rule: rule,
                             detail: detail, session: sid))
        do {
            let outcome = try ctx.withWritableStore { try $0.gateRequest(record) }
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

    /// What the user reads under the question: the call (redacted), where, which rule.
    static func context(tool: String, input: [String: Any], cwd: String, project: Project, rule: String,
                        detail: String, session: String) -> String {
        let call = GateCall.display(toolName: tool, input: input)
        return """
        \(tool == "Bash" ? "Command" : "Tool \(tool)"):
        \(call)

        Folder: \(GateRedactor.redact(cwd)) (project \(project.code))
        Rule: \(rule): \(detail)
        Claude Code session: \(session)

        Approve lets this exact call run once, in this session, within 24 hours. Edit… sends your text back to the agent instead.
        """
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["QUESTBITS_HOOK_DEBUG"] == "1" else { return }
        CLI.printErr("\(CLI.programName) hook pre-tool-use: \(message)")
    }
}
