import AppKit
import Combine
import SwiftUI

/// The UI process (`Howr --ui`), started by the agent when the menu or Settings opens.
/// It draws the SwiftUI LCD surfaces and exits as soon as the last one closes, so their
/// caches never stay resident. Settings edits and commands go to the agent, which owns
/// persistence, the schedule and playback.
@MainActor
final class UIAppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private lazy var status = ChimeStatus(settings: settings) { [weak self] in self?.send(["op": "skip"]) }
    private lazy var player = PreviewClient(settings: settings) { [weak self] id, speak in
        self?.send(["op": "preview", "sound": id, "speak": speak])
    }
    private lazy var loginItem = LoginItem { [weak self] on in
        self?.send(["op": "login", "set": on.map { $0 as Any } ?? NSNull()])
    }
    private var channel: Channel?
    private var popover: PopoverPanel?
    private var settingsWindow: SettingsWindow?
    /// The last command from the agent, reported back with `idle`.
    private var lastSeen = 0
    private var lastShown = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        settings.forward = { [weak self] key, value in
            self?.send(["op": "set", "key": key, "value": IPC.encode(value)])
        }
        // stdin closing means the agent is gone: nothing left to talk to.
        channel = Channel(read: .standardInput, write: .standardOutput,
                          onMessage: { [weak self] in self?.handle($0) }, onClose: { exit(0) })
        // Started but never asked to show anything: don't linger.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.reportIfIdle() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        showSettings()
        return false
    }

    private func send(_ message: [String: Any]) { channel?.send(message) }

    private func handle(_ m: [String: Any]) {
        if let seq = m["seq"] as? Int { lastSeen = seq }
        switch m["op"] as? String {
        case "state":
            if let snapshot = m["settings"] as? [String: Any] { settings.applySnapshot(snapshot) }
            settings.applyFromAgent("pausedUntil", IPC.decode(m["paused"]))
            settings.applyFromAgent("skippedChime", IPC.decode(m["skipped"]))
            let next = IPC.decode(m["next"]) as? Date
            if status.nextChime != next { status.nextChime = next }
        case "toggle":
            guard let a = m["anchor"] as? [Double], a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { return }
            togglePopover(below: NSRect(x: a[0], y: a[1], width: a[2], height: a[3]))
            reportIfIdle()
        case "settings":
            showSettings()
        case "set":
            // The agent refused or adjusted an edit: show what it actually has.
            if let key = m["key"] as? String { settings.applyFromAgent(key, IPC.decode(m["value"])) }
        case "login":
            let state = (m["state"] as? String).flatMap(LaunchAtLogin.State.init(rawValue:)) ?? .unavailable
            loginItem.update(state: state, error: m["error"] as? String)
        case "close":
            exit(0)
        default:
            break
        }
    }

    /// Once neither surface is showing, tells the agent; it replies `close` unless it has sent
    /// a command this process hasn't seen yet. Deferred so popover → Settings can hand over first.
    private func reportIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.popover?.isVisible != true && self.settingsWindow?.isVisible != true {
                self.send(["op": "idle", "seen": self.lastSeen])
            }
        }
    }

    // MARK: Popover

    private func togglePopover(below anchor: NSRect) {
        if let p = popover, p.isVisible {
            // A second click of a double-click on a cold start arrives right after the menu
            // appears; keep it open, as a double-click on a warm one would.
            if Date().timeIntervalSince(lastShown) < 0.3 { return }
            p.dismiss()
            return
        }
        // Clicking the icon while open makes the panel close on the outside click just before
        // this command arrives; treat that click as "close", not "reopen".
        if let p = popover, Date().timeIntervalSince(p.lastDismissed) < 0.3 { return }
        showPopover(below: anchor)
    }

    private func showPopover(below anchor: NSRect) {
        let panel = popover ?? PopoverPanel()
        popover = panel
        let root = LCDThemed {
            PopoverView(player: player,
                        openSettings: { [weak self] in self?.popover?.dismiss(); self?.showSettings() },
                        close: { [weak panel] in panel?.dismiss() },
                        quit: { [weak self] in
                            self?.send(["op": "quit"])
                            self?.channel?.flush { exit(0) }
                        })
        }
        .environmentObject(settings)
        .environmentObject(status)
        panel.onDismiss = { [weak self] in
            self?.send(["op": "popover", "visible": false])
            self?.reportIfIdle()
        }
        panel.present(NSHostingController(rootView: root), below: anchor)
        lastShown = Date()
        send(["op": "popover", "visible": true])
    }

    // MARK: Settings

    private func showSettings() {
        let window = settingsWindow ?? SettingsWindow()
        settingsWindow = window
        if window.contentViewController == nil {
            let root = LCDThemed {
                SettingsView(player: player, close: { [weak window] in window?.dismiss() }, loginItem: loginItem)
            }
            .environmentObject(settings)
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = .preferredContentSize
            window.contentViewController = controller
            // Resolve the real size before centering, and keep it on screen.
            let size = controller.view.fittingSize
            window.setContentSize(size)
            window.center()
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                var f = window.frame
                f.origin.y = min(max(f.origin.y, visible.minY), visible.maxY - f.height)
                window.setFrameOrigin(f.origin)
            }
        }
        window.onDismiss = { [weak self] in self?.reportIfIdle() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // If macOS declines the activation (another app keeps focus), still show it in front.
        window.orderFrontRegardless()
    }
}

/// The UI process's view of the schedule. Actions edit settings (the agent persists them,
/// re-arms its timer and reports the new next chime back), except Skip, which the agent
/// resolves against its own next chime in case this copy is a moment out of date.
@MainActor
final class ChimeStatus: ObservableObject {
    @Published var nextChime: Date?
    private let settings: Settings
    private let requestSkip: () -> Void

    init(settings: Settings, requestSkip: @escaping () -> Void = {}) {
        self.settings = settings
        self.requestSkip = requestSkip
        nextChime = settings.rules.nextChime(after: Date(), calendar: .autoupdatingCurrent)
    }

    func pause(for interval: TimeInterval) { settings.pausedUntil = Date().addingTimeInterval(interval) }

    func pauseUntilTomorrow() {
        let cal = Calendar.autoupdatingCurrent
        settings.pausedUntil = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    }

    func resume() { settings.pausedUntil = nil }

    func skipNext() { requestSkip() }
}

/// Asks the agent to play a preview, so it can never overlap a real chime.
@MainActor
final class PreviewClient {
    private let settings: Settings
    private let request: (String, Bool) -> Void

    init(settings: Settings, request: @escaping (String, Bool) -> Void) {
        self.settings = settings
        self.request = request
    }

    /// Returns false when nothing could be heard (volume at 0, or no sound and no voice).
    @discardableResult
    func preview(soundID: String? = nil, speak: Bool? = nil) -> Bool {
        let id = soundID ?? settings.soundID
        let speakIt = speak ?? settings.speakTime
        request(id, speakIt)
        return settings.volume > 0 && (id != SoundLibrary.noneID || speakIt)
    }
}

/// Borderless, non-activating panel that behaves like a menu: closes on Esc,
/// on a click elsewhere, or when it loses key status. Its SwiftUI content is torn down
/// on close so the clock face stops redrawing.
final class PopoverPanel: NSPanel {
    var onDismiss: (() -> Void)?
    private(set) var lastDismissed = Date.distantPast
    private var outsideClickMonitor: Any?
    private var presented = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }

    func present(_ controller: NSViewController, below anchor: NSRect) {
        contentViewController = controller
        let size = controller.view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrame(NSRect(x: x, y: anchor.minY - size.height - 4, width: size.width, height: size.height), display: true)
        presented = true
        makeKeyAndOrderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    /// Idempotent: resignKey, Esc, outside clicks and the status button may all race to close.
    func dismiss() {
        guard presented else { return }
        presented = false
        lastDismissed = Date()
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        orderOut(nil)
        contentViewController = nil
        onDismiss?()
    }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
}

/// Borderless settings window: the watch case is the whole window. Drag it anywhere.
/// A non-activating panel, like the menu, so it takes keyboard focus even when macOS
/// won't let the UI process become the active app.
final class SettingsWindow: NSPanel {
    var onDismiss: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 470, height: 760), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        title = "Howr Settings"
        setAccessibilityTitle("Howr Settings")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func dismiss() {
        orderOut(nil)
        contentViewController = nil   // free the view tree; it is rebuilt on next open
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" { dismiss(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
