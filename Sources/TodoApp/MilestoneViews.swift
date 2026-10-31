import SwiftUI

// MARK: - Milestones (1.5.0)

/// A milestone's name, target date and done/total, over a thin progress bar. Dropped tasks
/// count in neither. All done does not mean finished: a milestone closes only when the
/// user closes it (its acceptance is met).
struct MilestoneProgressLabel: View {
    let milestone: Milestone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: milestone.isClosed ? "flag.checkered" : "flag")
                    .font(.caption2).foregroundStyle(Theme.Colors.steel)
                Text(milestone.name).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(1)
                if milestone.isClosed { closedBadge }
                Spacer(minLength: 4)
                if let d = milestone.targetDate {
                    Text(fmtShortDate(d)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
                Text("\(milestone.done)/\(milestone.total)")
                    .font(Theme.Fonts.micro.monospacedDigit())
                    .foregroundStyle(allDone ? Theme.Colors.successAccent : Theme.Colors.steel)
            }
            ProjectProgressBar(done: milestone.done, total: milestone.total)
        }
        .help(helpText)
    }

    private var allDone: Bool { milestone.total > 0 && milestone.done == milestone.total }

    private var closedBadge: some View {
        Text("Closed")
            .font(Theme.Fonts.micro)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.Colors.surface, in: Capsule())
            .foregroundStyle(Theme.Colors.steel)
    }

    private var helpText: String {
        var s = "\(milestone.done) of \(milestone.total) tasks done"
        if milestone.open > 0 { s += ", \(milestone.open) open" }
        if !milestone.acceptance.isEmpty { s += "\nAcceptance: \(milestone.acceptance)" }
        return s
    }
}

/// The header of a milestone's group in the task list; `nil` is the tasks in none.
struct MilestoneSectionHeader: View {
    let milestone: Milestone?

    var body: some View {
        if let milestone {
            MilestoneProgressLabel(milestone: milestone)
                .padding(.vertical, 2)
        } else {
            Text("No milestone").font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.steel)
        }
    }
}

/// A task's milestone in a list row (not shown while the list is grouped by milestone).
struct MilestoneChip: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "flag")
            .font(Theme.Fonts.micro)
            .foregroundStyle(Theme.Colors.steel)
            .lineLimit(1)
            .help("Milestone: \(name)")
    }
}

/// The task detail's milestone menu: None or an open milestone of the task's project (its
/// own milestone stays listed once closed).
struct MilestonePicker: View {
    @EnvironmentObject var model: AppModel
    let task: TodoTask

    var body: some View {
        Picker("", selection: Binding(get: { task.milestoneId ?? 0 },
                                      set: { model.setMilestone(task, $0 == 0 ? nil : $0) })) {
            Text("None").tag(Int64(0))
            ForEach(options) { m in
                Text(m.isClosed ? "\(m.name) (closed)" : m.name).tag(m.id)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var options: [Milestone] {
        model.milestones(in: task.projectId).filter { !$0.isClosed || $0.id == task.milestoneId }
    }
}

/// The bar above a project's task list that groups it by milestone (shown once the
/// project has milestones).
struct MilestoneGroupBar: View {
    @Binding var grouped: Bool

    var body: some View {
        HStack {
            Toggle("Group by milestone", isOn: $grouped)
                .toggleStyle(.checkbox)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.slate)
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.xs)
        .qbParchment()
    }
}

/// What the milestone name sheet is for.
private enum MilestoneNaming: Identifiable {
    case new
    case rename(Milestone)

    var id: String {
        switch self {
        case .new: return "new"
        case .rename(let m): return "rename-\(m.id)"
        }
    }
}

/// The project Detail tab's milestones: each with its progress and acceptance, a menu to
/// rename, close or reopen, or delete it, and a button to add one.
struct MilestonesSection: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var naming: MilestoneNaming?
    @State private var name = ""
    @State private var closing: Milestone?
    @State private var deleting: Milestone?

    var body: some View {
        let list = model.milestones(in: project.id)
        let content = VStack(alignment: .leading, spacing: 8) {
            if list.isEmpty {
                Text("No milestones yet. Group tasks into stages, such as Phase 1 or v1.2.")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            }
            ForEach(list) { row($0) }
            if !project.isArchived {
                Button("New milestone…") { name = ""; naming = .new }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.brandBlue)
            }
        }
        return confirmations(content.sheet(item: $naming) { nameSheet($0) })
    }

    private func row(_ m: Milestone) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                MilestoneProgressLabel(milestone: m)
                if !m.acceptance.isEmpty {
                    Text("Acceptance: \(m.acceptance)")
                        .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Menu {
                Button("Rename…") { name = m.name; naming = .rename(m) }
                if m.isClosed {
                    Button("Reopen") { model.setMilestoneClosed(m, false) }
                } else {
                    Button("Close") { close(m) }
                }
                Divider()
                Button("Delete…", role: .destructive) { deleting = m }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Theme.Colors.steel)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
        }
    }

    /// Close at once when nothing is open; otherwise ask first.
    private func close(_ m: Milestone) {
        if m.open > 0 { closing = m } else { model.setMilestoneClosed(m, true) }
    }

    private func nameSheet(_ n: MilestoneNaming) -> some View {
        let isNew: Bool
        if case .new = n { isNew = true } else { isNew = false }
        return NameSheet(title: isNew ? "New Milestone" : "Rename Milestone", placeholder: "Milestone name",
                         text: $name, actionTitle: isNew ? "Create" : "Rename") {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            switch n {
            case .new: model.addMilestone(projectId: project.id, name: trimmed)
            case .rename(let m): model.renameMilestone(m, to: trimmed)
            }
        }
    }

    private func confirmations(_ content: some View) -> some View {
        content
            .alert("Close milestone?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                   presenting: closing) { m in
                Button("Cancel", role: .cancel) {}
                Button("Close anyway") { model.setMilestoneClosed(m, true, force: true) }
            } message: { m in
                Text("\(m.name) still has \(m.open) open task\(m.open == 1 ? "" : "s"). They keep the milestone.")
            }
            .alert("Delete milestone?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { m in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { model.deleteMilestone(m) }
            } message: { m in
                Text("Its tasks stay in the project, in no milestone.")
            }
    }
}
