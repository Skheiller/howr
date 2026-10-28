import AppKit
import Combine

/// The always-running agent: menu bar icon, scheduler and chimes. It never draws SwiftUI.
/// The menu and Settings run in a separate UI process (UIApp.swift) that exits when closed,
/// and each chime plays in its own short-lived process, so the agent stays near the
/// memory floor of any menu bar app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var runner = ChimeRunner(settings: settings)
    lazy var scheduler = Scheduler(settings: settings, player: runner)

    private let ui = UIHost()
    private var statusItem: NSStatusItem!
    private var popoverVisible = false
    private var lastPopoverClosed = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ note: Notification) {
        _ = scheduler

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Howr")
        }

        ui.onLaunch = { [weak self] in self?.sendState() }
        ui.onMessage = { [weak self] in self?.handle($0) }
        ui.onExit = { [weak self] in self?.uiDidExit() }

        settings.$pausedUntil
            .combineLatest(settings.$skippedChime, scheduler.$nextChime)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon(); self?.sendState() }
            .store(in: &cancellables)

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Self.trimMemory() }
    }

    /// Hands memory freed after startup or a UI session back to the system; otherwise those
    /// pages stay counted against the agent even though nothing uses them.
    private static func trimMemory() { malloc_zone_pressure_relief(nil, 0) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // Opening Howr.app again (Finder, Spotlight) shows Settings instead of doing nothing.
        // macOS just activated the agent; pass that on so Settings opens in front.
        ui.launchIfNeeded()
        if let app = ui.runningApp { NSApp.yieldActivation(to: app) }
        ui.send(["op": "settings"])
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        runner.stop(immediately: true)
        ui.terminate()
    }

    private func updateIcon() {
        let paused = (settings.pausedUntil ?? .distantPast) > Date()
        let silent = paused || scheduler.nextChime == nil
        statusItem.button?.image = silent ? MenuBarIcon.bellSlash : MenuBarIcon.bell
        statusItem.button?.toolTip = "Howr — " + LCDFormat.statusSentence(next: scheduler.nextChime, pausedUntil: settings.pausedUntil)
    }

    // MARK: UI process

    @objc private func togglePopover() {
        // The UI process closes the menu on any outside click, including one on this icon.
        // If that just happened, this click meant "close", not "open again".
        if !popoverVisible, Date().timeIntervalSince(lastPopoverClosed) < 0.3 { return }
        guard let button = statusItem.button, let window = button.window else { return }
        let r = window.convertToScreen(button.convert(button.bounds, to: nil))
        if !ui.isRunning { button.highlight(true) }   // instant feedback while the UI starts
        ui.send(["op": "toggle", "anchor": [r.minX, r.minY, r.width, r.height]])
    }

    /// The schedule as the agent sees it; the UI shows this rather than computing its own.
    private func sendState() {
        ui.notify([
            "op": "state",
            "settings": settings.snapshot,
            "next": IPC.encode(scheduler.nextChime),
            "paused": IPC.encode(settings.pausedUntil),
            "skipped": IPC.encode(settings.skippedChime),
        ])
    }

    private func handle(_ m: [String: Any]) {
        switch m["op"] as? String {
        case "set":
            guard let key = m["key"] as? String else { break }
            let requested = IPC.decode(m["value"])
            settings.apply(key, requested)
            // Refused or adjusted: tell the UI, so it never shows a value the agent doesn't have.
            let actual = settings.storedValue(key)
            if !Settings.same(actual, requested) {
                ui.notify(["op": "set", "key": key, "value": IPC.encode(actual)])
            }
        case "skip":
            if let next = scheduler.nextChime { settings.skippedChime = next }
        case "preview":
            runner.preview(soundID: m["sound"] as? String, speak: m["speak"] as? Bool)
        case "popover":
            let visible = m["visible"] as? Bool ?? false
            if popoverVisible, !visible { lastPopoverClosed = Date() }
            popoverVisible = visible
            statusItem.button?.highlight(visible)
        case "login":
            var error: String?
            if let on = m["set"] as? Bool { error = LaunchAtLogin.set(on) }
            ui.notify(["op": "login", "state": LaunchAtLogin.state.rawValue, "error": error.map { $0 as Any } ?? NSNull()])
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func uiDidExit() {
        if popoverVisible { lastPopoverClosed = Date() }
        popoverVisible = false
        statusItem.button?.highlight(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Self.trimMemory() }
    }
}
