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
                if model.showArchived {
                    ArchivedProjectsView()
                        .navigationSplitViewColumnWidth(min: 320, ideal: 420)
                } else if model.showInbox {
                    InboxListView()
                        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
                } else if model.showActivity {
                    ActivityListView()
                        .navigationSplitViewColumnWidth(min: 320, ideal: 400)
                } else if model.showQuestions {
                    QuestionListView()
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320)
                } else if model.showDashboard {
                    DashboardView()
                        .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                } else if let p = model.selectedProject, model.projectTab != .tasks {
                    ProjectTabColumn(project: p, tab: model.projectTab)
                        .modifier(ProjectTabsInset())
                        .navigationSplitViewColumnWidth(min: 280, ideal: 360)
                } else if model.boardView && model.boardAvailable {
                    BoardView()
                        .modifier(ProjectTabsInset())
                        .navigationSplitViewColumnWidth(min: 520, ideal: 820)
                } else {
                    TaskListView()
                        .modifier(ProjectTabsInset())
                        .navigationSplitViewColumnWidth(min: 280, ideal: 360)
                }
            } detail: {
                if model.showArchived {
                    ContentUnavailableViewCompat(text: "Find an archived project to open or unarchive it")
                } else if model.showInbox {
                    InboxDetailView()
                } else if model.showActivity {
                    ActivityDetailView()
                } else if model.showQuestions {
                    QuestionDetailView()
                } else if model.showDashboard {
                    ContentUnavailableViewCompat(text: "Your activity at a glance")
                } else if let p = model.selectedProject, model.projectTab != .tasks {
                    ProjectTabDetail(project: p, tab: model.projectTab)
                } else {
                    TaskDetailView()
                }
            }
            .frame(maxHeight: .infinity)
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

/// The sidebar footer's update entry: "Update to vX" once Sparkle found a newer version
/// (kept after the banner is closed), else a "Check for updates" link. Both go through the
/// same updater as the menu's Check for Updates….
struct SidebarUpdateLink: View {
    @ObservedObject private var notifier = UpdateNotifier.shared

    var body: some View {
        if let version = notifier.availableVersion {
            // A small pill, about the size of the version number.
            Button { notifier.onInstallTapped?() } label: {
                Label("Update to v\(version)", systemImage: "arrow.down.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Colors.onPrimary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.Colors.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Install QuestBits \(version)")
        } else {
            // Same size as the version number under it.
            Button { notifier.requestCheck?() } label: {
                Text("Check for updates").font(.caption2).foregroundStyle(Theme.Colors.brandBlue)
            }
            .buttonStyle(.plain)
            .help("Look for a newer QuestBits now")
        }
    }
}

/// `promo-banner`: black strip above the content when Sparkle finds a newer
/// version. Yellow "NEW" chip (`badge-promo`), on-dark copy, white pill
/// "Update Now" (`button-on-dark`) that re-opens Sparkle's install dialog.
struct UpdateBanner: View {
    @ObservedObject private var notifier = UpdateNotifier.shared

    var body: some View {
        if let version = notifier.availableVersion, !notifier.bannerDismissed {
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
    @State private var guideProject: Project?  // non-nil → its guide sheet open
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

    /// "Waiting on you": everything that needs the user, with its count (`waitingOnYou.count`).
    private var inboxRow: some View {
        Label {
            HStack {
                Text("Waiting on you")
                Spacer()
                if !model.waitingOnYou.isEmpty { inboxBadge(model.waitingOnYou.count) }
            }
        } icon: { QBIcon(name: "lucide-hourglass") }
            .font(Theme.Fonts.bodySmMedium)
            .foregroundStyle(model.showInbox ? Theme.Colors.brandBlue : Theme.Colors.ink)
            .contentShape(Rectangle())
            .onTapGesture { model.selectInbox() }
            .listRowBackground(sidebarRowCard(model.showInbox))
            .help("Questions, approvals, tasks and sessions waiting on you")
    }

    /// "Activity": what was done, by you and your agents (ActivityListView).
    private var activityRow: some View {
        Label { Text("Activity") } icon: { QBIcon(name: "lucide-scroll") }
            .font(Theme.Fonts.bodySmMedium)
            .foregroundStyle(model.showActivity ? Theme.Colors.brandBlue : Theme.Colors.ink)
            .contentShape(Rectangle())
            .onTapGesture { model.selectActivity() }
            .listRowBackground(sidebarRowCard(model.showActivity))
            .help("What you and your agents did: changes, notes and wiki edits")
    }

    private func inboxBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(Theme.Fonts.micro)
            .foregroundStyle(Theme.Colors.onDark)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.Colors.brandBlue, in: Capsule())
    }

    var body: some View {
        List(selection: Binding(
            get: { model.selectedProjectId },
            set: { model.selectProject($0) }
        )) {
            Section {
                inboxRow
                ForEach(SmartView.allCases, id: \.self) { v in
                    Label { Text(v.title) } icon: { QBIcon(name: qbSidebarIcon(v)) }
                        .font(Theme.Fonts.bodySmMedium)
                        .foregroundStyle(model.smartView == v ? Theme.Colors.brandBlue : Theme.Colors.ink)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectSmartView(v) }
                        .listRowBackground(sidebarRowCard(model.smartView == v))
                }
                activityRow
                Label { Text("Dashboard") } icon: { QBIcon(name: "lucide-castle") }
                    .font(Theme.Fonts.bodySmMedium)
                    .foregroundStyle(model.showDashboard ? Theme.Colors.brandBlue : Theme.Colors.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectDashboard() }
                    .listRowBackground(sidebarRowCard(model.showDashboard))
                Label {
                    HStack {
                        Text("Questions")
                        Spacer()
                        if !model.openQuestions.isEmpty {
                            Text("\(model.openQuestions.count)")
                                .font(Theme.Fonts.micro)
                                .foregroundStyle(Theme.Colors.onDark)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(qbStatusColor(.waiting), in: Capsule())
                        }
                    }
                } icon: { QBIcon(name: "lucide-scroll-text") }
                    .font(Theme.Fonts.bodySmMedium)
                    .foregroundStyle(model.showQuestions ? Theme.Colors.brandBlue : Theme.Colors.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectQuestions() }
                    .listRowBackground(sidebarRowCard(model.showQuestions))
                    .help("Questions agents left for you")
                Label { Text("Templates") } icon: { QBIcon(name: "lucide-backpack") }
                    .font(Theme.Fonts.bodySmMedium)
                    .contentShape(Rectangle())
                    .onTapGesture { showTemplates = true }
                    .help("Manage reusable task templates")
                Label { Text("Archived") } icon: { QBIcon(name: "tabler-barrel") }
                    .font(Theme.Fonts.bodySmMedium)
                    .foregroundStyle(model.showArchived ? Theme.Colors.brandBlue : Theme.Colors.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectArchived() }
                    .listRowBackground(sidebarRowCard(model.showArchived))
                    .help("Find archived projects and unarchive them")
            } header: {
                sidebarHeader("Quests")
            }
            Section {
                ForEach(model.activeProjects) { p in projectRow(p) }
                    // Drag to reorder; only active projects — the Archived group has no onMove.
                    .onMove { offsets, dest in model.moveProjects(from: offsets, to: dest) }
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
            VStack(spacing: 4) {
                SidebarUpdateLink()
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
            ProjectSheet(title: "New Project", picksTemplate: true) { v in
                model.addProject(name: v.name ?? "", detail: v.detail ?? "", code: v.code, repoPath: v.repoPath,
                                 guideTemplate: v.template)
            }
        }
        .sheet(item: $editing) { p in
            ProjectSheet(title: "Edit Project", projectId: p.id, name: p.name, detail: p.detail, code: p.code,
                         repoPath: p.repoPath ?? "") { v in
                model.editProject(p.id, name: v.name, detail: v.detail, code: v.code, repoPath: v.repoPath)
            }
        }
        .sheet(isPresented: $showTemplates) { TemplatesSheet() }
        .sheet(item: $guideProject) { p in GuideSheet(project: p) }
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
        guard model.smartView == nil, !model.showDashboard, !model.showQuestions, !model.showArchived, !model.showInbox,
              !model.showActivity,
              let sel = model.selectedProjectId else { return false }
        return model.archivedProjects.contains { $0.id == sel }
    }

    /// A project row (active or archived — archived rows are dimmed) with its context menu.
    /// The trailing number is the open tasks; the bar under the name is done out of the
    /// tasks still counted (dropped is in neither). A clay dot marks tasks waiting on the
    /// user. A project with no tasks shows an empty bar, so every row keeps one height.
    private func projectRow(_ p: Project) -> some View {
        let counts = model.projectCounts[p.id] ?? ProjectCounts()
        return HStack(spacing: 6) {
            QBIcon(name: "lucide-door-open")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).font(Theme.Fonts.bodySmMedium)
                    Spacer()
                    CodeBadge(code: p.code)
                    if counts.waitingOnUser > 0 {
                        Circle()
                            .fill(qbStatusColor(.waiting))
                            .frame(width: 6, height: 6)
                            .help("\(counts.waitingOnUser) waiting on you")
                    }
                    Text("\(counts.open)")
                        .font(Theme.Fonts.micro)
                        .foregroundStyle(Theme.Colors.slate)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.Colors.surface, in: Capsule())
                        .help("\(counts.open) open")
                }
                ProjectProgressBar(done: counts.done, total: counts.progressTotal)
                    .help("\(counts.done) of \(counts.progressTotal) done")
            }
        }
        .opacity(p.isArchived ? 0.6 : 1)
        .tag(p.id)
        .listRowBackground(sidebarRowCard(
            model.smartView == nil && !model.showDashboard && !model.showQuestions && !model.showArchived
                && !model.showInbox && !model.showActivity
                && model.selectedProjectId == p.id))
        .help(p.detail.isEmpty ? p.name : p.detail)
        .contextMenu {
            Button("Copy Code (\(p.code))") { model.copyCode(p.code) }
            Button("Edit…") { editing = p }
            Button("Edit Guide…") { guideProject = p }
            Button("Show Activity") { model.selectActivity(projectId: p.id) }
            // No new tasks in an archived project (the store refuses them too).
            if !p.isArchived {
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
        let open = model.projectCounts[p.id]?.open ?? 0
        if open == 0 {
            model.setArchived(p.id, true)
        } else {
            archiving = ArchiveRequest(project: p, openCount: open)
        }
    }

}

/// The thin done/total bar under a sidebar project name (and a milestone); empty when
/// `total` is 0.
struct ProjectProgressBar: View {
    let done: Int
    let total: Int

    var body: some View {
        let ratio = total > 0 ? min(Double(done) / Double(total), 1) : 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.hairlineSoft)
                Capsule()
                    .fill(qbStatusColor(.done))
                    .frame(width: CGFloat(ratio) * geo.size.width)
            }
        }
        .frame(height: 3)
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
                 + "but you can still open them from Archived in the sidebar, and unarchive them there.")
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

/// Create/edit sheet for a project: name, code and description, and when creating
/// (`picksTemplate`) the kind of project, whose template starts its agent guide. The
/// description uses the task Detail editor (blocks, bold, links, images), stored as
/// markdown; `showsDescription` false leaves it out (the Detail tab edits it in place).
/// The code is checked as it is typed; empty on a new project means one made from the name.
struct ProjectSheet: View {
    /// What to save. Editing a project, `name` and `detail` are nil when unchanged since
    /// the sheet opened, so an agent's write in the meantime is not reverted.
    struct Values {
        var name: String?
        var detail: String?
        var code: String?       // nil: left empty (a new project gets one from its name)
        var repoPath: String?   // nil: unchanged; "": no folder
        var template: GuideTemplate?
    }

    @EnvironmentObject var model: AppModel
    let title: String
    var projectId: Int64? = nil   // nil: a new project
    @State var name: String = ""
    @State var detail: String = ""
    @State var code: String = ""
    @State var repoPath: String = ""
    var picksTemplate = false
    var showsDescription = true
    @State private var template: GuideTemplate?
    @State private var detailHeight: CGFloat = 120
    @State private var flush = EditorFlush()
    @State private var opened: (name: String, detail: String, repoPath: String)?
    let onSave: (Values) -> Void
    @Environment(\.dismiss) private var dismiss

    private var codeProblem: String? { model.projectCodeProblem(code, for: projectId) }
    private var repoProblem: String? { model.repoPathProblem(repoPath, for: projectId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
            codeField
            repoField
            if showsDescription { descriptionEditor }
            if picksTemplate { templatePicker }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                // ⌘Return, not Return: Return belongs to the editor.
                Button("Save") { save() }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || codeProblem != nil
                              || repoProblem != nil)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 560)
        .qbParchment()
        .onAppear { if opened == nil { opened = (name, detail, repoPath) } }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Code").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                TextField("Code", text: $code, prompt: Text(projectId == nil ? "From the name" : "Code"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            if let codeProblem {
                Text(codeProblem).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.coralDark)
            } else if projectId != nil {
                Text("Its tasks keep their codes; new tasks take the new one.")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
        }
    }

    /// The folder find_project maps to this project: typed, or picked with Choose….
    private var repoField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Repo folder").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                TextField("Repo folder", text: $repoPath, prompt: Text("None"))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { chooseRepoFolder() }
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
            }
            if let repoProblem {
                Text(repoProblem).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.coralDark)
            } else {
                Text("Agents working in this folder or below it see this project. Leave empty if it has none.")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
        }
    }

    private func chooseRepoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = try? Store.normalizedRepoPath(repoPath) {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url { repoPath = url.path }
    }

    private var descriptionEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            ScrollView {
                // One document, so docId is fixed; an edit flushed as the sheet closes
                // without Save is dropped, like the rest of the sheet.
                MarkdownEditor(docId: 0, markdown: $detail, height: $detailHeight, store: model.store,
                               onOtherDoc: { _, _ in }, onError: { model.flashToast($0) }, flush: flush)
                    .frame(height: max(140, detailHeight + 8))
            }
            .frame(height: 240)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.hairlineStrong))
        }
    }

    /// Take the editor's last keystrokes (it sends edits 150 ms late), then save.
    private func save() {
        flush { md in
            if let md { detail = md }
            let n = name.trimmingCharacters(in: .whitespaces)
            let c = code.trimmingCharacters(in: .whitespaces)
            let r = repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty, codeProblem == nil, repoProblem == nil {
                let editing = projectId != nil
                onSave(Values(name: editing && n == opened?.name ? nil : n,
                              detail: editing && detail == opened?.detail ? nil : detail,
                              code: c.isEmpty ? nil : c,
                              repoPath: editing ? (r == opened?.repoPath ? nil : r) : (r.isEmpty ? nil : r),
                              template: template))
            }
            dismiss()
        }
    }

    private var templatePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Kind", selection: $template) {
                Text("None").tag(GuideTemplate?.none)
                ForEach(GuideTemplate.allCases) { t in Text(t.label).tag(GuideTemplate?.some(t)) }
            }
            Text("Starts the project's agent guide from a template you can edit.")
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
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
    @AppStorage("qbGroupByMilestone") private var groupByMilestone = false
    @State private var newTitle = ""

    var body: some View {
        Group {
            if model.selectedProjectId == nil && model.smartView == nil {
                ContentUnavailableViewCompat(text: "Select a view or project")
            } else {
                VStack(spacing: 0) {
                    SearchBar(query: $model.searchQuery)
                    if !projectMilestones.isEmpty { MilestoneGroupBar(grouped: $groupByMilestone) }
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
                .disabled(!model.canAddTask)
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
                if model.canAddTask { showNew = true }
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
                if model.canAddTask {
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
                    if groupsByMilestone {
                        milestoneSections
                    } else {
                        orderedActiveRows
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

    /// The active tasks in their saved order, reorderable by drag.
    private var orderedActiveRows: some View {
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
    }

    /// The selected project's milestones (none in a smart view).
    private var projectMilestones: [Milestone] {
        guard model.smartView == nil, let pid = model.selectedProjectId else { return [] }
        return model.milestones(in: pid)
    }

    private var groupsByMilestone: Bool { groupByMilestone && !projectMilestones.isEmpty }

    /// Active tasks grouped by milestone, in the project's milestone order, then the tasks in
    /// none. An open milestone shows even with no active task (its progress still counts);
    /// a closed one only while it has some. While searching, empty groups are left out.
    /// A subtask stays under its parent, whichever milestone it is in. Drag-to-reorder is
    /// off while grouped (order is per project, not per group).
    private var milestoneGroups: [(id: Int64, milestone: Milestone?, tasks: [TodoTask])] {
        let byMilestone = Dictionary(grouping: activeTasks) { $0.milestoneId ?? 0 }
        let known = Set(projectMilestones.map(\.id))
        var groups = projectMilestones.compactMap { m -> (id: Int64, milestone: Milestone?, tasks: [TodoTask])? in
            let tasks = byMilestone[m.id] ?? []
            if tasks.isEmpty && (m.isClosed || isSearching) { return nil }
            return (m.id, m, tasks)
        }
        let rest = activeTasks.filter { !known.contains($0.milestoneId ?? 0) }
        if !rest.isEmpty { groups.append((0, nil, rest)) }
        return groups
    }

    private var milestoneSections: some View {
        ForEach(milestoneGroups, id: \.id) { group in
            Section {
                ForEach(group.tasks) { taskRowCell($0) }
            } header: {
                MilestoneSectionHeader(milestone: group.milestone)
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
                showSubtaskUI: model.smartView == nil,
                showMilestone: !groupsByMilestone)
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
    var showMilestone: Bool = true

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

                // Code and chips on their own line, each at its natural size (wrapping onto
                // another line when the column is too narrow), and the title below at the full
                // width: it wraps between words instead of being squeezed next to the chips.
                VStack(alignment: .leading, spacing: 3) {
                    FlowLayout(spacing: 6, lineSpacing: 3) {
                        if task.priority != .none {
                            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(qbPriorityColor(task.priority))
                        }
                        CodeBadge(code: task.code)
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
                        if let n = model.blockingCounts[task.id] { BlocksOthersMark(count: n) }
                        WaitingChip(task: task)
                        if let claim = task.claim, !task.status.isClosed { ClaimChip(claim: claim) }
                    }
                    Text(task.title)
                        .font(Theme.Fonts.bodySm)
                        .strikethrough(task.status.isClosed)
                        .foregroundStyle(qbTitleColor(task.status))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if task.status == .waiting, let reason = task.waitingReason, !reason.isEmpty {
                            Text(reason)
                                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.coralDark)
                                .lineLimit(1)
                        }
                        if task.link != nil && !(task.link?.isEmpty ?? true) {
                            Image(systemName: "link").font(.caption2).foregroundStyle(Theme.Colors.steel)
                        }
                        if let branch = task.branch { BranchChip(name: branch) }
                        if showMilestone, let m = model.milestone(task.milestoneId) { MilestoneChip(name: m.name) }
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
                Spacer(minLength: 4)
                Text(task.status.display).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.stone)
                    .fixedSize()
            }

            // Subtasks (one level of nesting), shown only for top-level tasks in a project view.
            if showSubtaskUI && task.parentId == nil {
                ForEach(subtasks) { sub in
                    SubtaskRow(sub: sub)
                }
                // An archived project takes no new subtasks (the store refuses them).
                if model.canAddTask(to: task.projectId) {
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

/// Lays children out left to right at their natural size, starting a new line when the
/// next one would not fit the width offered (the task row's code and chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for (i, size) in zip(row.indices, row.sizes) {
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                  proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            row.sizes.append(size)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
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
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(selected ? Theme.Colors.surfacePricingFeatured : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        // Click to open the subtask in the detail column, for its Detail and notes.
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTaskIds = [sub.id] }
        .help("Open \(sub.code)")
        .padding(.leading, 20)
    }

    private var selected: Bool { model.selectedTaskId == sub.id }

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
                if let n = model.blockingCounts[task.id] { BlocksOthersMark(count: n) }
                Spacer()
                if let claim = task.claim, !task.status.isClosed { ClaimChip(claim: claim) }
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
    @State private var branch = ""
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
    // Draft link (not a task field either), cleared with the draft note.
    @State private var newLink = ""
    @State private var newLinkKind: LinkKind?   // nil = let the store guess
    // Add-relation row (cleared with the draft note), and the offer to drop a duplicate
    // shown right after one is marked.
    @State private var relationKind: RelationKind = .relates
    @State private var relationQuery = ""
    @State private var dropOffer: DuplicateDropOffer?
    @AppStorage("qbTimelineFilter") private var timelineFilter: TimelineFilter = .all
    @State private var detailHeight: CGFloat = 120   // the Detail editor's content height

    // Blocked-task guard: confirm before moving a blocked task to In Progress.
    @State private var showBlockedAlert = false
    @State private var statusBeforeBlock: TaskStatus = .todo

    var body: some View {
        Group {
            if let task = currentTask {
                editor(task)
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

    // MARK: editor modifiers (split into steps — one long modifier chain stalls the
    // type checker on slower machines, e.g. the CI runner)

    private func editor(_ task: TodoTask) -> some View {
        let content = sectionsScroll(task)
            .onAppear { load(task) }
            // Selection change or a store write (app or MCP): resync the editor.
            .onChange(of: currentTask) { _, new in if let new { sync(new) } }
        return blockedGuard(fieldAutosave(content))
    }

    /// Auto-save: any field change persists immediately (no Save button).
    private func fieldAutosave(_ content: some View) -> some View {
        let text = content
            .onChange(of: title) { _, _ in autosave() }
            .onChange(of: detail) { _, _ in autosave() }
            .onChange(of: branch) { _, v in
                // A branch name has no spaces: drop them as typed rather than fail the save.
                let name = v.filter { !$0.isWhitespace }
                if name != v { branch = name } else { autosave() }
            }
            .onChange(of: waitingOn) { _, _ in autosave() }
            .onChange(of: waitingReason) { _, _ in autosave() }
        return text
            .onChange(of: priority) { _, _ in autosave() }
            .onChange(of: hasDue) { _, _ in autosave() }
            .onChange(of: dueDate) { _, _ in autosave() }
            .onChange(of: tagsText) { _, _ in autosave() }
            .onChange(of: recurrence) { _, _ in autosave() }
            .onChange(of: estimateMinutes) { _, _ in autosave() }
    }

    private func blockedGuard(_ content: some View) -> some View {
        content
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
            .alert("Task is blocked", isPresented: $showBlockedAlert) {
                Button("Cancel", role: .cancel) { status = statusBeforeBlock }
                Button("Start anyway") { autosave() }
            } message: {
                Text("This task is blocked by an unfinished dependency. Move it to In Progress anyway?")
            }
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
                taskSection(task)
                dueDateSection
                tagsSection
                relationsSection(task)
                linksSection(task)
                detailSection(task)
                timelineSection(task)
                estimateSection(task)
                timingSection(task)
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
            CommandRow(command: AgentCommand.work(task.code), note: "Paste into Claude Code to start on this task")
        }
    }

    private func taskSection(_ task: TodoTask) -> some View {
        QBDetailSection("Task") {
            TextField("Title", text: $title).qbField()
            Picker("Status", selection: $status) {
                ForEach(TaskStatus.allCases, id: \.self) { Text($0.display).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let claim = task.claim { ClaimLine(task: task, claim: claim) }
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
            if task.milestoneId != nil || !model.milestones(in: task.projectId).isEmpty {
                labeledRow("Milestone") { MilestonePicker(task: task) }
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

    /// The task's relations, grouped by kind (Blocked by, Blocks, Related, Duplicates,
    /// Duplicated by), each a card that opens that task (in any project), then a row to
    /// find a task by code or title and relate it.
    private func relationsSection(_ task: TodoTask) -> some View {
        QBDetailSection("Relations") {
            let rel = model.selectedTaskRelations
            if rel.isEmpty {
                Text("No related tasks").foregroundStyle(Theme.Colors.slate).font(Theme.Fonts.caption)
            }
            ForEach(RelationKind.allCases.filter { !rel[$0].isEmpty }, id: \.self) { kind in
                relationGroup(task, kind, rel[kind])
            }
            addRelationRow(task)
        }
        .alert("Drop the duplicate?",
               isPresented: Binding(get: { dropOffer != nil }, set: { if !$0 { dropOffer = nil } }),
               presenting: dropOffer) { offer in
            Button("Drop \(offer.duplicate.code)", role: .destructive) {
                model.dropAsDuplicate(offer.duplicate, of: offer.original)
            }
            Button("Keep", role: .cancel) {}
        } message: { offer in
            Text("\(offer.duplicate.code) is a duplicate of \(offer.original.code). Drop it? It keeps its notes and history.")
        }
    }

    private func relationGroup(_ task: TodoTask, _ kind: RelationKind, _ items: [RelatedTask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.display).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            ForEach(items) { item in
                RelationCard(item: item, kind: kind,
                             onOpen: { model.openTask(item.id) },
                             onRemove: { model.removeRelation(task.id, item.id, kind: kind) })
            }
        }
    }

    private func addRelationRow(_ task: TodoTask) -> some View {
        let candidates = relationCandidates(for: task)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $relationKind) {
                    ForEach(RelationKind.allCases, id: \.self) { Text($0.display).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Find a task by code or title…", text: $relationQuery)
                    .qbField()
                    .onSubmit { if let first = candidates.first { commitRelation(task, first) } }
            }
            ForEach(candidates, id: \.id) { cand in
                Button { commitRelation(task, cand) } label: { relationCandidateLabel(cand) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func relationCandidateLabel(_ cand: TodoTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle").foregroundStyle(Theme.Colors.steel)
            CodeBadge(code: cand.code)
            Text(cand.title).font(Theme.Fonts.bodySm).lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// Tasks matching the search, other than this one and those already related this way.
    /// The store rejects the rest (a dependency cycle, a reverse duplicate) on add.
    private func relationCandidates(for task: TodoTask) -> [TodoTask] {
        let existing = Set(model.selectedTaskRelations[relationKind].map(\.id))
        return model.searchTasks(relationQuery, excluding: existing.union([task.id]))
    }

    /// Add the relation; after marking a duplicate that is still open, offer to drop it.
    private func commitRelation(_ task: TodoTask, _ other: TodoTask) {
        let kind = relationKind
        guard model.addRelation(task, to: other, kind: kind) else { return }
        relationQuery = ""
        if kind == .duplicates, !task.status.isClosed {
            dropOffer = DuplicateDropOffer(duplicate: task, original: other)
        } else if kind == .duplicatedBy, !other.status.isClosed {
            dropOffer = DuplicateDropOffer(duplicate: other, original: task)
        }
    }

    /// The working branch (mono, edited in place like the other fields) and the task's
    /// links, oldest first, with a row to add one.
    private func linksSection(_ task: TodoTask) -> some View {
        QBDetailSection("Links") {
            labeledRow("Branch") {
                TextField("none", text: $branch)
                    .font(Theme.Fonts.codeBadge)
                    .qbField()
                    .frame(maxWidth: 280)
                if !branch.isEmpty {
                    Button { model.copyCode(branch) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Colors.steel)
                        .help("Copy branch name")
                }
            }
            ForEach(model.selectedTaskLinks) { LinkRow(link: $0) }
            addLinkRow(task)
        }
    }

    private func addLinkRow(_ task: TodoTask) -> some View {
        HStack(spacing: 8) {
            TextField("Add a link: PR, design, doc, file…", text: $newLink)
                .qbField()
                .onSubmit { commitLink(task) }
            Picker("", selection: $newLinkKind) {
                Text("Auto").tag(LinkKind?.none)
                ForEach(LinkKind.allCases, id: \.self) { Text($0.display).tag(LinkKind?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Button("Add") { commitLink(task) }
                .buttonStyle(QBPrimaryButtonStyle(compact: true))
                .disabled(newLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commitLink(_ task: TodoTask) {
        guard !newLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.addLink(task, url: newLink, kind: newLinkKind) {
            newLink = ""
            newLinkKind = nil
        }
    }

    /// The Detail editor (Notion-style blocks over markdown, `MarkdownEditor`), as tall as
    /// its content. No field frame: the text sits on the section like a page.
    private func detailSection(_ task: TodoTask) -> some View {
        QBDetailSection("Detail") {
            MarkdownEditor(docId: task.id, markdown: $detail, height: $detailHeight, store: model.store,
                           onOtherDoc: { id, md in model.saveDetail(taskId: id, markdown: md) },
                           onError: { model.flashToast($0) })
                // A little room under short text for the "/" menu and link popups, which
                // stay inside the view.
                .frame(height: max(140, detailHeight + 8))
        }
    }

    /// The task's timeline: an input to add a note (with its kind), then the notes, the
    /// change history and the questions asked, newest first, filtered by kind. Notes come a
    /// page at a time (`AppModel.selectedTaskNotes`, which also picks up notes added over
    /// MCP on the next poll); while older notes are left out, so are older changes.
    private func timelineSection(_ task: TodoTask) -> some View {
        QBDetailSection("Timeline") {
            HStack(alignment: .top, spacing: 8) {
                TextField("Add a note…", text: $noteText, axis: .vertical)
                    .lineLimit(1...5)
                    .qbField()
                    .onSubmit { commitNote(task) }
                Picker("", selection: $noteKind) {
                    ForEach(NoteKind.writable, id: \.self) { Text($0.display).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add") { commitNote(task) }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Picker("Show", selection: $timelineFilter) {
                    ForEach(TimelineFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            .font(Theme.Fonts.caption)
            let entries = timelineEntries()
            if entries.isEmpty {
                Text(timelineFilter == .all ? "Nothing yet" : "Nothing of this kind yet")
                    .foregroundStyle(Theme.Colors.slate).font(Theme.Fonts.caption)
            } else {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .note(let n):
                            NoteRow(note: n, statusEvent: n.statusEventId.flatMap { id in
                                        model.selectedTaskEvents.first { $0.id == id } },
                                    question: n.questionId.flatMap { model.selectedTaskQuestions[$0] })
                        case .event(let e):
                            HistoryRow(event: e)
                        }
                    }
                }
            }
            if model.hasOlderNotes {
                Button("Show older") { model.showOlderNotes() }
                    .buttonStyle(QBLinkButtonStyle())
            }
        }
    }

    /// Notes and history merged newest first. A status change that came with a shown note
    /// appears inside that note, not again on its own.
    private func timelineEntries() -> [TimelineEntry] {
        let notes = model.selectedTaskNotes
        let shown = timelineFilter.includesNotes ? notes.filter(timelineFilter.matches) : []
        let linked = Set(shown.compactMap(\.statusEventId))
        // Older notes not loaded yet: leave out the changes from before them too.
        let floor = model.hasOlderNotes ? notes.last?.timestamp : nil
        var entries = shown.map(TimelineEntry.note)
        if timelineFilter == .all || timelineFilter == .changes {
            entries += model.selectedTaskEvents
                .filter { e in !linked.contains(e.id) && floor.map { e.timestamp >= $0 } ?? true }
                .map(TimelineEntry.event)
        }
        // History has whole-second times: equal times fall back to the row id, numerically.
        return entries.sorted { $0.date != $1.date ? $0.date > $1.date : $0.seq > $1.seq }
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
            // Effort only grew with the Pomodoro timer (gone in 1.5.0): shown when a task has some.
            if task.effortSeconds > 0 {
                LabeledContent("Effort", value: fmtEffort(task.effortSeconds))
            }
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

    // Per-field edits: the editor value differs from `t` (the snapshot, see `base`).
    private func titleEdited(_ t: TodoTask) -> Bool { title != t.title }
    private func detailEdited(_ t: TodoTask) -> Bool { detail != t.detail }
    private func branchEdited(_ t: TodoTask) -> Bool { branch != (t.branch ?? "") }
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
        if noteDraftTaskId != t.id {
            noteText = ""; noteKind = .note; noteDraftTaskId = t.id
            newLink = ""; newLinkKind = nil
            relationQuery = ""; dropOffer = nil
        }
        title = t.title; detail = t.detail; branch = t.branch ?? ""; status = t.status
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
        if !branchEdited(b) { branch = t.branch ?? "" }
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
        let edits = [titleEdited(b), detailEdited(b), branchEdited(b), statusEdited(b), priorityEdited(b),
                     dueEdited(b), tagsEdited(b), recurrenceEdited(b), estimateEdited(b),
                     waitingOnEdited(b), waitingReasonEdited(b)]
        guard edits.contains(true) else { return }
        model.updateTask(
            t,
            title: titleEdited(b) ? title : nil,
            detail: detailEdited(b) ? detail : nil,
            // Status and waiting fields go only when edited, so ordinary edits on a
            // waiting task skip the store's waiting check. Any other status clears them.
            status: statusEdited(b) ? status : nil,
            priority: priorityEdited(b) ? priority : nil,
            dueDate: dueEdited(b) ? .some(hasDue ? dueDate : nil) : nil,
            tags: tagsEdited(b) ? parsedTags : nil,
            recurrence: recurrenceEdited(b) ? .some(recurrence == "none" ? nil : recurrence) : nil,
            estimateSeconds: estimateEdited(b) ? estimateMinutes * 60 : nil,
            waitingOn: waitingOnEdited(b) ? waitingOn : nil,
            waitingReason: waitingReasonEdited(b) ? .some(waitingReason) : nil,
            branch: branchEdited(b) ? .some(branch.isEmpty ? nil : branch) : nil
        )
    }
}

/// A duplicate just marked in the detail, which the user is asked whether to drop.
struct DuplicateDropOffer {
    let duplicate: TodoTask
    let original: TodoTask
}

/// One related task in the detail's Relations: its status, code and title. A click opens
/// it (in its own project); the x removes the relation. A dependency still open is marked
/// as the one blocking this task.
struct RelationCard: View {
    let item: RelatedTask
    let kind: RelationKind
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: qbStatusIcon(item.status)).foregroundStyle(qbStatusColor(item.status))
            CodeBadge(code: item.code)
            Text(item.title)
                .font(Theme.Fonts.bodySm)
                .strikethrough(item.status.isClosed)
                .foregroundStyle(qbTitleColor(item.status))
                .lineLimit(1)
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.steel)
                .help("Remove relation")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(helpText)
    }

    private var helpText: String {
        kind == .blockedBy && !item.status.isClosed ? "Open \(item.code) — still blocking this task" : "Open \(item.code)"
    }
}

/// The list's mark on a task that other unfinished tasks are waiting on.
struct BlocksOthersMark: View {
    let count: Int

    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.caption2)
            .foregroundStyle(Theme.Colors.brandYellowDeep)
            .help("Blocks \(count) unfinished task\(count == 1 ? "" : "s")")
    }
}

/// One of a task's links in the detail: an icon for its kind and its title (or url, mono
/// for a branch), with the url under a title. A click opens it (`AppModel.openLink`); the
/// kind menu re-marks it; the x removes it.
struct LinkRow: View {
    @EnvironmentObject var model: AppModel
    let link: TaskLink

    var body: some View {
        HStack(spacing: 8) {
            Button { model.openLink(link) } label: { label }
                .buttonStyle(.plain)
                .help(link.url)
            Spacer(minLength: 4)
            kindMenu
            Button { model.removeLink(link) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.steel)
                .help("Remove link")
        }
        .contextMenu {
            Button("Copy URL") { model.copyCode(link.url) }
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: qbLinkIcon(link.kind))
                .foregroundStyle(Theme.Colors.brandBlue)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(link.title ?? link.url)
                    .font(link.kind == .branch && link.title == nil ? Theme.Fonts.codeBadge : Theme.Fonts.bodySm)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if link.title != nil {
                    Text(link.url)
                        .font(Theme.Fonts.micro)
                        .foregroundStyle(Theme.Colors.steel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var kindMenu: some View {
        Menu {
            ForEach(LinkKind.allCases, id: \.self) { k in
                Button { model.setLinkKind(link, k) } label: {
                    if k == link.kind { Label(k.display, systemImage: "checkmark") } else { Text(k.display) }
                }
            }
        } label: {
            Text(link.kind.display).font(Theme.Fonts.micro)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("What this link is")
    }
}

/// The SF Symbol for a link kind.
func qbLinkIcon(_ kind: LinkKind) -> String {
    switch kind {
    case .pr: return "arrow.triangle.pull"
    case .design: return "paintpalette"
    case .doc: return "doc.text"
    case .file: return "folder"
    case .branch: return "arrow.triangle.branch"
    case .other: return "link"
    }
}

/// The branch a task's work is on, as a small mono chip (task rows).
struct BranchChip: View {
    let name: String
    var body: some View {
        Label(name, systemImage: "arrow.triangle.branch")
            .font(Theme.Fonts.codeBadge)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.xs))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs).stroke(Theme.Colors.hairline, lineWidth: 1))
            .foregroundStyle(Theme.Colors.steel)
            .frame(maxWidth: 220, alignment: .leading)
            .help(name)
    }
}

/// One row in a task's change history.
struct HistoryRow: View {
    let event: TaskEvent
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink)
                if let by { Text(by).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).lineLimit(1) }
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

    private var label: String { TaskEvent.label(forField: event.field) }

    /// Who made the change, when recorded: "you" (the app) or "agent" (MCP, a hook), with
    /// the agent's session label; nothing on older rows.
    private var by: String? {
        guard let source = event.source else { return nil }
        switch source {
        case .app: return "by you"
        case .mcp, .hook:
            let session = event.sessionLabel ?? event.agentSessionId.map { "session \($0.prefix(8))" }
            return session.map { "by agent · \($0)" } ?? "by agent"
        case .cli, .importer: return "by \(source.display)"
        }
    }
}

/// What the task timeline shows: everything, the change history, or one kind of note.
/// One filter per NoteKind, so a new kind is filterable without touching this. Stored by
/// raw value ("all", "changes", or the kind's) in @AppStorage.
struct TimelineFilter: RawRepresentable, Hashable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let all = TimelineFilter(rawValue: "all")
    static let changes = TimelineFilter(rawValue: "changes")
    static var allCases: [TimelineFilter] {
        [.all, .changes] + NoteKind.allCases.map { TimelineFilter(rawValue: $0.rawValue) }
    }

    var kind: NoteKind? { NoteKind(rawValue: rawValue) }

    var title: String {
        switch self {
        case .all: return "Everything"
        case .changes: return "Changes"
        default: return kind?.display ?? rawValue
        }
    }

    var includesNotes: Bool { self != .changes }

    /// Does the note show? Questions also show the decision each answer became. An unknown
    /// stored value (a kind since removed) shows everything.
    func matches(_ note: TaskNote) -> Bool {
        if self == .changes { return false }
        guard let kind else { return true }
        return kind == .question ? note.kind == .question || note.questionId != nil : note.kind == kind
    }
}

/// One row of the task timeline.
enum TimelineEntry: Identifiable {
    case note(TaskNote)
    case event(TaskEvent)

    var id: String {
        switch self {
        case .note(let n): return "n\(n.id)"
        case .event(let e): return "e\(e.id)"
        }
    }

    var date: Date {
        switch self {
        case .note(let n): return n.timestamp
        case .event(let e): return e.timestamp
        }
    }

    /// The row id in its own table, for ordering entries with the same time.
    var seq: Int64 {
        switch self {
        case .note(let n): return n.id
        case .event(let e): return e.id
        }
    }
}

/// One note in the timeline: kind chip, who wrote it and when, then the (selectable)
/// text. The status change it came with and, for a question, its state and answer show
/// under it. The user's own notes can be edited in place; earlier versions are kept and
/// listed from the "edited" label.
struct NoteRow: View {
    @EnvironmentObject var model: AppModel
    let note: TaskNote
    var statusEvent: TaskEvent? = nil
    var question: Question? = nil
    @State private var editing = false
    @State private var draft = ""
    @State private var showEdits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                NoteKindChip(kind: note.kind)
                if let author = note.author {
                    Text(author.display).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.slate)
                }
                if note.editedAt != nil {
                    Button("edited") { showEdits = true }
                        .buttonStyle(.plain)
                        .font(Theme.Fonts.micro)
                        .foregroundStyle(Theme.Colors.steel)
                        .underline()
                        .help("Show earlier versions")
                        .popover(isPresented: $showEdits) { NoteEditsView(note: note) }
                }
                Spacer()
                if note.author == .user && note.questionId == nil && !editing {
                    Button { draft = note.text; editing = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Colors.steel)
                        .help("Edit your note")
                }
                Text(fmtDateTime(note.timestamp)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .lineLimit(1...8)
                    .qbField()
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                        .buttonStyle(QBSecondaryButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                    Button("Save") { if model.editNote(note, text: draft) { editing = false } }
                        .buttonStyle(QBPrimaryButtonStyle(compact: true))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(note.text)
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = statusEvent, e.field == "status" {
                Text("with status \(e.oldValue) → \(e.newValue)")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            if note.kind == .question, let q = question { questionFooter(q) }
        }
        .padding(.vertical, 2)
    }

    /// A question note's state: waiting for you (with a link to answer it), or the answer.
    @ViewBuilder
    private func questionFooter(_ q: Question) -> some View {
        switch q.status {
        case .open:
            HStack(spacing: 6) {
                Text("Waiting for your answer").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.coralDark)
                Button("Answer…") {
                    model.selectQuestions()
                    model.selectedQuestionId = q.id
                }
                .buttonStyle(QBLinkButtonStyle())
                .font(Theme.Fonts.micro)
            }
        case .answered, .resumed:
            Text("Answered: \(q.answer ?? "")" + (q.status == .answered ? " · agent has not picked it up yet" : ""))
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.mossDark)
                .textSelection(.enabled)
        case .cancelled:
            Text("Withdrawn" + (q.cancelReason.map { ": \($0)" } ?? ""))
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        }
    }
}

/// A note's earlier versions, newest first (popover from a note's "edited" label).
struct NoteEditsView: View {
    @EnvironmentObject var model: AppModel
    let note: TaskNote

    var body: some View {
        let edits = model.noteEdits(note)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Earlier versions").font(Theme.Fonts.captionBold)
            if edits.isEmpty {
                Text("No earlier versions").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            }
            ForEach(edits) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text("Replaced \(fmtDateTime(e.timestamp))").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                    Text(e.text).font(Theme.Fonts.bodySm).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(width: 320, alignment: .leading)
    }
}

/// Note kind pill: parchment for a note, gold for a decision, herb green for a review,
/// blue for progress, coral for a question, charcoal for a summary.
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
        case .progress: return (Theme.Colors.brandBlue.opacity(0.15), Theme.Colors.brandBlue)
        case .decision: return (Theme.Colors.yellowLight, Theme.Colors.yellowDark)
        case .summary: return (Theme.Colors.charcoal, Theme.Colors.onDark)
        case .review: return (Theme.Colors.tealLight, Theme.Colors.mossDark)
        case .question: return (Theme.Colors.coralLight, Theme.Colors.coralDark)
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

/// Format a date as "Nov 15", locale-safe (Gregorian).
func fmtShortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "MMM d"
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

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shortcuts: ShortcutStore
    @State private var notify = true
    @State private var sound = true
    @State private var agentNotify = true
    @State private var mcpStatus = ""
    @State private var showGuide = false

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Remind me when a task is due", isOn: $notify)
                Toggle("Notify me when an agent needs me", isOn: $agentNotify)
                    .help("A task an agent set waiting on you, a new question or approval, or a session waiting at its terminal")
                Toggle("Play sound", isOn: $sound).disabled(!notify && !agentNotify)
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
            CLISettingsSection()
            HookSettingsSection()
            Section {
                Button("Edit Guide for All Projects…") { showGuide = true }
            } header: {
                Text("Agent Guide")
            } footer: {
                Text("How agents work on your tasks. A project's own guide is in its menu in the sidebar (Edit Guide…).")
                    .font(.caption).foregroundStyle(.secondary)
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
        .sheet(isPresented: $showGuide) { GuideSheet(project: nil) }
        .onAppear { loadValues() }
        .onChange(of: notify) { _, _ in save() }
        .onChange(of: sound) { _, _ in save() }
        .onChange(of: agentNotify) { _, _ in save() }
    }

    private func loadValues() {
        let s = model.settings
        notify = s.notificationsEnabled
        sound = s.soundEnabled
        agentNotify = s.agentNotificationsEnabled
        refreshMCP()
    }

    private func refreshMCP() {
        if MCPRegistration.registeredPath() == nil { mcpStatus = "Not registered" }
        else if MCPRegistration.isUpToDate() { mcpStatus = "Registered ✓" }
        else { mcpStatus = "Registered (path outdated — re-register)" }
    }

    private func save() {
        model.saveSettings(AppSettings(notificationsEnabled: notify, soundEnabled: sound,
                                      agentNotificationsEnabled: agentNotify))
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
    var actionTitle = "Create"
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
                Button(actionTitle) { create() }
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

/// The stats dashboard: tasks completed per day (last 7 days), plus what is in flight now
/// (in progress, open questions). Uses Swift Charts, with a custom fallback below macOS 13.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    private var completedToday: Int { model.daySeries.last?.tasksCompleted ?? 0 }
    private var totalCompleted: Int { model.daySeries.reduce(0) { $0 + $1.tasksCompleted } }

    private var completedData: [BarDatum] {
        model.daySeries.map { BarDatum(label: weekday($0.date), value: Double($0.tasksCompleted)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Stats")
                    .font(Theme.Fonts.heading3)
                    .foregroundStyle(Theme.Colors.ink)
                summaryTiles
                ChartCard(title: "Tasks completed per day", subtitle: "last 7 days") {
                    BarChartView(data: completedData, unit: "count", tint: Theme.Colors.successAccent) { "\(Int($0))" }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .qbParchment()
        .navigationTitle("Dashboard")
        .onAppear { model.reloadDashboard() }
    }

    /// Summary tiles: completions (today, last 7 days) and the work in flight now.
    private var summaryTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            StatTile(icon: "checkmark.circle", tint: Theme.Colors.successAccent,
                     value: "\(completedToday)", label: "Completed today")
            StatTile(icon: "checkmark.seal", tint: Theme.Colors.brandCoral,
                     value: "\(totalCompleted)", label: "Completed (7d)")
            StatTile(icon: "play.circle", tint: Theme.Colors.brandYellowDeep,
                     value: "\(model.inProgressTasks.count)", label: "In progress")
            StatTile(icon: "questionmark.bubble", tint: Theme.Colors.brandBlue,
                     value: "\(model.openQuestions.count)", label: "Open questions")
        }
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
