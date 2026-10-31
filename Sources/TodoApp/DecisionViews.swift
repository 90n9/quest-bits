import SwiftUI

// MARK: - Decisions (what agents decided on their own, QUE-39)

/// The Decisions page's "show" filter.
enum DecisionShow: String, CaseIterable, Identifiable {
    case all = "All", new = "New", disagreed = "Disagreed"
    var id: String { rawValue }
}

/// The content column of the Decisions page: filters, then the decisions by day, newest
/// first. New ones (not seen yet) carry a dot; double-click (or Return) opens the task.
struct DecisionListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DecisionFilterBar()
            Divider()
            if model.decisions.isEmpty {
                ContentUnavailableViewCompat(text: emptyText)
            } else {
                list
            }
        }
        .navigationTitle("Decisions")
        .qbParchment()
    }

    private var emptyText: String {
        switch model.decisionsShow {
        case .all: return "No decisions here.\nDecisions your agents record on their own show up here."
        case .new: return "Nothing new.\nYou have seen every decision here."
        case .disagreed: return "You have not disagreed with any decision here."
        }
    }

    private var list: some View {
        List(selection: $model.decisionSelection) {
            ForEach(days, id: \.day) { section in
                Section(dayTitle(section.day)) {
                    ForEach(section.items) { DecisionRow(decision: $0).tag($0.id) }
                }
            }
        }
        .contextMenu(forSelectionType: AgentDecision.ID.self) { ids in
            if let d = decision(ids.first) {
                Button("Open \(d.taskCode)") { model.openDecisionTask(d.note.taskId, projectId: d.projectId) }
                if d.isNew { Button("Mark as Seen") { model.markDecisionsSeen([d.id]) } }
                Button("Copy Code (\(d.taskCode))") { model.copyCode(d.taskCode) }
            }
        } primaryAction: { ids in
            if let d = decision(ids.first) { model.openDecisionTask(d.note.taskId, projectId: d.projectId) }
        }
    }

    private func decision(_ id: AgentDecision.ID?) -> AgentDecision? {
        id.flatMap { id in model.decisions.first { $0.id == id } }
    }

    /// The decisions by calendar day, newest day first.
    private var days: [(day: Date, items: [AgentDecision])] {
        let cal = Calendar.current
        var out: [(day: Date, items: [AgentDecision])] = []
        for d in model.decisions {
            let day = cal.startOfDay(for: d.note.timestamp)
            if out.last?.day == day { out[out.count - 1].items.append(d) } else { out.append((day, [d])) }
        }
        return out
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }
}

/// Project, show and day filters above the list, and Mark All as Seen.
private struct DecisionFilterBar: View {
    @EnvironmentObject var model: AppModel
    @State private var date = Date()

    var body: some View {
        // Rows sized for a ~360pt list column: side by side, the project
        // name was cut to "All p…" and Mark All as Seen did not fit.
        VStack(alignment: .leading, spacing: 6) {
            projectPicker
            showPicker
            HStack(spacing: 8) {
                dayPicker
                if case .on = model.decisionsDay { datePicker }
                Spacer(minLength: 0)
                markAllButton
            }
        }
        .font(Theme.Fonts.caption)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var projectPicker: some View {
        Picker("Project", selection: $model.decisionsProjectId) {
            Text("All projects").tag(Int64?.none)
            ForEach(model.pickerProjects(selected: model.decisionsProjectId)) { p in
                Text("\(p.code) · \(p.name)").tag(Int64?.some(p.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 280, alignment: .leading)
        .help("Show one project's decisions, or every project's")
    }

    private var showPicker: some View {
        Picker("Show", selection: $model.decisionsShow) {
            ForEach(DecisionShow.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Every decision, only the ones you have not seen, or the ones you disagreed with")
    }

    private var dayPicker: some View {
        Picker("Day", selection: Binding(
            get: { model.decisionsDay.choice },
            set: { model.decisionsDay = ActivityDay.from($0, date: date) })) {
            ForEach(ActivityDay.Choice.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var datePicker: some View {
        DatePicker("Date", selection: Binding(
            get: { date },
            set: { date = $0; model.decisionsDay = .on($0) }), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .fixedSize()
    }

    private var newIds: [Int64] { model.decisions.filter(\.isNew).map(\.id) }

    private var markAllButton: some View {
        Button("Mark All as Seen") { model.markDecisionsSeen(newIds) }
            .buttonStyle(QBGhostButtonStyle())
            .fixedSize()
            .disabled(newIds.isEmpty)
            .help("Mark every new decision listed here as seen")
    }
}

/// Who recorded a decision: the agent and its session (or You, for a user's decision).
private func decisionActor(_ d: AgentDecision) -> ActivityActor {
    d.note.author == .user ? .user : .agent(sessionId: d.agentSessionId, label: d.note.sessionId)
}

/// A list row: task code, who, when, a dot when new, the decision in short, its task, and
/// whether you disagreed.
struct DecisionRow: View {
    let decision: AgentDecision

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            Text(decision.note.text)
                .font(decision.isNew ? Theme.Fonts.bodySmMedium : Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.ink).lineLimit(3)
            Text(decision.taskTitle)
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate).lineLimit(1)
            if let q = decision.disagreements.first { DisagreementState(question: q) }
        }
        .padding(.vertical, 3)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if decision.isNew {
                Circle().fill(Theme.Colors.brandBlue).frame(width: 7, height: 7).help("New: not seen yet")
            }
            CodeBadge(code: decision.taskCode)
            ActivityActorLabel(actor: decisionActor(decision))
            Spacer()
            Text(decision.note.timestamp.formatted(date: .omitted, time: .shortened))
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
    }
}

/// "You disagreed · waiting for the agent" / "· picked up by the agent".
private struct DisagreementState: View {
    let question: Question

    var body: some View {
        Label(text, systemImage: "hand.thumbsdown")
            .font(Theme.Fonts.micro)
            .foregroundStyle(question.status == .resumed ? Theme.Colors.mossDark : Theme.Colors.coralDark)
    }

    private var text: String {
        let state = question.status == .resumed ? "picked up by the agent" : "waiting for the agent"
        return "You disagreed (\(question.taskCode)) · \(state)"
    }
}

// MARK: - Detail column

/// The detail column of the Decisions page: the selected decision in full, Mark as Seen
/// and Disagree.
struct DecisionDetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let d = model.decisionSelection.flatMap({ id in model.decisions.first { $0.id == id } }) {
            DecisionDetail(decision: d).id(d.id)
        } else {
            ContentUnavailableViewCompat(text: model.decisions.isEmpty ? "No decisions" : "Pick a decision")
        }
    }
}

private struct DecisionDetail: View {
    @EnvironmentObject var model: AppModel
    let decision: AgentDecision
    @State private var disagreeing = false
    @State private var why = ""
    @FocusState private var typing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                header
                Text(decision.taskTitle)
                    .font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                meta
                Text(decision.note.text)
                    .font(Theme.Fonts.bodySm).foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                if !decision.disagreements.isEmpty { disagreements }
                if disagreeing { disagreeForm } else { actions }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .qbParchment()
    }

    private var header: some View {
        HStack(spacing: 6) {
            CodeBadge(code: decision.projectCode)
            Button("Open \(decision.taskCode)") {
                model.openDecisionTask(decision.note.taskId, projectId: decision.projectId)
            }
            .buttonStyle(QBLinkButtonStyle())
            .help("Open the task")
            Text(decision.taskStatus.rawValue.replacingOccurrences(of: "_", with: " "))
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            Spacer()
            if decision.isNew {
                Text("New").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.brandBlue)
            }
        }
    }

    private var meta: some View {
        HStack(spacing: 8) {
            ActivityActorLabel(actor: decisionActor(decision))
            Text(fmtDateTime(decision.note.timestamp)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
    }

    /// Your earlier disagreements, newest first: why, and whether the agent picked it up.
    private var disagreements: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(decision.disagreements) { q in
                VStack(alignment: .leading, spacing: 2) {
                    DisagreementState(question: q)
                    Text(q.answer ?? "")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var pending: Bool { decision.pendingDisagreement != nil }

    private var actions: some View {
        HStack {
            Button("Disagree…") { why = ""; disagreeing = true; typing = true }
                .buttonStyle(QBSecondaryButtonStyle(compact: true))
                .disabled(pending)
                .help(pending ? "The agent has not picked up your last disagreement yet"
                      : "Tell the agent why you disagree; it gets this with its answers")
            Spacer()
            if decision.isNew {
                Button("Mark as Seen") { model.markDecisionsSeen([decision.id]) }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .help("You have read it; it is no longer new")
            }
        }
    }

    private var disagreeForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Why do you disagree?").font(Theme.Fonts.captionBold)
            TextField("What should the agent do instead?", text: $why, axis: .vertical)
                .lineLimit(3...10)
                .qbField()
                .focused($typing)
            Text(decision.taskStatus.isClosed
                 ? "\(decision.taskCode) is closed: this goes to the agent on a new task."
                 : "This goes to the agent on \(decision.taskCode).")
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            HStack {
                Spacer()
                Button("Cancel") { disagreeing = false }
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Send to Agent") { if model.disagree(with: decision, why: why) { disagreeing = false } }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
