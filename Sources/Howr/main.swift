import AppKit

// A peer that went away must show up as a write error, not kill the process.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if Snapshot.run(args) { exit(0) }
    if let i = args.firstIndex(of: "--play") { ChimeProcess.run(Array(args[(i + 1)...])) }

    var ownership: AgentLock?
    if !args.contains("--ui") {
        do {
            ownership = try AgentLock.acquire()
            guard ownership != nil else { NSLog("Howr is already running."); exit(0) }
        } catch { NSLog("Howr could not acquire its agent lock: \(error)"); exit(1) }
    }

    // Default (no arguments, e.g. at login): the always-running agent.
    // `--ui`: the menu / Settings process the agent starts on demand.
    let app = NSApplication.shared
    let delegate: NSObject & NSApplicationDelegate = args.contains("--ui") ? UIAppDelegate() : AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime((delegate, ownership)) { app.run() }
}
