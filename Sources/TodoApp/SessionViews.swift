import SwiftUI

// MARK: - Claude Code sessions

/// What a Claude Code session is doing now (AgentSession.status), with the command to
/// resume it when that makes sense. Re-read every 30 seconds: "seen 3 min ago" ages, and a
/// waiting session turns quiet, without any database write. The process check
/// (`ClaudeProcess.isRunning`) is what lets it say a session ended when its terminal
/// closed without a SessionEnd; silence alone only makes it unsure.
struct SessionStatusLine: View {
    let session: AgentSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(status(at: context.date), now: context.date)
        }
    }

    private func status(at now: Date) -> SessionStatus {
        session.status(now: now, processAlive: ClaudeProcess.isRunning(pid: session.pid, startedAt: session.pidStartedAt))
    }

    private func content(_ status: SessionStatus, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.icon(status)).foregroundStyle(Self.color(status))
                Text(Self.text(status, session, now: now))
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.resumable {
                CommandRow(command: session.resumeCommand, note: "Paste into a terminal to resume this session")
            }
        }
    }

    static func icon(_ s: SessionStatus) -> String {
        switch s {
        case .waiting: return "hourglass"
        case .working: return "bolt.circle"
        case .idle: return "pause.circle"
        case .quiet: return "questionmark.circle"
        case .ended: return "stop.circle"
        }
    }

    static func color(_ s: SessionStatus) -> Color {
        switch s {
        case .waiting, .working: return Theme.Colors.mossDark
        case .idle: return Theme.Colors.brandBlue
        case .quiet: return Theme.Colors.brandYellowDeep
        case .ended: return Theme.Colors.steel
        }
    }

    static func text(_ s: SessionStatus, _ session: AgentSession, now: Date) -> String {
        let seen = ago(session.lastSeen, now: now)
        switch s {
        case .waiting:
            return "Session is waiting for your answer (seen \(seen))."
        case .working:
            return "Session is working (seen \(seen)). It picks answers up when it next checks."
        case .idle:
            return "Session is idle at its terminal since \(seen). It sees your answer on its next turn: "
                + "type in that terminal to wake it."
        case .quiet(let open):
            return "No word from the session since \(seen). "
                + (open ? "Its process is still open; it may be busy." : "It may have ended.")
        case .ended(let reason):
            let when = ago(session.endedAt ?? session.lastSeen, now: now)
            return "Session ended \(when)" + (endReason(reason).map { " (\($0))" } ?? "") + "."
        }
    }

    /// SessionEnd reasons (Claude Code's), and the two QuestBits sets itself.
    static func endReason(_ reason: String?) -> String? {
        switch reason {
        case "prompt_input_exit": return "exited"
        case "clear": return "cleared"
        case "logout": return "logged out"
        case "resume": return "switched to another session"
        case "superseded": return "another session started in the same process"
        case "process_exited": return "its process closed"
        case nil, "", "other": return nil
        default: return reason
        }
    }

    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 6 * 3600 { return "\(Int(s / 3600)) h ago" }
        return fmtDateTime(date)
    }
}

/// The Detail tab's list of a project's Claude Code sessions (started in its folder) of
/// the last week, last seen first.
struct ProjectSessionsList: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    static let cap = 8

    var body: some View {
        let sessions = model.agentSessions.filter { $0.projectId == project.id }
        if sessions.isEmpty {
            Text("None in the last week. Sessions show up here once the Claude Code hooks are installed.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.steel)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sessions.prefix(Self.cap)) { SessionRow(session: $0) }
                if sessions.count > Self.cap {
                    Text("…\(sessions.count - Self.cap) more").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
            }
        }
    }
}

/// One session: its id (copyable), folder and start, then its status line.
struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(String(session.id.prefix(8)))
                    .font(Theme.Fonts.codeBadge).foregroundStyle(Theme.Colors.ink)
                    .help(session.id)
                Text(folder).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).lineLimit(1)
                Spacer()
                Text("started \(fmtDateTime(session.startedAt))")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            SessionStatusLine(session: session)
        }
    }

    private var folder: String {
        session.cwd.isEmpty ? "" : (session.cwd as NSString).lastPathComponent
    }
}

// MARK: - Task claims

/// The small "agent" chip on a claimed task (task rows and board cards): which session
/// works on it, in the tooltip. An expired claim shows greyed until someone takes the task
/// over or it closes. Re-read every minute, so a claim that lapses without any write shows.
struct ClaimChip: View {
    let claim: TaskClaim

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            chip(live: claim.isLive(at: context.date), now: context.date)
        }
    }

    private func chip(live: Bool, now: Date) -> some View {
        Label(live ? "agent" : "agent (expired)", systemImage: live ? "bolt.fill" : "bolt.slash")
            .font(Theme.Fonts.micro)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(live ? Theme.Colors.tealLight : Theme.Colors.surface, in: Capsule())
            .foregroundStyle(live ? Theme.Colors.mossDark : Theme.Colors.steel)
            .help(claim.summary(now: now))
    }
}

/// The task detail's claim line: who holds the task and their last heartbeat, with a
/// button to release the claim (e.g. when the session is gone and should not keep it).
struct ClaimLine: View {
    @EnvironmentObject var model: AppModel
    let task: TodoTask
    let claim: TaskClaim

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(now: context.date)
        }
    }

    private func row(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: claim.isLive(at: now) ? "bolt.circle" : "bolt.slash")
                .foregroundStyle(claim.isLive(at: now) ? Theme.Colors.mossDark : Theme.Colors.steel)
            Text(claim.summary(now: now))
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                .help(claim.label.map { "\(claim.holder) · label: \($0)" } ?? claim.holder)
            Spacer()
            Button("Release") { model.releaseClaim(task) }
                .buttonStyle(QBGhostButtonStyle())
                .help("Release the claim so another session (or you) can take this task")
        }
    }
}
