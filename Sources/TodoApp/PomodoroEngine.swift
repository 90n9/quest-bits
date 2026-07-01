import Foundation
import Combine

/// Phases of the pomodoro cycle.
enum PomodoroPhase: String {
    case idle
    case focus
    case shortBreak
    case longBreak

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .focus: return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        }
    }
}

/// Global pomodoro timer. Not tied to a single task — runs for the whole session.
/// Completed focus phases are recorded to the store for daily stats.
@MainActor
final class PomodoroEngine: ObservableObject {
    @Published private(set) var phase: PomodoroPhase = .idle
    @Published private(set) var remaining: Int = 0      // seconds left in current phase
    @Published private(set) var running: Bool = false
    @Published private(set) var completedRounds: Int = 0 // focus phases done this cycle

    var settings: PomodoroSettings
    private let store: Store
    private var ticker: Timer?
    private var phaseStartedAt: Date?

    /// Called when a phase finishes (for notifications + UI). (finishedPhase, nextPhase)
    var onPhaseEnd: ((PomodoroPhase, PomodoroPhase) -> Void)?

    /// Called once per second while a focus phase is actively running (for effort accrual).
    var onFocusSecond: (() -> Void)?

    init(store: Store, settings: PomodoroSettings) {
        self.store = store
        self.settings = settings
    }

    // MARK: - Controls

    /// Start a focus phase from idle, or resume a paused phase.
    func startFocus() {
        if phase == .idle {
            beginPhase(.focus)
        }
        resume()
    }

    func resume() {
        guard !running, phase != .idle else { return }
        running = true
        if phaseStartedAt == nil { phaseStartedAt = Date() }
        startTicker()
    }

    func pause() {
        running = false
        ticker?.invalidate()
        ticker = nil
    }

    /// Stop entirely and reset to idle (does not record a partial focus session).
    func stop() {
        pause()
        phase = .idle
        remaining = 0
        phaseStartedAt = nil
    }

    /// Skip the current phase immediately (advance without recording focus).
    func skip() {
        advance(recordFocus: false)
    }

    // MARK: - Internals

    private func beginPhase(_ p: PomodoroPhase) {
        phase = p
        phaseStartedAt = nil
        switch p {
        case .focus: remaining = settings.focusSeconds
        case .shortBreak: remaining = settings.shortBreakSeconds
        case .longBreak: remaining = settings.longBreakSeconds
        case .idle: remaining = 0
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard running else { return }
        // Accrue effort during focus (and breaks too, if enabled).
        if phase == .focus || (settings.countBreaksAsEffort && (phase == .shortBreak || phase == .longBreak)) {
            onFocusSecond?()
        }
        if remaining > 0 {
            remaining -= 1
        }
        if remaining <= 0 {
            advance(recordFocus: true)
        }
    }

    /// Move to the next phase. If the finishing phase was focus and recordFocus is true,
    /// log a completed focus session.
    private func advance(recordFocus: Bool) {
        let finished = phase

        if finished == .focus {
            if recordFocus {
                completedRounds += 1
                let start = phaseStartedAt ?? Date().addingTimeInterval(-Double(settings.focusSeconds))
                try? store.recordFocusSession(
                    startedAt: start,
                    endedAt: Date(),
                    focusSeconds: settings.focusSeconds
                )
            }
            // Long break every N rounds, else short break.
            let next: PomodoroPhase =
                (completedRounds % max(1, settings.roundsBeforeLongBreak) == 0) ? .longBreak : .shortBreak
            beginPhase(next)
            onPhaseEnd?(finished, next)
        } else {
            // A break finished → back to focus.
            beginPhase(.focus)
            onPhaseEnd?(finished, .focus)
        }
        // Continue into the next phase, or pause for the user if auto-advance is off.
        phaseStartedAt = Date()
        if running {
            if settings.autoAdvance {
                startTicker()
            } else {
                pause()
            }
        }
    }

    // MARK: - Display

    var clock: String {
        let m = remaining / 60, s = remaining % 60
        return String(format: "%02d:%02d", m, s)
    }
}
