import Foundation
import UserNotifications

/// Schedules local notifications for task due dates, and posts the ones for what newly
/// waits on the user (`postWaiting`).
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

    /// Monotonically increasing token. Each `reconcile` bumps it on entry and
    /// captures the new value; the async completion bails if a newer call has
    /// since superseded it, so an outdated in-flight reconcile can never clobber
    /// a newer one (see the out-of-order removal race this guards against).
    private var generation: UInt64 = 0

    private func identifier(for taskId: Int64) -> String { "\(idPrefix)\(taskId)" }

    /// Reconcile pending due-date reminders against the current task set.
    /// - Parameters:
    ///   - tasks: the full task list (across all projects).
    ///   - enabled: `settings.notificationsEnabled`; when false, all reminders are cleared.
    ///   - soundEnabled: `settings.soundEnabled`; plays the default sound when true.
    func reconcile(tasks: [TodoTask], enabled: Bool, soundEnabled: Bool) {
        let now = Date()
        // Desired: still open (not done or dropped), has a due date still in the future
        // (never schedule in the past).
        let desired: [TodoTask] = enabled
            ? tasks.filter { !$0.status.isClosed && ($0.dueDate.map { $0 > now } ?? false) }
            : []
        let desiredIds = Set(desired.map { identifier(for: $0.id) })

        // `prefix` is the only captured state; re-fetch the (thread-safe) center
        // inside the handler to avoid capturing a non-Sendable instance.
        let prefix = self.idPrefix

        // Bump the generation on entry and capture it. The async completion below
        // runs on a background queue and can complete out of order with respect to
        // other reconcile calls; guarding on this token makes an outdated in-flight
        // reconcile a no-op so it cannot delete a reminder a newer call just added.
        generation &+= 1
        let token = generation

        // Perform BOTH the stale-removal and the (re)scheduling inside this single
        // completion handler, in order, so a later reconcile's add() can never be
        // undone by an earlier reconcile's still-in-flight removal.
        center.getPendingNotificationRequests { requests in
            Task { @MainActor in
                // Bail if a newer reconcile has superseded us.
                guard self.generation == token else { return }

                // Drop any of our pending reminders that are no longer wanted.
                let stale = requests
                    .map(\.identifier)
                    .filter { $0.hasPrefix(prefix) && !desiredIds.contains($0) }
                if !stale.isEmpty {
                    self.center.removePendingNotificationRequests(withIdentifiers: stale)
                }

                // (Re)schedule the desired reminders. add() with an existing
                // identifier replaces it.
                let calendar = Calendar.current
                for task in desired {
                    guard let due = task.dueDate else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "Task due: \(task.title)"
                    content.body = task.code.isEmpty
                        ? "This task is due now." : "\(task.code) is due now."
                    if soundEnabled { content.sound = .default }
                    let comps = calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: due)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    let req = UNNotificationRequest(
                        identifier: self.identifier(for: task.id), content: content, trigger: trigger)
                    self.center.add(req)
                }
            }
        }
    }

    // MARK: - Waiting on you (QUE-26)

    private nonisolated static let waitingPrefix = "waiting-"
    private nonisolated static let itemKey = "inboxItem"

    /// Post a notification now for what newly waits on the user (`WaitingWatch.notice`).
    /// Nothing is posted unless macOS allows this app's notifications; this never asks.
    /// The item goes in `userInfo`, so a click opens it (`waitingItem(in:)`).
    func postWaiting(title: String, body: String, sound: Bool, item: WaitingArrival.Item) {
        let info = [Self.itemKey: Self.encode(item)]
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            guard status == .authorized || status == .provisional else { return }
            Task { @MainActor in
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.threadIdentifier = "waiting"
                content.userInfo = info
                if sound { content.sound = .default }
                try? await self.center.add(UNNotificationRequest(
                    identifier: Self.waitingPrefix + UUID().uuidString, content: content, trigger: nil))
            }
        }
    }

    /// The item a waiting notification was posted for, from its `userInfo`; nil for any
    /// other notification (a due reminder).
    nonisolated static func waitingItem(in userInfo: [AnyHashable: Any]) -> WaitingArrival.Item? {
        guard let raw = userInfo[itemKey] as? String, let colon = raw.firstIndex(of: ":") else { return nil }
        let kind = raw[..<colon], id = String(raw[raw.index(after: colon)...])
        switch kind {
        case "session": return id.isEmpty ? nil : .session(id)
        case "question": return Int64(id).map { .question($0) }
        case "task": return Int64(id).map { .task($0) }
        default: return nil
        }
    }

    private static func encode(_ item: WaitingArrival.Item) -> String {
        switch item {
        case .session(let id): return "session:\(id)"
        case .question(let id): return "question:\(id)"
        case .task(let id): return "task:\(id)"
        }
    }
}
