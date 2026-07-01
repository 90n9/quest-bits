import Foundation
import Combine
import SwiftUI

/// Top-level observable state for the app. Wraps the shared Store, watches the DB
/// file for external (MCP) writes, and owns the pomodoro engine.
/// Cross-project smart filters shown in the sidebar.
enum SmartView: String, CaseIterable {
    case allTasks
    case inProgress

    var title: String { self == .allTasks ? "All Tasks" : "In Progress" }
    var icon: String { self == .allTasks ? "tray.full" : "circle.lefthalf.filled" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var tasks: [TodoTask] = []          // tasks for the selected project
    @Published var selectedProjectId: Int64?
    @Published var selectedTaskIds: Set<Int64> = []
    @Published var smartView: SmartView?      // when set, tasks span all projects
    @Published var searchQuery: String = ""   // live filter over the displayed task list

    // Task-area layout: false = list view, true = Kanban board. Persists across
    // project/smart-view selection; ignored while the dashboard is showing.
    @Published var boardView = false

    // In-progress tasks across all projects — surfaced in the menu bar dropdown.
    // Refreshed alongside the displayed task list so it tracks status changes.
    @Published var inProgressTasks: [TodoTask] = []

    // Ids of tasks currently blocked by an unfinished dependency (for the 🔒 badge).
    // Recomputed alongside the displayed task list.
    @Published var blockedTaskIds: Set<Int64> = []

    // Stats dashboard: when shown, the content column swaps to the dashboard.
    @Published var showDashboard = false
    @Published var daySeries: [DayStat] = []
    @Published var projectEfforts: [ProjectEffort] = []

    /// The single selected task id, or nil when zero or multiple are selected.
    var selectedTaskId: Int64? { selectedTaskIds.count == 1 ? selectedTaskIds.first : nil }
    @Published var stats: DailyStats = DailyStats(date: "", completedPomodoros: 0, totalFocusSeconds: 0)
    @Published var settings: PomodoroSettings = .standard

    // Set by menu commands; views observe these to open their create sheets.
    @Published var pendingNewProject = false
    @Published var pendingNewTask = false

    // Transient confirmation toast (e.g. after copying a code).
    @Published var toast: String?
    private var toastSeq = 0

    let store: Store
    let pomodoro: PomodoroEngine

    private var watchTimer: Timer?
    private var lastDBStamp: TimeInterval = 0
    private var effortBuffer = 0                 // unflushed focused seconds
    private var cancellables = Set<AnyCancellable>()

    init() {
        // App + MCP share the default DB location.
        let store = (try? Store()) ?? { fatalError("cannot open store") }()
        self.store = store
        let loaded = (try? store.loadSettings()) ?? .standard
        self.settings = loaded
        self.pomodoro = PomodoroEngine(store: store, settings: loaded)
        reloadAll()
        if selectedProjectId == nil { selectedProjectId = projects.first?.id }
        reloadTasks()
        startWatching()

        // Effort: accrue focused seconds onto in-progress tasks; flush when the timer stops.
        pomodoro.onFocusSecond = { [weak self] in self?.accrueEffortSecond() }
        pomodoro.$running.dropFirst().sink { [weak self] running in
            if !running { self?.flushEffort() }
        }.store(in: &cancellables)
    }

    // MARK: - Effort accrual

    private func accrueEffortSecond() {
        effortBuffer += 1
        if effortBuffer >= 5 { flushEffort() }   // batch writes
    }

    private func flushEffort() {
        guard effortBuffer > 0 else { return }
        let seconds = effortBuffer
        effortBuffer = 0
        let ids = (try? store.inProgressTaskIds()) ?? []
        guard !ids.isEmpty else { return }
        for id in ids { try? store.addEffort(toTaskId: id, seconds: seconds) }
        reloadTasks()
    }

    // MARK: - Reload

    func reloadAll() {
        projects = (try? store.listProjects()) ?? []
        if let sel = selectedProjectId, !projects.contains(where: { $0.id == sel }) {
            selectedProjectId = projects.first?.id
        }
        reloadTasks()
        reloadStats()
        if showDashboard { reloadDashboard() }
    }

    func reloadDashboard() {
        daySeries = (try? store.dailyStatsSeries(days: 7)) ?? []
        projectEfforts = (try? store.effortByProject()) ?? []
    }

    func reloadTasks() {
        let all = (try? store.listTasks(projectId: nil)) ?? []
        if let sv = smartView {
            tasks = sv == .inProgress ? all.filter { $0.status == .inProgress } : all
        } else if let pid = selectedProjectId {
            tasks = all.filter { $0.projectId == pid }
        } else {
            tasks = []
        }
        inProgressTasks = all.filter { $0.status == .inProgress }
        blockedTaskIds = Set((try? store.blockedTaskIds()) ?? [])
        syncDueReminders(all)
    }

    /// Keep local due-date notifications in sync with the current task set.
    /// Reconciles on every reload, so app edits and external (MCP) writes alike
    /// schedule/replace/cancel reminders without per-mutation bookkeeping.
    private func syncDueReminders(_ allTasks: [TodoTask]) {
        NotificationScheduler.shared.reconcile(
            tasks: allTasks,
            enabled: settings.notificationsEnabled,
            soundEnabled: settings.soundEnabled)
    }

    func reloadStats() {
        stats = (try? store.dailyStats()) ?? stats
    }

    func selectProject(_ id: Int64?) {
        showDashboard = false
        smartView = nil
        selectedProjectId = id
        selectedTaskIds = []
        searchQuery = ""
        reloadTasks()
    }

    func selectSmartView(_ v: SmartView) {
        showDashboard = false
        smartView = v
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        reloadTasks()
    }

    func selectDashboard() {
        showDashboard = true
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        reloadDashboard()
    }

    /// Case-insensitive match of a task against the current search query
    /// (title, detail, tags, code). Empty/whitespace query matches everything.
    func taskMatchesSearch(_ task: TodoTask) -> Bool {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if task.title.lowercased().contains(q) { return true }
        if task.detail.lowercased().contains(q) { return true }
        if task.code.lowercased().contains(q) { return true }
        if task.tags.contains(where: { $0.lowercased().contains(q) }) { return true }
        return false
    }

    /// Project code for a task id (used by smart views to label rows).
    func projectCode(for projectId: Int64) -> String {
        projects.first(where: { $0.id == projectId })?.code ?? ""
    }

    func history(forTask id: Int64) -> [TaskEvent] {
        (try? store.taskHistory(taskId: id)) ?? []
    }

    // MARK: - Project CRUD

    func addProject(name: String, detail: String = "") {
        guard let p = try? store.createProject(name: name, detail: detail) else { return }
        reloadAll()
        selectProject(p.id)
    }

    func renameProject(_ id: Int64, to name: String) {
        try? store.renameProject(id: id, name: name)
        reloadAll()
    }

    func updateProject(_ id: Int64, name: String? = nil, detail: String? = nil) {
        try? store.updateProject(id: id, name: name, detail: detail)
        reloadAll()
    }

    func deleteProject(_ id: Int64) {
        try? store.deleteProject(id: id)
        if selectedProjectId == id { selectedProjectId = nil }
        reloadAll()
    }

    // MARK: - Task CRUD

    func addTask(title: String) {
        guard let pid = selectedProjectId else { return }
        _ = try? store.createTask(projectId: pid, title: title)
        reloadTasks()
    }

    /// Add a subtask (one level of nesting) under a parent task.
    func addSubtask(title: String, parent: TodoTask) {
        _ = try? store.createTask(projectId: parent.projectId, title: title, parentId: parent.id)
        reloadTasks()
    }

    /// Toggle a subtask between done and todo (checkbox behavior).
    func toggleSubtaskDone(_ sub: TodoTask) {
        updateTask(sub, status: sub.status == .done ? .todo : .done)
    }

    func updateTask(_ task: TodoTask, title: String? = nil, detail: String? = nil, link: String?? = nil,
                    status: TaskStatus? = nil, priority: Priority? = nil, dueDate: Date?? = nil, tags: [String]? = nil,
                    recurrence: String?? = nil, estimateSeconds: Int? = nil) {
        try? store.updateTask(id: task.id, title: title, detail: detail, link: link, status: status,
                              priority: priority, dueDate: dueDate, tags: tags, recurrence: recurrence,
                              estimateSeconds: estimateSeconds)
        reloadTasks()
    }

    func cycleStatus(_ task: TodoTask) {
        let next: TaskStatus
        switch task.status {
        case .todo: next = .inProgress
        case .inProgress: next = .done
        case .done: next = .todo
        }
        updateTask(task, status: next)
    }

    func deleteTask(_ id: Int64) {
        try? store.deleteTask(id: id)
        reloadTasks()
    }

    /// Clone a task within its current project.
    func duplicateTask(_ id: Int64) {
        _ = try? store.duplicateTask(id: id)
        reloadTasks()
    }

    /// Copy a task into another project (original kept).
    func copyTask(_ id: Int64, toProject pid: Int64) {
        _ = try? store.duplicateTask(id: id, toProjectId: pid)
        reloadTasks()
    }

    /// Move a task to another project (transfer).
    func moveTask(_ id: Int64, toProject pid: Int64) {
        try? store.moveTask(id: id, toProjectId: pid)
        reloadTasks()
    }

    /// Reorder the displayed rows after a drag. `displayed` is the array the List is
    /// showing (top-level tasks in a project view; the flat list in a smart view), so
    /// offsets line up regardless of nesting.
    func moveTasks(_ displayed: [TodoTask], from offsets: IndexSet, to destination: Int) {
        var ordered = displayed
        ordered.move(fromOffsets: offsets, toOffset: destination)
        try? store.reorderTasks(orderedIds: ordered.map { $0.id })
        reloadTasks()
    }

    // MARK: - Dependencies (blocked-by)

    /// All tasks across every project (for dependency pickers).
    func allTasks() -> [TodoTask] {
        (try? store.listTasks(projectId: nil)) ?? []
    }

    /// Look up a task by id, preferring the loaded list, falling back to the store.
    func task(byId id: Int64) -> TodoTask? {
        tasks.first(where: { $0.id == id }) ?? (try? store.getTask(id: id))
    }

    /// The ids `taskId` is blocked by.
    func dependencies(of taskId: Int64) -> [Int64] {
        (try? store.dependencies(taskId: taskId)) ?? []
    }

    /// Add a blocked-by edge; surfaces store rejections (self/cycle) as a toast.
    func addDependency(_ taskId: Int64, dependsOn depId: Int64) {
        do {
            try store.addDependency(taskId: taskId, dependsOnId: depId)
            reloadTasks()
        } catch {
            flashToast("\(error)")
        }
    }

    func removeDependency(_ taskId: Int64, dependsOn depId: Int64) {
        try? store.removeDependency(taskId: taskId, dependsOnId: depId)
        reloadTasks()
    }

    // MARK: - Command actions (keyboard shortcuts)

    var selectedTask: TodoTask? { tasks.first(where: { $0.id == selectedTaskId }) }

    func toggleTimer() {
        if pomodoro.running { pomodoro.pause() } else { pomodoro.startFocus() }
    }

    /// Copy a code to the clipboard and flash a confirmation toast.
    func copyCode(_ code: String) {
        copyToClipboard(code)
        flashToast("Copied \(code)")
    }

    func flashToast(_ message: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { toast = message }
        toastSeq += 1
        let seq = toastSeq
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.toastSeq == seq else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }

    // Commands act on the whole selection (1 or many).
    func setStatusOnSelected(_ status: TaskStatus) { bulkSetStatus(status) }

    func duplicateSelected() {
        for id in selectedTaskIds { _ = try? store.duplicateTask(id: id) }
        reloadTasks()
    }

    func deleteSelected() { bulkDelete() }

    // MARK: - Bulk actions (operate on selectedTaskIds)

    private var selectionCount: Int { selectedTaskIds.count }

    func bulkSetStatus(_ status: TaskStatus) {
        for id in selectedTaskIds { try? store.updateTask(id: id, status: status) }
        reloadTasks()
        flashToast("Set \(selectionCount) to \(status.display)")
    }

    func bulkSetPriority(_ priority: Priority) {
        for id in selectedTaskIds { try? store.updateTask(id: id, priority: priority) }
        reloadTasks()
        flashToast("Set \(selectionCount) to \(priority.display) priority")
    }

    func bulkAddTags(_ tags: [String]) {
        guard !tags.isEmpty else { return }
        for id in selectedTaskIds { try? store.addTags(toTaskId: id, tags: tags) }
        reloadTasks()
        flashToast("Tagged \(selectionCount) tasks")
    }

    func bulkMove(toProject pid: Int64) {
        let n = selectionCount
        for id in selectedTaskIds { try? store.moveTask(id: id, toProjectId: pid) }
        selectedTaskIds = []
        reloadTasks()
        flashToast("Moved \(n) tasks")
    }

    func bulkCopy(toProject pid: Int64) {
        let n = selectionCount
        for id in selectedTaskIds { _ = try? store.duplicateTask(id: id, toProjectId: pid) }
        reloadTasks()
        flashToast("Copied \(n) tasks")
    }

    func bulkDelete() {
        let n = selectionCount
        for id in selectedTaskIds { try? store.deleteTask(id: id) }
        selectedTaskIds = []
        reloadTasks()
        flashToast("Deleted \(n) tasks")
    }

    // MARK: - Settings

    func saveSettings(_ s: PomodoroSettings) {
        settings = s
        pomodoro.settings = s
        try? store.saveSettings(s)
        // Toggling notifications/sound takes effect immediately for due reminders.
        syncDueReminders((try? store.listTasks(projectId: nil)) ?? [])
    }

    // MARK: - DB file watching (live reload on MCP writes)

    /// Poll the DB + WAL mtime; reload when an external process writes.
    /// WAL writes land in the -wal sidecar, so we watch both files.
    private func startWatching() {
        lastDBStamp = currentDBStamp()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForExternalChanges() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    private func currentDBStamp() -> TimeInterval {
        let fm = FileManager.default
        let paths = [store.dbURL.path, store.dbURL.path + "-wal"]
        var newest: TimeInterval = 0
        for p in paths {
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let m = attrs[.modificationDate] as? Date {
                newest = max(newest, m.timeIntervalSince1970)
            }
        }
        return newest
    }

    private func checkForExternalChanges() {
        let stamp = currentDBStamp()
        if stamp > lastDBStamp {
            lastDBStamp = stamp
            reloadAll()
        }
    }
}
