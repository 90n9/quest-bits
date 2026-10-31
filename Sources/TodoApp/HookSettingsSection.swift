import SwiftUI

/// Settings → Claude Code Hooks: install, update or remove this flavor's hooks in
/// ~/.claude/settings.json (`HookInstaller`). Nothing is installed until the user asks.
struct HookSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var status: HookInstaller.Status = .notInstalled
    @State private var error: String?
    @State private var backup: URL?

    private var cli: String? { CLIInstaller.bundledCLIPath() }
    private var settings: URL { HookInstaller.settingsURL() }

    var body: some View {
        Section {
            LabeledContent("Status", value: statusText)
            LabeledContent("Settings file") { pathText(settings.path) }
            if let backup {
                LabeledContent("Backup") { pathText(backup.path) }
            }
            buttons
            if let message = error ?? unreadableReason {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Claude Code Hooks")
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch status {
            case .installed:
                Button("Uninstall") { uninstall() }
            case .outdated:
                Button("Update Hooks") { install() }.disabled(cli == nil)
                Button("Uninstall") { uninstall() }
            case .notInstalled:
                Button("Install Claude Code Hooks") { install() }.disabled(cli == nil)
            case .unreadable:
                Button("Check Again") { error = nil; refresh() }
            }
        }
    }

    private var unreadableReason: String? {
        if case .unreadable(let why) = status { return homeAsTilde(why) }
        return nil
    }

    private var statusText: String {
        guard cli != nil else { return "Not in this build" }
        switch status {
        case .installed: return "Installed ✓"
        case .outdated: return "Outdated (update to this app)"
        case .notInstalled: return "Not installed"
        case .unreadable: return "Can't read settings.json"
        }
    }

    private var footer: String {
        "Adds hooks that call this app's CLI when a Claude Code session starts, takes a prompt, "
            + "stops and ends: the session shows in QuestBits, and a new session in a project's folder "
            + "starts with that project's brief; after a compaction, a session gets its claimed tasks back. "
            + "In a project's folder, risky calls (git push, releases, PRs, recursive rm outside the folder, "
            + "sending messages) wait for your approval under Questions, and a session waiting at its terminal "
            + "(a permission prompt, an MCP form, your input) shows as needing you there. Your other hooks and settings stay as they are, and "
            + "settings.json is backed up first. Takes effect in new Claude Code sessions."
    }

    private func pathText(_ path: String) -> some View {
        Text(tilde(path)).font(.caption.monospaced()).foregroundStyle(.secondary)
            .lineLimit(2).truncationMode(.middle)
    }

    private func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// A message with the home folder shown as ~.
    private func homeAsTilde(_ text: String) -> String {
        text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "~/")
    }

    private func refresh() {
        guard let cli else { status = .notInstalled; return }
        status = HookInstaller.status(settings: settings, cli: cli)
    }

    private func install() {
        guard let cli else { error = HookInstaller.InstallError.noBundledCLI.description; return }
        run("Installed Claude Code hooks") { try HookInstaller.install(settings: settings, cli: cli) }
    }

    private func uninstall() {
        run("Removed Claude Code hooks") { try HookInstaller.uninstall(settings: settings) }
    }

    private func run(_ done: String, _ action: () throws -> URL?) {
        do {
            if let made = try action() { backup = made }
            error = nil
            model.flashToast(done)
        } catch {
            self.error = homeAsTilde("\(error)")
        }
        refresh()
    }
}
