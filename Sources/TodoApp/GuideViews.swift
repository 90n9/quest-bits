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

/// Edit an agent guide: the user's guide for every project (`project` nil) or one
/// project's. get_guide gives agents QuestBits' built-in guide, then the user's, then the
/// project's. Saved as you type; History lists every version (the user's and agents') and
/// restores one. The guide is read when the sheet opens.
struct GuideSheet: View {
    @EnvironmentObject var model: AppModel
    let project: Project?
    @State private var markdown = ""
    @State private var height: CGFloat = 200
    @State private var latest: GuideVersion?
    @State private var loaded = false
    @State private var showHistory = false
    @State private var showBuiltIn = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(project.map { "Guide · \($0.name)" } ?? "Guide · All projects")
                    .font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Button("History…") { showHistory = true }
                    .buttonStyle(QBSecondaryButtonStyle(compact: true))
            }
            Text(project == nil
                 ? "How agents should work on your tasks in every project. They read it with get_guide, after QuestBits' built-in rules."
                 : "How agents should work on this project's tasks, e.g. what to check before asking and what \"done\" means. They read it with get_guide, after your guide for all projects.")
                .font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                .fixedSize(horizontal: false, vertical: true)
            if let latest {
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
            DisclosureGroup("QuestBits' built-in rules (\(AgentGuide.version))", isExpanded: $showBuiltIn) {
                ScrollView {
                    Text(AgentGuide.builtIn)
                        .font(Theme.Fonts.micro).foregroundStyle(Theme.Colors.slate)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
            .font(Theme.Fonts.caption)
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

    private func save(_ md: String) {
        guard loaded, let v = model.saveGuide(projectId: project?.id, markdown: md) else { return }
        latest = v
    }

    /// Save an earlier version's text as a new version, and show it.
    private func restore(_ v: GuideVersion) {
        guard let saved = model.saveGuide(projectId: project?.id, markdown: v.markdown,
                                          reason: "Restored version \(v.id)") else { return }
        latest = saved
        markdown = saved.markdown
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
                Text(GuideSheet.changedLabel(v)).font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.ink)
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
