import SwiftUI

/// Settings → Command Line: install or remove the ~/.local/bin link to the bundled
/// `questbits` CLI (`CLIInstaller`). A link to something else is replaced only after the
/// user confirms; a file or folder at that path is reported and left alone.
struct CLISettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var state: CLIInstaller.State = .notInstalled
    @State private var error: String?
    @State private var replaceTarget: String?   // the other link's destination, while asking

    private var target: String? { CLIInstaller.bundledCLIPath() }
    private var link: URL { CLIInstaller.linkURL() }

    var body: some View {
        Section {
            LabeledContent("Status", value: statusText)
            LabeledContent("Link") { pathText(link.path) }
            if case .linkedElsewhere(let dest) = state {
                LabeledContent("Points to") { pathText(dest) }
            }
            actionButton
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Command Line")
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        .alert("Replace the existing link?", isPresented: replaceAsked, presenting: replaceTarget) { _ in
            Button("Replace", role: .destructive) { install(replace: true) }
            Button("Cancel", role: .cancel) {}
        } message: { dest in
            Text("\(tilde(link.path)) points to \(tilde(dest)). Replace it with a link to this app's CLI?")
        }
    }

    @ViewBuilder private var actionButton: some View {
        if state == .installed {
            Button("Remove Link") { remove() }
        } else {
            Button("Install Link") { install(replace: false) }.disabled(target == nil)
        }
    }

    private var replaceAsked: Binding<Bool> {
        Binding(get: { replaceTarget != nil }, set: { if !$0 { replaceTarget = nil } })
    }

    private var statusText: String {
        guard target != nil else { return "Not in this build" }
        switch state {
        case .installed: return "Installed ✓"
        case .notInstalled: return "Not installed"
        case .linkedElsewhere: return "Linked to another copy"
        case .notALink: return "Path taken by another file"
        }
    }

    private var footer: String {
        "Links \(tilde(link.path)) to the CLI inside this app, so a terminal can run "
            + "`\(CLIInstaller.linkName) brief` or `\(CLIInstaller.linkName) export`. "
            + "~/.local/bin must be on your PATH. Hooks call the CLI inside the app, not this link."
    }

    private func pathText(_ path: String) -> some View {
        Text(tilde(path)).font(.caption.monospaced()).foregroundStyle(.secondary)
            .lineLimit(2).truncationMode(.middle)
    }

    private func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// An installer error with the home folder shown as ~.
    private func message(_ error: Error) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(error)".replacingOccurrences(of: home + "/", with: "~/")
    }

    private func refresh() {
        state = target.map { CLIInstaller.state(link: link, target: $0) } ?? .notInstalled
    }

    private func install(replace: Bool) {
        defer { refresh() }
        guard let target else { error = CLIInstaller.InstallError.noBundledCLI.description; return }
        do {
            try CLIInstaller.install(link: link, target: target, replace: replace)
            error = nil
            model.flashToast("Installed \(CLIInstaller.linkName)")
        } catch CLIInstaller.InstallError.linkedElsewhere(let dest) {
            error = nil
            replaceTarget = dest
        } catch {
            self.error = message(error)
        }
    }

    private func remove() {
        defer { refresh() }
        guard let target else { return }
        do {
            try CLIInstaller.remove(link: link, target: target)
            error = nil
            model.flashToast("Removed \(CLIInstaller.linkName)")
        } catch {
            self.error = message(error)
        }
    }
}
