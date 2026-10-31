import Foundation
import Combine
import SwiftUI

/// Top-level observable state for the app. Wraps the shared Store and watches the DB
/// file for external (MCP) writes.
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

    // In-progress tasks across all projects (the dashboard's count).
    // Refreshed alongside the displayed task list so it tracks status changes.
    @Published var inProgressTasks: [TodoTask] = []
    /// What is being worked on now, in projects not archived: In Progress tasks, and To Do
    /// tasks an agent holds a live claim on (next_task / claim_task). Live claims first,
    /// then the latest changed. The menu bar's "working" count and list; a waiting task
    /// counts under `waitingOnYou` (or waits on someone else), not here. Republished only
    /// when it changed.
    @Published private(set) var workingTasks: [TodoTask] = []
    // When the first live claim among `workingTasks` runs out: a claim expires without a
    // DB write, so the poll drops it then, from the list already read.
    private var nextClaimExpiry: Date?

    // Ids of tasks currently blocked by an unfinished dependency (for the 🔒 badge).
    // Recomputed alongside the displayed task list.
    @Published var blockedTaskIds: Set<Int64> = []
    // Open tasks that block open tasks, and how many (the list's "blocks others" mark).
    @Published private(set) var blockingCounts: [Int64: Int] = [:]

    /// Per-project task counts for the sidebar rows, refreshed with the tasks (and so
    /// with every poll). A project with no tasks has no entry.
    @Published private(set) var projectCounts: [Int64: ProjectCounts] = [:]
    /// Every project's milestones with their task counts (closed ones too), in order,
    /// refreshed with the tasks.
    @Published private(set) var milestones: [Milestone] = []

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
    /// Archived page: the content column lists archived projects to find and unarchive.
    @Published var showArchived = false
    /// "Waiting on you" page: the content column lists what needs the user (sessions at a
    /// terminal, open questions, tasks waiting on the user); the detail acts on the selection.
    @Published var showInbox = false
    @Published var inboxSelection: InboxItemID?
    /// Activity page: the content column lists what was done (task changes, notes, wiki
    /// edits), newest first, a row per run of one actor's entries on one task or page; the
    /// detail column shows the selected row's entries. Filters: project, day, who.
    @Published var showActivity = false
    @Published var activityProjectId: Int64? { didSet { if activityProjectId != oldValue { reloadActivity(resetLimit: true) } } }
    @Published var activityDay: ActivityDay = .any { didSet { if activityDay != oldValue { reloadActivity(resetLimit: true) } } }
    @Published var activityWho: ActivityWho = .everyone { didSet { if activityWho != oldValue { regroupActivity() } } }
    @Published private(set) var activityGroups: [ActivityGroup] = []
    /// Whether older entries than those read may exist (the read hit its limit).
    @Published private(set) var activityHasMore = false
    @Published var activitySelection: ActivityGroup.ID?
    private var activityEvents: [ActivityEvent] = []
    /// Decisions page (QUE-39): the decisions agents recorded on their own, newest first,
    /// with Mark as Seen and Disagree. Filters: project, day, all / new / disagreed.
    /// `newDecisionCount` (the sidebar badge) is refreshed with the questions; it is not
    /// part of Waiting on you.
    @Published var showDecisions = false
    @Published var decisionsProjectId: Int64? { didSet { if decisionsProjectId != oldValue { reloadDecisions() } } }
    @Published var decisionsDay: ActivityDay = .any { didSet { if decisionsDay != oldValue { reloadDecisions() } } }
    @Published var decisionsShow: DecisionShow = .all { didSet { if decisionsShow != oldValue { reloadDecisions() } } }
    @Published private(set) var decisions: [AgentDecision] = []
    @Published var decisionSelection: AgentDecision.ID?
    @Published private(set) var newDecisionCount = 0
    static let decisionsShown = 500
    private var activityLimit = AppModel.activityPage
    static let activityPage = 300
    /// What waits on the user now, refreshed with the questions (so with every poll) and
    /// republished only when it changed. `waitingOnYou.count` is the one count of it: the
    /// sidebar badge, and what the menu bar and notifications show.
    @Published private(set) var waitingOnYou = WaitingOnYou()
    // The parts it was built from, to drop a session whose process ended (no DB write
    // says so) without reading the DB again.
    private var inboxTasks: [InboxTask] = []
    private var attentionSessions: [AgentSession] = []
    // What was seen waiting so far, to notify only about what is new (QUE-26).
    private var waitingWatch = WaitingWatch()
    /// Open questions in projects not archived, longest waiting first; refreshed with the
    /// tasks (so with every poll), republished only when they changed.
    @Published private(set) var openQuestions: [Question] = []
    /// Claude Code sessions seen in the last week, plus older ones an open or answered
    /// question came from; last seen first. Refreshed with the questions.
    @Published private(set) var agentSessions: [AgentSession] = []
    /// The tab shown for the selected project; back to Tasks when another project is picked.
    @Published var projectTab: ProjectTab = .tasks
    /// The selected project's wiki (its Wiki tab): pages in full, the decision notes of its
    /// tasks, the selection, and the search typed above the list. Loaded only while the
    /// tab shows.
    @Published private(set) var wikiPages: [ProjectPage] = []
    @Published private(set) var wikiDecisionNotes: [NoteSearchHit] = []
    @Published var wikiSelection: WikiItem?
    @Published var wikiQuery = "" { didSet { if wikiQuery != oldValue { reloadWiki() } } }
    @Published var daySeries: [DayStat] = []

    /// The single selected task id, or nil when zero or multiple are selected.
    var selectedTaskId: Int64? { selectedTaskIds.count == 1 ? selectedTaskIds.first : nil }

    /// The project page is shown (not a smart view, the dashboard or the Questions page),
    /// so its tabs are.
    var selectedProject: Project? {
        guard smartView == nil, !showDashboard, !showQuestions, !showArchived, !showInbox, !showActivity,
              !showDecisions, let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    /// The tab of the project page, or nil when no project page is shown.
    var shownProjectTab: ProjectTab? { selectedProject == nil ? nil : projectTab }

    /// The questions the Questions page, or the project's Questions tab, lists.
    var shownQuestions: [Question] { questionsShown(in: openQuestions) }

    private func questionsShown(in open: [Question]) -> [Question] {
        guard shownProjectTab == .questions, let code = selectedProject?.code else { return open }
        return open.filter { $0.projectCode == code }
    }

    /// Whether the kanban board is offered for the current view. The board needs all
    /// its status columns to be meaningful, so it is suppressed in single-status
    /// smart views (which pre-filter tasks to one status). Available in project views
    /// and multi-status smart views (e.g. All Tasks).
    var boardAvailable: Bool {
        if let sv = smartView { return !sv.isSingleStatus }
        return true
    }
    @Published var settings: AppSettings = .standard

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
    // The selected task's links, oldest first (loaded with its notes).
    @Published private(set) var selectedTaskLinks: [TaskLink] = []
    // The selected task's relations, by kind (loaded with its notes).
    @Published private(set) var selectedTaskRelations = RelatedTasks()
    private var notesTaskId: Int64?
    private var notesLimit = AppModel.notesPage
    static let notesPage = 20
    // The last notes read error toasted, so a lasting failure toasts once, not on every reload.
    private var notesErrorShown: (taskId: Int64, error: String)?

    // Transient confirmation toast (e.g. after copying a code).
    @Published var toast: String?
    private var toastSeq = 0

    let store: Store

    private var watchTimer: Timer?
    private var lastDBStamp: TimeInterval = 0

    init() {
        // App + MCP share the default DB location.
        let store = (try? Store()) ?? { fatalError("cannot open store") }()
        store.origin = ChangeOrigin(.app)   // every change made here is the user's
        self.store = store
        self.settings = (try? store.loadSettings()) ?? .standard
        reloadAll()
        if selectedProjectId == nil { selectedProjectId = (activeProjects.first ?? projects.first)?.id }
        reloadTasks()
        startWatching()
    }

    // MARK: - Reload

    func reloadAll() {
        projects = (try? store.listProjects()) ?? []
        templates = (try? store.listTemplates()) ?? []
        if let sel = selectedProjectId, !projects.contains(where: { $0.id == sel }) {
            selectedProjectId = (activeProjects.first ?? projects.first)?.id
            projectTab = .tasks
            // As selectProject does: the gone project's wiki search must not carry over.
            wikiSelection = nil
            wikiQuery = ""
        }
        reloadTasks()
        if showDashboard { reloadDashboard() }
        if showActivity { reloadActivity() }
        if showDecisions { reloadDecisions() }
        reloadWiki()
    }

    func reloadDashboard() {
        daySeries = (try? store.dailyStatsSeries(days: 7)) ?? []
    }

    /// `timeline` false skips the selected task's notes / history / questions, for a write
    /// that cannot change them.
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
        setWorking(active)
        blockedTaskIds = Set((try? store.blockedTaskIds()) ?? [])
        let blocking = (try? store.blockingCounts()) ?? blockingCounts
        if blocking != blockingCounts { blockingCounts = blocking }
        // Publish only on a change: most polls leave the counts as they were, and the
        // sidebar needn't redraw.
        let counts = ProjectCounts.byProject(all)
        if counts != projectCounts { projectCounts = counts }
        let ms = (try? store.milestones()) ?? milestones
        if ms != milestones { milestones = ms }
        syncDueReminders(all)
        reloadQuestions()
        if timeline { reloadNotes() }
    }

    /// Tasks working now (see `workingTasks`), from `tasks` as read or as last listed.
    static func working(_ tasks: [TodoTask], now: Date = Date()) -> [TodoTask] {
        func live(_ t: TodoTask) -> Bool { t.claim?.isLive(at: now) == true }
        return tasks.filter { $0.status == .inProgress || ($0.status == .todo && live($0)) }
            .sorted { a, b in live(a) != live(b) ? live(a) : a.updatedAt > b.updatedAt }
    }

    private func setWorking(_ tasks: [TodoTask], now: Date = Date()) {
        let working = Self.working(tasks, now: now)
        if working != workingTasks { workingTasks = working }
        nextClaimExpiry = working.compactMap { $0.claim.flatMap { $0.isLive(at: now) ? $0.expiresAt : nil } }.min()
    }

    /// Refresh the open questions; drop a selection that is no longer open (answered
    /// here, or withdrawn by the agent) for the next one in line.
    func reloadQuestions() {
        let readAt = Date()
        let open = (try? store.questions(statuses: [.open], activeOnly: true)) ?? openQuestions
        if open != openQuestions { openQuestions = open }
        let sessions = (try? store.agentSessions(seenSince: Date().addingTimeInterval(-Self.sessionsShownSeconds)))
            ?? agentSessions
        if sessions != agentSessions { agentSessions = sessions }
        let shown = questionsShown(in: open)
        if showQuestions || shownProjectTab == .questions,
           selectedQuestionId.map({ id in !shown.contains { $0.id == id } }) ?? true {
            selectedQuestionId = shown.first?.id
        }
        if let tasks = try? store.inbox() { inboxTasks = tasks.map { InboxTask(task: $0.task, projectCode: $0.projectCode) } }
        if let sessions = try? store.sessionsNeedingUser() { attentionSessions = sessions }
        rebuildWaitingOnYou()
        notifyNewWaiting(readAt: readAt)
        if let n = try? store.newDecisionCount(), n != newDecisionCount { newDecisionCount = n }
    }

    /// Notify about what newly waits on the user (QUE-26): one notification per read, for
    /// everything new in it (`WaitingWatch` has the rules). The watch sees every read, also
    /// while notifications are off, so turning them on never announces old items.
    private func notifyNewWaiting(readAt: Date) {
        let arrivals = waitingWatch.arrivals(
            in: waitingOnYou, readAt: readAt,
            projectCode: { id in id.map(projectCode(for:)) ?? "" },
            isGate: { q in (try? store.isGateQuestion(id: q.id)) ?? false },
            setByAgent: { t in
                WaitingWatch.setByAgent(history: (try? store.taskHistory(taskId: t.id)) ?? [])
            })
        guard settings.agentNotificationsEnabled, let first = arrivals.first,
              let notice = WaitingWatch.notice(arrivals) else { return }
        NotificationScheduler.shared.postWaiting(title: notice.title, body: notice.body,
                                                 sound: settings.soundEnabled, item: first.item)
    }

    /// The Waiting on you page at what a notification was posted for (its click).
    func showWaitingArrival(_ item: WaitingArrival.Item) {
        switch item {
        case .session(let id): showInboxItem(.session(id))
        case .question(let id): showInboxItem(.question(id))
        case .task(let id): showInboxItem(.task(id))
        }
    }

    /// Rebuild `waitingOnYou` from the open questions and the parts last read (each
    /// session's process is checked again). On the page, a selection that is gone (answered,
    /// resumed, dismissed) moves to the item now in its place, so the next one is up.
    private func rebuildWaitingOnYou() {
        let built = WaitingOnYou(questions: openQuestions, tasks: inboxTasks, sessions: attentionSessions)
        guard built != waitingOnYou else { return }
        let before = inboxItems
        waitingOnYou = built
        guard showInbox else { return }
        let items = inboxItems
        if let sel = inboxSelection, items.contains(sel) { return }
        let at = inboxSelection.flatMap { before.firstIndex(of: $0) } ?? 0
        inboxSelection = items.isEmpty ? nil : items[min(at, items.count - 1)]
    }

    /// The page's items in order: sessions at a terminal, then questions, then waiting
    /// tasks (each longest waiting first).
    var inboxItems: [InboxItemID] {
        waitingOnYou.sessions.map { .session($0.id) } + waitingOnYou.questions.map { .question($0.id) }
            + waitingOnYou.tasks.map { .task($0.id) }
    }

    /// The item after `item` on the page (wrapping), or nil when it is the only one.
    func inboxItem(after item: InboxItemID) -> InboxItemID? {
        let items = inboxItems
        guard let i = items.firstIndex(of: item), items.count > 1 else { return nil }
        return items[(i + 1) % items.count]
    }

    static let sessionsShownSeconds: TimeInterval = 7 * 24 * 3600

    /// The Claude Code session a question was asked from: the one the MCP server linked,
    /// else the session id inside its label.
    func agentSession(for q: Question) -> AgentSession? {
        guard let sid = q.agentSessionId ?? AgentSession.sessionId(in: q.sessionId) else { return nil }
        return agentSessions.first { $0.id == sid }
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

    /// The projects a page's project picker lists: the active ones, plus `selected` when it
    /// is archived (opened from an archived project's menu), so the picker never goes blank.
    func pickerProjects(selected: Int64?) -> [Project] {
        guard let selected, !activeProjects.contains(where: { $0.id == selected }),
              let p = projects.first(where: { $0.id == selected }) else { return activeProjects }
        return activeProjects + [p]
    }

    func selectProject(_ id: Int64?) {
        if id != selectedProjectId { projectTab = .tasks; wikiSelection = nil; wikiQuery = "" }
        showDashboard = false
        showQuestions = false
        showArchived = false
        showInbox = false
        showActivity = false
        showDecisions = false
        smartView = nil
        selectedProjectId = id
        selectedTaskIds = []
        searchQuery = ""
        reloadTasks()
    }

    func selectSmartView(_ v: SmartView) {
        showDashboard = false
        showQuestions = false
        showArchived = false
        showInbox = false
        showActivity = false
        showDecisions = false
        smartView = v
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        reloadTasks()
    }

    func selectDashboard() {
        showDashboard = true
        showQuestions = false
        showArchived = false
        showInbox = false
        showActivity = false
        showDecisions = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        reloadDashboard()
    }

    func selectQuestions() {
        showQuestions = true
        showDashboard = false
        showArchived = false
        showInbox = false
        showActivity = false
        showDecisions = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        selectedQuestionId = nil
        reloadQuestions()
    }

    func selectInbox() {
        showInbox = true
        showActivity = false
        showDecisions = false
        showQuestions = false
        showDashboard = false
        showArchived = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        inboxSelection = nil
        reloadQuestions()
        inboxSelection = inboxItems.first
    }

    /// Show the Activity page, for one project or (nil) every project not archived.
    func selectActivity(projectId: Int64? = nil) {
        showActivity = true
        showDecisions = false
        showInbox = false
        showQuestions = false
        showDashboard = false
        showArchived = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        activitySelection = nil
        if activityProjectId != projectId { activityProjectId = projectId } else { reloadActivity(resetLimit: true) }
    }

    /// Reread the feed with the filters (on every DB change while the page shows). The
    /// selection stays while its row is there, else moves to the newest row.
    func reloadActivity(resetLimit: Bool = false) {
        guard showActivity else { return }
        if resetLimit { activityLimit = Self.activityPage }
        let range = activityDay.range()
        guard let events = try? store.activity(projectId: activityProjectId, from: range?.from, to: range?.to,
                                               limit: activityLimit) else { return }
        activityHasMore = events.count >= activityLimit
        activityEvents = events
        regroupActivity()
    }

    /// Older entries: read a page more.
    func loadMoreActivity() {
        activityLimit += Self.activityPage
        reloadActivity()
    }

    private func regroupActivity() {
        let groups = ActivityGroup.group(activityEvents.filter(activityWho.matches))
        if groups != activityGroups { activityGroups = groups }
        if activitySelection.map({ id in !groups.contains { $0.id == id } }) ?? true {
            activitySelection = groups.first?.id
        }
    }

    /// Open what a feed row is about: its task, or its page on the project's Wiki tab.
    func openActivity(_ group: ActivityGroup) {
        switch group.subject {
        case .task(let id, _, _):
            // Its project's list first: `tasks` still holds the list shown before this page.
            selectProject(group.projectId)
            openTask(id)
        case .page(let id, _, _):
            selectProject(group.projectId)
            selectProjectTab(.wiki)
            wikiSelection = .page(id)
        }
    }

    // MARK: - Decisions page (QUE-39)

    /// Show the Decisions page, for one project or (nil) every project not archived.
    func selectDecisions(projectId: Int64? = nil) {
        showDecisions = true
        showActivity = false
        showInbox = false
        showQuestions = false
        showDashboard = false
        showArchived = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        decisionSelection = nil
        if decisionsProjectId != projectId { decisionsProjectId = projectId } else { reloadDecisions() }
    }

    /// Reread the list with the filters (on every DB change while the page shows). The
    /// selection stays while its decision is listed, else moves to the newest.
    func reloadDecisions() {
        guard showDecisions else { return }
        let range = decisionsDay.range()
        // One project picked (from its context menu, archived or not) shows its decisions
        // whether or not it is archived; all projects leaves the archived ones out.
        let filter = DecisionFilter(projectId: decisionsProjectId, from: range?.from, to: range?.to,
                                    newOnly: decisionsShow == .new, disagreedOnly: decisionsShow == .disagreed,
                                    includeArchived: decisionsProjectId != nil, limit: Self.decisionsShown)
        guard let list = try? store.decisions(filter) else { return }
        if list != decisions { decisions = list }
        if decisionSelection.map({ id in !list.contains { $0.id == id } }) ?? true {
            decisionSelection = list.first?.id
        }
    }

    /// Mark decisions seen (one, or every new one listed).
    func markDecisionsSeen(_ ids: [Int64]) {
        do {
            try store.markDecisionsSeen(noteIds: ids)
        } catch {
            flashToast("Couldn't mark as seen: \(error)")
        }
        reloadDecisions()
        if let n = try? store.newDecisionCount() { newDecisionCount = n }
    }

    /// Send the user's disagreement with a decision to the agent (Store.disagree). Returns
    /// whether it was sent, so the form can close.
    @discardableResult
    func disagree(with d: AgentDecision, why: String) -> Bool {
        do {
            let r = try store.disagree(noteId: d.id, why: why)
            if let t = r.createdTask {
                flashToast("\(d.taskCode) is closed: sent to the agent as \(t.code)")
            } else {
                flashToast("Sent to the agent on \(r.question.taskCode)")
            }
            reloadTasks()
            reloadDecisions()
            if let n = try? store.newDecisionCount() { newDecisionCount = n }
            return true
        } catch {
            flashToast("Couldn't send: \(error)")
            return false
        }
    }

    /// Open a decision's task (or the task its disagreement went to).
    func openDecisionTask(_ taskId: Int64, projectId: Int64) {
        selectProject(projectId)
        openTask(taskId)
    }

    /// The "Waiting on you" page with `item` selected (the menu bar's entries), or its
    /// first item when `item` is nil or gone.
    func showInboxItem(_ item: InboxItemID?) {
        selectInbox()
        if let item, inboxItems.contains(item) { inboxSelection = item }
    }

    /// A task selected in its project's list (the menu bar's working entries).
    func showTask(_ task: TodoTask) {
        selectProject(task.projectId)
        selectedTaskIds = [task.id]
    }

    /// Open what an inbox item is about: a question's or a task's task, a session's project.
    func openInboxItem(_ item: InboxItemID) {
        switch item {
        case .question(let id):
            if let q = waitingOnYou.questions.first(where: { $0.id == id }) { openTask(q.taskId) }
        case .task(let id):
            openTask(id)
        case .session(let id):
            if let pid = waitingOnYou.sessions.first(where: { $0.id == id })?.projectId { selectProject(pid) }
        }
    }

    /// A task waiting on the user, answered: back to In Progress, with the user's note (if
    /// any) in the same write. A blocked task asks first, like any move to In Progress.
    func resumeWaiting(_ task: TodoTask, note: String = "") {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                try store.updateTask(id: task.id, status: .inProgress, author: .user,
                                     note: text.isEmpty ? nil : NoteDraft(text: text, kind: .note, author: .user))
                flashToast("\(task.code) is in progress")
            } catch {
                flashToast("Couldn't resume \(task.code): \(error)")
            }
            reloadTasks()
        }
        if blockedConfirmNeeded(forIds: [task.id], to: .inProgress) {
            blockedConfirm = BlockedConfirm(
                message: "This task is blocked by an unfinished dependency. Move it to In Progress anyway?",
                onConfirm: apply)
        } else {
            apply()
        }
    }

    /// New Task (⌘N): on another tab of a project page, back to Tasks first, where the
    /// new-task field is; it opens once the list is showing again.
    func requestNewTask() {
        if shownProjectTab != nil, projectTab != .tasks {
            projectTab = .tasks
            DispatchQueue.main.async { self.pendingNewTask = true }
            return
        }
        // Only where a task list shows (a project or a smart view): on the Dashboard,
        // Questions or Archived page the flag would wait for the next list instead.
        guard smartView != nil || selectedProject != nil else { return }
        pendingNewTask = true
    }

    /// Show a tab of the selected project's page; the Questions tab selects its first question.
    func selectProjectTab(_ tab: ProjectTab) {
        projectTab = tab
        if tab == .questions { selectedQuestionId = nil; reloadQuestions() }
        if tab == .wiki { reloadWiki() }
    }

    func selectArchived() {
        showArchived = true
        showQuestions = false
        showDashboard = false
        showInbox = false
        showActivity = false
        showDecisions = false
        smartView = nil
        selectedProjectId = nil
        selectedTaskIds = []
        searchQuery = ""
        reloadTasks()
    }

    /// The question after `id` in the list shown (wrapping), or nil when it is the only one.
    func questionAfter(_ id: Int64) -> Int64? {
        let shown = shownQuestions
        guard let i = shown.firstIndex(where: { $0.id == id }), shown.count > 1 else { return nil }
        return shown[(i + 1) % shown.count].id
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
            if !selectedTaskLinks.isEmpty { selectedTaskLinks = [] }
            if !selectedTaskRelations.isEmpty { selectedTaskRelations = RelatedTasks() }
            return
        }
        do {
            let rows = try store.notes(taskId: id, limit: notesLimit + 1)
            let events = try store.taskHistory(taskId: id)
            let questions = Dictionary(uniqueKeysWithValues: try store.questions(
                statuses: QuestionStatus.allCases, taskId: id).map { ($0.id, $0) })
            let links = try store.links(taskId: id)
            let relations = try store.relatedTasks(taskId: id)
            let page = Array(rows.prefix(notesLimit)), older = rows.count > notesLimit
            if page != selectedTaskNotes { selectedTaskNotes = page }
            if older != hasOlderNotes { hasOlderNotes = older }
            if events != selectedTaskEvents { selectedTaskEvents = events }
            if questions != selectedTaskQuestions { selectedTaskQuestions = questions }
            if links != selectedTaskLinks { selectedTaskLinks = links }
            if relations != selectedTaskRelations { selectedTaskRelations = relations }
            notesErrorShown = nil
        } catch {
            if switched {
                if !selectedTaskNotes.isEmpty { selectedTaskNotes = [] }
                if hasOlderNotes { hasOlderNotes = false }
                if !selectedTaskEvents.isEmpty { selectedTaskEvents = [] }
                if !selectedTaskQuestions.isEmpty { selectedTaskQuestions = [:] }
                if !selectedTaskLinks.isEmpty { selectedTaskLinks = [] }
                if !selectedTaskRelations.isEmpty { selectedTaskRelations = RelatedTasks() }
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

    func addProject(name: String, detail: String = "", code: String? = nil, repoPath: String? = nil,
                    guideTemplate: GuideTemplate? = nil) {
        do {
            let p = try store.createProject(name: name, detail: detail, code: code, repoPath: repoPath,
                                            guideTemplate: guideTemplate)
            reloadAll()
            selectProject(p.id)
        } catch {
            flashToast("Couldn't create the project: \(error)")
        }
    }

    /// Save the project sheet: the code first, then the repo folder (each may be refused,
    /// e.g. taken since the sheet checked it), then the name and description. `detail` and
    /// `repoPath` nil leave them as they are; an empty `repoPath` removes the folder.
    func editProject(_ id: Int64, name: String?, detail: String?, code: String?, repoPath: String? = nil) {
        if let code, code.uppercased() != projects.first(where: { $0.id == id })?.code {
            do {
                try store.setProjectCode(id: id, code: code)
            } catch {
                flashToast("Couldn't change the code: \(error)")
                reloadAll()
                return
            }
        }
        if let repoPath {
            do {
                try store.setProjectRepoPath(id: id, path: repoPath)
            } catch {
                flashToast("Couldn't change the repo folder: \(error)")
                reloadAll()
                return
            }
        }
        updateProject(id, name: name, detail: detail)
    }

    /// A project's own gate rules (QUE-36); empty when there are none or they can't be read.
    func gateRules(projectId: Int64) -> [String] {
        (try? store.gateRules(projectId: projectId)) ?? []
    }

    /// Replace a project's own gate rules, if they are still `basedOn` (what the editor
    /// started from). Throws `GateRulesChanged` when they changed meanwhile (an agent added
    /// one), or `StoreError` with why they were not saved.
    func setGateRules(projectId: Int64, rules: [String], basedOn: [String]) throws {
        try store.setGateRules(projectId: projectId, rules: rules, basedOn: basedOn)
    }

    /// Whether question `id` was asked by the gate (QUE-36).
    func isGateQuestion(_ id: Int64) -> Bool {
        (try? store.isGateQuestion(id: id)) ?? false
    }

    /// Why `raw` can't be the repo folder of project `id` (nil: a new project), or nil when
    /// it can. Empty is fine (no folder). The store checks again when it saves.
    func repoPathProblem(_ raw: String, for id: Int64?) -> String? {
        let path: String?
        do { path = try Store.normalizedRepoPath(raw) } catch {
            return Store.isAbsolute(raw) ? "Choose the project's own folder, not / or your home folder"
                                         : "Enter a full path, starting with / or ~"
        }
        // Unchanged is fine (e.g. shared with a project unarchived since), so the rest of
        // the project stays editable.
        guard let path, path != projects.first(where: { $0.id == id })?.repoPath else { return nil }
        let resolved = Store.resolvedPath(path)
        if let other = projects.first(where: { p in
            p.id != id && !p.isArchived && p.repoPath.map(Store.resolvedPath) == resolved
        }) {
            return "Already the folder of \(other.name)"
        }
        return nil
    }

    /// Why `raw` can't be the code of project `id` (nil: a new project), or nil when it
    /// can. Empty is fine for a new project (a code is made from its name). The store
    /// checks again when it saves.
    func projectCodeProblem(_ raw: String, for id: Int64?) -> String? {
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { return id == nil ? nil : "Enter a code" }
        // An unchanged code is fine even if it predates these rules (e.g. one made from
        // a name starting with a digit), so the rest of the project stays editable.
        if let id, let stored = projects.first(where: { $0.id == id })?.code,
           raw.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(stored) == .orderedSame { return nil }
        guard let code = Store.normalizedProjectCode(raw) else {
            return "1–10 letters A–Z or digits, starting with a letter"
        }
        if let other = projects.first(where: { $0.id != id && $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            return "\(code) is already the code of \(other.name)"
        }
        return nil
    }

    func renameProject(_ id: Int64, to name: String) {
        try? store.renameProject(id: id, name: name)
        reloadAll()
    }

    func updateProject(_ id: Int64, name: String? = nil, detail: String? = nil) {
        try? store.updateProject(id: id, name: name, detail: detail)
        reloadAll()
    }

    /// Save a project's description as it is typed (the Detail tab): rereads only the
    /// projects, not everything reloadAll does.
    func saveProjectDetail(_ id: Int64, markdown: String) {
        do {
            try store.updateProject(id: id, detail: markdown)
        } catch {
            flashToast("Couldn't save the description: \(error)")
            return
        }
        projects = (try? store.listProjects()) ?? projects
    }

    // MARK: - Agent guides

    /// The current guide of a scope (`projectId` nil = every project); nil if never saved
    /// or unreadable.
    func guide(projectId: Int64?) -> GuideVersion? {
        (try? store.guide(projectId: projectId)) ?? nil
    }

    func guideHistory(projectId: Int64?) -> [GuideVersion] {
        (try? store.guideHistory(projectId: projectId, limit: 50)) ?? []
    }

    /// Save the user's edit of a guide, made from version `basedOn` (nil: the scope had
    /// none). Edits within 10 minutes of the user's last save stay one version (the editor
    /// saves as you type). Throws GuideConflict when another save (an agent's) came first.
    @discardableResult
    func saveGuide(projectId: Int64?, markdown: String, basedOn: Int64?, reason: String? = nil) throws -> GuideVersion {
        try store.saveGuide(projectId: projectId, markdown: markdown, author: .user, reason: reason,
                            mergeWindow: reason == nil ? 600 : nil, basedOn: .some(basedOn))
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
                    waitingOn: WaitingOn? = nil, waitingReason: String?? = nil, branch: String?? = nil) {
        let on = status == .waiting ? (waitingOn ?? task.waitingOn ?? .user) : waitingOn
        do {
            try store.updateTask(id: task.id, title: title, detail: detail, link: link, status: status,
                                 priority: priority, dueDate: dueDate, tags: tags, recurrence: recurrence,
                                 estimateSeconds: estimateSeconds, waitingOn: on, waitingReason: waitingReason,
                                 branch: branch, author: .user)
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
    /// showing (the open top-level tasks of one project), so offsets line up regardless of
    /// nesting. They go to the top in the new order; closed ones stay below them, and
    /// subtasks stay with their parents (the same `Store.reorderTasks` MCP reorder_tasks uses).
    func moveTasks(_ displayed: [TodoTask], from offsets: IndexSet, to destination: Int) {
        var ordered = displayed
        ordered.move(fromOffsets: offsets, toOffset: destination)
        do {
            try store.reorderTasks(ids: ordered.map(\.id))
        } catch {
            flashToast("Couldn't reorder: \(error)")
        }
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

    // MARK: - Task lookup

    /// All tasks across every project (for the relation search).
    func allTasks() -> [TodoTask] {
        (try? store.listTasks(projectId: nil)) ?? []
    }

    /// Look up a task by id, preferring the loaded list, falling back to the store.
    func task(byId id: Int64) -> TodoTask? {
        tasks.first(where: { $0.id == id }) ?? (try? store.getTask(id: id))
    }

    // MARK: - Relations

    /// Relate `task` to `other` (`kind` seen from `task`); store rejections (self, cycle,
    /// a reverse duplicate) show as a toast. Returns whether it was added.
    @discardableResult
    func addRelation(_ task: TodoTask, to other: TodoTask, kind: RelationKind) -> Bool {
        do {
            if try !store.addRelation(taskId: task.id, otherId: other.id, kind: kind) {
                flashToast("\(other.code) is already listed")
            }
            reloadTasks()
            return true
        } catch {
            flashToast("\(error)")
            return false
        }
    }

    func removeRelation(_ taskId: Int64, _ otherId: Int64, kind: RelationKind) {
        do {
            try store.removeRelation(taskId: taskId, otherId: otherId, kind: kind)
        } catch {
            flashToast("\(error)")
        }
        reloadTasks()
    }

    /// Drop `task` as a duplicate of `original` (after the user agreed), with a note.
    func dropAsDuplicate(_ task: TodoTask, of original: TodoTask) {
        do {
            try store.updateTask(id: task.id, status: .dropped, author: .user,
                                 note: NoteDraft(text: "Dropped as a duplicate of \(original.code).",
                                                 kind: .summary, author: .user))
        } catch {
            flashToast("\(error)")
        }
        reloadTasks()
    }

    /// Show a task from anywhere (e.g. a relation in another project): select it where it
    /// is listed now, or else open its project with it selected.
    /// Only a task list on screen counts: off the list pages (Waiting on you, Activity…)
    /// `tasks` can still hold the list shown before, and selecting there would select a
    /// task the user cannot see (the Task menu, ⌘⌫ included, would act on it).
    func openTask(_ id: Int64) {
        let listShown = smartView != nil || shownProjectTab == .tasks
        if listShown, tasks.contains(where: { $0.id == id }) {
            selectedTaskIds = [id]
            return
        }
        guard let pid = task(byId: id)?.projectId else { return }
        selectProject(pid)
        if projectTab != .tasks { selectProjectTab(.tasks) }
        selectedTaskIds = [id]
    }

    /// Tasks in any project whose code or title contains `query` (case-insensitive), code
    /// matches first, at most `limit`, leaving out `excluding`.
    func searchTasks(_ query: String, excluding: Set<Int64>, limit: Int = 8) -> [TodoTask] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let hits = allTasks().filter {
            !excluding.contains($0.id)
                && ($0.code.localizedCaseInsensitiveContains(q) || $0.title.localizedCaseInsensitiveContains(q))
        }
        let byCode = hits.filter { $0.code.localizedCaseInsensitiveContains(q) }
        let byTitle = hits.filter { !$0.code.localizedCaseInsensitiveContains(q) }
        return Array((byCode + byTitle).prefix(limit))
    }

    // MARK: - Wiki

    /// Reread the selected project's wiki while its Wiki tab shows (every DB change from
    /// an agent lands here too, through reloadAll). With a search typed, only the pages and
    /// decision notes that match. A selection that is gone falls back to the first item.
    func reloadWiki() {
        guard shownProjectTab == .wiki, let pid = selectedProjectId else { return }
        let q = wikiQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var pages: [ProjectPage]
        var notes: [NoteSearchHit]
        if q.isEmpty {
            pages = (try? store.pages(projectId: pid)) ?? wikiPages
            notes = (try? store.decisionNotes(projectId: pid)) ?? wikiDecisionNotes
        } else if let found = try? store.searchPages(query: q, projectId: pid, limit: 200) {
            pages = found.pages.map(\.page)
            notes = found.decisionNotes
        } else {
            pages = []; notes = []
        }
        if pages != wikiPages { wikiPages = pages }
        if notes != wikiDecisionNotes { wikiDecisionNotes = notes }
        let items = wikiItems
        if wikiSelection.map({ !items.contains($0) }) ?? true { wikiSelection = items.first }
    }

    /// The wiki list in order: decision pages, decision notes, then notes.
    var wikiItems: [WikiItem] {
        wikiPages.filter { $0.kind == .decision }.map { .page($0.id) }
            + wikiDecisionNotes.map { .note($0.note.id) }
            + wikiPages.filter { $0.kind == .note }.map { .page($0.id) }
    }

    /// Add a page to the selected project and select it; nil (with a toast) when refused.
    @discardableResult
    func createWikiPage(kind: PageKind, title: String) -> ProjectPage? {
        guard let pid = selectedProjectId else { return nil }
        do {
            let page = try store.createPage(projectId: pid, kind: kind, title: title, author: .user).page
            wikiQuery = ""
            reloadWiki()
            wikiSelection = .page(page.id)
            return page
        } catch {
            flashToast("Couldn't add the page: \(error)")
            return nil
        }
    }

    /// Save the user's edit of a page made from `version`. Throws PageConflict when an
    /// agent changed it first (nothing is written), or the store's refusal.
    func saveWikiPage(_ id: Int64, title: String, body: String, outcome: String?, decidedOn: String?,
                      taskIds: [Int64], version: Int) throws {
        let page = try store.page(id: id)
        try store.updatePage(id: id, title: title, body: body,
                             outcome: page.kind == .decision ? .some(outcome) : nil,
                             decidedOn: page.kind == .decision ? decidedOn.map { .some($0) } : nil,
                             taskIds: taskIds, author: .user, expectedVersion: version)
        reloadWiki()
    }

    func setWikiPageKind(_ id: Int64, _ kind: PageKind) {
        do { try store.updatePage(id: id, kind: kind, author: .user) } catch { flashToast("\(error)") }
        reloadWiki()
    }

    func deleteWikiPage(_ id: Int64) {
        do { try store.deletePage(id: id) } catch { flashToast("Couldn't delete the page: \(error)") }
        reloadWiki()
    }

    /// How many pages of each kind a project's wiki has.
    func wikiCounts(projectId: Int64) -> [PageKind: Int] {
        (try? store.pageCounts(projectId: projectId)) ?? [:]
    }

    func wikiPageHistory(_ id: Int64) -> [PageEvent] {
        (try? store.pageHistory(pageId: id, limit: 200)) ?? []
    }

    /// A task code written in a wiki page, clicked: show the task on the Tasks tab.
    func openTask(code: String) {
        guard let id = store.taskId(forCode: code) else { return flashToast("No task \(code)") }
        projectTab = .tasks
        openTask(id)
    }

    // MARK: - Milestones

    func milestones(in projectId: Int64) -> [Milestone] { milestones.filter { $0.projectId == projectId } }

    func milestone(_ id: Int64?) -> Milestone? { id.flatMap { id in milestones.first { $0.id == id } } }

    /// Add a milestone to a project; a store refusal (a name taken, an archived project)
    /// shows as a toast. Returns whether it was added.
    @discardableResult
    func addMilestone(projectId: Int64, name: String) -> Bool {
        do {
            try store.createMilestone(projectId: projectId, name: name)
        } catch {
            flashToast("\(error)")
            return false
        }
        reloadTasks()
        return true
    }

    func renameMilestone(_ m: Milestone, to name: String) {
        do {
            try store.updateMilestone(id: m.id, name: name)
        } catch {
            flashToast("\(error)")
        }
        reloadTasks()
    }

    /// Close or reopen a milestone. Closing one with open tasks needs `force` (the view
    /// asks first).
    func setMilestoneClosed(_ m: Milestone, _ closed: Bool, force: Bool = false) {
        do {
            try store.updateMilestone(id: m.id, closed: closed, force: force)
        } catch {
            flashToast("\(error)")
        }
        reloadTasks()
    }

    func deleteMilestone(_ m: Milestone) {
        do {
            try store.deleteMilestone(id: m.id)
        } catch {
            flashToast("\(error)")
        }
        reloadTasks()
    }

    /// Put a task in a milestone of its project (nil: in none).
    func setMilestone(_ task: TodoTask, _ milestoneId: Int64?) {
        guard milestoneId != task.milestoneId else { return }
        do {
            try store.updateTask(id: task.id, milestoneId: .some(milestoneId), author: .user)
        } catch {
            flashToast("\(error)")
        }
        reloadTasks()
    }

    // MARK: - Links

    /// Add a link to a task as the user; `kind` nil lets the store guess it. A URL the
    /// task already has is not added twice (a toast says so). Returns false (with a
    /// toast) if the store rejected it.
    @discardableResult
    func addLink(_ task: TodoTask, url: String, kind: LinkKind?) -> Bool {
        do {
            let added = try store.addLink(taskId: task.id, url: url, kind: kind, author: .user)
            if !added.created { flashToast("\(task.code) already has this link") }
        } catch {
            flashToast("Couldn't add the link: \(error)")
            return false
        }
        reloadTasks()
        return true
    }

    /// Change what a link is marked as, by its id: a link removed (or changed) meanwhile
    /// is not added back.
    func setLinkKind(_ link: TaskLink, _ kind: LinkKind) {
        do {
            try store.setLinkKind(id: link.id, kind: kind, url: link.url)
        } catch {
            flashToast("Couldn't change the link: \(error)")
        }
        reloadTasks()
    }

    /// Release an agent's claim on a task (the user may release any claim). The status is
    /// left as is: the user decides what happens to the task next.
    func releaseClaim(_ task: TodoTask) {
        do {
            _ = try store.releaseClaim(taskId: task.id, actor: .user, reopen: false)
        } catch {
            flashToast("Couldn't release the claim: \(error)")
        }
        reloadTasks()
    }

    /// The user says a session no longer needs them at its terminal (e.g. they answered
    /// it and the session has not made a call the hooks see since).
    func dismissAttention(_ session: AgentSession) {
        do {
            // Only what the user saw: a newer "needs you" raised since the last poll stays.
            try store.clearSessionAttention(id: session.id, at: session.attention?.at ?? Date())
        } catch {
            flashToast("Couldn't dismiss: \(error)")
        }
        reloadQuestions()
    }

    func removeLink(_ link: TaskLink) {
        do {
            try store.removeLink(id: link.id, url: link.url)
        } catch {
            flashToast("Couldn't remove the link: \(error)")
        }
        reloadTasks()
    }

    /// Open a link: a web or mail URL in its app; a file path is shown in Finder (never
    /// opened: an agent may have written it). Anything else — a branch name, a custom
    /// scheme — is copied to the clipboard instead.
    func openLink(_ link: TaskLink) {
        let s = link.url
        if link.kind != .branch, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        if link.kind != .branch, s.hasPrefix("/") || s.hasPrefix("~/") || s.lowercased().hasPrefix("file://") {
            let path = s.lowercased().hasPrefix("file://") ? (URL(string: s)?.path ?? "") : (s as NSString).expandingTildeInPath
            if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return
            }
            flashToast("Not found: \(s)")
            return
        }
        copyToClipboard(s)
        flashToast("Copied \(s)")
    }

    // MARK: - Command actions (keyboard shortcuts)

    var selectedTask: TodoTask? { tasks.first(where: { $0.id == selectedTaskId }) }

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

    func saveSettings(_ s: AppSettings) {
        settings = s
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
            // An older QuestBits (an MCP server started before the update) writes only the
            // fields it knows: carry its writes in before reading (links, stale claims).
            store.syncOlderBinaryWrites()
            reloadAll()   // reloads the selected task's notes too: an agent may have added one
            return
        }
        if !attentionSessions.isEmpty {
            // A session's terminal may have closed without a hook firing: no DB write tells.
            rebuildWaitingOnYou()
        }
        if let expiry = nextClaimExpiry, expiry <= Date() { setWorking(workingTasks) }
    }
}
