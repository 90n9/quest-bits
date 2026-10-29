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

    /// True when the view pre-filters tasks to a single status. The kanban board
    /// is meaningless here (only one of its columns can ever populate), so
    /// the board toggle is suppressed for these views.
    var isSingleStatus: Bool { self == .inProgress }
}

/// A pending blocked-task confirmation surfaced by a single app-level alert.
/// Any call site that would move a blocked task to In Progress stashes one of
/// these on the model instead of owning its own alert, so the confirm-then-proceed
/// UX is identical across the list, board, bulk bar, and menu.
struct BlockedConfirm: Identifiable {
    let id = UUID()
    let message: String
    let onConfirm: () -> Void
    var onCancel: (() -> Void)? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var tasks: [TodoTask] = []          // tasks for the selected project
    @Published var selectedProjectId: Int64?
    @Published var selectedTaskIds: Set<Int64> = [] {
        didSet { if selectedTaskId != notesTaskId { reloadNotes() } }
    }
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

    // Non-nil while an app-level blocked-task confirmation is on screen. Set by any
    // path that tries to move a blocked task to In Progress; presented once by the root.
    @Published var blockedConfirm: BlockedConfirm?

    // Reusable task templates (managed via the Templates sheet + MCP).
    @Published var templates: [TaskTemplate] = []

    // Stats dashboard: when shown, the content column swaps to the dashboard.
    @Published var showDashboard = false
    @Published var daySeries: [DayStat] = []
    @Published var projectEfforts: [ProjectEffort] = []

    /// The single selected task id, or nil when zero or multiple are selected.
    var selectedTaskId: Int64? { selectedTaskIds.count == 1 ? selectedTaskIds.first : nil }

    /// Whether the kanban board is offered for the current view. The board needs all
    /// its status columns to be meaningful, so it is suppressed in single-status
    /// smart views (which pre-filter tasks to one status). Available in project views
    /// and multi-status smart views (e.g. All Tasks).
    var boardAvailable: Bool {
        if let sv = smartView { return !sv.isSingleStatus }
        return true
    }
    @Published var stats: DailyStats = DailyStats(date: "", completedPomodoros: 0, totalFocusSeconds: 0)
    @Published var settings: PomodoroSettings = .standard

    // Set by menu commands; views observe these to open their create sheets.
    @Published var pendingNewProject = false
    @Published var pendingNewTask = false

    // Notes of the single selected task, newest first: the latest `notesLimit` of them.
    // Loaded on selection change and on every task reload (app writes and MCP polls),
    // republished only when they changed.
    @Published private(set) var selectedTaskNotes: [TaskNote] = []
    @Published private(set) var hasOlderNotes = false
    private var notesTaskId: Int64?
    private var notesLimit = AppModel.notesPage
    static let notesPage = 20

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
        templates = (try? store.listTemplates()) ?? []
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
        reloadNotes()
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

    /// Refresh `selectedTaskNotes` for the selected task. A different task starts again
    /// from the first page. One extra row tells whether older notes exist. On a read
    /// error the shown notes are kept and a toast says so.
    private func reloadNotes() {
        let id = selectedTaskId
        if id != notesTaskId { notesTaskId = id; notesLimit = Self.notesPage }
        guard let id else {
            if !selectedTaskNotes.isEmpty { selectedTaskNotes = [] }
            if hasOlderNotes { hasOlderNotes = false }
            return
        }
        do {
            let rows = try store.notes(taskId: id, limit: notesLimit + 1)
            let page = Array(rows.prefix(notesLimit)), older = rows.count > notesLimit
            if page != selectedTaskNotes { selectedTaskNotes = page }
            if older != hasOlderNotes { hasOlderNotes = older }
        } catch {
            flashToast("Couldn't load notes: \(error)")
        }
    }

    /// Show the next page of older notes for the selected task.
    func showOlderNotes() {
        notesLimit += Self.notesPage
        reloadNotes()
    }

    /// Append a note to a task. Returns false (with a toast) if the store rejected it.
    @discardableResult
    func addNote(_ task: TodoTask, text: String, kind: NoteKind) -> Bool {
        do {
            try store.addNote(taskId: task.id, text: text, kind: kind)
        } catch {
            flashToast("Couldn't add a note to \(task.code): \(error)")
            return false
        }
        reloadTasks()   // the note bumped updated_at; reloads the notes too
        return true
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

    /// Toggle a subtask between done and todo (checkbox behavior). A dropped subtask
    /// reopens to todo, like a done one.
    func toggleSubtaskDone(_ sub: TodoTask) {
        updateTask(sub, status: sub.status.isClosed ? .todo : .done)
    }

    /// Moving to Waiting without saying on whom keeps the task's current `waitingOn`,
    /// else defaults to the user — the store rejects a waiting task with neither.
    func updateTask(_ task: TodoTask, title: String? = nil, detail: String? = nil, link: String?? = nil,
                    status: TaskStatus? = nil, priority: Priority? = nil, dueDate: Date?? = nil, tags: [String]? = nil,
                    recurrence: String?? = nil, estimateSeconds: Int? = nil,
                    waitingOn: WaitingOn? = nil, waitingReason: String?? = nil) {
        let on = status == .waiting ? (waitingOn ?? task.waitingOn ?? .user) : waitingOn
        do {
            try store.updateTask(id: task.id, title: title, detail: detail, link: link, status: status,
                                 priority: priority, dueDate: dueDate, tags: tags, recurrence: recurrence,
                                 estimateSeconds: estimateSeconds, waitingOn: on, waitingReason: waitingReason)
        } catch {
            flashToast("Couldn't save \(task.code): \(error)")
        }
        reloadTasks()
    }

    func cycleStatus(_ task: TodoTask) {
        let next: TaskStatus
        switch task.status {
        case .todo: next = .inProgress
        case .inProgress: next = .done
        case .waiting: next = .inProgress   // the wait is over: resume work
        case .done, .dropped: next = .todo   // reopen
        }
        setStatus(task, to: next)
    }

    /// Shared blocked-guard decision: true iff moving these tasks to `status` should
    /// prompt for confirmation — i.e. the target is In Progress and at least one task
    /// has an unfinished dependency. Marking Done is never guarded.
    func blockedConfirmNeeded(forIds ids: [Int64], to status: TaskStatus) -> Bool {
        !blockedForConfirm(ids, to: status).isEmpty
    }

    /// The ids behind `blockedConfirmNeeded`: those with an open dependency when the
    /// target is In Progress, else none. Callers that also need the count use this.
    private func blockedForConfirm(_ ids: [Int64], to status: TaskStatus) -> Set<Int64> {
        status == .inProgress ? idsWithOpenDependency(ids) : []
    }

    /// Which of `ids` have an unfinished dependency, whatever their own status. Not
    /// `blockedTaskIds`: a done task is never reported blocked, but reopening it into
    /// In Progress while a dependency is open should still prompt.
    private func idsWithOpenDependency(_ ids: [Int64]) -> Set<Int64> {
        (try? store.idsWithOpenDependency(ids)) ?? []
    }

    /// Move a single task to `status`, routing through the blocked guard. If the task
    /// is blocked and the target is In Progress, stashes a confirmation (advisory —
    /// the user can proceed); otherwise applies immediately.
    func setStatus(_ task: TodoTask, to status: TaskStatus) {
        if blockedConfirmNeeded(forIds: [task.id], to: status) {
            blockedConfirm = BlockedConfirm(
                message: "This task is blocked by an unfinished dependency. Move it to In Progress anyway?",
                onConfirm: { [weak self] in self?.updateTask(task, status: status) })
        } else {
            updateTask(task, status: status)
        }
    }

    func deleteTask(_ id: Int64) {
        try? store.deleteTask(id: id)
        reloadTasks()
    }

    /// Clone a task within its current project (a fresh todo).
    func duplicateTask(_ id: Int64) {
        _ = try? store.duplicateTask(id: id)
        reloadTasks()
    }

    /// Copy a task into another project (original kept), status and times included.
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

    // MARK: - Templates

    func reloadTemplates() {
        templates = (try? store.listTemplates()) ?? []
    }

    func addTemplate(name: String, title: String, detail: String = "", priority: Priority = .none,
                     tags: [String] = [], estimateSeconds: Int = 0) {
        _ = try? store.createTemplate(name: name, title: title, detail: detail,
                                      priority: priority, tags: tags, estimateSeconds: estimateSeconds)
        reloadTemplates()
    }

    func deleteTemplate(_ id: Int64) {
        try? store.deleteTemplate(id: id)
        reloadTemplates()
    }

    /// Instantiate a template into a project. Selects the new task when its project
    /// is the one on screen, and flashes a confirmation toast.
    func newTaskFromTemplate(_ templateId: Int64, intoProject pid: Int64) {
        guard let task = try? store.instantiateTemplate(id: templateId, intoProjectId: pid) else { return }
        reloadTasks()
        if smartView == nil && selectedProjectId == pid { selectedTaskIds = [task.id] }
        flashToast("Added \(task.code)")
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
    func setStatusOnSelected(_ status: TaskStatus, waitingOn: WaitingOn? = nil) {
        bulkSetStatus(status, waitingOn: waitingOn)
    }

    func duplicateSelected() {
        for id in selectedTaskIds { _ = try? store.duplicateTask(id: id) }
        reloadTasks()
    }

    func deleteSelected() { bulkDelete() }

    // MARK: - Bulk actions (operate on selectedTaskIds)

    private var selectionCount: Int { selectedTaskIds.count }

    /// `waitingOn` applies only to Waiting; without it the tasks wait on the user.
    func bulkSetStatus(_ status: TaskStatus, waitingOn: WaitingOn? = nil) {
        let ids = Array(selectedTaskIds)
        let blockedIds = blockedForConfirm(ids, to: status)
        if !blockedIds.isEmpty {
            let blocked = blockedIds.count
            let noun = blocked == 1 ? "task is" : "tasks are"
            blockedConfirm = BlockedConfirm(
                message: "\(blocked) selected \(noun) blocked by an unfinished dependency. Move to In Progress anyway?",
                onConfirm: { [weak self] in self?.performBulkSetStatus(status, waitingOn: waitingOn, ids: ids) })
        } else {
            performBulkSetStatus(status, waitingOn: waitingOn, ids: Array(selectedTaskIds))
        }
    }

    /// One all-or-nothing store write: on failure no task changes and the toast says why.
    private func performBulkSetStatus(_ status: TaskStatus, waitingOn: WaitingOn?, ids: [Int64]) {
        let on = status == .waiting ? (waitingOn ?? .user) : nil
        do {
            try store.bulkUpdateTasks(ids: ids, status: status, waitingOn: on)
            let label = on.map { "Waiting on \(qbWaitingOnLabel($0))" } ?? status.display
            flashToast("Set \(ids.count) to \(label)")
        } catch {
            flashToast("Couldn't set status: \(error)")
        }
        reloadTasks()
    }

    func bulkSetPriority(_ priority: Priority) {
        for id in selectedTaskIds { try? store.updateTask(id: id, priority: priority) }
        reloadTasks()
        flashToast("Set \(selectionCount) to \(priority.display) priority")
    }

    func bulkAddTags(_ tags: [String]) {
        guard !tags.isEmpty else { return }
        do {
            try store.bulkUpdateTasks(ids: Array(selectedTaskIds), addTags: tags)
            flashToast("Tagged \(selectionCount) tasks")
        } catch {
            flashToast("Couldn't tag: \(error)")
        }
        reloadTasks()
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
