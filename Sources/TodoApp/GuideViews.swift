import SwiftUI

// MARK: - Agent commands

/// Claude Code commands for the bundled MCP server's prompts (AgentGuide), named after
/// this flavor's registration (quest-bits or quest-bits-dev), for the user to paste.
enum AgentCommand {
    static func work(_ code: String) -> String {
        "/mcp__\(MCPRegistration.serverKey)__\(AgentGuide.workPrompt) \(code)"
    }
    static var resume: String { "/mcp__\(MCPRegistration.serverKey)__\(AgentGuide.resumePrompt)" }
    static var resumeLoop: String { "/loop 20m \(resume)" }
}

/// A command to paste into Claude Code, with a copy button.
struct CommandRow: View {
    @EnvironmentObject var model: AppModel
    let command: String
    var note: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(command)
                    .font(Theme.Fonts.codeBadge)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if let note {
                    Text(note).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                }
            }
            Spacer(minLength: 4)
            Button {
                copyToClipboard(command)
                model.flashToast("Copied")
            } label: {
                Image(systemName: "doc.on.doc").foregroundStyle(Theme.Colors.brandBlue)
            }
            .buttonStyle(.borderless)
            .help("Copy command")
        }
    }
}

// MARK: - Guides

/// The guide editor in a sheet (the user's guide for every project, or a project's from
/// its sidebar menu). A project's Guide tab shows the same GuideEditor in place.
struct GuideSheet: View {
    let project: Project?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GuideEditor(project: project)
            HStack {
                Spacer()
                // No Return shortcut: Return belongs to the editor.
                Button("Done") { dismiss() }
                    .buttonStyle(QBPrimaryButtonStyle(compact: true))
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 620, height: 640)
        .qbParchment()
    }
}

/// Edit an agent guide: the user's guide for every project (`project` nil) or one
/// project's. get_guide gives agents QuestBits' built-in guide, then the user's, then the
/// project's. Saved as you type; History lists every version (the user's and agents') and
/// restores one. Each save names the version it was edited from: if an agent saved in
/// between, the editor shows the agent's version instead of overwriting it. After any
/// other failed save it stops saving and says so, rather than failing on every keystroke.
/// `showsBuiltIn` false leaves out the built-in rules, for a page that shows them beside it.
struct GuideEditor: View {
    @EnvironmentObject var model: AppModel
    let project: Project?
    var showsBuiltIn = true
    @State private var markdown = ""
    @State private var height: CGFloat = 200
    @State private var latest: GuideVersion?
    @State private var loaded = false
    @State private var showHistory = false
    @State private var showBuiltIn = false
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project.map { "Guide · \($0.name)" } ?? "Guide · All projects")
                    .font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                Spacer()
                if project != nil, loaded, markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    templateMenu
                }
                Button("History…") { showHistory = true }
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
            }
            Text(project == nil
                 ? "How agents should work on your tasks in every project. They read it with get_guide, after QuestBits' built-in rules."
                 : "How agents should work on this project's tasks, e.g. what to check before asking and what \"done\" means. They read it with get_guide, after your guide for all projects.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                // No fixedSize: in a project's Guide tab the split view measures this column
                // at tiny widths, and a text fixed to its full height there would stretch
                // the whole window's content.
                .lineLimit(3)
            if let saveError {
                Text(saveError).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.coralDark)
            } else if let latest {
                Text(Self.changedLabel(latest)).font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
            }
            ScrollView {
                if loaded {
                    // docId only tells this editor's documents apart; it shows one guide.
                    MarkdownEditor(docId: 0, markdown: $markdown, height: $height, store: model.store,
                                   onOtherDoc: { _, md in save(md) }, onError: { model.flashToast($0) })
                        .frame(height: max(240, height + 8))
                }
            }
            .frame(maxHeight: .infinity)
            if showsBuiltIn {
                DisclosureGroup("QuestBits' built-in rules (\(AgentGuide.version))", isExpanded: $showBuiltIn) {
                    ScrollView {
                        GuideMarkdownView(markdown: AgentGuide.builtIn)
                            .padding(.vertical, 4)
                    }
                    .frame(height: 220)
                }
                .font(Theme.Fonts.caption)
            }
        }
        .onAppear {
            latest = model.guide(projectId: project?.id)
            markdown = latest?.markdown ?? ""
            loaded = true
        }
        .onChange(of: markdown) { _, md in save(md) }
        .sheet(isPresented: $showHistory) {
            GuideHistoryView(project: project) { restore($0) }
        }
    }

    private func save(_ md: String, reason: String? = nil) {
        guard loaded, saveError == nil else { return }
        do {
            latest = try model.saveGuide(projectId: project?.id, markdown: md, basedOn: latest?.id, reason: reason)
            if reason != nil, let latest { markdown = latest.markdown }
        } catch let conflict as GuideConflict {
            // An agent saved first: show its version (the edit that hit it is not saved).
            latest = conflict.current
            markdown = conflict.current.markdown
            model.flashToast("An agent changed this guide; showing its version")
        } catch {
            saveError = "Couldn't save the guide: \(error). Close and open it again."
        }
    }

    /// Save an earlier version's text as a new version, and show it.
    private func restore(_ v: GuideVersion) {
        save(v.markdown, reason: "Restored version \(v.id)")
    }

    /// Fill a still-empty project guide from a template, as a version of its own.
    private var templateMenu: some View {
        Menu("Start from template") {
            ForEach(GuideTemplate.allCases) { t in
                Button(t.label) { save(t.markdown, reason: t.reason) }
            }
        }
        .menuStyle(.button).buttonStyle(QBSecondaryButtonStyle(compact: true)).fixedSize()
    }

    static func changedLabel(_ v: GuideVersion) -> String {
        var s = "Version \(v.id) · \(fmtDateTime(v.timestamp)) · "
        s += v.author == .user ? "you" : "an agent" + (v.sessionId.map { " (\($0))" } ?? "")
        if let r = v.reason { s += " · \(r)" }
        return s
    }
}

/// A guide's versions, newest first (the first is the current one); Restore saves an
/// earlier one's text as a new version.
struct GuideHistoryView: View {
    @EnvironmentObject var model: AppModel
    let project: Project?
    let onRestore: (GuideVersion) -> Void
    @State private var versions: [GuideVersion] = []
    @State private var expanded: Set<Int64> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Guide history").font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            if versions.isEmpty {
                Text("No versions yet.").font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                Spacer()
            } else {
                List(versions) { v in row(v, current: v.id == versions.first?.id) }
            }
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
        .onAppear { versions = model.guideHistory(projectId: project?.id) }
    }

    private func row(_ v: GuideVersion, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(GuideEditor.changedLabel(v)).font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Spacer()
                if current {
                    Text("Current").font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.steel)
                } else {
                    Button("Restore") { onRestore(v); dismiss() }
                        .buttonStyle(QBSecondaryButtonStyle(compact: true))
                }
            }
            Text(v.markdown.isEmpty ? "(empty)" : v.markdown)
                .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.slate)
                .lineLimit(expanded.contains(v.id) ? nil : 3)
                .textSelection(.enabled)
                .onTapGesture {
                    if expanded.contains(v.id) { expanded.remove(v.id) } else { expanded.insert(v.id) }
                }
        }
        .padding(.vertical, 3)
    }
}

/// Read-only rendering of the guide markdown QuestBits writes itself (AgentGuide.builtIn):
/// `## ` headings, `- ` bullets and paragraphs, with inline `code` and **bold**.
struct GuideMarkdownView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(String), bullet(String), paragraph(String)
    }

    private var blocks: [Block] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return .heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                switch block {
                case .heading(let t):
                    Text(t.uppercased())
                        .font(Theme.Fonts.microUppercase).tracking(0.5)
                        .foregroundStyle(Theme.Colors.steel)
                        .padding(.top, i == 0 ? 0 : 8)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Theme.Colors.brandYellowDeep)
                        inline(t)
                    }
                case .paragraph(let t):
                    inline(t)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> some View {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
            .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            .fixedSize(horizontal: false, vertical: true)
    }
}
