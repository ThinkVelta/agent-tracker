import AppKit
import ApplicationServices

/// Thin, non-throwing wrappers over the Accessibility C API. Split out of
/// `TerminalFocuser` so that file stays about *choosing* a window rather than
/// about the mechanics of reading one.
enum AXAccess {
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func children(of element: AXUIElement) -> [AXUIElement]? {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
    }

    static func title(of element: AXUIElement) -> String? {
        attribute(element, kAXTitleAttribute as String) as? String
    }

    static func windows(of app: NSRunningApplication) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        return attribute(axApp, kAXWindowsAttribute as String) as? [AXUIElement]
    }

    /// The window's live working directory, as terminals report it through
    /// `AXDocument`.
    static func documentPath(of element: AXUIElement) -> String? {
        WindowIdentity.directory(
            fromDocumentAttribute: attribute(element, kAXDocumentAttribute as String) as? String)
    }

    /// The app's "Window" menu. Matching the English title is a documented
    /// limitation; localized menu bars fall back to the AX window list.
    static func windowMenuItems(of app: NSRunningApplication) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = element(attribute(axApp, kAXMenuBarAttribute as String)),
            let topItems = children(of: menuBar),
            let windowItem = topItems.first(where: { title(of: $0) == "Window" }),
            let menu = children(of: windowItem)?.first
        else { return nil }
        return children(of: menu)
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}
