import SwiftUI
import AppKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                ProjectSidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } content: {
                TaskListView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 360)
            } detail: {
                TaskDetailView()
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
            } else if model.tasks.isEmpty {
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
            } else {
                VStack(spacing: 0) {
                    if model.selectedTaskIds.count >= 2 {
                        BulkActionBar(otherProjects: otherProjects)
                        Divider()
                    }
                    List(selection: $model.selectedTaskIds) {
                        ForEach(model.tasks) { task in
                            TaskRow(task: task)
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
                        .onMove { offsets, dest in model.moveTasks(from: offsets, to: dest) }
                    }
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

    private var projectName: String {
        if let sv = model.smartView { return sv.title }
        return model.projects.first(where: { $0.id == model.selectedProjectId })?.name ?? "Tasks"
    }

    /// Projects other than the one currently selected (move/copy targets).
    private var otherProjects: [Project] {
        model.projects.filter { $0.id != model.selectedProjectId }
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

    var body: some View {
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
        .padding(.vertical, 2)
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

/// Minimal stand-in so older SDKs without ContentUnavailableView still compile.
struct ContentUnavailableViewCompat: View {
    let text: String
    var body: some View {
        VStack { Text(text).foregroundStyle(.secondary).font(.title3) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
