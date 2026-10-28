import AppKit
import Combine

/// Arms exactly one timer: for the next chime, or earlier if a pause/skip expires first so the
/// status and icon stay truthful. No polling: the process sleeps between events.
@MainActor
final class Scheduler: ObservableObject {
    /// A boundary that fires later than this is dropped, never played late.
    static let maxLateness: TimeInterval = 5

    static func isDue(_ target: Date, now: Date, asleep: Bool) -> Bool {
        !asleep && now >= target && now.timeIntervalSince(target) <= maxLateness
    }

    @Published private(set) var nextChime: Date?

    private let settings: Settings
    private let player: ChimeRunner
    private var calendar: Calendar { Calendar.autoupdatingCurrent }
    private var timer: Timer?
    private var asleep = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables: Set<AnyCancellable> = []

    init(settings: Settings, player: ChimeRunner) {
        self.settings = settings
        self.player = player

        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification) { s in
            // Disarm so an overdue timer can never fire into the wake-up and play a stale chime.
            s.asleep = true
            s.timer?.invalidate()
            s.timer = nil
        }
        observe(ws, NSWorkspace.didWakeNotification) { s in s.asleep = false; s.reschedule() }
        observe(ws, NSWorkspace.screensDidWakeNotification) { s in s.reschedule() }
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observe(nc, name) { s in s.reschedule() }
        }

        // Any rule change re-arms on the next run-loop pass (coalesces bursts of edits).
        settings.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reschedule() }
            .store(in: &cancellables)

        reschedule()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Scheduler) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
        observers.append((center, token))
    }

    func reschedule() {
        timer?.invalidate()
        timer = nil
        let now = Date()

        // Drop expired one-shot state so it never lingers in the UI.
        if let p = settings.pausedUntil, p <= now { settings.pausedUntil = nil }
        if let s = settings.skippedChime, s < now.addingTimeInterval(-1) { settings.skippedChime = nil }

        let next = settings.rules.nextChime(after: now, calendar: calendar)
        if nextChime != next { nextChime = next }
        guard !asleep else { return }

        // Wake for whichever comes first: the chime, the end of a pause, or the skipped boundary passing.
        let expiries = [settings.pausedUntil, settings.skippedChime.map { $0.addingTimeInterval(1.5) }].compactMap { $0 }
        guard let wake = ([next].compactMap { $0 } + expiries).min() else { return }

        let t = Timer(fire: wake, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire(chime: next) }
        }
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire(chime target: Date?) {
        defer { reschedule() }
        guard let target else { return }
        let now = Date()
        // Woken early for a state expiry, or very late after sleep: don't play.
        guard Self.isDue(target, now: now, asleep: asleep) else { return }
        guard settings.rules.shouldChime(at: target, calendar: calendar) else { return }
        if settings.quietWhenLocked && SystemState.isScreenLockedOrAsleep { return }
        if settings.quietDuringCalls && SystemState.isMicrophoneInUse { return }
        player.chime(at: target)
    }
}
