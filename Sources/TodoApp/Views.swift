import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner()
            NavigationSplitView {
                ProjectSidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } content: {
                if model.showDashboard {
                    DashboardView()
                        .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                } else if model.boardView && model.boardAvailable {
                    BoardView()
                        .navigationSplitViewColumnWidth(min: 520, ideal: 820)
                } else {
                    TaskListView()
                        .navigationSplitViewColumnWidth(min: 280, ideal: 360)
                }
            } detail: {
                if model.showDashboard {
                    ContentUnavailableViewCompat(text: "Your activity at a glance")
                } else {
                    TaskDetailView()
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            PomodoroBar()
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(text: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        // Single app-level blocked-task confirmation. Every path that moves a blocked
        // task to In Progress (list, board drag, bulk bar, Task menu) routes here.
        .alert("Task is blocked",
               isPresented: Binding(get: { model.blockedConfirm != nil },
                                    set: { if !$0 { model.blockedConfirm = nil } }),
               presenting: model.blockedConfirm) { confirm in
            Button("Cancel", role: .cancel) { confirm.onCancel?() }
            Button("Start anyway") { confirm.onConfirm() }
        } message: { confirm in
            Text(confirm.message)
        }
    }
}

/// Floating confirmation pill (e.g. "Copied GEN-3").
struct ToastView: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(Theme.Fonts.captionBold)
            .foregroundStyle(Theme.Colors.onPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.Colors.successAccent, in: Capsule())
            .shadow(color: Theme.Colors.inkDeep.opacity(0.12), radius: 12, y: 4)
    }
}

/// `promo-banner`: black strip above the content when Sparkle finds a newer
/// version. Yellow "NEW" chip (`badge-promo`), on-dark copy, white pill
/// "Update Now" (`button-on-dark`) that re-opens Sparkle's install dialog.
struct UpdateBanner: View {
    @ObservedObject private var notifier = UpdateNotifier.shared

    var body: some View {
        if let version = notifier.availableVersion {
            HStack(spacing: Theme.Spacing.sm) {
                Text("NEW")
                    .qbBadge(background: Theme.Colors.brandYellow, foreground: Theme.Colors.primary)
                Text("QuestBits \(version) is available")
                    .font(Theme.Fonts.bodySmMedium)
                    .foregroundStyle(Theme.Colors.onDark)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.xs)
                Button("Update Now") { notifier.onInstallTapped?() }
                    .buttonStyle(QBOnDarkButtonStyle(compact: true))
                Button {
                    notifier.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.onDarkMuted)
                }
                .buttonStyle(.plain)
                .help("Dismiss until the next check")
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(maxWidth: .infinity)
            .qbHearth()
        }
    }
}

// MARK: - Projects sidebar

struct ProjectSidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    @State private var editing: Project?      // non-nil → edit sheet open
    @State private var showTemplates = false
    @State private var archiving: ArchiveRequest?   // non-nil → archive confirm sheet open
    @AppStorage("qbArchivedExpanded") private var archivedExpanded = false

    /// Cozy-RPG sidebar icons (bundled Lucide set) for the smart views.
    private func qbSidebarIcon(_ v: SmartView) -> String {
        v == .allTasks ? "lucide-map" : "lucide-swords"
    }

    /// Section header in the quest-log voice (micro-uppercase, steel).
    private func sidebarHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.Fonts.microUppercase)
            .tracking(0.5)
            .foregroundStyle(Theme.Colors.steel)
    }

    /// Selected sidebar row: selection-gold card with a gold stroke (mockup
    /// `nav-item-active`). Unselected rows stay transparent.
    @ViewBuilder
    private func sidebarRowCard(_ selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surfacePricingFeatured)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.brandYellow.opacity(0.7), lineWidth: 1)
                )
        } else {
            Color.clear
        }
    }

    var body: some View {
        List(selection: Binding(
            get: { model.selectedProjectId },
            set: { model.selectProject($0) }
        )) {
            Section {
                ForEach(SmartView.allCases, id: \.self) { v in
                    Label { Text(v.title) } icon: { QBIcon(name: qbSidebarIcon(v)) }
                        .font(Theme.Fonts.bodySmMedium)
                        .foregroundStyle(model.smartView == v ? Theme.Colors.brandBlue : Theme.Colors.ink)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectSmartView(v) }
                        .listRowBackground(sidebarRowCard(model.smartView == v))
                }
                Label { Text("Dashboard") } icon: { QBIcon(name: "lucide-castle") }
                    .font(Theme.Fonts.bodySmMedium)
                    .foregroundStyle(model.showDashboard ? Theme.Colors.brandBlue : Theme.Colors.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectDashboard() }
                    .listRowBackground(sidebarRowCard(model.showDashboard))
                Label { Text("Templates") } icon: { QBIcon(name: "lucide-backpack") }
                    .font(Theme.Fonts.bodySmMedium)
                    .contentShape(Rectangle())
                    .onTapGesture { showTemplates = true }
                    .help("Manage reusable task templates")
            } header: {
                sidebarHeader("Quests")
            }
            Section {
                ForEach(model.activeProjects) { p in projectRow(p) }
            } header: {
                sidebarHeader("Quest Logs")
            }
            if !model.archivedProjects.isEmpty {
                Section(isExpanded: $archivedExpanded) {
                    ForEach(model.archivedProjects) { p in projectRow(p) }
                } header: {
                    sidebarHeader("Archived")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption2)
                    .foregroundStyle(Theme.Colors.stone)
                #if DEV_BUILD
                Text("DEV")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.orange))
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .help("New Project")
            }
        }
        .sheet(isPresented: $showNew) {
            ProjectSheet(title: "New Project") { name, detail in
                model.addProject(name: name, detail: detail)
            }
        }
        .sheet(item: $editing) { p in
            ProjectSheet(title: "Edit Project", name: p.name, detail: p.detail) { name, detail in
                model.updateProject(p.id, name: name, detail: detail)
            }
        }
        .sheet(isPresented: $showTemplates) { TemplatesSheet() }
        // The selected project just got archived (here or by an agent): open the Archived
        // group so its row, and the selection, stay visible.
        .onChange(of: selectedIsArchived) { _, archived in
            if archived { archivedExpanded = true }
        }
        .sheet(item: $archiving) { req in
            ArchiveProjectSheet(project: req.project, openCount: req.openCount) {
                model.setArchived(req.project.id, true)
            }
        }
        .onChange(of: model.pendingNewProject) { _, pending in
            if pending { showNew = true; model.pendingNewProject = false }
        }
    }

    /// True while the selected sidebar item is an archived project.
    private var selectedIsArchived: Bool {
        guard model.smartView == nil, !model.showDashboard, let sel = model.selectedProjectId else { return false }
        return model.archivedProjects.contains { $0.id == sel }
    }

    /// A project row (active or archived — archived rows are dimmed) with its context menu.
    private func projectRow(_ p: Project) -> some View {
        HStack(spacing: 6) {
            QBIcon(name: "lucide-door-open")
            Text(p.name).font(Theme.Fonts.bodySmMedium)
            Spacer()
            CodeBadge(code: p.code)
            Text("\(taskCount(p.id))")
                .font(Theme.Fonts.micro)
                .foregroundStyle(Theme.Colors.slate)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Theme.Colors.surface, in: Capsule())
        }
        .opacity(p.isArchived ? 0.6 : 1)
        .tag(p.id)
        .listRowBackground(sidebarRowCard(
            model.smartView == nil && !model.showDashboard && model.selectedProjectId == p.id))
        .help(p.detail.isEmpty ? p.name : p.detail)
        .contextMenu {
            Button("Copy Code (\(p.code))") { model.copyCode(p.code) }
            Button("Edit…") { editing = p }
            if model.templates.isEmpty {
                Button("New Task from Template…") { showTemplates = true }
            } else {
                Menu("New Task from Template") {
                    ForEach(model.templates) { t in
                        Button(t.name) { model.newTaskFromTemplate(t.id, intoProject: p.id) }
                    }
                    Divider()
                    Button("Manage Templates…") { showTemplates = true }
                }
            }
            Divider()
            if p.isArchived {
                Button("Unarchive") { model.setArchived(p.id, false) }
            } else {
                Button("Archive") { requestArchive(p) }
            }
            Button("Delete", role: .destructive) { model.deleteProject(p.id) }
        }
    }

    /// Archive straight away when nothing is open; otherwise confirm with the open count.
    private func requestArchive(_ p: Project) {
        let open = model.openTaskCount(p.id)
        if open == 0 {
            model.setArchived(p.id, true)
        } else {
            archiving = ArchiveRequest(project: p, openCount: open)
        }
    }

    private func taskCount(_ pid: Int64) -> Int {
        (try? model.store.listTasks(projectId: pid).count) ?? 0
    }
}

/// A pending archive of a project that still has open tasks (drives the confirm sheet).
private struct ArchiveRequest: Identifiable {
    let project: Project
    let openCount: Int
    var id: Int64 { project.id }
}

/// Confirms archiving a project that still has open tasks. The tasks are kept as they
/// are; the project moves to the sidebar's Archived group.
struct ArchiveProjectSheet: View {
    let project: Project
    let openCount: Int
    let onArchive: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Archive \(project.name)?").font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            Text("\(openCount) open task\(openCount == 1 ? "" : "s") will stay open. "
                 + "Archived projects leave All Tasks, In Progress and the menu bar, "
                 + "but you can still open them from the Archived group.")
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.slate)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                Button("Archive") {
                    onArchive()
                    dismiss()
                }
                .buttonStyle(QBPrimaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 380)
        .qbParchment()
    }
}

/// Create/edit sheet for a project: name + description.
struct ProjectSheet: View {
    let title: String
    @State var name: String = ""
    @State var detail: String = ""
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Description").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            TextEditor(text: $detail)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.hairlineStrong))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                Button("Save") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { onSave(n, detail) }
                    dismiss()
                }
                .buttonStyle(QBPrimaryButtonStyle(compact: true))
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 380)
        .qbParchment()
    }
}

/// Manage reusable task templates: browse existing ones, delete, and add new.
/// New tasks are spawned from a template via a project's context menu (or MCP).
struct TemplatesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var title = ""
    @State private var detail = ""
    @State private var priority: Priority = .none
    @State private var tagsText = ""
    @State private var estimateMinutes = 0

    private var parsedTags: [String] {
        tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Task Templates").font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
            }
            .padding(Theme.Spacing.md)
            Divider()
            Form {
                Section("Templates") {
                    if model.templates.isEmpty {
                        Text("No templates yet. Add one below.")
                            .foregroundStyle(Theme.Colors.slate).font(Theme.Fonts.caption)
                    } else {
                        ForEach(model.templates) { t in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if t.priority != .none {
                                        Image(systemName: "flag.fill").font(.caption2)
                                            .foregroundStyle(qbPriorityColor(t.priority))
                                    }
                                    Text(t.name).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink)
                                    Spacer()
                                    Button(role: .destructive) { model.deleteTemplate(t.id) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless).foregroundStyle(Theme.Colors.steel)
                                    .help("Delete template")
                                }
                                Text(t.title).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                                HStack(spacing: 6) {
                                    if t.estimateSeconds > 0 {
                                        Label(fmtEffort(t.estimateSeconds), systemImage: "target")
                                            .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                                    }
                                    ForEach(t.tags.prefix(4), id: \.self) { TagChip(text: $0) }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                Section("New Template") {
                    TextField("Template name (e.g. Bug report)", text: $name)
                    TextField("Task title", text: $title)
                    Picker("Priority", selection: $priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.display).tag($0) }
                    }
                    TextField("comma, separated, tags", text: $tagsText)
                    Stepper(value: $estimateMinutes, in: 0...6000, step: 5) {
                        Text(estimateMinutes == 0 ? "No estimate" : "Estimate: \(fmtMinutes(Double(estimateMinutes)))")
                    }
                    TextEditor(text: $detail)
                        .frame(height: 60)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.hairlineStrong))
                    Button("Add Template") { addTemplate() }
                        .buttonStyle(QBSecondaryButtonStyle(compact: true))
                        .disabled(!canAdd)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 460, height: 580)
    }

    private func addTemplate() {
        guard canAdd else { return }
        model.addTemplate(
            name: name.trimmingCharacters(in: .whitespaces),
            title: title.trimmingCharacters(in: .whitespaces),
            detail: detail,
            priority: priority,
            tags: parsedTags,
            estimateSeconds: estimateMinutes * 60
        )
        name = ""; title = ""; detail = ""; priority = .none; tagsText = ""; estimateMinutes = 0
    }
}

// MARK: - Shared token mappings

/// Priority accent, from the DESIGN.md tag-chip text colors (coral-dark / yellow-dark / brand-blue).
func qbPriorityColor(_ p: Priority) -> Color {
    switch p {
    case .high: return Theme.Colors.coralDark
    case .medium: return Theme.Colors.yellowDark
    case .low: return Theme.Colors.brandBlue
    case .none: return Theme.Colors.stone
    }
}

/// Priority chip pair, per `badge-tag-coral` / `badge-tag-yellow` / `badge-tag-purple`.
func qbPriorityChipColors(_ p: Priority) -> (bg: Color, fg: Color) {
    switch p {
    case .high: return (Theme.Colors.coralLight, Theme.Colors.coralDark)
    case .medium: return (Theme.Colors.surfaceYellow, Theme.Colors.yellowDark)
    case .low: return (Theme.Colors.surfacePricingFeatured, Theme.Colors.brandBlue)
    case .none: return (Theme.Colors.surface, Theme.Colors.steel)
    }
}

/// Task-status accent: stone (todo), yellow-deep (in progress), clay (waiting),
/// success-accent (done), muted (dropped).
func qbStatusColor(_ s: TaskStatus) -> Color {
    switch s {
    case .todo: return Theme.Colors.stone
    case .inProgress: return Theme.Colors.brandYellowDeep
    case .waiting: return Theme.Colors.brandCoral
    case .done: return Theme.Colors.successAccent
    case .dropped: return Theme.Colors.muted
    }
}

/// Status glyph, shared by list rows and board column headers.
func qbStatusIcon(_ s: TaskStatus) -> String {
    switch s {
    case .todo: return "circle"
    case .inProgress: return "circle.lefthalf.filled"
    case .waiting: return "pause.circle"
    case .done: return "checkmark.circle.fill"
    case .dropped: return "xmark.circle"
    }
}

/// Title color for a task row/card: closed tasks fade (done to stone, dropped further,
/// to muted); callers also strike through any closed title.
func qbTitleColor(_ s: TaskStatus) -> Color {
    switch s {
    case .todo, .inProgress, .waiting: return Theme.Colors.ink
    case .done: return Theme.Colors.stone
    case .dropped: return Theme.Colors.muted
    }
}

/// Who a waiting task waits on, as the app's own user reads it ("Waiting on Me").
func qbWaitingOnLabel(_ w: WaitingOn) -> String {
    switch w {
    case .user: return "Me"
    case .external: return "External"
    }
}

// MARK: - Task list

struct TaskListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    // Collapsed-done preference persists across launches.
    @AppStorage("qbShowDoneTasks") private var showDone = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if model.selectedProjectId == nil && model.smartView == nil {
                ContentUnavailableViewCompat(text: "Select a view or project")
            } else {
                VStack(spacing: 0) {
                    SearchBar(query: $model.searchQuery)
                    Divider()
                    taskContent
                }
            }
        }
        .navigationTitle(projectName)
        .toolbar {
            ToolbarItem(placement: .principal) { ViewModeToggle() }
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(QBPrimaryButtonStyle(compact: true))
                .help("New Task (⌘N)")
                .disabled(model.selectedProjectId == nil)
            }
        }
        .sheet(isPresented: $showNew) {
            NameSheet(title: "New Task", placeholder: "Task title", text: $newTitle) {
                let title = newTitle.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { model.addTask(title: title) }
                newTitle = ""
            }
        }
        .onChange(of: model.pendingNewTask) { _, pending in
            if pending {
                if model.selectedProjectId != nil { showNew = true }
                model.pendingNewTask = false
            }
        }
    }

    @ViewBuilder private var taskContent: some View {
        if model.tasks.isEmpty {
            VStack(spacing: Theme.Spacing.md) {
                Text(model.smartView != nil ? "No tasks here" : "No tasks in this project")
                    .font(Theme.Fonts.subtitle)
                    .foregroundStyle(Theme.Colors.slate)
                if model.smartView == nil {
                    Button { showNew = true } label: {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(QBPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .qbParchment()
        } else if displayedTasks.isEmpty {
            ContentUnavailableViewCompat(
                text: "No tasks match \u{201C}\(model.searchQuery.trimmingCharacters(in: .whitespaces))\u{201D}")
        } else {
            VStack(spacing: 0) {
                if model.selectedTaskIds.count >= 2 {
                    BulkActionBar(otherProjects: otherProjects)
                    Divider()
                }
                List(selection: $model.selectedTaskIds) {
                    ForEach(activeTasks) { task in
                        taskRowCell(task)
                    }
                    .onMove { offsets, dest in
                        // Reordering rewrites a dense sort_order for exactly the ids passed in.
                        // That is only correct within a single project's full, unfiltered list.
                        // While searching, activeTasks is a filtered subset, so a drag would
                        // clobber the ordering of hidden tasks. In a smart view the rows span
                        // multiple projects, so a global reorder scrambles each project's
                        // per-project ordering. Disable reordering in both cases.
                        guard model.smartView == nil, !isSearching else { return }
                        model.moveTasks(activeTasks, from: offsets, to: dest)
                    }
                    // Closed (done and dropped) quests collapse into a toggle section at the bottom.
                    if !doneTasks.isEmpty {
                        doneToggleRow
                        if showDone {
                            ForEach(doneTasks) { task in
                                taskRowCell(task)
                            }
                        }
                    }
                }
                // List draws its own system background; hide it so the parchment
                // canvas shows through (matches sidebar/detail panes).
                .scrollContentBackground(.hidden)
                .qbParchment()
            }
        }
    }

    private var projectName: String {
        if let sv = model.smartView { return sv.title }
        return model.projects.first(where: { $0.id == model.selectedProjectId })?.name ?? "Tasks"
    }

    /// Active projects other than the one currently selected (move/copy targets;
    /// archived projects are left out).
    private var otherProjects: [Project] {
        model.activeProjects.filter { $0.id != model.selectedProjectId }
    }

    private var isSearching: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Rows shown as top-level List items. In a project view, only top-level tasks
    /// (subtasks render nested under their parent); in a smart view, the flat list.
    /// When searching, keep a top-level task if it matches or any of its subtasks match.
    private var displayedTasks: [TodoTask] {
        let base = model.smartView == nil ? model.tasks.filter { $0.parentId == nil } : model.tasks
        if !isSearching {
            return base
        } else if model.smartView == nil {
            return base.filter { task in
                model.taskMatchesSearch(task)
                    || model.tasks.contains { $0.parentId == task.id && model.taskMatchesSearch($0) }
            }
        } else {
            return base.filter { model.taskMatchesSearch($0) }
        }
    }

    /// Closed tasks (done and dropped) live in a collapsed section at the bottom (see
    /// `doneToggleRow`); active tasks keep their manual sort order.
    private var activeTasks: [TodoTask] { displayedTasks.filter { !$0.status.isClosed } }
    private var doneTasks: [TodoTask] { displayedTasks.filter { $0.status.isClosed } }

    /// One task row with selection background and context menu — shared by the
    /// active list and the collapsed done section.
    @ViewBuilder
    private func taskRowCell(_ task: TodoTask) -> some View {
        TaskRow(task: task,
                subtasks: subtasks(of: task),
                showSubtaskUI: model.smartView == nil)
            .tag(task.id)
            // Replace the system accent selection fill — fixed ink/steel row
            // text is unreadable on it. Selection-gold matches the sidebar.
            .listRowBackground(model.selectedTaskIds.contains(task.id)
                ? Theme.Colors.surfacePricingFeatured : Color.clear)
            .contextMenu {
                Button("Copy Code (\(task.code))") { model.copyCode(task.code) }
                Button("Duplicate") { model.duplicateTask(task.id) }

                if !otherProjects.isEmpty {
                    Menu("Move to") {
                        ForEach(otherProjects) { p in
                            Button(p.name) { model.moveTask(task.id, toProject: p.id) }
                        }
                    }
                    Menu("Copy to") {
                        ForEach(otherProjects) { p in
                            Button(p.name) { model.copyTask(task.id, toProject: p.id) }
                        }
                    }
                }

                Divider()
                Button("Delete", role: .destructive) { model.deleteTask(task.id) }
            }
    }

    /// "Done (N)" collapse header — click to show/hide finished (done and dropped) quests.
    private var doneToggleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: showDone ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Colors.steel)
            Text("Done")
                .font(Theme.Fonts.bodySmMedium)
                .foregroundStyle(Theme.Colors.steel)
            Text("\(doneTasks.count)")
                .font(Theme.Fonts.micro)
                .foregroundStyle(Theme.Colors.slate)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Theme.Colors.surface, in: Capsule())
            Spacer()
        }
        .padding(.top, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { showDone.toggle() } }
        .listRowBackground(Color.clear)
        .help(showDone ? "Hide finished quests" : "Show finished quests")
    }

    /// Subtasks of a task, taken from the already-loaded flat list (project view only).
    /// While searching, show all subtasks when the parent matches, otherwise only the
    /// subtasks that match the query.
    private func subtasks(of task: TodoTask) -> [TodoTask] {
        guard model.smartView == nil else { return [] }
        let subs = model.tasks.filter { $0.parentId == task.id }
        guard isSearching, !model.taskMatchesSearch(task) else { return subs }
        return subs.filter { model.taskMatchesSearch($0) }
    }
}

/// Live-filter search field for the task list header, with a clear button.
struct SearchBar: View {
    @Binding var query: String

    var body: some View {
        // `search-pill`: surface background, steel text, body-sm, 8px corners, hairline border.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.steel)
            TextField("Search tasks", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.bodySm)
                // Spec's steel is the rest/placeholder tone; entered text stays ink for legibility.
                .foregroundStyle(Theme.Colors.ink)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.steel)
                .help("Clear search")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: 40)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.hairline, lineWidth: 1))
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .qbParchment()
    }
}

/// Action bar shown above the task list when 2+ tasks are selected.
struct BulkActionBar: View {
    @EnvironmentObject var model: AppModel
    let otherProjects: [Project]
    @State private var showTagSheet = false
    @State private var tagText = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("\(model.selectedTaskIds.count) selected")
                .font(Theme.Fonts.bodySmMedium)
                .foregroundStyle(Theme.Colors.ink)

            Spacer()

            Menu {
                ForEach(TaskStatus.allCases, id: \.self) { s in
                    if s == .waiting {
                        ForEach(WaitingOn.allCases, id: \.self) { on in
                            Button("Waiting on \(qbWaitingOnLabel(on))") { model.bulkSetStatus(s, waitingOn: on) }
                        }
                    } else {
                        Button(s.display) { model.bulkSetStatus(s) }
                    }
                }
            } label: { FilterPillLabel(text: "Status") }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            Menu {
                ForEach(Priority.allCases, id: \.self) { p in
                    Button(p.display) { model.bulkSetPriority(p) }
                }
            } label: { FilterPillLabel(text: "Priority") }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            if !otherProjects.isEmpty {
                Menu {
                    ForEach(otherProjects) { p in Button(p.name) { model.bulkMove(toProject: p.id) } }
                } label: { FilterPillLabel(text: "Move") }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                Menu {
                    ForEach(otherProjects) { p in Button(p.name) { model.bulkCopy(toProject: p.id) } }
                } label: { FilterPillLabel(text: "Copy") }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }
            Button("Add Tags") { showTagSheet = true }
                .buttonStyle(QBGhostButtonStyle())
            Button(role: .destructive) { model.bulkDelete() } label: {
                Image(systemName: "trash").foregroundStyle(Theme.Colors.coralDark)
            }
                .buttonStyle(QBGhostButtonStyle())
                .help("Delete selected")
            Button("Clear") { model.selectedTaskIds = [] }
                .buttonStyle(QBGhostButtonStyle())
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.surface)
        .sheet(isPresented: $showTagSheet) {
            NameSheet(title: "Add tags to \(model.selectedTaskIds.count) tasks",
                      placeholder: "comma, separated, tags", text: $tagText) {
                let tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                model.bulkAddTags(tags)
                tagText = ""
            }
        }
    }
}

/// `filter-dropdown` chrome for Menu labels: pill, canvas background, hairline-strong border.
struct FilterPillLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .font(Theme.Fonts.bodySmMedium)
        .foregroundStyle(Theme.Colors.ink)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Colors.canvas, in: Capsule())
        .overlay(Capsule().stroke(Theme.Colors.hairlineStrong, lineWidth: 1))
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: TodoTask
    var subtasks: [TodoTask] = []
    var showSubtaskUI: Bool = false

    @State private var addingSubtask = false
    @State private var newSubtaskTitle = ""

    private var doneCount: Int { subtasks.filter { $0.status == .done }.count }
    /// Subtasks still part of the work: dropped ones leave the n/total count.
    private var countedSubtasks: Int { subtasks.filter { $0.status != .dropped }.count }
    private var isBlocked: Bool { model.blockedTaskIds.contains(task.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button(action: {
                    // Cycling status routes through the shared blocked guard in the model,
                    // which surfaces the confirmation for a blocked todo → In Progress move.
                    model.cycleStatus(task)
                }) {
                    Image(systemName: qbStatusIcon(task.status))
                        .foregroundStyle(qbStatusColor(task.status))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Click to cycle status")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if task.priority != .none {
                            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(qbPriorityColor(task.priority))
                        }
                        CodeBadge(code: task.code)
                        Text(task.title)
                            .font(Theme.Fonts.bodySm)
                            .strikethrough(task.status.isClosed)
                            .foregroundStyle(qbTitleColor(task.status))
                        if countedSubtasks > 0 {
                            Text("\(doneCount)/\(countedSubtasks)")
                                .font(Theme.Fonts.micro.monospacedDigit())
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.Colors.surface, in: Capsule())
                                .foregroundStyle(doneCount == countedSubtasks ? Theme.Colors.successAccent : Theme.Colors.steel)
                                .help("\(doneCount) of \(countedSubtasks) subtasks done")
                        }
                        if isBlocked {
                            Text("🔒 blocked")
                                .font(Theme.Fonts.micro)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Theme.Colors.brandRed, in: Capsule())
                                .foregroundStyle(Theme.Colors.coralDark)
                                .help("Blocked by an unfinished dependency")
                        }
                        WaitingChip(task: task)
                    }
                    HStack(spacing: 8) {
                        if task.status == .waiting, let reason = task.waitingReason, !reason.isEmpty {
                            Text(reason)
                                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.coralDark)
                                .lineLimit(1)
                        }
                        if task.link != nil && !(task.link?.isEmpty ?? true) {
                            Image(systemName: "link").font(.caption2).foregroundStyle(Theme.Colors.steel)
                        }
                        if task.effortSeconds > 0 {
                            Label(fmtEffort(task.effortSeconds), systemImage: "hourglass")
                                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                        }
                        if task.estimateSeconds > 0 {
                            EstimateBadge(estimateSeconds: task.estimateSeconds, actualSeconds: task.effortSeconds)
                        }
                        if let due = task.dueDate {
                            Label(dueText(due), systemImage: "calendar")
                                .font(Theme.Fonts.micro)
                                .foregroundStyle(isOverdue(due, task) ? Theme.Colors.coralDark : Theme.Colors.steel)
                        }
                        if let rec = task.recurrence, !rec.isEmpty {
                            Text("↻ \(rec)").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                        }
                        ForEach(task.tags.prefix(3), id: \.self) { TagChip(text: $0) }
                    }
                }
                Spacer()
                Text(task.status.display).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.stone)
            }

            // Subtasks (one level of nesting), shown only for top-level tasks in a project view.
            if showSubtaskUI && task.parentId == nil {
                ForEach(subtasks) { sub in
                    SubtaskRow(sub: sub)
                }
                if addingSubtask {
                    HStack(spacing: 8) {
                        Image(systemName: "square").foregroundStyle(Theme.Colors.steel)
                        TextField("Subtask title", text: $newSubtaskTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.Fonts.bodySm)
                            .onSubmit { commitSubtask() }
                        Button("Add") { commitSubtask() }
                            .buttonStyle(QBPrimaryButtonStyle(compact: true))
                            .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { addingSubtask = false; newSubtaskTitle = "" }
                            .buttonStyle(QBGhostButtonStyle())
                    }
                    .padding(.leading, 26)
                } else {
                    Button {
                        addingSubtask = true
                    } label: {
                        Label("subtask", systemImage: "plus")
                    }
                    .buttonStyle(QBLinkButtonStyle())
                    .padding(.leading, 26)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func commitSubtask() {
        let t = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { model.addSubtask(title: t, parent: task) }
        newSubtaskTitle = ""
        addingSubtask = false
    }


    private func dueText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    private func isOverdue(_ d: Date, _ t: TodoTask) -> Bool {
        !t.status.isClosed && Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: Date())
    }
}

/// A single subtask line: checkbox + title, indented under its parent.
struct SubtaskRow: View {
    @EnvironmentObject var model: AppModel
    let sub: TodoTask

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { model.toggleSubtaskDone(sub) }) {
                Image(systemName: subtaskBox)
                    .foregroundStyle(sub.status.isClosed ? qbStatusColor(sub.status) : Theme.Colors.steel)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Toggle done")

            Text(sub.title)
                .font(Theme.Fonts.bodySm)
                .strikethrough(sub.status.isClosed)
                .foregroundStyle(qbTitleColor(sub.status))
            Spacer()
        }
        .padding(.leading, 26)
    }

    private var subtaskBox: String {
        switch sub.status {
        case .done: return "checkmark.square.fill"
        case .dropped: return "xmark.square"
        case .todo, .inProgress, .waiting: return "square"
        }
    }
}

// MARK: - Kanban board

/// Segmented list/board switch, shown in the task-area toolbar in both modes.
struct ViewModeToggle: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Only offer the board where every status column can populate. Single-status
        // smart views force the list, so hide the toggle there.
        if model.boardAvailable {
            Picker("View", selection: Binding(
                get: { model.boardView },
                set: { model.boardView = $0 }
            )) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "rectangle.split.3x1").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Switch between list and board")
        }
    }
}

/// Kanban board: one column per status (Todo / In Progress / Waiting / Done) for the
/// current project or smart view. Cards drag between columns to change status.
/// Dropped has no column of its own: dropped cards sit, faded, in Done (closed).
struct BoardView: View {
    @EnvironmentObject var model: AppModel

    private static let columns = TaskStatus.allCases.filter { $0.boardColumn == $0 }

    /// Cards shown on the board: top-level tasks in a project view (subtasks stay
    /// nested in the list); the flat set in a smart view. The board honors the same
    /// search query as the list, so toggling list ↔ board keeps the filter consistent.
    private var boardTasks: [TodoTask] {
        let base = model.smartView == nil ? model.tasks.filter { $0.parentId == nil } : model.tasks
        guard !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        return base.filter { model.taskMatchesSearch($0) }
    }

    var body: some View {
        Group {
            if model.selectedProjectId == nil && model.smartView == nil {
                ContentUnavailableViewCompat(text: "Select a view or project")
            } else {
                VStack(spacing: 0) {
                    SearchBar(query: $model.searchQuery)
                    Divider()
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(Self.columns, id: \.self) { status in
                                BoardColumn(status: status,
                                            tasks: boardTasks.filter { $0.status.boardColumn == status })
                            }
                        }
                        .padding(16)
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .navigationTitle(boardTitle)
        .toolbar {
            ToolbarItem(placement: .principal) { ViewModeToggle() }
        }
    }

    private var boardTitle: String {
        if let sv = model.smartView { return sv.title }
        return model.projects.first(where: { $0.id == model.selectedProjectId })?.name ?? "Board"
    }
}

private extension TaskStatus {
    /// The board column a card with this status sits in (see `BoardView`).
    var boardColumn: TaskStatus { self == .dropped ? .done : self }
}

/// One board column: a status header + a scrollable stack of cards. Accepts a
/// dropped card and re-files it to this column's status.
struct BoardColumn: View {
    @EnvironmentObject var model: AppModel
    let status: TaskStatus
    let tasks: [TodoTask]
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: qbStatusIcon(status)).foregroundStyle(qbStatusColor(status))
                Text(status.display).font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                Text("\(tasks.count)")
                    .font(Theme.Fonts.micro.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.Colors.canvas, in: Capsule())
                    .foregroundStyle(Theme.Colors.steel)
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(tasks) { task in
                        BoardCard(task: task)
                            .onDrag {
                                NSItemProvider(object: String(task.id) as NSString)
                            }
                    }
                    if tasks.isEmpty {
                        Text("No tasks")
                            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.stone)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(
            (targeted ? Theme.Colors.surfacePricingFeatured : Theme.Colors.surface),
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(targeted ? Theme.Colors.brandBlue : Theme.Colors.hairlineSoft,
                        lineWidth: targeted ? 2 : 1)
        )
        .onDrop(of: [.plainText], isTargeted: $targeted) { providers in
            handleDrop(providers)
        }
    }

    /// Load the dragged task id and move it to this column's status.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let id = Int64(str) else { return }
            Task { @MainActor in
                // Compare columns, so a dropped card let go back in Done stays dropped.
                if let task = model.task(byId: id), task.status.boardColumn != status {
                    // Route through the shared blocked guard so a drag onto In Progress
                    // gets the same confirmation as the list/bulk/menu paths. A drop on
                    // Waiting keeps the card's waiting-on, else waits on the user.
                    model.setStatus(task, to: status)
                }
            }
        }
        return true
    }
}

/// A draggable card: code, priority, title, and effort/due when present.
/// Tapping it selects the task so the detail column reflects it.
struct BoardCard: View {
    @EnvironmentObject var model: AppModel
    let task: TodoTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if task.priority != .none {
                    Image(systemName: "flag.fill").font(.caption2).foregroundStyle(qbPriorityColor(task.priority))
                }
                CodeBadge(code: task.code)
                Spacer()
            }
            Text(task.title)
                .font(Theme.Fonts.bodySm)
                .lineLimit(3)
                .foregroundStyle(qbTitleColor(task.status))
                .strikethrough(task.status.isClosed)
            if task.status == .waiting {
                HStack(spacing: 6) {
                    WaitingChip(task: task)
                    if let reason = task.waitingReason, !reason.isEmpty {
                        Text(reason)
                            .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.coralDark)
                            .lineLimit(2)
                    }
                }
            }
            HStack(spacing: 8) {
                if task.priority != .none {
                    let chip = qbPriorityChipColors(task.priority)
                    Text(task.priority.display)
                        .font(Theme.Fonts.micro)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(chip.bg, in: Capsule())
                        .foregroundStyle(chip.fg)
                }
                if task.effortSeconds > 0 {
                    Label(fmtEffort(task.effortSeconds), systemImage: "hourglass")
                        .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
                if task.estimateSeconds > 0 {
                    EstimateBadge(estimateSeconds: task.estimateSeconds, actualSeconds: task.effortSeconds)
                }
                if let due = task.dueDate {
                    Label(dueText(due), systemImage: "calendar")
                        .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
                ForEach(task.tags.prefix(2), id: \.self) { TagChip(text: $0) }
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // `template-card`: canvas surface, 16px corners, hairline border; selection uses
        // the featured-card treatment (2px brand-blue).
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .stroke(model.selectedTaskId == task.id ? Theme.Colors.brandBlue : Theme.Colors.hairline,
                        lineWidth: model.selectedTaskId == task.id ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTaskIds = [task.id] }
        .help(task.title)
    }


    private func dueText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}

// MARK: - Task detail

struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel

    @State private var title = ""
    @State private var detail = ""
    @State private var link = ""
    @State private var status: TaskStatus = .todo
    @State private var waitingOn: WaitingOn = .user   // used only while status is Waiting
    @State private var waitingReason = ""
    @State private var priority: Priority = .none
    @State private var hasDue = false
    @State private var dueDate = Date()
    @State private var tagsText = ""
    @State private var recurrence = "none"   // "none" | "daily" | "weekly" | "monthly"
    @State private var estimateMinutes = 0   // 0 = no estimate
    /// The stored task the editor fields were last synced from. A field is the user's
    /// edit only while it differs from this snapshot; autosave sends just those fields,
    /// and a store change (e.g. an MCP write) refreshes the fields the user hasn't touched.
    @State private var base: TodoTask?
    // Draft note (not a task field: autosave ignores it). Kept while the same task is
    // shown, cleared only when a different task is loaded.
    @State private var noteText = ""
    @State private var noteKind: NoteKind = .note
    @State private var noteDraftTaskId: Int64?

    // Blocked-task guard: confirm before moving a blocked task to In Progress.
    @State private var showBlockedAlert = false
    @State private var statusBeforeBlock: TaskStatus = .todo

    var body: some View {
        Group {
            if let task = currentTask {
                sectionsScroll(task)
                .onAppear { load(task) }
                // Selection change or a store write (app or MCP): resync the editor.
                .onChange(of: currentTask) { _, new in if let new { sync(new) } }
                // Auto-save: any field change persists immediately (no Save button).
                .onChange(of: title) { _, _ in autosave() }
                .onChange(of: detail) { _, _ in autosave() }
                .onChange(of: link) { _, _ in autosave() }
                .onChange(of: status) { old, new in
                    // Moving a blocked task to In Progress requires confirmation. Uses the
                    // shared guard decision; keeps a local alert so the picker can revert
                    // on cancel (the segmented control's binding is view-local state).
                    // Only a user edit (status off the snapshot) is checked: a load or
                    // resync never raises the alert or queries the store.
                    if let t = currentTask, new != base?.status,
                       model.blockedConfirmNeeded(forIds: [t.id], to: new) {
                        statusBeforeBlock = old
                        showBlockedAlert = true
                    } else {
                        autosave()
                    }
                }
                .onChange(of: waitingOn) { _, _ in autosave() }
                .onChange(of: waitingReason) { _, _ in autosave() }
                .onChange(of: priority) { _, _ in autosave() }
                .onChange(of: hasDue) { _, _ in autosave() }
                .onChange(of: dueDate) { _, _ in autosave() }
                .onChange(of: tagsText) { _, _ in autosave() }
                .onChange(of: recurrence) { _, _ in autosave() }
                .onChange(of: estimateMinutes) { _, _ in autosave() }
                .alert("Task is blocked", isPresented: $showBlockedAlert) {
                    Button("Cancel", role: .cancel) { status = statusBeforeBlock }
                    Button("Start anyway") { autosave() }
                } message: {
                    Text("This task is blocked by an unfinished dependency. Move it to In Progress anyway?")
                }
            } else {
                ContentUnavailableViewCompat(text: model.selectedTaskIds.count >= 2
                    ? "\(model.selectedTaskIds.count) tasks selected — use the bulk bar above"
                    : "Select a task")
            }
        }
        // Ornamental quest frame around the detail pane (decorative overlay only).
        .padding(10)
        .qbQuestFrame()
        .padding(6)
    }

    private var parsedTags: [String] {
        tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Label-left / control-right row inside a QBDetailSection (replaces the
    /// implicit layout grouped Form rows used to provide).
    @ViewBuilder
    private func labeledRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label).font(Theme.Fonts.bodySm).foregroundStyle(Theme.Colors.slate)
            Spacer()
            control()
        }
    }

    // MARK: detail sections (split out — one inlined expression stalls the type checker)

    private func sectionsScroll(_ task: TodoTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                referenceSection(task)
                taskSection
                dueDateSection
                tagsSection
                blockedSection(task)
                linkSection
                detailSection
                notesSection(task)
                estimateSection(task)
                timingSection(task)
                historySection(task)
            }
            .padding(Theme.Spacing.md)
        }
        .qbParchment()
    }

    private func referenceSection(_ task: TodoTask) -> some View {
        QBDetailSection("Reference") {
            HStack {
                CodeBadge(code: task.code)
                Spacer()
                CopyCodeButton(code: task.code)
            }
        }
    }

    private var taskSection: some View {
        QBDetailSection("Task") {
            TextField("Title", text: $title).qbField()
            Picker("Status", selection: $status) {
                ForEach(TaskStatus.allCases, id: \.self) { Text($0.display).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if status == .waiting {
                labeledRow("Waiting on") {
                    Picker("", selection: $waitingOn) {
                        ForEach(WaitingOn.allCases, id: \.self) { Text(qbWaitingOnLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                TextField("Reason (optional)", text: $waitingReason).qbField()
            }
            labeledRow("Priority") {
                Picker("", selection: $priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var dueDateSection: some View {
        QBDetailSection("Due Date") {
            Toggle("Has due date", isOn: $hasDue)
                .font(Theme.Fonts.bodySm)
            if hasDue {
                labeledRow("Due") {
                    QBDateField(date: $dueDate)
                }
            }
            labeledRow("Repeat") {
                Picker("", selection: $recurrence) {
                    Text("Never").tag("none")
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                    Text("Monthly").tag("monthly")
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var tagsSection: some View {
        QBDetailSection("Tags") {
            TextField("comma, separated, tags", text: $tagsText).qbField()
            if !parsedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(parsedTags, id: \.self) { TagChip(text: $0) }
                    }
                }
            }
        }
    }

    private func blockedSection(_ task: TodoTask) -> some View {
        QBDetailSection("Blocked By") {
            let deps = model.dependencies(of: task.id)
            if deps.isEmpty {
                Text("No blocking tasks").foregroundStyle(Theme.Colors.slate).font(Theme.Fonts.caption)
            } else {
                ForEach(deps, id: \.self) { depId in
                    if let dep = model.task(byId: depId) {
                        HStack(spacing: 8) {
                            // A closed (done or dropped) dependency no longer blocks.
                            Image(systemName: dep.status.isClosed ? qbStatusIcon(dep.status) : "circle")
                                .foregroundStyle(dep.status.isClosed ? qbStatusColor(dep.status) : Theme.Colors.brandYellowDeep)
                            CodeBadge(code: dep.code)
                            Text(dep.title).font(Theme.Fonts.bodySm).lineLimit(1)
                            Spacer()
                            Button {
                                model.removeDependency(task.id, dependsOn: depId)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.Colors.steel)
                            .help("Remove dependency")
                        }
                    }
                }
            }
            Menu("Add blocking task…") {
                ForEach(model.projects) { p in
                    let cands = candidateDeps(for: task).filter { $0.projectId == p.id }
                    if !cands.isEmpty {
                        Menu(p.name) {
                            ForEach(cands, id: \.id) { cand in
                                Button("\(cand.code)  \(cand.title)") {
                                    model.addDependency(task.id, dependsOn: cand.id)
                                }
                            }
                        }
                    }
                }
            }
            .font(Theme.Fonts.bodySmMedium)
            .fixedSize()
        }
    }

    private var linkSection: some View {
        QBDetailSection("Link") {
            HStack {
                TextField("https://…", text: $link).qbField()
                if let url = URL(string: link), !link.isEmpty {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                }
            }
        }
    }

    private var detailSection: some View {
        QBDetailSection("Detail") {
            TextEditor(text: $detail)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .qbField()
        }
    }

    /// The task's append-only log: an input to add a note (with its kind), then the
    /// notes newest first, a page at a time (`AppModel.selectedTaskNotes`, which also
    /// picks up notes added over MCP on the next poll).
    private func notesSection(_ task: TodoTask) -> some View {
        QBDetailSection("Notes") {
            HStack(alignment: .top, spacing: 8) {
                TextField("Add a note…", text: $noteText, axis: .vertical)
                    .lineLimit(1...5)
                    .qbField()
                    .onSubmit { commitNote(task) }
                Picker("", selection: $noteKind) {
                    ForEach(NoteKind.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add") { commitNote(task) }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.selectedTaskNotes.isEmpty {
                Text("No notes yet").foregroundStyle(Theme.Colors.slate).font(Theme.Fonts.caption)
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(model.selectedTaskNotes) { NoteRow(note: $0) }
                }
                if model.hasOlderNotes {
                    Button("Show older notes") { model.showOlderNotes() }
                        .buttonStyle(QBLinkButtonStyle())
                }
            }
        }
    }

    private func commitNote(_ task: TodoTask) {
        guard !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.addNote(task, text: noteText, kind: noteKind) {
            noteText = ""
            noteKind = .note
        }
    }

    private func estimateSection(_ task: TodoTask) -> some View {
        QBDetailSection("Estimate") {
            Stepper(value: $estimateMinutes, in: 0...6000, step: 5) {
                Text(estimateMinutes == 0 ? "No estimate" : "Estimate: \(fmtMinutes(Double(estimateMinutes)))")
                    .font(Theme.Fonts.bodySm)
            }
            if estimateMinutes > 0 {
                EstimateVsActualView(estimateSeconds: estimateMinutes * 60,
                                     actualSeconds: task.effortSeconds)
                    .padding(.vertical, 2)
            }
        }
    }

    private func timingSection(_ task: TodoTask) -> some View {
        QBDetailSection("Timing") {
            LabeledContent("Effort", value: fmtEffort(task.effortSeconds))
            if let s = task.startedAt {
                LabeledContent("Started", value: fmtDateTime(s))
            }
            if let c = task.completedAt {
                LabeledContent("Completed", value: fmtDateTime(c))
            }
            if let s = task.startedAt, let c = task.completedAt, c >= s {
                LabeledContent("Elapsed", value: fmtEffort(Int(c.timeIntervalSince(s))))
            }
        }
        .font(Theme.Fonts.bodySm)
    }

    private func historySection(_ task: TodoTask) -> some View {
        QBDetailSection {
            DisclosureGroup("History (\(model.history(forTask: task.id).count))") {
                let events = model.history(forTask: task.id)
                if events.isEmpty {
                    Text("No changes yet").foregroundStyle(Theme.Colors.slate).font(Theme.Fonts.caption)
                } else {
                    ForEach(events) { e in HistoryRow(event: e) }
                }
            }
            .font(Theme.Fonts.bodySmMedium)
        }
    }

    /// Tasks eligible to become a blocking dependency: any task other than this one
    /// that isn't already a dependency. The store rejects cycles on add.
    private func candidateDeps(for task: TodoTask) -> [TodoTask] {
        let existing = Set(model.dependencies(of: task.id))
        return model.allTasks().filter { $0.id != task.id && !existing.contains($0.id) }
    }

    // Per-field edits: the editor value differs from `t` (the snapshot, see `base`).
    private func titleEdited(_ t: TodoTask) -> Bool { title != t.title }
    private func detailEdited(_ t: TodoTask) -> Bool { detail != t.detail }
    private func linkEdited(_ t: TodoTask) -> Bool { link != (t.link ?? "") }
    private func statusEdited(_ t: TodoTask) -> Bool { status != t.status }
    private func priorityEdited(_ t: TodoTask) -> Bool { priority != t.priority }
    private func dueEdited(_ t: TodoTask) -> Bool {
        hasDue != (t.dueDate != nil) || (hasDue && !sameDay(dueDate, t.dueDate))
    }
    private func tagsEdited(_ t: TodoTask) -> Bool { parsedTags != t.tags }
    private func recurrenceEdited(_ t: TodoTask) -> Bool { recurrence != (t.recurrence ?? "none") }
    private func estimateEdited(_ t: TodoTask) -> Bool { estimateMinutes * 60 != t.estimateSeconds }
    // The waiting fields count only while the editor is on Waiting (they show only then).
    private func waitingOnEdited(_ t: TodoTask) -> Bool { status == .waiting && waitingOn != t.waitingOn }
    private func waitingReasonEdited(_ t: TodoTask) -> Bool {
        status == .waiting && waitingReason != (t.waitingReason ?? "")
    }

    private func sameDay(_ a: Date, _ b: Date?) -> Bool {
        guard let b else { return false }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }

    private var currentTask: TodoTask? {
        model.tasks.first(where: { $0.id == model.selectedTaskId })
    }

    /// Fill every editor field from `t` and make it the snapshot.
    private func load(_ t: TodoTask) {
        base = t
        if noteDraftTaskId != t.id { noteText = ""; noteKind = .note; noteDraftTaskId = t.id }
        title = t.title; detail = t.detail; link = t.link ?? ""; status = t.status
        waitingOn = t.waitingOn ?? .user; waitingReason = t.waitingReason ?? ""
        priority = t.priority
        hasDue = t.dueDate != nil
        dueDate = t.dueDate ?? Date()
        tagsText = t.tags.joined(separator: ", ")
        recurrence = t.recurrence ?? "none"
        estimateMinutes = t.estimateSeconds / 60
    }

    /// The stored task changed: a new selection loads outright; for the same task each
    /// field the user has not edited (still equal to the snapshot) takes the stored
    /// value, and an edited field keeps the user's value. Then `t` is the snapshot.
    /// The field onChange handlers that follow see no edits, so nothing is written back.
    private func sync(_ t: TodoTask) {
        guard let b = base, b.id == t.id else { return load(t) }
        if !titleEdited(b) { title = t.title }
        if !detailEdited(b) { detail = t.detail }
        if !linkEdited(b) { link = t.link ?? "" }
        if !waitingOnEdited(b) { waitingOn = t.waitingOn ?? .user }   // before status: reads it
        if !waitingReasonEdited(b) { waitingReason = t.waitingReason ?? "" }
        if !statusEdited(b) { status = t.status }
        if !priorityEdited(b) { priority = t.priority }
        // Due date and tags refresh only when the stored value moved, so an unchanged
        // field keeps the user's in-progress text (e.g. a trailing ", ") and time of day.
        if !dueEdited(b), t.dueDate != b.dueDate { hasDue = t.dueDate != nil; dueDate = t.dueDate ?? Date() }
        if !tagsEdited(b), t.tags != b.tags { tagsText = t.tags.joined(separator: ", ") }
        if !recurrenceEdited(b) { recurrence = t.recurrence ?? "none" }
        if !estimateEdited(b) { estimateMinutes = t.estimateSeconds / 60 }
        base = t
    }

    /// Persist the user's edits: only the fields that differ from the snapshot, so a
    /// field the store changed underneath (an MCP write) is never overwritten with a
    /// stale value. No-op right after load()/sync() (nothing edited), so it won't loop.
    /// The store write reloads the tasks, and the resulting sync() moves the snapshot.
    private func autosave() {
        guard let b = base, let t = currentTask, b.id == t.id else { return }
        let edits = [titleEdited(b), detailEdited(b), linkEdited(b), statusEdited(b), priorityEdited(b),
                     dueEdited(b), tagsEdited(b), recurrenceEdited(b), estimateEdited(b),
                     waitingOnEdited(b), waitingReasonEdited(b)]
        guard edits.contains(true) else { return }
        model.updateTask(
            t,
            title: titleEdited(b) ? title : nil,
            detail: detailEdited(b) ? detail : nil,
            link: linkEdited(b) ? .some(link.isEmpty ? nil : link) : nil,
            // Status and waiting fields go only when edited, so ordinary edits on a
            // waiting task skip the store's waiting check. Any other status clears them.
            status: statusEdited(b) ? status : nil,
            priority: priorityEdited(b) ? priority : nil,
            dueDate: dueEdited(b) ? .some(hasDue ? dueDate : nil) : nil,
            tags: tagsEdited(b) ? parsedTags : nil,
            recurrence: recurrenceEdited(b) ? .some(recurrence == "none" ? nil : recurrence) : nil,
            estimateSeconds: estimateEdited(b) ? estimateMinutes * 60 : nil,
            waitingOn: waitingOnEdited(b) ? waitingOn : nil,
            waitingReason: waitingReasonEdited(b) ? .some(waitingReason) : nil
        )
    }
}

/// One row in a task's change history.
struct HistoryRow: View {
    let event: TaskEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Text(fmtDateTime(event.timestamp)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            if event.field != "created" {
                let old = value(event.oldValue), new = value(event.newValue)
                Text(old.isEmpty ? "→ \(new)" : "\(old) → \(new)")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
        }
        .padding(.vertical, 1)
    }

    /// History stores waiting-on by raw value (user / external); show the app's labels.
    private func value(_ v: String) -> String {
        guard event.field == "waiting on", let on = WaitingOn(rawValue: v) else { return v }
        return qbWaitingOnLabel(on)
    }

    private var label: String {
        switch event.field {
        case "created": return "Created"
        case "status": return "Status"
        case "waiting on": return "Waiting on"
        case "priority": return "Priority"
        case "due date": return "Due date"
        case "tags": return "Tags"
        case "link": return "Link"
        case "estimate": return "Estimate"
        case "project": return "Moved project"
        default: return event.field.capitalized
        }
    }
}

/// One entry in a task's notes: kind chip and time, then the (selectable) text.
struct NoteRow: View {
    let note: TaskNote
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                NoteKindChip(kind: note.kind)
                Spacer()
                Text(fmtDateTime(note.timestamp)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            Text(note.text)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// Note kind pill: parchment for a note, gold for a decision, herb green for a review.
struct NoteKindChip: View {
    let kind: NoteKind
    var body: some View {
        Text(kind.display.lowercased())
            .font(Theme.Fonts.micro)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(colors.fill, in: Capsule())
            .foregroundStyle(colors.text)
    }

    private var colors: (fill: Color, text: Color) {
        switch kind {
        case .note: return (Theme.Colors.surface, Theme.Colors.slate)
        case .decision: return (Theme.Colors.yellowLight, Theme.Colors.yellowDark)
        case .review: return (Theme.Colors.tealLight, Theme.Colors.mossDark)
        }
    }
}

/// Format a duration in seconds as "45s" / "12m" / "1h 5m".
func fmtEffort(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60
    if m < 60 { return "\(m)m" }
    return "\(m / 60)h \(m % 60)m"
}

/// Compact estimate-vs-actual chip for task rows: a target icon with the estimate,
/// plus a signed over/under delta once any effort has been logged.
struct EstimateBadge: View {
    let estimateSeconds: Int
    let actualSeconds: Int

    var body: some View {
        let over = actualSeconds > estimateSeconds
        let delta = abs(actualSeconds - estimateSeconds)
        HStack(spacing: 3) {
            Image(systemName: "target").font(.caption2)
            Text("est \(fmtEffort(estimateSeconds))")
                .foregroundStyle(Theme.Colors.steel)
            if actualSeconds > 0 && delta > 0 {
                Text(over ? "+\(fmtEffort(delta))" : "-\(fmtEffort(delta))")
                    .foregroundStyle(over ? Theme.Colors.coralDark : Theme.Colors.successAccent)
            }
        }
        .font(Theme.Fonts.micro)
        .foregroundStyle(Theme.Colors.steel)
        .help("Estimate \(fmtEffort(estimateSeconds)) vs actual \(fmtEffort(actualSeconds))")
    }
}

/// Estimate vs actual effort with a proportional bar and an under/over summary.
/// The bar fills green up to the estimate and turns red once actual exceeds it.
struct EstimateVsActualView: View {
    let estimateSeconds: Int
    let actualSeconds: Int

    var body: some View {
        let est = max(estimateSeconds, 1)
        let ratio = min(Double(actualSeconds) / Double(est), 1.0)
        let over = actualSeconds > estimateSeconds
        let delta = abs(actualSeconds - estimateSeconds)
        let pct = Int((Double(delta) / Double(est) * 100).rounded())
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Estimate", systemImage: "target")
                Spacer()
                Text(fmtEffort(estimateSeconds)).monospacedDigit()
            }
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Colors.hairlineSoft)
                    Capsule()
                        .fill(over ? Theme.Colors.brandCoral : Theme.Colors.successAccent)
                        .frame(width: CGFloat(ratio) * geo.size.width)
                }
            }
            .frame(height: 8)
            HStack {
                Text("Actual \(fmtEffort(actualSeconds))")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                Spacer()
                if actualSeconds == 0 {
                    Text("not started").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.stone)
                } else if delta == 0 {
                    Text("on estimate").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.successAccent)
                } else {
                    Text(over ? "over by \(fmtEffort(delta)) (\(pct)%)" : "under by \(fmtEffort(delta)) (\(pct)%)")
                        .font(Theme.Fonts.micro)
                        .foregroundStyle(over ? Theme.Colors.coralDark : Theme.Colors.successAccent)
                }
            }
        }
    }
}

/// Format a date+time, locale-safe (Gregorian).
func fmtDateTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "MMM d, HH:mm"
    return f.string(from: d)
}

/// Small tag pill — `badge-tag-purple`: lavender surface, brand-blue text, full pill.
struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Fonts.micro)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.Colors.surfacePricingFeatured, in: Capsule())
            .foregroundStyle(Theme.Colors.brandBlue)
    }
}

/// Who a waiting task waits on (clay fill, ember text); the reason shows on hover.
/// Renders nothing for a task that is not waiting.
struct WaitingChip: View {
    let task: TodoTask
    var body: some View {
        if task.status == .waiting, let on = task.waitingOn {
            Text("⏸ waiting on \(qbWaitingOnLabel(on).lowercased())")
                .font(Theme.Fonts.micro)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Theme.Colors.coralLight, in: Capsule())
                .foregroundStyle(Theme.Colors.bluePressed)
                .help(task.waitingReason.flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting on \(qbWaitingOnLabel(on))")
        }
    }
}

// MARK: - Pomodoro bar

struct PomodoroBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: PomodoroEngine

    var body: some View {
        HStack(spacing: 16) {
            // Phase + clock (heading-4 scale, monospaced digits for the countdown)
            HStack(spacing: 8) {
                QBIcon(name: phaseIcon(engine.phase), size: 20)
                    .foregroundStyle(Theme.Colors.brandYellow)
                Text(engine.phase == .idle ? "Ready" : engine.clock)
                    .font(.system(size: 22, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Colors.onDark)
                    .frame(minWidth: 90, alignment: .leading)
                Text(engine.phase.label)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onDarkMuted)
            }

            Rectangle().fill(Theme.Colors.onDarkMuted.opacity(0.35))
                .frame(width: 1, height: 24)

            // Controls: Start/Pause is the primary CTA; Skip/Stop stay quiet.
            HStack(spacing: 10) {
                if engine.running {
                    Button { engine.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(QBOnDarkButtonStyle(compact: true))
                } else {
                    Button { engine.startFocus() } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(QBOnDarkButtonStyle(compact: true))
                }
                Button { engine.skip() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(QBGhostButtonStyle(onDark: true))
                    .disabled(engine.phase == .idle)
                Button { engine.stop() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(QBGhostButtonStyle(onDark: true))
                    .disabled(engine.phase == .idle)
            }

            Spacer()

            // Daily stats
            HStack(spacing: 16) {
                statBadge(icon: "checkmark.seal", value: "\(model.stats.completedPomodoros)", label: "pomodoros")
                statBadge(icon: "clock", value: "\(model.stats.totalFocusSeconds / 60)m", label: "focus today")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .qbHearth()
    }

    /// Bundled icon name per phase — hearth metaphor: campfire while focusing,
    /// a tavern break, a proper rest, embers when idle.
    private func phaseIcon(_ phase: PomodoroPhase) -> String {
        switch phase {
        case .focus: return "tabler-campfire"
        case .shortBreak: return "lucide-beer"
        case .longBreak: return "lucide-bed"
        case .idle: return "lucide-flame-kindling"
        }
    }

    private func statBadge(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(Theme.Colors.onDarkMuted)
            Text(value).font(Theme.Fonts.bodyMdMedium.monospacedDigit()).foregroundStyle(Theme.Colors.onDark)
            Text(label).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.onDarkMuted)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var focusMin = 25
    @State private var shortMin = 5
    @State private var longMin = 15
    @State private var rounds = 4

    @EnvironmentObject var shortcuts: ShortcutStore
    @State private var notify = true
    @State private var sound = true
    @State private var autoAdvance = true
    @State private var breaksEffort = false
    @State private var mcpStatus = ""

    var body: some View {
        Form {
            Section("Pomodoro Durations (minutes)") {
                Stepper("Focus: \(focusMin)", value: $focusMin, in: 1...120)
                Stepper("Short break: \(shortMin)", value: $shortMin, in: 1...60)
                Stepper("Long break: \(longMin)", value: $longMin, in: 1...60)
                Stepper("Rounds before long break: \(rounds)", value: $rounds, in: 1...12)
            }
            Section("Notifications") {
                Toggle("Notify when a phase ends", isOn: $notify)
                Toggle("Play sound", isOn: $sound).disabled(!notify)
            }
            Section("Timer Behavior") {
                Toggle("Auto-start next phase", isOn: $autoAdvance)
                Toggle("Count break time as effort", isOn: $breaksEffort)
            }
            Section("Updates") {
                LabeledContent("Version",
                               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Button("Check for Updates…") { UpdateNotifier.shared.requestCheck?() }
            }
            Section("Claude Code (MCP)") {
                LabeledContent("Status", value: mcpStatus)
                if let p = MCPRegistration.registeredPath() {
                    LabeledContent("Path") {
                        Text(p).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                    }
                }
                Button("Re-register") {
                    MCPRegistration.registerIfNeeded(force: true)
                    refreshMCP()
                    model.flashToast("MCP re-registered")
                }
            }
            Section {
                ForEach(ShortcutAction.allCases) { a in
                    HStack {
                        Text(a.title)
                        Spacer()
                        ShortcutField(shortcut: Binding(
                            get: { shortcuts.shortcut(a) },
                            set: { shortcuts.set(a, $0) }
                        ))
                        Button { shortcuts.reset(a) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless)
                            .help("Reset to default")
                    }
                }
                Button("Reset All Shortcuts") { shortcuts.resetAll() }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new keys (Esc to cancel). Shortcuts work while the app is focused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Database") {
                    Text(model.store.dbURL.path).font(.caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.dbURL])
                }
                Button("Export Backup…") { exportBackup() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
        .onAppear { loadValues() }
        .onChange(of: focusMin) { _, _ in save() }
        .onChange(of: shortMin) { _, _ in save() }
        .onChange(of: longMin) { _, _ in save() }
        .onChange(of: rounds) { _, _ in save() }
        .onChange(of: notify) { _, _ in save() }
        .onChange(of: sound) { _, _ in save() }
        .onChange(of: autoAdvance) { _, _ in save() }
        .onChange(of: breaksEffort) { _, _ in save() }
    }

    private func loadValues() {
        let s = model.settings
        focusMin = s.focusSeconds / 60
        shortMin = s.shortBreakSeconds / 60
        longMin = s.longBreakSeconds / 60
        rounds = s.roundsBeforeLongBreak
        notify = s.notificationsEnabled
        sound = s.soundEnabled
        autoAdvance = s.autoAdvance
        breaksEffort = s.countBreaksAsEffort
        refreshMCP()
    }

    private func refreshMCP() {
        if MCPRegistration.registeredPath() == nil { mcpStatus = "Not registered" }
        else if MCPRegistration.isUpToDate() { mcpStatus = "Registered ✓" }
        else { mcpStatus = "Registered (path outdated — re-register)" }
    }

    private func save() {
        model.saveSettings(PomodoroSettings(
            focusSeconds: focusMin * 60,
            shortBreakSeconds: shortMin * 60,
            longBreakSeconds: longMin * 60,
            roundsBeforeLongBreak: rounds,
            notificationsEnabled: notify,
            soundEnabled: sound,
            autoAdvance: autoAdvance,
            countBreaksAsEffort: breaksEffort
        ))
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QuestBits-backup.sqlite"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do { try model.store.backup(to: url); model.flashToast("Backup saved") }
            catch { model.flashToast("Backup failed") }
        }
    }
}

// MARK: - Helpers

/// Small modal sheet to enter a name and confirm. Enter = Create, Esc = Cancel.
struct NameSheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 340)
        .qbParchment()
    }

    private func create() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCreate()
        dismiss()
    }
}

/// Small monospaced chip showing a project/task code — surface fill, steel text,
/// `{rounded.xs}` corners (monospaced code reads better rectangular than as a pill).
struct CodeBadge: View {
    let code: String
    var body: some View {
        Text(code)
            .font(Theme.Fonts.codeBadge)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.xs))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs).stroke(Theme.Colors.hairline, lineWidth: 1))
            .foregroundStyle(Theme.Colors.steel)
    }
}

/// Put a string on the system clipboard.
func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Copy button that swaps to an animated "Copied!" checkmark for ~1.5s,
/// and also drives the global toast via the model.
struct CopyCodeButton: View {
    @EnvironmentObject var model: AppModel
    let code: String
    @State private var copied = false

    var body: some View {
        Button {
            model.copyCode(code)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                withAnimation(.easeOut(duration: 0.25)) { copied = false }
            }
        } label: {
            Label(copied ? "Copied!" : "Copy code",
                  systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(Theme.Fonts.bodySmMedium)
                .foregroundStyle(copied ? Theme.Colors.successAccent : Theme.Colors.brandBlue)
                .scaleEffect(copied ? 1.05 : 1.0)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(copied)
    }
}

// MARK: - Stats dashboard

/// A single bar-chart datum (label on the x-axis, numeric height).
struct BarDatum: Identifiable, Hashable {
    let label: String
    let value: Double
    var id: String { label }
}

/// Format a minutes value as "45m" / "1h 5m".
func fmtMinutes(_ minutes: Double) -> String {
    let m = max(0, Int(minutes.rounded()))
    if m < 60 { return "\(m)m" }
    return "\(m / 60)h \(m % 60)m"
}

/// The stats dashboard: focus, pomodoros, and completed tasks per day (last 7 days),
/// plus accrued effort per project. Uses Swift Charts, with a custom fallback below macOS 13.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    private var totalFocusSeconds: Int { model.daySeries.reduce(0) { $0 + $1.focusSeconds } }
    private var totalPomodoros: Int { model.daySeries.reduce(0) { $0 + $1.pomodoros } }
    private var totalCompleted: Int { model.daySeries.reduce(0) { $0 + $1.tasksCompleted } }
    private var totalTrackedSeconds: Int { model.projectEfforts.reduce(0) { $0 + $1.effortSeconds } }

    private var focusData: [BarDatum] {
        model.daySeries.map { BarDatum(label: weekday($0.date), value: Double($0.focusSeconds) / 60.0) }
    }
    private var pomodoroData: [BarDatum] {
        model.daySeries.map { BarDatum(label: weekday($0.date), value: Double($0.pomodoros)) }
    }
    private var completedData: [BarDatum] {
        model.daySeries.map { BarDatum(label: weekday($0.date), value: Double($0.tasksCompleted)) }
    }
    /// Top projects by effort (skip zero-effort ones; show at most 8).
    private var effortData: [BarDatum] {
        model.projectEfforts
            .filter { $0.effortSeconds > 0 }
            .prefix(8)
            .map { BarDatum(label: $0.code, value: Double($0.effortSeconds) / 60.0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Stats")
                    .font(Theme.Fonts.heading3)
                    .foregroundStyle(Theme.Colors.ink)

                // Summary tiles (last 7 days + all-time tracked effort).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    StatTile(icon: "clock", tint: Theme.Colors.brandYellowDeep,
                             value: fmtEffort(totalFocusSeconds), label: "Focus (7d)")
                    StatTile(icon: "checkmark.seal", tint: Theme.Colors.brandCoral,
                             value: "\(totalPomodoros)", label: "Pomodoros (7d)")
                    StatTile(icon: "checkmark.circle", tint: Theme.Colors.successAccent,
                             value: "\(totalCompleted)", label: "Completed (7d)")
                    StatTile(icon: "hourglass", tint: Theme.Colors.brandBlue,
                             value: fmtEffort(totalTrackedSeconds), label: "Tracked effort")
                }

                ChartCard(title: "Focus per day", subtitle: "minutes, last 7 days") {
                    BarChartView(data: focusData, unit: "min", tint: Theme.Colors.brandYellowDeep) { fmtMinutes($0) }
                }
                ChartCard(title: "Pomodoros per day", subtitle: "completed focus sessions") {
                    BarChartView(data: pomodoroData, unit: "count", tint: Theme.Colors.brandCoral) { "\(Int($0))" }
                }
                ChartCard(title: "Tasks completed per day", subtitle: "last 7 days") {
                    BarChartView(data: completedData, unit: "count", tint: Theme.Colors.successAccent) { "\(Int($0))" }
                }
                ChartCard(title: "Effort per project", subtitle: "minutes tracked, top projects") {
                    if effortData.isEmpty {
                        Text("No tracked effort yet — run a focus timer on an in-progress task.")
                            .font(Theme.Fonts.bodySm).foregroundStyle(Theme.Colors.slate)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        BarChartView(data: effortData, unit: "min", tint: Theme.Colors.brandBlue) { fmtMinutes($0) }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .qbParchment()
        .navigationTitle("Dashboard")
        .onAppear { model.reloadDashboard() }
    }

    /// Short weekday ("Mon") for a yyyy-MM-dd date string; falls back to the raw string.
    private func weekday(_ ymd: String) -> String {
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.calendar = Calendar(identifier: .gregorian)
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: ymd) else { return ymd }
        let out = DateFormatter()
        out.calendar = Calendar(identifier: .gregorian)
        out.dateFormat = "EEE"
        return out.string(from: d)
    }
}

/// Compact summary tile: icon, big value, caption.
struct StatTile: View {
    let icon: String
    let tint: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text(value)
                .font(Theme.Fonts.heading4.monospacedDigit())
                .foregroundStyle(Theme.Colors.ink)
            Text(label).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.steel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .qbCard(padding: Theme.Spacing.md)
    }
}

/// A titled card wrapping a chart.
struct ChartCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                Text(subtitle).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.steel)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .qbCard(padding: Theme.Spacing.md)
    }
}

/// Bar chart over `data`. Uses Swift Charts on macOS 13+, else a lightweight
/// GeometryReader/rectangle fallback so the build never depends on Charts at runtime.
struct BarChartView: View {
    let data: [BarDatum]
    let unit: String
    let tint: Color
    let format: (Double) -> String

    var body: some View {
        if #available(macOS 13.0, *) {
            Chart(data) { d in
                BarMark(
                    x: .value("Category", d.label),
                    y: .value(unit, d.value)
                )
                .foregroundStyle(tint.gradient)
                .annotation(position: .top) {
                    if d.value > 0 {
                        Text(format(d.value)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                    }
                }
            }
            .chartXScale(domain: data.map(\.label))
            .frame(height: 170)
        } else {
            FallbackBarChart(data: data, tint: tint, format: format)
                .frame(height: 170)
        }
    }
}

/// Custom bar chart for SDKs without Swift Charts.
struct FallbackBarChart: View {
    let data: [BarDatum]
    let tint: Color
    let format: (Double) -> String

    var body: some View {
        let maxV = max(data.map(\.value).max() ?? 1, 1)
        GeometryReader { geo in
            let barArea = max(geo.size.height - 34, 1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(data) { d in
                    VStack(spacing: 4) {
                        Text(d.value > 0 ? format(d.value) : "")
                            .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: Theme.Radius.xs)
                            .fill(tint)
                            .frame(height: CGFloat(d.value / maxV) * barArea)
                        Text(d.label).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// Minimal stand-in so older SDKs without ContentUnavailableView still compile.
struct ContentUnavailableViewCompat: View {
    let text: String
    var body: some View {
        VStack { Text(text).foregroundStyle(Theme.Colors.slate).font(Theme.Fonts.subtitle) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .qbParchment()
    }
}
