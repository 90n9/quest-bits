import SwiftUI

/// The project Overview's "Gate" section (QUE-36): the rules that make an agent's call wait
/// for your approval in this project's folder — the defaults, always on, and the project's
/// own, which only you can remove (agents can add one with add_gate_rule).
struct GateRulesSection: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var rules: [String] = []
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
            ForEach(rules, id: \.self) { rule in
                Text(rule).font(Theme.Fonts.caption.monospaced()).foregroundStyle(Theme.Colors.ink)
                    .textSelection(.enabled)
            }
            Button("Edit rules…") { load(); editing = true }
                .buttonStyle(.plain)
                .font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.brandBlue)
        }
        .onAppear(perform: load)
        .onChange(of: project.id) { _, _ in load() }
        .sheet(isPresented: $editing, onDismiss: load) {
            GateRulesSheet(project: project, original: rules)
        }
    }

    private var summary: String {
        let n = GateRule.defaults.count
        return rules.isEmpty ? "\(n) default rules, none of the project's own"
                             : "\(n) default rules, plus the project's own:"
    }

    private func load() { rules = model.gateRules(projectId: project.id) }
}

/// Edit a project's own gate rules, one per line; the defaults are listed for reference.
/// Save only replaces the rules the editor started from (`original`): when an agent added
/// one meanwhile, nothing is saved, the new rules are added to the text and the user saves
/// again, so an agent's rule never disappears unseen.
struct GateRulesSheet: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State private var original: [String]
    @State private var rules: String
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(project: Project, original: [String]) {
        self.project = project
        _original = State(initialValue: original)
        _rules = State(initialValue: original.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gate Rules · \(project.code)").font(Theme.Fonts.heading5).foregroundStyle(Theme.Colors.ink)
            Text(help).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.slate)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $rules)
                .font(Theme.Fonts.caption.monospaced())
                .frame(minHeight: 120)
                .qbField()
            if let problem {
                Text(problem).font(Theme.Fonts.caption).foregroundStyle(.red)
            }
            DisclosureGroup("Default rules (always on)") { defaultsList }
                .font(Theme.Fonts.bodySmMedium)
            buttons
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 520)
    }

    private var help: String {
        "One rule per line. A shell command as plain words, program first (terraform apply, "
            + "git push --force), or tool: and an MCP tool name where * matches anything "
            + "(tool:mcp__*__create_issue). In this project's folder, a matching call waits for your approval."
    }

    private var defaultsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(GateRule.defaults, id: \.text) { rule in
                Text(rule.text).font(Theme.Fonts.caption.monospaced()).foregroundStyle(Theme.Colors.slate)
            }
        }
        .padding(.top, 4)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(QBSecondaryButtonStyle(compact: true))
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(QBPrimaryButtonStyle(compact: true))
        }
    }

    private func save() {
        let lines = rules.split(whereSeparator: \.isNewline).map(String.init)
        do {
            try model.setGateRules(projectId: project.id, rules: lines, basedOn: original)
            dismiss()
        } catch let changed as Store.GateRulesChanged {
            merge(changed.current)
        } catch {
            problem = "\(error)"
        }
    }

    /// The stored rules changed meanwhile: add the ones the editor did not start with.
    private func merge(_ current: [String]) {
        let added = current.filter { !original.contains($0) }
        let typed = Set(rules.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        })
        let missing = added.filter { !typed.contains($0.lowercased()) }
        if !missing.isEmpty { rules += (rules.isEmpty || rules.hasSuffix("\n") ? "" : "\n") + missing.joined(separator: "\n") }
        original = current
        problem = "The rules changed while you were editing"
            + (added.isEmpty ? "" : " (added: " + added.joined(separator: ", ") + ")")
            + ", so nothing was saved. They are in the list now; check it and save again."
    }
}
