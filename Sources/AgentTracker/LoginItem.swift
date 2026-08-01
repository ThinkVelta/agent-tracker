import Foundation
import ServiceManagement

/// Start-at-login via SMAppService. Only meaningful from a real .app bundle:
/// a bare SPM binary (`swift run`) has nothing launchd can register, so the
/// UI disables the control with an explanation instead of failing silently.
enum LoginItem {
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Reads the *actual* registration state, never a cached intent — the
    /// user can change this behind our back in System Settings, and a control
    /// must not show "on" while unbound.
    static var isEnabled: Bool {
        isSupported && SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isSupported else { return }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
