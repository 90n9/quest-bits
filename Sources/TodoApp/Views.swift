import SwiftUI
import AppKit
import Charts

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                ProjectSidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } content: {
                if model.showDashboard {
                    DashboardView()
                        .navigationSplitViewColumnWidth(min: 420, ideal: 560)
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
    }
}

/// Floating confirmation pill (e.g. "Copied GEN-3").
struct ToastView: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.92), in: Capsule())
            .shadow(radius: 6, y: 2)
    }
}

// MARK: - Projects sidebar

struct ProjectSidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
    @State private var editing: Project?      // non-nil → edit sheet open

    var body: some View {
        List(selection: Binding(
            get: { model.selectedProjectId },
            set: { model.selectProject($0) }
        )) {
            Section("Views") {
                ForEach(SmartView.allCases, id: \.self) { v in
                    Label(v.title, systemImage: v.icon)
                        .foregroundStyle(model.smartView == v ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectSmartView(v) }
                        .listRowBackground(model.smartView == v ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                Label("Dashboard", systemImage: "chart.bar.xaxis")
                    .foregroundStyle(model.showDashboard ? Color.accentColor : .primary)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectDashboard() }
                    .listRowBackground(model.showDashboard ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            Section("Projects") {
                ForEach(model.projects) { p in
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        CodeBadge(code: p.code)
                        Text(p.name)
                        Spacer()
                        Text("\(taskCount(p.id))").foregroundStyle(.secondary).font(.caption)
                    }
                    .tag(p.id)
                    .help(p.detail.isEmpty ? p.name : p.detail)
                    .contextMenu {
                        Button("Copy Code (\(p.code))") { model.copyCode(p.code) }
                        Button("Edit…") { editing = p }
                        Button("Delete", role: .destructive) { model.deleteProject(p.id) }
                    }
                }
            }
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
        .onChange(of: model.pendingNewProject) { _, pending in
            if pending { showNew = true; model.pendingNewProject = false }
        }
    }

    private func taskCount(_ pid: Int64) -> Int {
        (try? model.store.listTasks(projectId: pid).count) ?? 0
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
            Text(title).font(.headline)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $detail)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { onSave(n, detail) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Task list

struct TaskListView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNew = false
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
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
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
            VStack(spacing: 12) {
                Text(model.smartView != nil ? "No tasks here" : "No tasks in this project")
                    .foregroundStyle(.secondary)
                if model.smartView == nil {
                    Button { showNew = true } label: {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    ForEach(displayedTasks) { task in
                        TaskRow(task: task,
                                subtasks: subtasks(of: task),
                                showSubtaskUI: model.smartView == nil)
                            .tag(task.id)
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
                    .onMove { offsets, dest in
                        // Reordering rewrites a dense sort_order for exactly the ids passed in.
                        // That is only correct when displayedTasks is the full unfiltered list;
                        // while searching it is a filtered subset, so a drag would clobber the
                        // ordering of hidden tasks. Disable reordering during search.
                        guard !isSearching else { return }
                        model.moveTasks(displayedTasks, from: offsets, to: dest)
                    }
                }
            }
        }
    }

    private var projectName: String {
        if let sv = model.smartView { return sv.title }
        return model.projects.first(where: { $0.id == model.selectedProjectId })?.name ?? "Tasks"
    }

    /// Projects other than the one currently selected (move/copy targets).
    private var otherProjects: [Project] {
        model.projects.filter { $0.id != model.selectedProjectId }
    }

    private var isSearching: Bool {
        !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Rows shown as top-level List items. In a project view, only top-level tasks
    /// (subtasks render nested under their parent); in a smart view, the flat list.
    /// When searching, keep a top-level task if it matches or any of its subtasks match.
    private var displayedTasks: [TodoTask] {
        let base = model.smartView == nil ? model.tasks.filter { $0.parentId == nil } : model.tasks
        guard isSearching else { return base }
        if model.smartView == nil {
            return base.filter { task in
                model.taskMatchesSearch(task)
                    || model.tasks.contains { $0.parentId == task.id && model.taskMatchesSearch($0) }
            }
        }
        return base.filter { model.taskMatchesSearch($0) }
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tasks", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

/// Action bar shown above the task list when 2+ tasks are selected.
struct BulkActionBar: View {
    @EnvironmentObject var model: AppModel
    let otherProjects: [Project]
    @State private var showTagSheet = false
    @State private var tagText = ""

    var body: some View {
        HStack(spacing: 10) {
            Text("\(model.selectedTaskIds.count) selected")
                .font(.subheadline.weight(.semibold))

            Spacer()

            Menu("Status") {
                ForEach(TaskStatus.allCases, id: \.self) { s in
                    Button(s.display) { model.bulkSetStatus(s) }
                }
            }
            Menu("Priority") {
                ForEach(Priority.allCases, id: \.self) { p in
                    Button(p.display) { model.bulkSetPriority(p) }
                }
            }
            if !otherProjects.isEmpty {
                Menu("Move") {
                    ForEach(otherProjects) { p in Button(p.name) { model.bulkMove(toProject: p.id) } }
                }
                Menu("Copy") {
                    ForEach(otherProjects) { p in Button(p.name) { model.bulkCopy(toProject: p.id) } }
                }
            }
            Button("Add Tags") { showTagSheet = true }
            Button(role: .destructive) { model.bulkDelete() } label: { Image(systemName: "trash") }
                .help("Delete selected")
            Button("Clear") { model.selectedTaskIds = [] }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: TodoTask
    var subtasks: [TodoTask] = []
    var showSubtaskUI: Bool = false

    @State private var addingSubtask = false
    @State private var newSubtaskTitle = ""

    private var doneCount: Int { subtasks.filter { $0.status == .done }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button(action: { model.cycleStatus(task) }) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Click to cycle status")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if task.priority != .none {
                            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(priorityColor)
                        }
                        CodeBadge(code: task.code)
                        Text(task.title)
                            .strikethrough(task.status == .done)
                            .foregroundStyle(task.status == .done ? .secondary : .primary)
                        if !subtasks.isEmpty {
                            Text("\(doneCount)/\(subtasks.count)")
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(doneCount == subtasks.count ? Color.green : .secondary)
                                .help("\(doneCount) of \(subtasks.count) subtasks done")
                        }
                    }
                    HStack(spacing: 8) {
                        if task.link != nil && !(task.link?.isEmpty ?? true) {
                            Image(systemName: "link").font(.caption2).foregroundStyle(.secondary)
                        }
                        if task.effortSeconds > 0 {
                            Label(fmtEffort(task.effortSeconds), systemImage: "hourglass")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let due = task.dueDate {
                            Label(dueText(due), systemImage: "calendar")
                                .font(.caption2)
                                .foregroundStyle(isOverdue(due, task) ? Color.red : .secondary)
                        }
                        if let rec = task.recurrence, !rec.isEmpty {
                            Text("↻ \(rec)").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(task.tags.prefix(3), id: \.self) { TagChip(text: $0) }
                    }
                }
                Spacer()
                Text(task.status.display).font(.caption2).foregroundStyle(.secondary)
            }

            // Subtasks (one level of nesting), shown only for top-level tasks in a project view.
            if showSubtaskUI && task.parentId == nil {
                ForEach(subtasks) { sub in
                    SubtaskRow(sub: sub)
                }
                if addingSubtask {
                    HStack(spacing: 8) {
                        Image(systemName: "square").foregroundStyle(.secondary)
                        TextField("Subtask title", text: $newSubtaskTitle)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .onSubmit { commitSubtask() }
                        Button("Add") { commitSubtask() }
                            .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { addingSubtask = false; newSubtaskTitle = "" }
                    }
                    .padding(.leading, 26)
                } else {
                    Button {
                        addingSubtask = true
                    } label: {
                        Label("subtask", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
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

    private var priorityColor: Color {
        switch task.priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        case .none: return .secondary
        }
    }

    private func dueText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    private func isOverdue(_ d: Date, _ t: TodoTask) -> Bool {
        t.status != .done && Calendar.current.startOfDay(for: d) < Calendar.current.startOfDay(for: Date())
    }

    private var statusIcon: String {
        switch task.status {
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }
    private var statusColor: Color {
        switch task.status {
        case .todo: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        }
    }
}

/// A single subtask line: checkbox + title, indented under its parent.
struct SubtaskRow: View {
    @EnvironmentObject var model: AppModel
    let sub: TodoTask

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { model.toggleSubtaskDone(sub) }) {
                Image(systemName: sub.status == .done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(sub.status == .done ? Color.green : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Toggle done")

            Text(sub.title)
                .font(.callout)
                .strikethrough(sub.status == .done)
                .foregroundStyle(sub.status == .done ? .secondary : .primary)
            Spacer()
        }
        .padding(.leading, 26)
    }
}

// MARK: - Task detail

struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel

    @State private var title = ""
    @State private var detail = ""
    @State private var link = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: Priority = .none
    @State private var hasDue = false
    @State private var dueDate = Date()
    @State private var tagsText = ""
    @State private var recurrence = "none"   // "none" | "daily" | "weekly" | "monthly"

    var body: some View {
        Group {
            if let task = currentTask {
                Form {
                    Section("Reference") {
                        HStack {
                            CodeBadge(code: task.code)
                            Spacer()
                            CopyCodeButton(code: task.code)
                        }
                    }
                    Section("Task") {
                        TextField("Title", text: $title)
                        Picker("Status", selection: $status) {
                            ForEach(TaskStatus.allCases, id: \.self) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Picker("Priority", selection: $priority) {
                            ForEach(Priority.allCases, id: \.self) { Text($0.display).tag($0) }
                        }
                    }
                    Section("Due Date") {
                        Toggle("Has due date", isOn: $hasDue)
                        if hasDue {
                            DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                        }
                        Picker("Repeat", selection: $recurrence) {
                            Text("Never").tag("none")
                            Text("Daily").tag("daily")
                            Text("Weekly").tag("weekly")
                            Text("Monthly").tag("monthly")
                        }
                    }
                    Section("Tags") {
                        TextField("comma, separated, tags", text: $tagsText)
                        if !parsedTags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(parsedTags, id: \.self) { TagChip(text: $0) }
                                }
                            }
                        }
                    }
                    Section("Link") {
                        HStack {
                            TextField("https://…", text: $link)
                            if let url = URL(string: link), !link.isEmpty {
                                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            }
                        }
                    }
                    Section("Detail") {
                        TextEditor(text: $detail)
                            .frame(minHeight: 120)
                            .font(.body)
                    }
                    Section("Timing") {
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
                    Section {
                        DisclosureGroup("History (\(model.history(forTask: task.id).count))") {
                            let events = model.history(forTask: task.id)
                            if events.isEmpty {
                                Text("No changes yet").foregroundStyle(.secondary).font(.caption)
                            } else {
                                ForEach(events) { e in HistoryRow(event: e) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .onAppear { load(task) }
                .onChange(of: model.selectedTaskId) { _, _ in if let t = currentTask { load(t) } }
                // Auto-save: any field change persists immediately (no Save button).
                .onChange(of: title) { _, _ in autosave() }
                .onChange(of: detail) { _, _ in autosave() }
                .onChange(of: link) { _, _ in autosave() }
                .onChange(of: status) { _, _ in autosave() }
                .onChange(of: priority) { _, _ in autosave() }
                .onChange(of: hasDue) { _, _ in autosave() }
                .onChange(of: dueDate) { _, _ in autosave() }
                .onChange(of: tagsText) { _, _ in autosave() }
                .onChange(of: recurrence) { _, _ in autosave() }
            } else {
                ContentUnavailableViewCompat(text: model.selectedTaskIds.count >= 2
                    ? "\(model.selectedTaskIds.count) tasks selected — use the bulk bar above"
                    : "Select a task")
            }
        }
    }

    private var parsedTags: [String] {
        tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// True when the editor fields differ from the stored task.
    private func isDirty(_ t: TodoTask) -> Bool {
        title != t.title
            || detail != t.detail
            || link != (t.link ?? "")
            || status != t.status
            || priority != t.priority
            || hasDue != (t.dueDate != nil)
            || (hasDue && !sameDay(dueDate, t.dueDate))
            || parsedTags != t.tags
            || recurrence != (t.recurrence ?? "none")
    }

    private func sameDay(_ a: Date, _ b: Date?) -> Bool {
        guard let b else { return false }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }

    private var currentTask: TodoTask? {
        model.tasks.first(where: { $0.id == model.selectedTaskId })
    }

    private func load(_ t: TodoTask) {
        title = t.title; detail = t.detail; link = t.link ?? ""; status = t.status
        priority = t.priority
        hasDue = t.dueDate != nil
        dueDate = t.dueDate ?? Date()
        tagsText = t.tags.joined(separator: ", ")
        recurrence = t.recurrence ?? "none"
    }

    /// Persist current editor state if it differs from the stored task.
    /// No-op right after load() (fields equal the task), so it won't loop.
    private func autosave() {
        guard let t = currentTask, isDirty(t) else { return }
        model.updateTask(
            t,
            title: title,
            detail: detail,
            link: .some(link.isEmpty ? nil : link),
            status: status,
            priority: priority,
            dueDate: .some(hasDue ? dueDate : nil),
            tags: parsedTags,
            recurrence: .some(recurrence == "none" ? nil : recurrence)
        )
    }
}

/// One row in a task's change history.
struct HistoryRow: View {
    let event: TaskEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.caption.weight(.medium))
                Spacer()
                Text(fmtDateTime(event.timestamp)).font(.caption2).foregroundStyle(.secondary)
            }
            if event.field != "created" {
                Text(event.oldValue.isEmpty ? "→ \(event.newValue)" : "\(event.oldValue) → \(event.newValue)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    private var label: String {
        switch event.field {
        case "created": return "Created"
        case "status": return "Status"
        case "priority": return "Priority"
        case "due date": return "Due date"
        case "tags": return "Tags"
        case "link": return "Link"
        case "project": return "Moved project"
        default: return event.field.capitalized
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

/// Format a date+time, locale-safe (Gregorian).
func fmtDateTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "MMM d, HH:mm"
    return f.string(from: d)
}

/// Small tag pill.
struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

// MARK: - Pomodoro bar

struct PomodoroBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: PomodoroEngine

    var body: some View {
        HStack(spacing: 16) {
            // Phase + clock
            HStack(spacing: 8) {
                Text(phaseIcon(engine.phase)).font(.title2)
                Text(engine.phase == .idle ? "Ready" : engine.clock)
                    .font(.system(.title2, design: .monospaced))
                    .frame(minWidth: 90, alignment: .leading)
                Text(engine.phase.label).foregroundStyle(.secondary)
            }

            Divider().frame(height: 24)

            // Controls
            HStack(spacing: 10) {
                if engine.running {
                    Button { engine.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                } else {
                    Button { engine.startFocus() } label: { Label("Start", systemImage: "play.fill") }
                }
                Button { engine.skip() } label: { Image(systemName: "forward.fill") }
                    .disabled(engine.phase == .idle)
                Button { engine.stop() } label: { Image(systemName: "stop.fill") }
                    .disabled(engine.phase == .idle)
            }

            Spacer()

            // Daily stats
            HStack(spacing: 16) {
                statBadge(icon: "checkmark.seal", value: "\(model.stats.completedPomodoros)", label: "pomodoros")
                statBadge(icon: "clock", value: "\(model.stats.totalFocusSeconds / 60)m", label: "focus today")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func phaseIcon(_ phase: PomodoroPhase) -> String {
        switch phase {
        case .focus: return "🍅"
        case .shortBreak, .longBreak: return "☕️"
        case .idle: return "⏰"
        }
    }

    private func statBadge(icon: String, value: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
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
        panel.nameFieldStringValue = "TodoApp-backup.sqlite"
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
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func create() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCreate()
        dismiss()
    }
}

/// Small monospaced pill showing a project/task code.
struct CodeBadge: View {
    let code: String
    var body: some View {
        Text(code)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
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
                .foregroundStyle(copied ? Color.green : Color.accentColor)
                .scaleEffect(copied ? 1.05 : 1.0)
                .contentTransition(.symbolEffect(.replace))
        }
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
                Text("Stats").font(.largeTitle.bold())

                // Summary tiles (last 7 days + all-time tracked effort).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    StatTile(icon: "clock", tint: .orange, value: fmtEffort(totalFocusSeconds), label: "Focus (7d)")
                    StatTile(icon: "checkmark.seal", tint: .red, value: "\(totalPomodoros)", label: "Pomodoros (7d)")
                    StatTile(icon: "checkmark.circle", tint: .green, value: "\(totalCompleted)", label: "Completed (7d)")
                    StatTile(icon: "hourglass", tint: .blue, value: fmtEffort(totalTrackedSeconds), label: "Tracked effort")
                }

                ChartCard(title: "Focus per day", subtitle: "minutes, last 7 days") {
                    BarChartView(data: focusData, unit: "min", tint: .orange) { fmtMinutes($0) }
                }
                ChartCard(title: "Pomodoros per day", subtitle: "completed focus sessions") {
                    BarChartView(data: pomodoroData, unit: "count", tint: .red) { "\(Int($0))" }
                }
                ChartCard(title: "Tasks completed per day", subtitle: "last 7 days") {
                    BarChartView(data: completedData, unit: "count", tint: .green) { "\(Int($0))" }
                }
                ChartCard(title: "Effort per project", subtitle: "minutes tracked, top projects") {
                    if effortData.isEmpty {
                        Text("No tracked effort yet — run a focus timer on an in-progress task.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        BarChartView(data: effortData, unit: "min", tint: .blue) { fmtMinutes($0) }
                    }
                }
            }
            .padding(20)
        }
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
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
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
                        Text(format(d.value)).font(.caption2).foregroundStyle(.secondary)
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
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(height: 14)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(tint)
                            .frame(height: CGFloat(d.value / maxV) * barArea)
                        Text(d.label).font(.caption2).foregroundStyle(.secondary)
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
        VStack { Text(text).foregroundStyle(.secondary).font(.title3) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
