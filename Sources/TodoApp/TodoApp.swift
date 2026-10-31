import SwiftUI
import AppKit
import Combine
import UserNotifications
import Sparkle

@main
struct TodoAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate.model)
                .frame(minWidth: 820, minHeight: 520)
                // DESIGN.md defines light tokens only — lock the app to light appearance.
                .preferredColorScheme(.light)
                .tint(Theme.Colors.brandBlue)
        }
        .windowToolbarStyle(.unified)
        .commands { TodoCommands(model: delegate.model, shortcuts: delegate.shortcuts) }

        // Menu bar item: a static icon, with the active task and window/update/quit
        // commands in the dropdown. No timer and no per-second redraw.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(delegate.model)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.shortcuts)
                .preferredColorScheme(.light)
                .tint(Theme.Colors.brandBlue)
        }
    }
}

/// Keyboard shortcuts, surfaced as menu items so they're discoverable.
/// Key bindings come from the (customizable) ShortcutStore.
struct TodoCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var shortcuts: ShortcutStore

    private func sc(_ a: ShortcutAction) -> KeyboardShortcut {
        let s = shortcuts.shortcut(a)
        return KeyboardShortcut(s.keyEquivalent, modifiers: s.modifiers)
    }

    var body: some Commands {
        // "Check for Updates…" in the app menu, right under "About".
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateNotifier.shared.requestCheck?() }
        }

        // Replace (not append to) the .newItem group: a WindowGroup auto-installs a
        // "New Window" command bound to ⌘N. Appending our New Task (also ⌘N) leaves
        // two ⌘N bindings and New Window wins, so the shortcut never creates a task.
        // Replacing the group drops New Window and lets New Task own ⌘N.
        CommandGroup(replacing: .newItem) {
            Button("New Task") { model.requestNewTask() }
                .keyboardShortcut(sc(.newTask))
            Button("New Project") { model.pendingNewProject = true }
                .keyboardShortcut(sc(.newProject))
        }

        CommandMenu("Task") {
            Button("Duplicate Task") { model.duplicateSelected() }
                .keyboardShortcut(sc(.duplicate)).disabled(model.selectedTaskId == nil)
            Button("Delete Task") { model.deleteSelected() }
                .keyboardShortcut(sc(.delete)).disabled(model.selectedTaskId == nil)
            Divider()
            Button("Mark Todo") { model.setStatusOnSelected(.todo) }
                .keyboardShortcut(sc(.statusTodo)).disabled(model.selectedTaskId == nil)
            Button("Mark In Progress") { model.setStatusOnSelected(.inProgress) }
                .keyboardShortcut(sc(.statusInProgress)).disabled(model.selectedTaskId == nil)
            Button("Mark Waiting on Me") { model.setStatusOnSelected(.waiting, waitingOn: .user) }
                .keyboardShortcut(sc(.statusWaitingUser)).disabled(model.selectedTaskId == nil)
            Button("Mark Waiting on External") { model.setStatusOnSelected(.waiting, waitingOn: .external) }
                .keyboardShortcut(sc(.statusWaitingExternal)).disabled(model.selectedTaskId == nil)
            Button("Mark Done") { model.setStatusOnSelected(.done) }
                .keyboardShortcut(sc(.statusDone)).disabled(model.selectedTaskId == nil)
            Button("Mark Dropped") { model.setStatusOnSelected(.dropped) }
                .keyboardShortcut(sc(.statusDropped)).disabled(model.selectedTaskId == nil)
        }
    }
}

/// Owns the model and notification setup. The menu-bar item is a SwiftUI
/// `MenuBarExtra` scene (see `TodoAppMain`), not a hand-rolled status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let shortcuts = ShortcutStore()
    var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        MCPRegistration.registerIfNeeded()
        requestNotificationPermission()

        // Sparkle auto-updater. `startingUpdater: true` schedules the first
        // background check per SUScheduledCheckInterval from Info.plist
        // (auto-checks are compiled off in local dev builds — see build-app.sh).
        // Sparkle's standard user driver presents the native "new version",
        // download-progress, and install-and-relaunch dialogs.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        // Every UI entry point (banner button, menu-bar item, app menu,
        // Settings) routes through the same updater.
        UpdateNotifier.shared.onInstallTapped = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
        UpdateNotifier.shared.requestCheck = { [weak self] in
            self?.updaterController.checkForUpdates(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar after the window closes.
        false
    }

    // MARK: - Sparkle

    /// Fires when Sparkle confirms an appcast entry is newer than the running
    /// build. Surface it in the in-window banner so the user can act even if
    /// they dismissed the native dialog. Deliberately NOT hooking
    /// `didDownloadUpdate` for a "restart now" alert: that fires before the
    /// update is extracted/validated/staged — Sparkle's own user driver shows
    /// the correct "Install and Relaunch" dialog once staging completes.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        UpdateNotifier.shared.setAvailable(version: item.displayVersionString)
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

extension AppDelegate: SPUUpdaterDelegate {}

// MARK: - Menu bar

/// The menu-bar title: a static template icon (it follows the menu bar's light/dark
/// tint). QUE-25 replaces it with the waiting-on-you / working counts.
struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "checklist")
            .accessibilityLabel("QuestBits")
    }
}

/// Dropdown for the menu-bar item: the active in-progress task, then window,
/// update and quit commands.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let active = model.inProgressTasks.first {
            let extra = model.inProgressTasks.count - 1
            Text("Active: \(active.title)" + (extra > 0 ? " (+\(extra) more)" : ""))
        } else {
            Text("No task in progress")
        }

        Divider()

        Button("Show Main Window") { Self.showMainWindow() }
        Button("Check for Updates…") { UpdateNotifier.shared.requestCheck?() }
        Button("Quit Todo") { NSApp.terminate(nil) }
    }

    /// Bring the main window forward (recreating window behavior of the old
    /// status-item click), keeping the app's activation working as before.
    static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
