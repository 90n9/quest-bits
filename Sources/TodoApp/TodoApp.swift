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

        // Menu bar item: the icon with what waits on the user and what is being worked on;
        // the dropdown lists both. Redrawn from the model's poll, no timer of its own.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set before launch finishes, so a click that launched the app is delivered too.
        UNUserNotificationCenter.current().delegate = self
    }

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

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show notifications while the app is in front too (a banner, in the list, with the
    /// sound the request carries): a window may be open on something else.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click on a "waiting on you" notification opens the Waiting on you page at its item.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let item = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? NotificationScheduler.waitingItem(in: response.notification.request.content.userInfo) : nil
        completionHandler()
        guard let item else { return }
        Task { @MainActor in
            MenuBarContent.showMainWindow()
            self.model.showWaitingArrival(item)
        }
    }
}

// MARK: - Menu bar

/// The menu-bar title: the template icon (it follows the menu bar's light/dark tint), then
/// "✋ N" for what waits on the user (`waitingOnYou.count`) and "⚡ M" for the tasks being
/// worked on (`workingTasks`), "·" between them. A zero count is left out, so with nothing
/// waiting or working only the icon shows.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let waiting = model.waitingOnYou.count, working = model.workingTasks.count
        Self.title(waiting: waiting, working: working)
            .accessibilityLabel(Self.spoken(waiting: waiting, working: working))
    }

    static func title(waiting: Int, working: Int) -> Text {
        let icon = Image(systemName: "checklist")
        let w = Text("\(Image(systemName: "hand.raised.fill")) \(waiting)")
        let k = Text("\(Image(systemName: "bolt.fill")) \(working)")
        switch (waiting > 0, working > 0) {
        case (true, true): return Text("\(icon) \(w) · \(k)")
        case (true, false): return Text("\(icon) \(w)")
        case (false, true): return Text("\(icon) \(k)")
        case (false, false): return Text(icon)
        }
    }

    static func spoken(waiting: Int, working: Int) -> String {
        "QuestBits: \(waiting) waiting on you, \(working) working"
    }
}

/// Dropdown for the menu-bar item: the first few things waiting on the user (each opens
/// the Waiting on you page at it), the tasks being worked on (each opens the task), then
/// window, update and quit commands.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel

    /// How many entries each section lists before "Show all…".
    static let shown = 5

    var body: some View {
        // Plain Text headers and Dividers, not Sections: a menu Section adds a separator
        // on both sides, so two in a row drew a double line.
        waitingSection
        Divider()
        workingSection
        Divider()
        Button("Show Main Window") { Self.showMainWindow() }
        Button("Check for Updates…") { UpdateNotifier.shared.requestCheck?() }
        Button("Quit QuestBits") { NSApp.terminate(nil) }
    }

    @ViewBuilder private var waitingSection: some View {
        let entries = waitingEntries
        if entries.isEmpty {
            Text("Nothing waiting on you")
        } else {
            Text("Waiting on you · \(entries.count)")
            ForEach(entries.prefix(Self.shown)) { entry in
                Button { reveal { model.showInboxItem(entry.id) } } label: {
                    Label(entry.title, systemImage: entry.symbol)
                }
            }
            if entries.count > Self.shown {
                Button("Show all \(entries.count)…") { reveal { model.showInboxItem(nil) } }
            }
        }
    }

    @ViewBuilder private var workingSection: some View {
        let working = model.workingTasks
        if working.isEmpty {
            Text("Nothing in progress")
        } else {
            Text("Working · \(working.count)")
            ForEach(working.prefix(Self.shown)) { task in
                Button { reveal { model.showTask(task) } } label: {
                    Label(Self.line(task.code, task.title), systemImage: Self.symbol(task))
                }
            }
            if working.count > Self.shown {
                Button("Show all In Progress…") { reveal { model.selectSmartView(.inProgress) } }
            }
        }
    }

    /// One menu line per waiting item, in the page's order (sessions at a terminal, then
    /// questions, then tasks).
    private var waitingEntries: [MenuEntry] {
        let w = model.waitingOnYou
        let sessions = w.sessions.map { s in
            MenuEntry(id: .session(s.id), symbol: "terminal",
                      title: Self.line(s.projectId.map(model.projectCode(for:)) ?? "",
                                       s.attention?.headline ?? "Needs you at the terminal"))
        }
        let questions = w.questions.map { q in
            MenuEntry(id: .question(q.id), symbol: "questionmark.bubble", title: Self.line(q.taskCode, q.prompt))
        }
        let tasks = w.tasks.map { t in
            MenuEntry(id: .task(t.id), symbol: "hourglass", title: Self.line(t.task.code, t.task.title))
        }
        return sessions + questions + tasks
    }

    private struct MenuEntry: Identifiable {
        let id: InboxItemID
        let symbol: String
        let title: String
    }

    /// "GEN-3 · Title", the text on one line and cut to fit a menu.
    static func line(_ code: String, _ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let cut = flat.count > 60 ? String(flat.prefix(59)) + "…" : flat
        return code.isEmpty ? cut : "\(code) · \(cut)"
    }

    /// A bolt for a task an agent holds a live claim on, else a plain "in progress" mark.
    static func symbol(_ task: TodoTask) -> String {
        task.claim?.isLive() == true ? "bolt.fill" : "circle.lefthalf.filled"
    }

    /// Bring the main window forward, then run `action` (which picks what it shows).
    private func reveal(_ action: () -> Void) {
        Self.showMainWindow()
        action()
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
