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

    /// Per-project task counts for the sidebar rows, refreshed with the tasks (and so
    /// with every poll). A project with no tasks has no entry.
    @Published private(set) var projectCounts: [Int64: ProjectCounts] = [:]

    // Non-nil while an app-level blocked-task confirmation is on screen. Set by any
    // path that tries to move a blocked task to In Progress; presented once by the root.
    @Published var blockedConfirm: BlockedConfirm?

    // Reusable task templates (managed via the Templates sheet + MCP).
    @Published var templates: [TaskTemplate] = []

    // Stats dashboard: when shown, the content column swaps to the dashboard.
    @Published var showDashboard = false
    // Questions page (ask loop): when shown, the content column lists open questions and
    // the detail column answers the selected one.
    @Published var showQuestions = false
    @Published var selectedQuestionId: Int64?
    /// Open questions in projects not archived, longest waiting first; refreshed with the
    /// tasks (so with every poll), republished only when they changed.
    @Published private(set) var openQuestions: [Question] = []
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
    // Loaded on selection change and with every task reload (an app edit, or the poll
    // seeing an external write, may add notes or history); republished only when changed.
    @Published private(set) var selectedTaskNotes: [TaskNote] = []
    @Published private(set) var hasOlderNotes = false
    // The rest of the selected task's timeline, loaded with its notes: the change history
    // and every question asked on it (by id, for the question notes).
    @Published private(set) var selectedTaskEvents: [TaskEvent] = []
    @Published private(set) var selectedTaskQuestions: [Int64: Question] = [:]
    private var notesTaskId: Int64?
    private var notesLimit = AppModel.notesPage
    static let notesPage = 20
    // The last notes read error toasted, so a lasting failure toasts once, not on every reload.
    private var notesErrorShown: (taskId: Int64, error: String)?

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
        if selectedProjectId == nil { selectedProjectId = (activeProjects.first ?? projects.first)?.id }
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
        reloadTasks(timeline: false)   // effort is not on the timeline
    }

    // MARK: - Reload

    func reloadAll() {
        projects = (try? store.listProjects()) ?? []
        templates = (try? store.listTemplates()) ?? []
        if let sel = selectedProjectId, !projects.contains(where: { $0.id == sel }) {
            selectedProjectId = (activeProjects.first ?? projects.first)?.id
        }
        reloadTasks()
        reloadStats()
        if showDashboard { reloadDashboard() }
    }

    func reloadDashboard() {
        daySeries = (try? store.dailyStatsSeries(days: 7)) ?? []
        projectEfforts = (try? store.effortByProject()) ?? []
    }

    /// `timeline` false skips the selected task's notes / history / questions, for a write
    /// that cannot change them (the effort flush every few seconds while a timer runs).
    func reloadTasks(timeline: Bool = true) {
        let all = (try? store.listTasks(projectId: nil)) ?? []
        // Cross-project views (smart views, menu bar) leave out archived projects; a
        // selected project shows in full, archived or not. Due-date reminders still cover
        // every task. Filtered here from `all` so the task table is read once per reload;
        // the rule is `Project.isArchived`, the one Store.activeProjectSQL /
        // activeProjectJoinSQL apply in SQL for MCP — change them together.
        let archived = Set(archivedProjects.map(\.id))
        let active = archived.isEmpty ? all : all.filter { !archived.contains($0.projectId) }
        if let sv = smartView {
            tasks = sv == .inProgress ? active.filter { $0.status == .inProgress } : active
        } else if let pid = selectedProjectId {
            tasks = all.filter { $0.projectId == pid }
        } else {
            tasks = []
        }
        // Drop selected tasks that are gone (e.g. deleted over MCP), so the all-or-nothing
        // bulk actions don't keep failing on a task the user can no longer see.
        let shown = Set(tasks.map(\.id))
        let kept = selectedTaskIds.filter(shown.contains)
        if kept != selectedTaskIds { selectedTaskIds = kept }
        inProgressTasks = active.filter { $0.status == .inProgress }
        blockedTaskIds = Set((try? store.blockedTaskIds()) ?? [])
        // Publish only on a change: most polls and effort flushes leave the counts as
        // they were, and the sidebar needn't redraw.
        let counts = ProjectCounts.byProject(all)
        if counts != projectCounts { projectCounts = counts }
        syncDueReminders(all)
        reloadQuestions()
        if timeline { reloadNotes() }
    }

    /// Refresh the open questions; drop a selection that is no longer open (answered
    /// here, or withdrawn by the agent) for the next one in line.
    func reloadQuestions() {
        let open = (try? store.questions(statuses: [.open], activeOnly: true)) ?? openQuestions
        if open != openQuestions { openQuestions = open }
        if showQuestions, selectedQuestionId.map({ id in !open.contains { $0.id == id } }) ?? true {
            selectedQuestionId = open.first?.id
        }
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
        showQuestions = false
        smartView = nil
        selectedProjectId = id
        selectedTaskIds = []
        searchQuery = ""
        reloadTasks()
    }

    func selectSmartView(_ v: SmartView) {
        showDashboard = false
        showQuestions = false
        smartView = v
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        reloadTasks()
    }

    func selectDashboard() {
        showDashboard = true
        showQuestions = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        reloadDashboard()
    }

    func selectQuestions() {
        showQuestions = true
        showDashboard = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        selectedQuestionId = nil
        reloadQuestions()
    }

    /// The question after `id` in the list (wrapping), or nil when it is the only one.
    func questionAfter(_ id: Int64) -> Int64? {
        guard let i = openQuestions.firstIndex(where: { $0.id == id }), openQuestions.count > 1 else { return nil }
        return openQuestions[(i + 1) % openQuestions.count].id
    }

    /// Answer a question from the Questions page; on success select the next one.
    /// Returns false (with a toast) if the store rejected it, e.g. the agent withdrew it.
    @discardableResult
    func answerQuestion(_ q: Question, answer: String, choice: Int?) -> Bool {
        let next = questionAfter(q.id)
        do {
            try store.answerQuestion(id: q.id, answer: answer, choice: choice)
        } catch {
            flashToast("Couldn't answer \(q.taskCode): \(error)")
            reloadQuestions()
            return false
        }
        selectedQuestionId = next
        reloadTasks()   // the task may have left waiting; reloads the questions and notes
        flashToast("Answered \(q.taskCode)")
        return true
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

    /// Projects not archived, in sidebar order (also the move/copy targets).
    var activeProjects: [Project] { projects.filter { !$0.isArchived } }

    /// Archived projects, in sidebar order (the collapsed "Archived" group).
    var archivedProjects: [Project] { projects.filter(\.isArchived) }

    /// A project is on screen and takes new tasks (an archived one doesn't).
    var canAddTask: Bool {
        guard let pid = selectedProjectId else { return false }
        return canAddTask(to: pid)
    }

    /// The project takes new tasks and subtasks: it is not archived (the store refuses those).
    func canAddTask(to projectId: Int64) -> Bool {
        !archivedProjects.contains { $0.id == projectId }
    }

    /// Project code for a task id (used by smart views to label rows).
    func projectCode(for projectId: Int64) -> String {
        projects.first(where: { $0.id == projectId })?.code ?? ""
    }


    /// Refresh `selectedTaskNotes` for the selected task. A different task starts again
    /// from the first page. One extra row tells whether older notes exist. On a read
    /// error a toast says so, once per task and error; the shown notes are kept only when
    /// they belong to the same task.
    private func reloadNotes() {
        let id = selectedTaskId
        let switched = id != notesTaskId
        if switched { notesTaskId = id; notesLimit = Self.notesPage }
        guard let id else {
            if !selectedTaskNotes.isEmpty { selectedTaskNotes = [] }
            if hasOlderNotes { hasOlderNotes = false }
            if !selectedTaskEvents.isEmpty { selectedTaskEvents = [] }
            if !selectedTaskQuestions.isEmpty { selectedTaskQuestions = [:] }
            return
        }
        do {
            let rows = try store.notes(taskId: id, limit: notesLimit + 1)
            let events = try store.taskHistory(taskId: id)
            let questions = Dictionary(uniqueKeysWithValues: try store.questions(
                statuses: QuestionStatus.allCases, taskId: id).map { ($0.id, $0) })
            let page = Array(rows.prefix(notesLimit)), older = rows.count > notesLimit
            if page != selectedTaskNotes { selectedTaskNotes = page }
            if older != hasOlderNotes { hasOlderNotes = older }
            if events != selectedTaskEvents { selectedTaskEvents = events }
            if questions != selectedTaskQuestions { selectedTaskQuestions = questions }
            notesErrorShown = nil
        } catch {
            if switched {
                if !selectedTaskNotes.isEmpty { selectedTaskNotes = [] }
                if hasOlderNotes { hasOlderNotes = false }
                if !selectedTaskEvents.isEmpty { selectedTaskEvents = [] }
                if !selectedTaskQuestions.isEmpty { selectedTaskQuestions = [:] }
            }
            let message = "\(error)"
            guard notesErrorShown?.taskId != id || notesErrorShown?.error != message else { return }
            notesErrorShown = (id, message)
            flashToast("Couldn't load notes: \(message)")
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
            try store.addNote(taskId: task.id, text: text, kind: kind, author: .user)
        } catch {
            flashToast("Couldn't add a note to \(task.code): \(error)")
            return false
        }
        reloadTasks()   // the note bumped updated_at; reloads the notes
        return true
    }

    /// Replace the text of the user's own note (earlier text is kept). Returns false
    /// (with a toast) if the store rejected it.
    @discardableResult
    func editNote(_ note: TaskNote, text: String) -> Bool {
        do {
            try store.editNote(id: note.id, text: text)
        } catch {
            flashToast("Couldn't edit the note: \(error)")
            return false
        }
        reloadTasks()   // reloads the notes
        return true
    }

    /// Save the Detail of a task that is no longer the one in the detail column: an editor
    /// change that arrived after the user moved on. Toasts on failure.
    func saveDetail(taskId: Int64, markdown: String) {
        do {
            try store.updateTask(id: taskId, detail: markdown)
        } catch {
            flashToast("Couldn't save the detail of a task you left: \(error)")
            return
        }
        reloadTasks()
    }

    /// A note's earlier texts, newest first (empty on a read error).
    func noteEdits(_ note: TaskNote) -> [NoteEdit] {
        (try? store.noteEdits(noteId: note.id)) ?? []
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

    /// Archive or unarchive a project. It stays selected (an archived project is still
    /// viewable); a failed write surfaces as a toast.
    func setArchived(_ id: Int64, _ archived: Bool) {
        do {
            try store.setProjectArchived(id: id, archived: archived)
        } catch {
            flashToast("Couldn't \(archived ? "archive" : "unarchive") project: \(error)")
        }
        reloadAll()
    }

    /// Reorder the active projects after a sidebar drag (offsets index `activeProjects`).
    /// The order is written synchronously on the drop and read back in the same call, so
    /// no poll can reload the old order in between; on a failed write the reload shows
    /// the stored order. The poll stamp is taken before the reload: this write doesn't
    /// trigger a second one, and a write by an agent after it still does.
    func moveProjects(from offsets: IndexSet, to destination: Int) {
        var ordered = activeProjects
        ordered.move(fromOffsets: offsets, toOffset: destination)
        do {
            try store.reorderProjects(ids: ordered.map(\.id))
        } catch {
            flashToast("Couldn't reorder projects: \(error)")
        }
        lastDBStamp = currentDBStamp()
        reloadAll()
    }

    func deleteProject(_ id: Int64) {
        try? store.deleteProject(id: id)
        if selectedProjectId == id { selectedProjectId = nil }
        reloadAll()
    }

    // MARK: - Task CRUD

    /// A failed create (e.g. into an archived project) surfaces as a toast.
    func addTask(title: String) {
        guard let pid = selectedProjectId else { return }
        do {
            try store.createTask(projectId: pid, title: title)
        } catch {
            flashToast("Couldn't add the task: \(error)")
        }
        reloadTasks()
    }

    /// Add a subtask (one level of nesting) under a parent task.
    func addSubtask(title: String, parent: TodoTask) {
        do {
            try store.createTask(projectId: parent.projectId, title: title, parentId: parent.id)
        } catch {
            flashToast("Couldn't add a subtask to \(parent.code): \(error)")
        }
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
        do {
            try store.deleteTask(id: id)
        } catch {
            flashToast("Couldn't delete: \(error)")
        }
        reloadTasks()
    }

    /// Clone a task within its current project (a fresh todo).
    func duplicateTask(_ id: Int64) {
        do {
            _ = try store.duplicateTask(id: id)
        } catch {
            flashToast("Couldn't duplicate: \(error)")
        }
        reloadTasks()
    }

    /// Copy a task into another project (original kept), status and times included.
    func copyTask(_ id: Int64, toProject pid: Int64) {
        do {
            _ = try store.duplicateTask(id: id, toProjectId: pid)
        } catch {
            flashToast("Couldn't copy: \(error)")
        }
        reloadTasks()
    }

    /// Move a task to another project (transfer).
    func moveTask(_ id: Int64, toProject pid: Int64) {
        do {
            try store.moveTask(id: id, toProjectId: pid)
        } catch {
            flashToast("Couldn't move: \(error)")
        }
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
        let task: TodoTask
        do {
            task = try store.instantiateTemplate(id: templateId, intoProjectId: pid)
        } catch {
            flashToast("Couldn't add the task: \(error)")
            return
        }
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

    /// One all-or-nothing store write: on failure no copy is made and the toast says why.
    func duplicateSelected() {
        guard !selectedTaskIds.isEmpty else { return }
        do {
            try store.bulkDuplicateTasks(ids: orderedSelection)
            flashToast("Duplicated \(selectionCount) \(selectionCount == 1 ? "task" : "tasks")")
        } catch {
            flashToast("Couldn't duplicate: \(error)")
        }
        reloadTasks()
    }

    func deleteSelected() { bulkDelete() }

    // MARK: - Bulk actions (operate on selectedTaskIds)

    private var selectionCount: Int { selectedTaskIds.count }

    /// The selection in list order, so copies get codes and positions in the order shown.
    private var orderedSelection: [Int64] {
        tasks.map(\.id).filter(selectedTaskIds.contains)
    }

    /// `waitingOn` applies only to Waiting; without it each task keeps whom it waits on,
    /// and a task waiting on no one waits on the user.
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
        // Like the single-task path: without a who, each task keeps its own, and one
        // waiting on no one waits on the user.
        let on = status == .waiting ? waitingOn : nil
        do {
            try store.bulkUpdateTasks(ids: ids, status: status, waitingOn: on, waitingOnDefault: .user)
            let label = on.map { "Waiting on \(qbWaitingOnLabel($0))" } ?? status.display
            flashToast("Set \(ids.count) to \(label)")
        } catch {
            flashToast("Couldn't set status: \(error)")
        }
        reloadTasks()
    }

    /// One all-or-nothing store write, like bulkAddTags.
    func bulkSetPriority(_ priority: Priority) {
        do {
            try store.bulkUpdateTasks(ids: Array(selectedTaskIds), priority: priority)
            flashToast("Set \(selectionCount) to \(priority.display) priority")
        } catch {
            flashToast("Couldn't set priority: \(error)")
        }
        reloadTasks()
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

    /// One all-or-nothing store write: on failure no task moves and the toast says why
    /// (the selection is kept, so the user can pick another project).
    func bulkMove(toProject pid: Int64) {
        do {
            try store.bulkMoveTasks(ids: Array(selectedTaskIds), toProjectId: pid, copy: false)
            flashToast("Moved \(selectionCount) tasks")
            selectedTaskIds = []
        } catch {
            flashToast("Couldn't move: \(error)")
        }
        reloadTasks()
    }

    /// One all-or-nothing store write, like bulkMove.
    func bulkCopy(toProject pid: Int64) {
        do {
            try store.bulkMoveTasks(ids: orderedSelection, toProjectId: pid, copy: true)
            flashToast("Copied \(selectionCount) tasks")
        } catch {
            flashToast("Couldn't copy: \(error)")
        }
        reloadTasks()
    }

    /// One all-or-nothing store write: on failure no task is deleted, the selection is
    /// kept and the toast says why (e.g. the MCP server holding the write lock).
    func bulkDelete() {
        guard !selectedTaskIds.isEmpty else { return }
        let n = selectionCount
        do {
            try store.bulkDeleteTasks(ids: Array(selectedTaskIds))
            selectedTaskIds = []
            flashToast("Deleted \(n) \(n == 1 ? "task" : "tasks")")
        } catch {
            flashToast("Couldn't delete: \(error)")
        }
        reloadTasks()
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
            reloadAll()   // reloads the selected task's notes too: an agent may have added one
        }
    }
}
