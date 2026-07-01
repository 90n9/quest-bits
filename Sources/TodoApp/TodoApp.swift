import SwiftUI
import AppKit
import Combine
import UserNotifications

@main
struct TodoAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.pomodoro)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands { TodoCommands(model: delegate.model, shortcuts: delegate.shortcuts) }

        Settings {
            SettingsView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.shortcuts)
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
            Button("Mark Done") { model.setStatusOnSelected(.done) }
                .keyboardShortcut(sc(.statusDone)).disabled(model.selectedTaskId == nil)
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

/// Owns the model, the menu-bar status item, and notification setup.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let shortcuts = ShortcutStore()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MCPRegistration.registerIfNeeded()
        requestNotificationPermission()
        setupMenuBar()
        wirePomodoroNotifications()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar after the window closes.
        false
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        let item = NSStatusItem.create()
        if let button = item.button {
            button.title = "🍅 --:--"
            button.target = self
            button.action = #selector(toggleWindow)
        }
        // Live-update the title from the pomodoro clock.
        Publishers.CombineLatest3(model.pomodoro.$remaining, model.pomodoro.$phase, model.pomodoro.$running)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, phase, running in
                guard let self, let button = self.statusItem?.button else { return }
                let icon = phase == .focus ? "🍅" : (phase == .idle ? "⏸" : "☕️")
                button.title = phase == .idle ? "\(icon) --:--" : "\(icon) \(self.model.pomodoro.clock)\(running ? "" : " ⏸")"
            }
            .store(in: &cancellables)
        statusItem = item
    }

    @objc private func toggleWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            return
        }
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

private extension NSStatusItem {
    static func create() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }
}
