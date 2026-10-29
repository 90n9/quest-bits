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
                .environmentObject(delegate.model.pomodoro)
                .frame(minWidth: 820, minHeight: 520)
                // DESIGN.md defines light tokens only — lock the app to light appearance.
                .preferredColorScheme(.light)
                .tint(Theme.Colors.brandBlue)
        }
        .windowToolbarStyle(.unified)
        .commands { TodoCommands(model: delegate.model, shortcuts: delegate.shortcuts) }

        // Menu bar timer: live phase + mm:ss countdown, with the active task and
        // Start/Pause · Skip · Stop controls in the dropdown. Observes the same
        // PomodoroEngine the main window uses — no duplicated timer logic.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.pomodoro)
        } label: {
            MenuBarLabel(engine: delegate.model.pomodoro)
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
            Button("New Task") { model.pendingNewTask = true }
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

        CommandMenu("Timer") {
            Button(model.pomodoro.running ? "Pause" : "Start") { model.toggleTimer() }
                .keyboardShortcut(sc(.timerToggle))
            Button("Skip Phase") { model.pomodoro.skip() }
                .keyboardShortcut(sc(.timerSkip))
            Button("Stop Timer") { model.pomodoro.stop() }
                .keyboardShortcut(sc(.timerStop))
        }
    }
}

/// Owns the model and notification setup. The menu-bar timer is a SwiftUI
/// `MenuBarExtra` scene (see `TodoAppMain`), not a hand-rolled status item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let shortcuts = ShortcutStore()
    var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        MCPRegistration.registerIfNeeded()
        requestNotificationPermission()
        wirePomodoroNotifications()

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

    private func wirePomodoroNotifications() {
        model.pomodoro.onPhaseEnd = { [weak self] finished, next in
            guard let self, self.model.settings.notificationsEnabled else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(finished.label) complete"
            content.body = next == .focus ? "Break over — back to focus." : "Time for a \(next.label.lowercased())."
            if self.model.settings.soundEnabled { content.sound = .default }
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
}

extension AppDelegate: SPUUpdaterDelegate {}

// MARK: - Menu bar timer

/// The menu-bar title: phase icon + live mm:ss. Observes the shared engine so it
/// updates on every tick, exactly like the main window's PomodoroBar.
struct MenuBarLabel: View {
    @ObservedObject var engine: PomodoroEngine

    var body: some View {
        Text(title)
    }

    private var title: String {
        let icon = engine.phase == .focus ? "🍅" : (engine.phase == .idle ? "⏸" : "☕️")
        if engine.phase == .idle { return "\(icon) --:--" }
        return "\(icon) \(engine.clock)\(engine.running ? "" : " ⏸")"
    }
}

/// Dropdown for the menu-bar timer: current phase/clock, the active in-progress
/// task, and Start/Pause · Skip · Stop wired to the existing engine + model.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var engine: PomodoroEngine

    var body: some View {
        // No live clock here: the countdown ticking every second while the menu is
        // open forces an NSMenu rebuild per tick, which desyncs the hover highlight
        // (the blue highlight lands on the wrong item). The menu-bar label already
        // shows the live mm:ss; the dropdown only needs the (rarely-changing) phase.
        Text(phaseHeadline)

        if let active = model.inProgressTasks.first {
            let extra = model.inProgressTasks.count - 1
            Text("Active: \(active.title)" + (extra > 0 ? " (+\(extra) more)" : ""))
        } else {
            Text("No task in progress")
        }

        Divider()

        Button(engine.running ? "Pause" : "Start") { model.toggleTimer() }
        Button("Skip Phase") { engine.skip() }
            .disabled(engine.phase == .idle)
        Button("Stop") { engine.stop() }
            .disabled(engine.phase == .idle)

        Divider()

        Button("Show Main Window") { Self.showMainWindow() }
        Button("Check for Updates…") { UpdateNotifier.shared.requestCheck?() }
        Button("Quit Todo") { NSApp.terminate(nil) }
    }

    private var phaseHeadline: String {
        engine.phase == .idle ? "Ready" : engine.phase.label
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
