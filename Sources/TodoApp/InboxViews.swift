import SwiftUI

// MARK: - Waiting on you (inbox)

/// An item on the Waiting on you page (`AppModel.inboxItems`): a session waiting at its
/// terminal (by session id), an open question, or a task waiting on the user (by id).
enum InboxItemID: Hashable {
    case session(String)
    case question(Int64)
    case task(Int64)
}

/// The content column of the Waiting on you page: everything that needs the user, across
/// projects, in three sections (sessions at a terminal, questions, tasks), each the longest
/// waiting first. Rows carry the quick action (Dismiss, Approve, Answered); the detail
/// column handles the rest. Double-click (or Return) opens the task or project.
struct InboxListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.waitingOnYou.isEmpty {
                ContentUnavailableViewCompat(text: "Nothing waits on you.\nQuestions, approvals and tasks agents hand you show up here.")
            } else {
                list
            }
        }
        .navigationTitle("Waiting on you")
        .qbParchment()
    }

    private var list: some View {
        List(selection: $model.inboxSelection) {
            let w = model.waitingOnYou
            if !w.sessions.isEmpty {
                Section("At the terminal") {
                    ForEach(w.sessions) { InboxSessionRow(session: $0).tag(InboxItemID.session($0.id)) }
                }
            }
            if !w.questions.isEmpty {
                Section("Questions") {
                    ForEach(w.questions) { InboxQuestionRow(question: $0).tag(InboxItemID.question($0.id)) }
                }
            }
            if !w.tasks.isEmpty {
                Section("Tasks waiting on you") {
                    ForEach(w.tasks) { InboxTaskRow(item: $0).tag(InboxItemID.task($0.id)) }
                }
            }
        }
        .contextMenu(forSelectionType: InboxItemID.self) { items in
            if let item = items.first { Button(openLabel(item)) { model.openInboxItem(item) } }
        } primaryAction: { items in
            if let item = items.first { model.openInboxItem(item) }
        }
    }

    private func openLabel(_ item: InboxItemID) -> String {
        if case .session = item { return "Open Project" }
        return "Open Task"
    }
}

/// The first line of every inbox row: project code, a label, and how long it has waited.
private struct InboxRowHeader: View {
    let projectCode: String?
    let label: String
    let since: Date

    var body: some View {
        HStack(spacing: 6) {
            if let projectCode { CodeBadge(code: projectCode) }
            Text(label).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).lineLimit(1)
            Spacer()
            Text(since, format: .relative(presentation: .named))
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
    }
}

/// A session waiting at its terminal: what it waits for, with Dismiss.
struct InboxSessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            InboxRowHeader(projectCode: session.projectId.map(model.projectCode(for:)).flatMap { $0.isEmpty ? nil : $0 },
                           label: "session \(session.id.prefix(8))", since: session.attention?.at ?? session.lastSeen)
            HStack(alignment: .firstTextBaseline) {
                Text(session.attention?.headline ?? "Needs you at the terminal")
                    .font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                Spacer(minLength: 4)
                Button("Dismiss") { model.dismissAttention(session) }
                    .buttonStyle(QBGhostButtonStyle())
                    .help("Handled it: remove this until the session needs you again")
            }
        }
        .padding(.vertical, 3)
    }
}

/// An open question; an approval can be approved right from the row.
struct InboxQuestionRow: View {
    @EnvironmentObject var model: AppModel
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            InboxRowHeader(projectCode: question.projectCode, label: "\(question.taskCode) · \(question.taskTitle)",
                           since: question.askedAt)
            HStack(alignment: .firstTextBaseline) {
                if question.kind == .approve {
                    Image(systemName: "checkmark.shield").foregroundStyle(Theme.Colors.brandBlue)
                        .help("Approval")
                }
                Text(question.prompt).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                Spacer(minLength: 4)
                if question.kind == .approve {
                    Button("Approve") { model.answerQuestion(question, answer: Store.approvedAnswer, choice: nil) }
                        .buttonStyle(QBGhostButtonStyle())
                        .help("Approve as asked (select it to read the details or edit first)")
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// A task waiting on the user: its reason, and Answered to put it back in progress.
struct InboxTaskRow: View {
    @EnvironmentObject var model: AppModel
    let item: InboxTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            InboxRowHeader(projectCode: item.projectCode, label: item.task.code, since: item.since)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.task.title).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                    if let reason = item.task.waitingReason, !reason.isEmpty {
                        Text(reason).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate).lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Button("Answered") { model.resumeWaiting(item.task) }
                    .buttonStyle(QBGhostButtonStyle())
                    .help("The wait is over: move it to In Progress")
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail column

/// The detail column of the Waiting on you page: the selected item, to act on.
struct InboxDetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let w = model.waitingOnYou
        switch model.inboxSelection {
        case .question(let id)?:
            if let q = w.questions.first(where: { $0.id == id }) {
                QuestionCard(question: q, skipTo: .some(skip(.question(id)))).id(q.id)
            } else { empty }
        case .task(let id)?:
            if let item = w.tasks.first(where: { $0.id == id }) { InboxTaskDetail(item: item).id(id) } else { empty }
        case .session(let id)?:
            if let s = w.sessions.first(where: { $0.id == id }) { InboxSessionDetail(session: s).id(id) } else { empty }
        case nil:
            empty
        }
    }

    private var empty: some View {
        ContentUnavailableViewCompat(text: model.waitingOnYou.isEmpty ? "Nothing waits on you" : "Pick an item")
    }

    /// Skip goes to the page's next item; nil (Skip disabled) when this is the only one.
    private func skip(_ item: InboxItemID) -> (() -> Void)? {
        guard let next = model.inboxItem(after: item) else { return nil }
        return { model.inboxSelection = next }
    }
}

/// A session waiting at its terminal: its status (with the folder to cd into, Dismiss, and
/// the resume command when it can be resumed), and a way to its project.
struct InboxSessionDetail: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header
                Text(session.attention?.headline ?? "Needs you at the terminal")
                    .font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                SessionStatusLine(session: session)
                CommandRow(command: session.resumeCommand, note: "If its terminal is gone: resume it in a new one")
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .qbParchment()
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let pid = session.projectId {
                CodeBadge(code: model.projectCode(for: pid))
                Button("Open project") { model.selectProject(pid) }
                    .buttonStyle(QBLinkButtonStyle())
            }
            Text(session.id).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Text("started \(fmtDateTime(session.startedAt))").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
    }
}

/// A task waiting on the user: why and since when, a note to add, and Answered to put it
/// back in progress (with the note typed, in the same write).
struct InboxTaskDetail: View {
    @EnvironmentObject var model: AppModel
    let item: InboxTask
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header
                Text(item.task.title)
                    .font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                waitingLine
                TextField("Add a note (your answer, what you did)…", text: $note, axis: .vertical)
                    .lineLimit(2...8)
                    .qbField()
                buttons
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .qbParchment()
    }

    private var header: some View {
        HStack(spacing: 6) {
            CodeBadge(code: item.projectCode)
            Button(item.task.code) { model.openTask(item.task.id) }
                .buttonStyle(QBLinkButtonStyle())
                .help("Open the task")
            Spacer()
        }
    }

    private var waitingLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "hourglass").foregroundStyle(qbStatusColor(.waiting))
                Text("Waiting on you since \(fmtDateTime(item.since)) (\(item.since, format: .relative(presentation: .named)))")
            }
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            if let reason = item.task.waitingReason, !reason.isEmpty {
                Text(reason).font(Theme.Fonts.bodySm).foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("Add Note") { addNote() }
                .buttonStyle(QBSecondaryButtonStyle(compact: true))
                .disabled(trimmed.isEmpty)
                .help("Add the note and leave the task waiting")
            Spacer()
            Button("Answered → In Progress") { model.resumeWaiting(item.task, note: note) }
                .buttonStyle(QBPrimaryButtonStyle(compact: true))
                .keyboardShortcut(.return, modifiers: .command)
                .help("The wait is over: move it to In Progress, with the note if you typed one (⌘↵)")
        }
    }

    private var trimmed: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addNote() {
        if model.addNote(item.task, text: trimmed, kind: .note) { note = "" }
    }
}
