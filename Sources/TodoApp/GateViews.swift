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
            Button("Edit rules…") { editing = true }
                .buttonStyle(.plain)
                .font(Theme.Fonts.captionBold).foregroundStyle(Theme.Colors.brandBlue)
        }
        .onAppear(perform: load)
        .onChange(of: project.id) { _, _ in load() }
        .sheet(isPresented: $editing, onDismiss: load) {
            GateRulesSheet(project: project, rules: rules.joined(separator: "\n"))
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
struct GateRulesSheet: View {
    @EnvironmentObject var model: AppModel
    let project: Project
    @State var rules: String
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

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
        if let error = model.setGateRules(projectId: project.id, rules: lines) {
            problem = error
        } else {
            dismiss()
        }
    }
}
