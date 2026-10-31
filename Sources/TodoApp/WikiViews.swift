import SwiftUI

// MARK: - Project wiki (1.5.0)

/// An entry of a project's wiki list: one of its pages, or a decision note of one of its
/// tasks (shown under Decisions, read from the task, never copied).
enum WikiItem: Hashable {
    case page(Int64)
    case note(Int64)
}

/// The Wiki tab's content column: the project's decisions (decision pages, then the
/// decision notes of its tasks) and notes, with a search over them and buttons to add a
/// page. Agents read and write the same pages over MCP (search_pages, create_page, ...).
struct WikiListView: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var newKind: PageKind?

    var body: some View {
        Group {
            if model.wikiItems.isEmpty {
                ContentUnavailableViewCompat(text: model.wikiQuery.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "No pages yet.\nKeep the project's decisions and notes here; agents search them."
                    : "Nothing matches \"\(model.wikiQuery)\"")
            } else {
                list
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { searchBar }
        .navigationTitle(project.name)
        .qbParchment()
        .sheet(item: $newKind) { kind in
            NewPageSheet(kind: kind) { title in model.createWikiPage(kind: kind, title: title) != nil }
        }
    }

    private var decisions: [ProjectPage] { model.wikiPages.filter { $0.kind == .decision } }
    private var notes: [ProjectPage] { model.wikiPages.filter { $0.kind == .note } }

    private var list: some View {
        List(selection: $model.wikiSelection) {
            if !decisions.isEmpty || !model.wikiDecisionNotes.isEmpty {
                // Identified by WikiItem: a page and a note may share a numeric id.
                Section("Decisions") {
                    ForEach(decisions.map { WikiItem.page($0.id) } + model.wikiDecisionNotes.map { WikiItem.note($0.note.id) },
                            id: \.self) { item in row(item).tag(item) }
                }
            }
            if !notes.isEmpty {
                Section("Notes") {
                    ForEach(notes.map { WikiItem.page($0.id) }, id: \.self) { item in row(item).tag(item) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: WikiItem) -> some View {
        switch item {
        case .page(let id):
            if let p = model.wikiPages.first(where: { $0.id == id }) { WikiPageRow(page: p) }
        case .note(let id):
            if let hit = model.wikiDecisionNotes.first(where: { $0.note.id == id }) { WikiNoteRow(hit: hit) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search the wiki", text: $model.wikiQuery)
                .textFieldStyle(.roundedBorder)
            Menu("New") {
                Button("Decision…") { newKind = .decision }
                Button("Note…") { newKind = .note }
            }
            .menuStyle(.button).buttonStyle(QBSecondaryButtonStyle(compact: true)).fixedSize()
            .disabled(project.isArchived)
            .help(project.isArchived ? "Unarchive the project to add pages" : "Add a page")
        }
        .padding(10)
        .background(alignment: .bottom) { Divider() }
    }
}

extension PageKind: Identifiable {
    public var id: String { rawValue }
}

/// A page in the wiki list: title, then its date (decisions) or last change.
struct WikiPageRow: View {
    let page: ProjectPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(page.title).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(2)
            Text(subtitle).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if page.kind == .decision {
            return [page.decidedOn, page.outcome].compactMap { $0 }.joined(separator: " · ")
        }
        return "Updated \(fmtDateTime(page.updatedAt))"
    }
}

/// A task's decision note in the wiki list: the task's code and the note's first line.
struct WikiNoteRow: View {
    let hit: NoteSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                CodeBadge(code: hit.taskCode)
                Text("Decision note").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                Spacer(minLength: 4)
                Text(fmtShortDate(hit.note.timestamp)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            Text(firstLine).font(Theme.Fonts.bodySm).foregroundStyle(Theme.Colors.ink).lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private var firstLine: String {
        hit.note.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}

/// Name a new page; Create adds it and opens it for editing.
struct NewPageSheet: View {
    let kind: PageKind
    /// Returns whether the page was added (a refusal shows as a toast and keeps the sheet).
    let onCreate: (String) -> Bool
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .decision ? "New Decision" : "New Note")
                .font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            TextField(kind == .decision ? "What was decided, in a few words" : "Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                Button("Create", action: create)
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 420)
        .qbParchment()
    }

    private func create() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if onCreate(title) { dismiss() }
    }
}

// MARK: - Detail column

/// The Wiki tab's detail column: the selected page (read, or edited), or a task's
/// decision note.
struct WikiDetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.wikiSelection {
        case .page(let id):
            if let page = model.wikiPages.first(where: { $0.id == id }) {
                WikiPageView(page: page).id(id)
            } else {
                ContentUnavailableViewCompat(text: "Pick a page")
            }
        case .note(let id):
            if let hit = model.wikiDecisionNotes.first(where: { $0.note.id == id }) {
                WikiDecisionNoteView(hit: hit)
            } else {
                ContentUnavailableViewCompat(text: "Pick a page")
            }
        case nil:
            ContentUnavailableViewCompat(text: model.wikiItems.isEmpty ? "No pages yet" : "Pick a page")
        }
    }
}

/// A page, rendered: kind, title, a decision's date and outcome, its tasks, the body.
/// Task codes in the text open the task. Edit switches to the editor in place.
struct WikiPageView: View {
    @EnvironmentObject var model: AppModel
    let page: ProjectPage
    @State private var editing = false
    @State private var showHistory = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if editing {
                WikiPageEditor(page: page) { editing = false }
            } else {
                reader
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .qbParchment()
        .onAppear { if page.version == 1 && page.body.isEmpty && page.author == .user { editing = true } }
        .sheet(isPresented: $showHistory) { WikiHistoryView(page: page) }
        .confirmationDialog("Delete \"\(page.title)\"?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteWikiPage(page.id) }
        } message: {
            Text("The page and its history are deleted. This can't be undone.")
        }
    }

    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if page.kind == .decision, let outcome = page.outcome {
                    labeled("Outcome") {
                        Text(outcome).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                    }
                }
                if !page.tasks.isEmpty {
                    labeled("Tasks") { WikiTaskChips(tasks: page.tasks) }
                }
                if page.body.isEmpty {
                    Text("Empty").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.steel)
                } else {
                    WikiMarkdownView(markdown: page.body)
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(page.kind.display.uppercased()).font(Theme.Fonts.microUppercase).tracking(0.5)
                    .foregroundStyle(Theme.Colors.steel)
                if let d = page.decidedOn {
                    Text(d).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
                Spacer()
                actions
            }
            Text(page.title).font(Theme.Fonts.heading4).foregroundStyle(Theme.Colors.inkDeep)
                .textSelection(.enabled)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Edit") { editing = true }
                .buttonStyle(QBSecondaryButtonStyle(compact: true))
            Menu("More") {
                Button(page.kind == .decision ? "Make it a note" : "Make it a decision") {
                    model.setWikiPageKind(page.id, page.kind == .decision ? .note : .decision)
                }
                Button("History…") { showHistory = true }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            }
            .menuStyle(.button).buttonStyle(QBSecondaryButtonStyle(compact: true)).fixedSize()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Version \(page.version) · updated \(fmtDateTime(page.updatedAt)) · created by "
                 + (page.author == .user ? "you" : "an agent") + (page.sessionId.map { " (\($0))" } ?? ""))
            if let source = sourceLine { Text(source) }
        }
        .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
        .padding(.top, 8)
    }

    /// Where an imported page came from, as far as known.
    private var sourceLine: String? {
        let p = page.provenance
        guard !p.isEmpty else { return nil }
        var parts = [p.source ?? p.key ?? "an import"]
        if let a = p.author { parts.append("by \(a)") }
        if let t = p.timestamp { parts.append(fmtDateTime(t)) }
        return "From " + parts.joined(separator: " · ")
    }

    private func labeled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Theme.Fonts.microUppercase).tracking(0.5)
                .foregroundStyle(Theme.Colors.steel)
            content()
        }
    }
}

/// A page's tasks as code chips; clicking one opens the task.
struct WikiTaskChips: View {
    @EnvironmentObject var model: AppModel
    let tasks: [RelatedTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tasks) { t in
                Button { model.openTask(code: t.code) } label: {
                    HStack(spacing: 6) {
                        CodeBadge(code: t.code)
                        Text(t.title).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate).lineLimit(1)
                        if t.status.isClosed {
                            Text(t.status.rawValue).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(t.code)")
            }
        }
    }
}

/// A task's decision note, read-only here (it lives on the task).
struct WikiDecisionNoteView: View {
    @EnvironmentObject var model: AppModel
    let hit: NoteSearchHit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("DECISION NOTE").font(Theme.Fonts.microUppercase).tracking(0.5).foregroundStyle(Theme.Colors.steel)
                Button { model.openTask(code: hit.taskCode) } label: {
                    HStack(spacing: 6) {
                        CodeBadge(code: hit.taskCode)
                        Text(hit.taskTitle).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.ink).lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(hit.taskCode)")
                WikiMarkdownView(markdown: hit.note.text)
                Text(byLine).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                Text("Written on the task; edit or reply to it there.")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .qbParchment()
    }

    private var byLine: String {
        var s = fmtDateTime(hit.note.timestamp)
        if let a = hit.note.author { s += " · " + (a == .user ? "you" : "an agent") }
        if let session = hit.note.sessionId { s += " (\(session))" }
        return s
    }
}

// MARK: - Editing

/// Edit a page in place: title, a decision's outcome and date, its tasks (codes) and the
/// body in the block editor. Save writes it all at once, made from the version shown: if
/// an agent changed the page meanwhile, nothing is saved; the editor stays open with the
/// user's text and shows the agent's version beside it, and a second Save overwrites it.
struct WikiPageEditor: View {
    @EnvironmentObject var model: AppModel
    let page: ProjectPage
    let onClose: () -> Void
    @State private var title = ""
    @State private var outcome = ""
    @State private var decidedOn = Date()
    @State private var taskCodes = ""
    @State private var body_ = ""
    @State private var height: CGFloat = 200
    @State private var flush = EditorFlush()
    @State private var loaded = false
    /// The version the edit started from: `page` follows the store (an agent's write
    /// reloads it), so the save must not take the newer version as its base.
    @State private var baseVersion = 0
    /// The agent's version, after a save refused because the page changed meanwhile.
    @State private var conflict: ProjectPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let conflict { ConflictNotice(theirs: conflict, onDismiss: { self.conflict = nil }) }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Fonts.bodyMdMedium)
            if page.kind == .decision { decisionFields }
            field("Tasks") {
                TextField("Task codes, e.g. \(model.selectedProject?.code ?? "GEN")-3, \(model.selectedProject?.code ?? "GEN")-7",
                          text: $taskCodes)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                if loaded {
                    MarkdownEditor(docId: page.id, markdown: $body_, height: $height, store: model.store,
                                   onOtherDoc: { _, _ in }, onError: { model.flashToast($0) }, flush: flush)
                        .frame(height: max(260, height + 8))
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.hairlineStrong))
            buttons
        }
        .onAppear(perform: load)
    }

    private var decisionFields: some View {
        HStack(alignment: .top, spacing: 10) {
            field("Outcome") {
                TextField("What was decided", text: $outcome).textFieldStyle(.roundedBorder)
            }
            field("Decided on") {
                DatePicker("", selection: $decidedOn, displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).fixedSize()
            }
        }
    }

    private var buttons: some View {
        HStack {
            Text("Write task codes like \(model.selectedProject?.code ?? "GEN")-3 anywhere; they open the task.")
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel).lineLimit(2)
            Spacer()
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                .buttonStyle(QBSecondaryButtonStyle(compact: true))
            // ⌘Return, not Return: Return belongs to the editor.
            Button("Save", action: save)
                .buttonStyle(QBPrimaryButtonStyle(compact: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            content()
        }
    }

    private func load() {
        title = page.title
        outcome = page.outcome ?? ""
        decidedOn = page.decidedOn.flatMap { Self.dayFormatter.date(from: $0) } ?? Date()
        taskCodes = page.tasks.map(\.code).joined(separator: ", ")
        body_ = page.body
        baseVersion = page.version
        loaded = true
    }

    /// Take the editor's last keystrokes (it sends edits 150 ms late), then save.
    private func save() {
        flush { md in
            if let md { body_ = md }
            var ids: [Int64] = []
            for code in taskCodes.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) {
                guard let id = model.store.taskId(forCode: code) else {
                    return model.flashToast("No task \(code)")
                }
                ids.append(id)
            }
            do {
                try model.saveWikiPage(page.id, title: title, body: body_, outcome: outcome,
                                       decidedOn: page.kind == .decision ? Self.dayFormatter.string(from: decidedOn) : nil,
                                       taskIds: ids, version: baseVersion)
                onClose()
            } catch let c as PageConflict {
                // Keep the user's text; the next Save is made from the agent's version, so
                // it overwrites it on purpose (after the user merged what they want).
                conflict = c.current
                baseVersion = c.current.version
                model.reloadWiki()
            } catch {
                model.flashToast("Couldn't save the page: \(error)")
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Shown in the page editor after a save was refused: an agent changed the page while it
/// was being edited. The user's text stays in the editor; the agent's is here to read and
/// copy from, and Save again writes the user's version over it.
private struct ConflictNotice: View {
    let theirs: ProjectPage
    let onDismiss: () -> Void
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if expanded { agentText }
        }
        .padding(Theme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Colors.surfaceSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.Colors.hairlineStrong))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.Colors.steel)
            Text("Not saved: an agent changed this page while you edited it. Your text is kept below. "
                 + "Merge what you need from the agent's version, then Save again to replace it with yours.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(expanded ? "Hide Agent's Version" : "Show Agent's Version") { expanded.toggle() }
                .buttonStyle(QBSecondaryButtonStyle(compact: true))
            Button("Copy Agent's Text", action: copy).buttonStyle(QBSecondaryButtonStyle(compact: true))
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Hide this notice")
        }
    }

    private var agentText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(theirs.title).font(Theme.Fonts.bodyMdMedium)
                if let outcome = theirs.outcome, !outcome.isEmpty {
                    Text("Outcome: \(outcome)").font(Theme.Fonts.caption)
                }
                Text(theirs.body).font(Theme.Fonts.caption).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(theirs.body, forType: .string)
    }
}

/// A page's changes, newest first.
struct WikiHistoryView: View {
    @EnvironmentObject var model: AppModel
    let page: ProjectPage
    @State private var events: [PageEvent] = []
    @State private var expanded: Set<Int64> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("History · \(page.title)").font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink).lineLimit(1)
            List(events) { e in row(e) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 560, height: 520)
        .qbParchment()
        .onAppear { events = model.wikiPageHistory(page.id) }
    }

    private func row(_ e: PageEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label(e)).font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink).lineLimit(1)
            if e.field != "created" {
                Text(e.field == "body" ? e.oldValue : "\(e.oldValue.isEmpty ? "(none)" : e.oldValue) → \(e.newValue.isEmpty ? "(none)" : e.newValue)")
                    .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.slate)
                    .lineLimit(expanded.contains(e.id) ? nil : 3)
                    .textSelection(.enabled)
                    .onTapGesture {
                        if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) }
                    }
            }
        }
        .padding(.vertical, 3)
    }

    private func label(_ e: PageEvent) -> String {
        let what = e.field == "created" ? "Created" : e.field == "body" ? "Text changed (was:)"
            : e.field.replacingOccurrences(of: "_", with: " ").capitalized
        let who = e.author.map { $0 == .user ? "you" : "an agent" } ?? "unknown"
        return "\(what) · \(fmtDateTime(e.timestamp)) · \(who)" + (e.sessionId.map { " (\($0))" } ?? "")
    }
}

// MARK: - Markdown

/// Read-only rendering of a wiki page's markdown: headings, bullet / numbered / task
/// lists, quotes, code blocks, rules and paragraphs, with inline markdown (bold, italic,
/// `code`, links). Task codes (GEN-3) become links that open the task.
struct WikiMarkdownView: View {
    @EnvironmentObject var model: AppModel
    let markdown: String

    enum Block: Hashable {
        case heading(Int, String), bullet(Int, String), numbered(String, String), quote(String)
        case code(String), rule, paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.taskScheme else { return .systemAction }
            model.openTask(code: url.absoluteString.dropFirst(Self.taskScheme.count + 1).description)
            return .handled
        })
    }

    @ViewBuilder
    private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let t):
            inline(t, font: level <= 1 ? Theme.Fonts.heading5 : level == 2 ? Theme.Fonts.bodyMdMedium : Theme.Fonts.bodySmMedium,
                   color: Theme.Colors.inkDeep)
                .padding(.top, 4)
        case .bullet(let depth, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(depth % 2 == 0 ? "•" : "◦").foregroundStyle(Theme.Colors.brandYellowDeep)
                inline(t)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).font(Theme.Fonts.bodySmMedium).foregroundStyle(Theme.Colors.steel)
                inline(t)
            }
        case .quote(let t):
            inline(t, color: Theme.Colors.slate)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.Colors.hairlineStrong).frame(width: 3) }
        case .code(let t):
            Text(t).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.Colors.ink)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.xs))
        case .rule:
            Divider()
        case .paragraph(let t):
            inline(t)
        }
    }

    private func inline(_ s: String, font: Font = Theme.Fonts.bodySm, color: Color = Theme.Colors.ink) -> some View {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let linked = Self.linkTaskCodes(s)
        return Text((try? AttributedString(markdown: linked, options: opts)) ?? AttributedString(s))
            .font(font).foregroundStyle(color)
            .tint(Theme.Colors.brandBlue)
            .fixedSize(horizontal: false, vertical: true)
    }

    static let taskScheme = "questbits-task"

    /// Task codes outside `code` spans and links turned into links to the task.
    static func linkTaskCodes(_ s: String) -> String {
        let parts = s.components(separatedBy: "`")
        return parts.enumerated().map { i, part in
            guard i % 2 == 0 else { return part }   // inside a code span
            return part.replacingOccurrences(
                of: #"(?<![\[\w/#.-])([A-Z][A-Z0-9]{0,9}-\d+)(?![\w\]])"#,
                with: "[$1](\(taskScheme):$1)", options: .regularExpression)
        }.joined(separator: "`")
    }

    /// Split markdown into blocks, line by line; lines of one paragraph are joined.
    static func blocks(_ markdown: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]?
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let indent = raw.prefix { $0 == " " }.count / 2
            if let m = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush(); out.append(.heading(line[m].count - 1, String(line[m.upperBound...])))
            } else if line == "---" || line == "***" || line == "___" {
                flush(); out.append(.rule)
            } else if let m = line.range(of: #"^[-*+] \[( |x|X)\] "#, options: .regularExpression) {
                flush(); out.append(.bullet(indent, (line[m].contains(" ] ") ? "☐ " : "☑ ") + line[m.upperBound...]))
            } else if let m = line.range(of: #"^[-*+] "#, options: .regularExpression) {
                flush(); out.append(.bullet(indent, String(line[m.upperBound...])))
            } else if let m = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush(); out.append(.numbered(String(line[m].dropLast()), String(line[m.upperBound...])))
            } else if line.hasPrefix(">") {
                flush(); out.append(.quote(line.drop { $0 == ">" }.trimmingCharacters(in: .whitespaces)))
            } else {
                para.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}
