import SwiftUI
import AppKit

// MARK: - Questions page (ask loop)

/// The Questions page's filter: open questions, or the history (answered, picked up by
/// the agent, or withdrawn).
enum QuestionShow: String, CaseIterable, Identifiable {
    case open = "Open", history = "History"
    var id: String { rawValue }
}

/// The content column of the Questions page: every open question in projects not
/// archived, longest waiting first (on a project's Questions tab, that project's only),
/// or the history, newest first. Selecting one opens its card in the detail pane.
struct QuestionListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.shownQuestions.isEmpty {
                ContentUnavailableViewCompat(text: emptyText)
            } else {
                List(selection: $model.selectedQuestionId) {
                    ForEach(model.shownQuestions) { q in
                        QuestionRow(question: q).tag(q.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.questionsShow == .open { resumeCommands }
        }
        .navigationTitle(model.selectedProject?.name ?? "Questions")
        .qbParchment()
    }
}

extension QuestionListView {
    private var filterBar: some View {
        Picker("Show", selection: $model.questionsShow) {
            ForEach(QuestionShow.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 240)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) { Divider() }
        .help("Open questions, or the ones already answered or withdrawn")
    }

    private var emptyText: String {
        switch (model.questionsShow, model.selectedProject == nil) {
        case (.open, true): return "No questions waiting.\nWhen an agent needs you to decide, it asks here."
        case (.open, false): return "No questions waiting in this project."
        case (.history, true): return "No answered questions yet."
        case (.history, false): return "No answered questions in this project yet."
        }
    }

    /// For a session that stopped waiting (wait_for_answers returns after its time, or
    /// the user stopped it): what to paste there so it picks the answers up.
    var resumeCommands: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No fixedSize: the split view measures this column at tiny widths, and a text
            // fixed to its full height there would stretch the whole window's content.
            Text("An agent waiting on your answers carries on by itself. If its session stopped waiting, paste one of these there:")
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                .lineLimit(3)
            CommandRow(command: AgentCommand.resume, note: "pick up answers now")
            CommandRow(command: AgentCommand.resumeLoop, note: "check again every 20 minutes")
        }
        .padding(10)
        .background(alignment: .top) { Divider() }
    }
}

/// A question in the list: project and task code, how long it has waited, the question.
struct QuestionRow: View {
    let question: Question

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                CodeBadge(code: question.taskCode)
                Text(question.taskTitle).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).lineLimit(1)
                Spacer()
                Text(question.askedAt, format: .relative(presentation: .named))
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            Text(question.prompt).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(2)
            if question.status != .open {
                Label(question.historyLine, systemImage: question.status == .cancelled ? "xmark.circle" : "checkmark.circle")
                    .font(Theme.Fonts.micro)
                    .foregroundStyle(question.status == .cancelled ? Theme.Colors.steel : Theme.Colors.mossDark)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

extension Question {
    /// The chosen option's label and the typed answer, as one line ("" when neither).
    var answerText: String {
        let picked = answerChoice.flatMap { options.indices.contains($0) ? options[$0].label : nil }
        let typed = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [picked, typed.isEmpty || typed == picked ? nil : typed].compactMap { $0 }.joined(separator: " — ")
    }

    /// A closed question's outcome in the history list.
    var historyLine: String {
        switch status {
        case .cancelled: return "Withdrawn" + (cancelReason.map { ": \($0)" } ?? "")
        default: return answerText.isEmpty ? "Answered" : answerText
        }
    }
}

/// The detail column of the Questions page: the selected question's card.
struct QuestionDetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let id = model.selectedQuestionId, let q = model.shownQuestions.first(where: { $0.id == id }) {
            // A fresh card per question, so a draft answer never carries over.
            if q.status == .open {
                QuestionCard(question: q).id(q.id)
            } else {
                AnsweredQuestionCard(question: q).id(q.id)
            }
        } else {
            ContentUnavailableViewCompat(text: model.shownQuestions.isEmpty
                ? "Nothing to answer" : "Pick a question to answer")
        }
    }
}

/// Answer one question. choice: pick an option (1–4 on the keyboard) and/or type an
/// answer; text: type it (options, if any, are suggestions); approve: approve the draft
/// in the context, or edit it and send the edit. ⌘↵ sends and moves to the next question.
struct QuestionCard: View {
    @EnvironmentObject var model: AppModel
    let question: Question
    /// Where Skip goes instead of the next question (the Waiting on you page: its next
    /// item); nil there disables Skip.
    var skipTo: (() -> Void)?? = nil
    @State private var choice: Int?
    @State private var typed = ""
    @State private var editingDraft = false
    @State private var draft = ""
    @State private var contextShown = false
    @State private var keyMonitor: Any?
    @State private var cardWindow: NSWindow?
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header
                if let session = model.agentSession(for: question) {
                    SessionStatusLine(session: session)
                }
                Text(question.prompt)
                    .font(Theme.Fonts.heading5)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !question.context.isEmpty && question.kind != .approve {
                    DisclosureGroup("Context", isExpanded: $contextShown) {
                        markdown(question.context).padding(.top, 4)
                    }
                    .font(Theme.Fonts.bodySmMedium)
                }
                switch question.kind {
                case .approve: approveBody
                case .choice, .text, .disagree: answerBody
                }
                footer
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 640, alignment: .leading)
            // Fill the column, so the parchment does too (not just under the card).
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .qbParchment()
        .background(WindowReader(window: $cardWindow))
        // 1–4 pick an option. A local monitor, not keyboardShortcut: the question list
        // keeps the focus and swallows plain keys before a shortcut sees them.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                pickOption(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    /// Key codes of the 1–9 keys, top row and keypad: the physical key, so it works in
    /// any keyboard layout (in Thai, the top row types Thai characters, not digits).
    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                                                   83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]

    /// A plain digit in the card's window picks (or unpicks) that option — unless text is
    /// being typed, where the digit belongs to the text (other windows keep their keys). Returns whether the key was used.
    private func pickOption(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let window = event.window, window === cardWindow, !(window.firstResponder is NSText),
              let n = Self.digitKeys[event.keyCode], n <= question.options.count
        else { return false }
        choice = choice == n - 1 ? nil : n - 1
        return true
    }

    private var header: some View {
        HStack(spacing: 6) {
            CodeBadge(code: question.projectCode)
            Button(question.taskCode) { openTask() }
                .buttonStyle(QBLinkButtonStyle())
                .help("Open the task")
            Text(question.taskTitle).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate).lineLimit(1)
            Spacer()
            if let s = question.sessionId {
                Text(s).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).help("Agent session")
            }
            Text("asked \(fmtDateTime(question.askedAt))").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
    }

    @ViewBuilder
    private var answerBody: some View {
        if !question.options.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, o in
                    optionButton(i, o)
                }
            }
        }
        TextField(question.kind == .text ? "Type your answer…" : "Or type your own answer…",
                  text: $typed, axis: .vertical)
            .lineLimit(1...8)
            .qbField()
            .focused($typing)
    }

    /// An option: number, label, its note; the recommended one is green. Pressing its
    /// number picks it too (`pickOption`).
    private func optionButton(_ i: Int, _ o: QuestionOption) -> some View {
        let picked = choice == i
        let accent = o.recommended ? Theme.Colors.mossDark : Theme.Colors.ink
        return Button { choice = picked ? nil : i } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(i + 1)").font(Theme.Fonts.captionBold).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(o.label).font(Theme.Fonts.bodySmMedium)
                        if o.recommended {
                            Text("recommended").font(Theme.Fonts.micro)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.Colors.tealLight, in: Capsule())
                                .fixedSize()
                        }
                    }
                    if !o.note.isEmpty {
                        Text(o.note).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if picked { Image(systemName: "checkmark.circle.fill") }
            }
            .foregroundStyle(accent)
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Theme.Colors.surfacePricingFeatured : Theme.Colors.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(picked ? Theme.Colors.brandYellow : (o.recommended ? Theme.Colors.brandTeal : Theme.Colors.hairline),
                        lineWidth: picked ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var approveBody: some View {
        if editingDraft {
            TextField("", text: $draft, axis: .vertical)
                .lineLimit(3...16)
                .qbField()
                .focused($typing)
        } else if !question.context.isEmpty {
            approveContext
                .padding(Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    private var footer: some View {
        HStack {
            Button("Skip for now") { skip() }
                .buttonStyle(QBSecondaryButtonStyle(compact: true))
                .fixedSize()
                .disabled(skipTo.map { $0 == nil } ?? (model.questionAfter(question.id) == nil))
                .help("Leave it open and go to the next question")
            Spacer()
            if question.kind == .approve {
                if editingDraft {
                    Button("Cancel edit") { editingDraft = false }
                        .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    Button("Send edit") { send(answer: draft, choice: nil) }
                        .buttonStyle(QBPrimaryButtonStyle(compact: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Edit…") { draft = question.context; editingDraft = true; typing = true }
                        .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    Button("Approve") { send(answer: Store.approvedAnswer, choice: nil) }
                        .buttonStyle(QBPrimaryButtonStyle(compact: true))
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                Button("Send") { send(answer: typed, choice: choice) }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(choice == nil && typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (⌘↵) and go to the next question")
            }
        }
    }

    /// A gate question's context is a tool call: shown as typed (markdown would eat `*`, `_`
    /// and backslashes), so the user approves exactly what they read.
    @ViewBuilder private var approveContext: some View {
        if model.isGateQuestion(question.id) {
            Text(verbatim: question.context)
                .font(Theme.Fonts.bodySm.monospaced())
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            markdown(question.context)
        }
    }

    private func markdown(_ s: String) -> some View {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(s))
            .font(Theme.Fonts.bodySm)
            .foregroundStyle(Theme.Colors.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func send(answer: String, choice: Int?) {
        model.answerQuestion(question, answer: answer, choice: choice)
    }

    private func skip() {
        if let skipTo { skipTo?(); return }
        if let next = model.questionAfter(question.id) { model.selectedQuestionId = next }
    }

    /// Show the question's task in its project.
    private func openTask() {
        guard let pid = model.task(byId: question.taskId)?.projectId else { return }
        model.selectProject(pid)
        model.selectedTaskIds = [question.taskId]
    }
}

/// Reports the window a view is in (nil until it is in one), for code that must tell
/// that window's events from others'.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView { Reader(window: $window) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        @Binding var target: NSWindow?
        init(window: Binding<NSWindow?>) {
            _target = window
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            // Not during the view update that moved it: set the state on the next turn.
            DispatchQueue.main.async { [weak self] in self?.target = w }
        }
    }
}

/// A question from the history, read only: what was asked, the context, and the answer
/// (or why it was withdrawn), with the task one click away.
struct AnsweredQuestionCard: View {
    @EnvironmentObject var model: AppModel
    let question: Question

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: 6) {
                    CodeBadge(code: question.projectCode)
                    Button(question.taskCode) { openTask() }
                        .buttonStyle(QBLinkButtonStyle())
                        .help("Open the task")
                    Text(question.taskTitle).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate).lineLimit(1)
                    Spacer()
                    Text("asked \(fmtDateTime(question.askedAt))").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
                Text(question.prompt)
                    .font(Theme.Fonts.heading5)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !question.context.isEmpty {
                    DisclosureGroup("Context") {
                        Text(question.context)
                            .font(Theme.Fonts.bodySm).foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .font(Theme.Fonts.bodySmMedium)
                }
                outcome
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .qbParchment()
    }

    @ViewBuilder private var outcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            if question.status == .cancelled {
                Text("WITHDRAWN").font(Theme.Fonts.microUppercase).foregroundStyle(Theme.Colors.steel)
                Text(question.cancelReason ?? "The agent withdrew the question.")
                    .font(Theme.Fonts.bodySm).foregroundStyle(Theme.Colors.ink)
            } else {
                Text("YOUR ANSWER").font(Theme.Fonts.microUppercase).foregroundStyle(Theme.Colors.steel)
                Text(question.answerText.isEmpty ? "—" : question.answerText)
                    .font(Theme.Fonts.bodyMdMedium).foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Spacing.md) {
                    if let at = question.answeredAt { Text("answered \(fmtDateTime(at))") }
                    if let at = question.resumedAt { Text("agent picked it up \(fmtDateTime(at))") }
                }
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .qbCard(padding: Theme.Spacing.md)
    }

    /// Show the question's task in its project.
    private func openTask() {
        guard let pid = model.task(byId: question.taskId)?.projectId else { return }
        model.selectProject(pid)
        model.selectedTaskIds = [question.taskId]
    }
}
