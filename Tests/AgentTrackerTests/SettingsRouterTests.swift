import Testing

@testable import AgentTracker

@MainActor
struct SettingsRouterTests {
    /// Settings opens where it always did unless something asked otherwise.
    @Test func defaultsToGeneral() {
        #expect(SettingsRouter().selection == .general)
    }

    /// `show` sets the tab first, then opens: the window must find the
    /// selection already changed, not race it.
    @Test func showSelectsTheTabThenOpens() {
        let router = SettingsRouter()
        var openedWithSelection: SettingsTab?
        router.show(.about) { openedWithSelection = router.selection }
        #expect(router.selection == .about)
        #expect(openedWithSelection == .about)
    }

    /// The marker an update notification carries is the only thing that tells a
    /// click "open Settings" from "focus a session".
    @Test func updateFieldIsDistinctFromTheSessionKey() {
        #expect(Notifications.updateField != AttentionNotifier.sessionKeyField)
    }
}
