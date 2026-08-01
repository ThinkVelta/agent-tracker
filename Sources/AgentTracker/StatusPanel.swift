import AppKit

/// The dropdown's window: a borderless panel we chrome ourselves, because
/// NSPopover's corner radius is system-drawn and not configurable (user
/// feedback: too round) and its arrow nub adds height.
///
/// Borderless panels refuse key status by default, and the search field needs
/// it; `.nonactivatingPanel` means typing works without activating the app
/// (the Spotlight pattern), so opening the dropdown never steals focus.
final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Wraps `contentView` in the system popover material, clipped to the
    /// theme's (tighter) radius, with the floating behavior the dropdown
    /// needs: follows the user across Spaces, shows over full-screen apps.
    convenience init(wrapping contentView: NSView) {
        self.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .none
        hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.Metrics.panelCornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        contentView.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: effect.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        self.contentView = effect
    }
}
