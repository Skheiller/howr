import ServiceManagement

/// Thin wrapper over SMAppService that reports the real state instead of a bare Bool.
/// Only the agent reads or changes registration: it is the process macOS launched as
/// Howr.app (the UI process just opens System Settings for approval).
enum LaunchAtLogin {
    enum State: String { case on, off, needsApproval, unavailable }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered: .off
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    /// Returns an error message if the change failed.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The UI process's view of the login item. The agent reads and changes the real one.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var state: LaunchAtLogin.State
    @Published private(set) var error: String?
    private let request: (Bool?) -> Void

    /// `request(nil)` asks the agent for the current state, `request(on)` asks it to change.
    init(state: LaunchAtLogin.State = .off, request: @escaping (Bool?) -> Void) {
        self.state = state
        self.request = request
    }

    func refresh() { request(nil) }

    func set(_ on: Bool) { request(on) }

    /// The agent's answer.
    func update(state: LaunchAtLogin.State, error: String?) {
        if self.state != state { self.state = state }
        if self.error != error { self.error = error }
    }
}
