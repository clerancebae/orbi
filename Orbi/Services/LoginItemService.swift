import Foundation
import Observation
import OSLog
import ServiceManagement

/// Wraps `SMAppService.mainApp` for the launch-at-login toggle.
@MainActor
@Observable
final class LoginItemService {
    private let log = Logger(subsystem: "com.berke.Orbi", category: "LoginItem")

    private(set) var isEnabled: Bool = false
    private(set) var needsApproval: Bool = false
    private(set) var lastError: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            log.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
