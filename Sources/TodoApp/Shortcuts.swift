import SwiftUI
import AppKit

/// A customizable keyboard shortcut: a key plus modifier flags.
struct Shortcut: Codable, Hashable {
    var key: String        // single char ("n", "1", ".") or token ("return","space","delete")
    var cmd: Bool
    var shift: Bool
    var opt: Bool
    var ctrl: Bool

    var keyEquivalent: KeyEquivalent {
        switch key {
        case "return": return .return
        case "space": return .space
        case "delete": return .delete
        case "escape": return .escape
        default:
            let ch: Character = key.lowercased().first ?? " "
            return KeyEquivalent(ch)
        }
    }

    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if cmd { m.insert(.command) }
        if shift { m.insert(.shift) }
        if opt { m.insert(.option) }
        if ctrl { m.insert(.control) }
        return m
    }

    /// Human glyph string, e.g. "⇧⌘N".
    var display: String {
        var s = ""
        if ctrl { s += "⌃" }
        if opt { s += "⌥" }
        if shift { s += "⇧" }
        if cmd { s += "⌘" }
        switch key {
        case "return": s += "↩"
        case "space": s += "␣"
        case "delete": s += "⌫"
        case "escape": s += "⎋"
        default: s += key.uppercased()
        }
        return s
    }
}

/// Every rebindable command in the app.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTask, newProject, duplicate, delete
    case statusTodo, statusInProgress, statusWaitingUser, statusWaitingExternal, statusDone, statusDropped
    case timerToggle, timerSkip, timerStop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTask: return "New Task"
        case .newProject: return "New Project"
        case .duplicate: return "Duplicate Task"
        case .delete: return "Delete Task"
        case .statusTodo: return "Mark Todo"
        case .statusInProgress: return "Mark In Progress"
        case .statusWaitingUser: return "Mark Waiting on Me"
        case .statusWaitingExternal: return "Mark Waiting on External"
        case .statusDone: return "Mark Done"
        case .statusDropped: return "Mark Dropped"
        case .timerToggle: return "Start / Pause Timer"
        case .timerSkip: return "Skip Phase"
        case .timerStop: return "Stop Timer"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .newTask:         return Shortcut(key: "n", cmd: true, shift: false, opt: false, ctrl: false)
        case .newProject:      return Shortcut(key: "n", cmd: true, shift: true, opt: false, ctrl: false)
        case .duplicate:       return Shortcut(key: "d", cmd: true, shift: false, opt: false, ctrl: false)
        case .delete:          return Shortcut(key: "delete", cmd: true, shift: false, opt: false, ctrl: false)
        case .statusTodo:      return Shortcut(key: "1", cmd: true, shift: false, opt: false, ctrl: false)
        case .statusInProgress:return Shortcut(key: "2", cmd: true, shift: false, opt: false, ctrl: false)
        case .statusDone:      return Shortcut(key: "3", cmd: true, shift: false, opt: false, ctrl: false)
        case .statusWaitingUser:     return Shortcut(key: "4", cmd: true, shift: false, opt: false, ctrl: false)
        case .statusWaitingExternal: return Shortcut(key: "5", cmd: true, shift: false, opt: false, ctrl: false)
        case .statusDropped:         return Shortcut(key: "6", cmd: true, shift: false, opt: false, ctrl: false)
        case .timerToggle:     return Shortcut(key: "return", cmd: true, shift: false, opt: false, ctrl: false)
        case .timerSkip:       return Shortcut(key: "k", cmd: true, shift: false, opt: false, ctrl: false)
        case .timerStop:       return Shortcut(key: ".", cmd: true, shift: false, opt: false, ctrl: false)
        }
    }
}

/// Holds the current (possibly customized) bindings; persists to UserDefaults.
@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var map: [String: Shortcut] = [:]
    private let key = "shortcutBindings"

    init() { load() }

    func shortcut(_ a: ShortcutAction) -> Shortcut { map[a.id] ?? a.defaultShortcut }

    func set(_ a: ShortcutAction, _ s: Shortcut) { map[a.id] = s; save() }

    func reset(_ a: ShortcutAction) { map[a.id] = nil; save() }

    func resetAll() { map = [:]; save() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) else { return }
        map = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// A field that displays a shortcut and records a new one when clicked.
struct ShortcutField: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false

    var body: some View {
        Button(recording ? "Press keys…" : shortcut.display) { recording = true }
            .frame(minWidth: 110)
            .buttonStyle(.bordered)
            .background(
                KeyCaptureView(recording: $recording) { captured in
                    shortcut = captured
                    recording = false
                }
            )
    }
}

/// Invisible AppKit view that captures the next keystroke while `recording`.
struct KeyCaptureView: NSViewRepresentable {
    @Binding var recording: Bool
    let onCapture: (Shortcut) -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let v = CaptureNSView()
        v.onCapture = { sc in onCapture(sc) }
        v.onCancel = { recording = false }
        return v
    }

    func updateNSView(_ view: CaptureNSView, context: Context) {
        view.onCapture = { sc in onCapture(sc) }
        view.onCancel = { recording = false }
        if recording { DispatchQueue.main.async { view.window?.makeFirstResponder(view) } }
    }

    final class CaptureNSView: NSView {
        var onCapture: ((Shortcut) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var k: String
            switch event.keyCode {
            case 36, 76: k = "return"
            case 49: k = "space"
            case 51, 117: k = "delete"
            case 53: onCancel?(); return                 // Esc cancels
            default: k = (event.charactersIgnoringModifiers ?? "").lowercased()
            }
            guard !k.isEmpty else { onCancel?(); return }
            onCapture?(Shortcut(
                key: k,
                cmd: mods.contains(.command),
                shift: mods.contains(.shift),
                opt: mods.contains(.option),
                ctrl: mods.contains(.control)
            ))
        }
    }
}
