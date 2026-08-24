import AppKit
import SwiftUI

/// Which Settings tab is showing, and the one seam for opening the window on a
/// chosen one. `TabView` has no way to be told a tab from outside, so the
/// selection lives here and the view binds to it; anything that wants to land
/// somewhere specific sets `selection` first, then opens the window.
enum SettingsTab: Hashable {
    case general, menuBar, sessions, advanced, about
}

@MainActor
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()

    @Published var selection: SettingsTab = .general

    /// Open Settings on `tab`. Sets the tab first so the window finds the
    /// selection already changed, then runs `open`, which owns the actual
    /// window-showing and any activation. Defaults to the AppKit path for
    /// callers with no SwiftUI environment (the notification handler); a
    /// SwiftUI caller passes a closure around the `openSettings` action.
    func show(_ tab: SettingsTab, open: () -> Void = SettingsRouter.openViaAppKit) {
        selection = tab
        open()
    }

    /// Opening Settings from AppKit, where the SwiftUI `openSettings` action is
    /// not in scope. The selector was renamed at macOS 13 (`showPreferences`
    /// to `showSettings`); this build targets 14, so the new name is tried
    /// first and the old one is a belt-and-braces fallback rather than a
    /// silent no-op if a future OS renames it again. Activates first, because
    /// an accessory app's windows otherwise open without focus.
    static func openViaAppKit() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        if NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) { return }
        // No third way to open Settings from AppKit. Best-effort, but say so:
        // a future OS renaming the selector would otherwise be a dead click
        // with nothing in the log the About tab sends people to.
        DebugLog.log(
            "[settings] \(DebugLog.timestamp()) could not open Settings; no known selector handled")
    }
}
