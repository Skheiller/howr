import AppKit

/// Agent side of the UI process: starts `Howr --ui` on demand and talks to it over its
/// stdin/stdout.
///
/// The UI never decides to exit on its own: when nothing is showing it reports `idle` with
/// the last command it has seen. Only if that is the last command sent does the agent stop
/// using it and reply `close`, so a command can't land in a process that is about to exit.
@MainActor
final class UIHost {
    var onLaunch: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    /// The UI is gone and no other one is running.
    var onExit: (() -> Void)?

    private let executable: URL?
    private let arguments: [String]

    /// One UI process and its pipe. It ends once the process has exited *and* its output has
    /// been read to EOF, so a final message (Quit, a last edit) is never dropped.
    private final class Session {
        let process: Process
        var channel: Channel?
        var exited = false
        var drained = false
        var lastCommand = 0
        init(process: Process) { self.process = process }
    }

    /// The session that receives commands.
    private var current: Session?
    /// Every session still running or still being read, current or retired.
    private var live: [Session] = []

    init(executable: URL? = Bundle.main.executableURL, arguments: [String] = ["--ui"]) {
        self.executable = executable
        self.arguments = arguments
    }

    var isRunning: Bool { current != nil }

    /// The UI process as an app, e.g. to hand it activation.
    var runningApp: NSRunningApplication? {
        current.flatMap { NSRunningApplication(processIdentifier: $0.process.processIdentifier) }
    }

    func launchIfNeeded() {
        if current == nil { launch() }
    }

    /// Sends a command that may open a window, starting the UI process if needed.
    func send(_ message: [String: Any]) {
        launchIfNeeded()
        guard let s = current else { return }
        if !deliver(message, to: s) {
            // The pipe broke, so that process is gone: run the command in a fresh one.
            retire(s)
            launch()
            if let fresh = current { deliver(message, to: fresh) }
        }
    }

    /// Sends only to a UI process that is already open (state updates). Not tracked.
    func notify(_ message: [String: Any]) {
        current?.channel?.send(message)
    }

    func terminate() {
        for s in live {
            s.channel?.send(["op": "close"])
            if s.process.isRunning { s.process.terminate() }
        }
    }

    @discardableResult
    private func deliver(_ message: [String: Any], to s: Session) -> Bool {
        s.lastCommand += 1
        var m = message
        m["seq"] = s.lastCommand
        return s.channel?.send(m) == true
    }

    private func launch() {
        guard let executable else { return }
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        let toUI = Pipe(), fromUI = Pipe()
        p.standardInput = toUI
        p.standardOutput = fromUI
        let s = Session(process: p)
        p.terminationHandler = { [weak self, weak s] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let s else { return }
                    s.exited = true
                    self.retire(s)
                    self.finishIfDone(s)
                }
            }
        }
        do { try p.run() } catch { NSLog("Howr: could not start the UI: \(error)"); return }
        s.channel = Channel(read: fromUI.fileHandleForReading, write: toUI.fileHandleForWriting,
                            onMessage: { [weak self, weak s] m in
                                guard let self, let s else { return }
                                self.receive(m, from: s)
                            },
                            onClose: { [weak self, weak s] in
                                guard let self, let s else { return }
                                s.drained = true
                                if s.process.isRunning { s.process.terminate() }
                                self.finishIfDone(s)
                            })
        current = s
        live.append(s)
        onLaunch?()
    }

    private func receive(_ m: [String: Any], from s: Session) {
        if m["op"] as? String == "idle" {
            if s === current, (m["seen"] as? Int) == s.lastCommand {
                retire(s)
                s.channel?.send(["op": "close"])
            }
            return
        }
        onMessage?(m)
    }

    private func retire(_ s: Session) {
        if current === s { current = nil }
    }

    private func finishIfDone(_ s: Session) {
        guard s.exited, s.drained, live.contains(where: { $0 === s }) else { return }
        s.channel?.close()
        s.channel = nil
        live.removeAll { $0 === s }
        if current == nil { onExit?() }
    }
}
