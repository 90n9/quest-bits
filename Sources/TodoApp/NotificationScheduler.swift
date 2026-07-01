import Foundation
import UserNotifications

/// Schedules local notifications for task due dates.
///
/// Reuses the app's existing notification authorization (requested once in
/// `AppDelegate.applicationDidFinishLaunching`) — this type never asks for
/// permission itself. Reminders are keyed by task id ("due-<id>"), so adding a
/// request for a task that already has one *replaces* it (reschedule semantics).
///
/// The single entry point is `reconcile(tasks:enabled:soundEnabled:)`: it diffs
/// the desired reminder set (future-due, non-done tasks) against what's currently
/// pending, removing anything stale (due cleared, task completed/deleted, or
/// notifications turned off) and (re)scheduling the rest. Calling it after every
/// task-list reload keeps reminders correct for app edits and external (MCP) writes
/// alike, with no per-mutation bookkeeping.
@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    private let idPrefix = "due-"

    private func identifier(for taskId: Int64) -> String { "\(idPrefix)\(taskId)" }

    /// Reconcile pending due-date reminders against the current task set.
    /// - Parameters:
    ///   - tasks: the full task list (across all projects).
    ///   - enabled: `settings.notificationsEnabled`; when false, all reminders are cleared.
    ///   - soundEnabled: `settings.soundEnabled`; plays the default sound when true.
    func reconcile(tasks: [TodoTask], enabled: Bool, soundEnabled: Bool) {
        let now = Date()
        // Desired: not done, has a due date still in the future (never schedule in the past).
        let desired: [TodoTask] = enabled
            ? tasks.filter { $0.status != .done && ($0.dueDate.map { $0 > now } ?? false) }
            : []
        let desiredIds = Set(desired.map { identifier(for: $0.id) })

        // `prefix` is the only captured state; re-fetch the (thread-safe) center
        // inside the handler to avoid capturing a non-Sendable instance.
        let prefix = self.idPrefix

        // Drop any of our pending reminders that are no longer wanted.
        center.getPendingNotificationRequests { requests in
            let stale = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) && !desiredIds.contains($0) }
            if !stale.isEmpty {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: stale)
            }
        }

        // (Re)schedule the desired reminders. add() with an existing identifier replaces it.
        let calendar = Calendar.current
        for task in desired {
            guard let due = task.dueDate else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Task due: \(task.title)"
            content.body = task.code.isEmpty ? "This task is due now." : "\(task.code) is due now."
            if soundEnabled { content.sound = .default }
            let comps = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: due)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(
                identifier: identifier(for: task.id), content: content, trigger: trigger)
            center.add(req)
        }
    }
}
