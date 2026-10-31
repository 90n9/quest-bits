import SwiftUI

// MARK: - Project page tabs

/// The tabs of a project's page. Tasks is the list (or board) and task detail as before;
/// the others show the rest of the project in place of popups and the sidebar menu.
enum ProjectTab: String, CaseIterable, Identifiable {
    case tasks, detail, wiki, guide, questions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: return "Tasks"
        case .detail: return "Detail"
        case .wiki: return "Wiki"
        case .guide: return "Guide"
        case .questions: return "Questions"
        }
    }
}

/// The tab bar at the top of a project's content column.
struct ProjectTabBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Project view", selection: Binding(get: { model.projectTab }, set: { model.selectProjectTab($0) })) {
            ForEach(ProjectTab.allCases) { tab in Text(label(tab)).tag(tab) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(alignment: .bottom) { Divider() }
    }

    private func label(_ tab: ProjectTab) -> String {
        guard tab == .questions, let code = model.selectedProject?.code else { return tab.title }
        let n = model.openQuestions.filter { $0.projectCode == code }.count
        return n > 0 ? "\(tab.title) (\(n))" : tab.title
    }
}

/// Adds the project tab bar above a content column while a project page is shown.
struct ProjectTabsInset: ViewModifier {
    @EnvironmentObject var model: AppModel

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if model.selectedProject != nil { ProjectTabBar() }
        }
    }
}

/// The content column of a project tab other than Tasks.
struct ProjectTabColumn: View {
    let project: Project
    let tab: ProjectTab

    var body: some View {
        switch tab {
        case .tasks: EmptyView()
        case .detail: ProjectOverview(project: project)
        case .wiki: WikiListView(project: project)
        case .guide: GuideContextView(project: project)
        case .questions: QuestionListView()
        }
    }
}

/// The detail column of a project tab other than Tasks.
struct ProjectTabDetail: View {
    let project: Project
    let tab: ProjectTab

    var body: some View {
        switch tab {
        case .tasks: EmptyView()
        case .detail:
            ProjectDescriptionEditor(project: project).id(project.id)
        case .guide:
            GuideEditor(project: project, showsBuiltIn: false).id(project.id)
                .padding(Theme.Spacing.lg)
                .qbParchment()
        case .wiki: WikiDetailView()
        case .questions: QuestionDetailView()
        }
    }
}

// MARK: - Detail tab

/// The Detail tab's content column: the project at a glance, with links to the other tabs.
struct ProjectOverview: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var editing = false
    @State private var archiving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(project.name).font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                HStack(spacing: 8) {
                    CodeBadge(code: project.code)
                    CopyCodeButton(code: project.code)
                }
                section("Tasks") {
                    let c = model.projectCounts[project.id] ?? ProjectCounts()
                    stat("Open", c.open)
                    stat("Waiting on you", c.waitingOnUser)
                    stat("Done", c.done)
                }
                section("Milestones") {
                    MilestonesSection(project: project)
                }
                section("Wiki") {
                    let pages = model.wikiCounts(projectId: project.id)
                    stat("Decisions", pages[.decision] ?? 0)
                    stat("Notes", pages[.note] ?? 0)
                    link("Open Wiki", .wiki)
                }
                section("Questions") {
                    let n = model.openQuestions.filter { $0.projectCode == project.code }.count
                    stat("Waiting for your answer", n)
                    if n > 0 { link("Answer…", .questions) }
                }
                section("Agent sessions") {
                    ProjectSessionsList(project: project)
                }
                section("Repo folder") {
                    Text(project.repoPath ?? "None").font(Theme.Fonts.caption)
                        .foregroundStyle(project.repoPath == nil ? Theme.Colors.steel : Theme.Colors.slate)
                        .textSelection(.enabled)
                }
                section("Gate") {
                    GateRulesSection(project: project)
                }
                section("Agent guide") {
                    Text(guideLabel).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                    link("Open Guide", .guide)
                }
                Text("Created \(fmtDateTime(project.createdAt))")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                HStack(spacing: 8) {
                    Button("Edit project…") { editing = true }
                        .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    if project.isArchived {
                        Button("Unarchive") { model.setArchived(project.id, false) }
                            .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    } else {
                        Button("Archive…") { archiving = true }
                            .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle(project.name)
        .qbParchment()
        .sheet(isPresented: $editing) {
            ProjectSheet(title: "Edit Project", projectId: project.id, name: project.name, code: project.code,
                         repoPath: project.repoPath ?? "", showsDescription: false) { v in
                model.editProject(project.id, name: v.name, detail: nil, code: v.code, repoPath: v.repoPath)
            }
        }
        .sheet(isPresented: $archiving) {
            ArchiveProjectSheet(project: project, openCount: model.projectCounts[project.id]?.open ?? 0) {
                model.setArchived(project.id, true)
            }
        }
    }

    private var guideLabel: String {
        guard let g = model.guide(projectId: project.id), !g.markdown.isEmpty else { return "No guide yet" }
        return "Version \(g.id) · \(fmtDateTime(g.timestamp))"
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Theme.Fonts.microUppercase).tracking(0.5)
                .foregroundStyle(Theme.Colors.steel)
            content()
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            Spacer()
            Text("\(value)").font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink)
        }
    }

    private func link(_ title: String, _ tab: ProjectTab) -> some View {
        Button(title) { model.selectProjectTab(tab) }
            .buttonStyle(.plain)
            .font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.brandBlue)
    }
}

/// The Detail tab's detail column: the project's description in the Notion-style editor,
/// saved as it is typed. Like the task Detail, it keeps the stored text it was last synced
/// from (`base`): a store change (an agent's update_project) replaces the text only while
/// the user has not edited it, and only an edit (text ≠ base) is written.
struct ProjectDescriptionEditor: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var detail = ""
    @State private var base: String?
    @State private var height: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description").font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            Text("What this project is about. Agents get it with list_projects.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            ScrollView {
                if base != nil {
                    MarkdownEditor(docId: project.id, markdown: $detail, height: $height, store: model.store,
                                   onOtherDoc: { id, md in model.saveProjectDetail(id, markdown: md) },
                                   onError: { model.flashToast($0) })
                        .frame(height: max(320, height.isFinite ? height + 8 : 0))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Spacing.lg)
        .padding(10)
        .qbQuestFrame()
        .padding(6)
        .onAppear { detail = project.detail; base = project.detail }
        .onChange(of: project.detail) { _, stored in
            if detail == base { detail = stored }
            base = stored
        }
        .onChange(of: detail) { _, md in
            if let base, md != base { model.saveProjectDetail(project.id, markdown: md) }
        }
    }
}

// MARK: - Guide tab

/// The Guide tab's content column: what agents read before this project's guide (the
/// built-in rules, then the user's guide for every project), read-only, with the user's
/// guide editable in a sheet. The project's own guide is edited in the detail column.
struct GuideContextView: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var userGuide: GuideVersion?
    @State private var editingUserGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agents call get_guide and read three parts in order. This project's guide comes last and is on the right.")
                    .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                part("1 · QuestBits' built-in rules (\(AgentGuide.version))") {
                    GuideMarkdownView(markdown: AgentGuide.builtIn)
                }
                part("2 · Your guide for all projects") {
                    if let text = userGuide?.markdown, !text.isEmpty {
                        GuideMarkdownView(markdown: text)
                    } else {
                        Text("Empty").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.steel)
                    }
                    Button("Edit…") { editingUserGuide = true }
                        .buttonStyle(QBSecondaryButtonStyle(compact: true))
                }
                part("3 · \(project.name)'s guide") {
                    Text("Edit it on the right.").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.steel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
        }
        .navigationTitle(project.name)
        .qbParchment()
        .onAppear { userGuide = model.guide(projectId: nil) }
        .sheet(isPresented: $editingUserGuide, onDismiss: { userGuide = model.guide(projectId: nil) }) {
            GuideSheet(project: nil)
        }
    }

    private func part(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink)
            content()
        }
    }
}

// MARK: - Archived page

/// The Archived page's content column: archived projects, searchable by name or code,
/// each with its task counts, to open (an archived project is still viewable) or unarchive.
struct ArchivedProjectsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    private var shown: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = model.archivedProjects.sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Group {
            if model.archivedProjects.isEmpty {
                ContentUnavailableViewCompat(text: "No archived projects.\nArchive one from its Detail tab or the sidebar menu.")
            } else if shown.isEmpty {
                ContentUnavailableViewCompat(text: "No archived project matches \"\(query)\"")
            } else {
                List(shown) { p in row(p) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TextField("Search archived projects", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .background(alignment: .bottom) { Divider() }
        }
        .navigationTitle("Archived")
        .qbParchment()
    }

    private func row(_ p: Project) -> some View {
        let c = model.projectCounts[p.id] ?? ProjectCounts()
        // Name and buttons on separate lines: the column can be narrow.
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CodeBadge(code: p.code)
                Text(p.name).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(2)
            }
            Text("\(c.open) open · \(c.done) done" + (p.archivedAt.map { " · archived \(fmtDateTime($0))" } ?? ""))
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).lineLimit(1)
            HStack(spacing: 8) {
                Button("Open") { model.selectProject(p.id) }
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                Button("Unarchive") { model.setArchived(p.id, false) }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .fixedSize()
            }
        }
        .padding(.vertical, 6)
    }
}
