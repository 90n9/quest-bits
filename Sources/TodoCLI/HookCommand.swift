import Foundation

/// `questbits hook <event>`: Claude Code hook commands that record the session the hook
/// fires in (`agent_sessions`, see AgentSession), reading the hook's event JSON on stdin.
/// Only session_id, cwd, transcript_path, source (SessionStart) and reason (SessionEnd)
/// are read; a prompt or reply in the event is never stored.
///
///   session-start       SessionStart       running; prints the session line (and --brief)
///   user-prompt-submit  UserPromptSubmit   running
///   stop                Stop               idle (its turn ended)
///   session-end         SessionEnd         ended, with the reason
///
/// A hook must never get in Claude Code's way: every hook exits 0 and is silent on stderr,
/// whatever goes wrong (no database, bad JSON, a locked database), and creates no database.
/// (Exit 2 would block a Stop or a prompt.) QUESTBITS_HOOK_DEBUG=1 reports errors on stderr.
enum HookCommand {
    static let command = CLICommand(
        name: "hook",
        usage: "hook <session-start|user-prompt-submit|stop|session-end> [--brief]",
        summary: "Claude Code hook: record the session from the event JSON on stdin (always exits 0).",
        details: """
        Register each as a command hook on the Claude Code event of the same name, with the
        full path of this binary (Settings → Claude Code Hooks in the app does this).
        Reads the hook's JSON on stdin (session_id, cwd, ...).
          session-start       SessionStart: records the session as running and, when cwd belongs to
                              a project, prints "QuestBits session: <id>" for the agent's context
            --brief           also print `brief` for that folder first
          user-prompt-submit  UserPromptSubmit: running (the prompt itself is not read or stored)
          stop                Stop: idle, waiting at the terminal
          session-end         SessionEnd: ended, with its reason
        Always exits 0 and prints nothing on stderr; QUESTBITS_HOOK_DEBUG=1 shows errors.
        """,
        flags: ["brief"],
        neverFails: true,
        run: { run($0, $1) })

    static let events = ["session-start", "user-prompt-submit", "stop", "session-end"]

    static func run(_ args: CLIArgs, _ ctx: CLIContext) -> Int32 {
        do {
            try record(args, ctx)
        } catch CLIError.usage(let message), CLIError.failure(let message) {
            debug(message)
        } catch {
            debug("\(error)")
        }
        return 0
    }

    private static func record(_ args: CLIArgs, _ ctx: CLIContext) throws {
        guard args.positionals.count == 1, let name = args.positionals.first, events.contains(name) else {
            throw CLIError.usage("expected one of: " + events.joined(separator: ", "))
        }
        // Read stdin first, so Claude Code never blocks writing the event to us.
        let input = ctx.readStdin()
        guard ctx.databaseExists else { return }
        guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let sid = (json["session_id"] as? String)?.trimmingCharacters(in: .whitespaces), !sid.isEmpty
        else { throw CLIError.failure("no session_id in the event JSON") }
        let field = { (key: String) -> String? in (json[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let cwd = field("cwd") ?? ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] ?? ctx.cwd

        let kind: SessionEvent.Kind
        switch name {
        case "session-start": kind = .start
        case "user-prompt-submit": kind = .prompt
        case "stop": kind = .stop
        default: kind = .end
        }
        let event = SessionEvent(kind, sessionId: sid, cwd: cwd, transcriptPath: field("transcript_path"),
                                 source: kind == .start ? field("source") : nil,
                                 endReason: kind == .end ? field("reason") : nil,
                                 process: kind == .end ? nil : ClaudeProcess.host())
        let out = try ctx.withWritableStore { store -> String in
            let session = try store.recordSession(event)
            guard kind == .start, let session else { return "" }
            // Tidy up: sessions whose Claude Code process closed without a SessionEnd.
            _ = try? store.endSessionsWithoutProcess()
            guard let pid = session.projectId,
                  let project = try store.listProjects(includeArchived: false).first(where: { $0.id == pid })
            else { return "" }
            var lines = ""
            if args.has("brief") {
                lines = capped(try BriefCommand.render(project, store: store, next: BriefCommand.defaultNext),
                               code: project.code) + "\n"
            }
            return lines + sessionLine(session.id)
        }
        if !out.isEmpty { ctx.write(out) }
    }

    /// Claude Code keeps at most 10,000 characters of a hook's stdout in context (more is
    /// saved to a file and only a preview is shown), so a brief with a long project guide is
    /// cut at a line boundary well below that, leaving room for the session line.
    static let briefLimit = 8_000

    static func capped(_ brief: String, code: String) -> String {
        guard brief.count > briefLimit else { return brief }
        var kept = String(brief.prefix(briefLimit))
        if let lastBreak = kept.lastIndex(of: "\n") { kept = String(kept[..<lastBreak]) }
        return kept + "\n\n…brief cut here; get_guide \(code) and list_tasks have the rest.\n"
    }

    /// What the agent reads at session start (plain stdout of a SessionStart hook joins
    /// its context): the session id to pass as the `session` label.
    static func sessionLine(_ id: String) -> String {
        """
        QuestBits session: \(id)
        When you use QuestBits tools, pass this id as `session` (ask_user, get_answers, wait_for_answers, \
        add_note); a subagent adds a suffix, e.g. \(id)/QUE-3.

        """
    }

    private static func debug(_ message: String) {
        guard ProcessInfo.processInfo.environment["QUESTBITS_HOOK_DEBUG"] == "1" else { return }
        CLI.printErr("\(CLI.programName) hook: \(message)")
    }
}
