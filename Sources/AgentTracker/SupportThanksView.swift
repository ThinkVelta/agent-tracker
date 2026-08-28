import SwiftUI

/// The once-per-update thanks window: a short note and the ways to support
/// the project, styled after the first-run window so the two read as
/// siblings. The footer's opt-out writes the same preference Settings ›
/// About exposes, so either place can turn it back on.
struct SupportThanksView: View {
    /// Closes the hosting window.
    var dismiss: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            hero
            supportLinks
            footer
        }
        .frame(width: 430)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                Circle().fill(.red).frame(width: 16, height: 16)
                Circle().fill(.green).frame(width: 16, height: 16)
                Circle().fill(.gray).frame(width: 16, height: 16)
            }
            .padding(.top, 28)
            Text("Thank you for using AgentTracker")
                .font(.system(size: 19, weight: .bold))
            Text(
                "It's free and open source. If it has earned its place in your "
                    + "menu bar, a star or a small contribution keeps it going."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 18)
    }

    private var supportLinks: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                supportTile(
                    "Sponsor on GitHub", symbol: "heart.fill", tint: .pink,
                    url: SupportThanks.sponsorsURL)
                supportTile(
                    "Donate with PayPal", symbol: "dollarsign.circle.fill", tint: .blue,
                    url: SupportThanks.paypalURL)
            }
            .padding(.horizontal, 20)
            Link(destination: SupportThanks.repoURL) {
                HStack(spacing: 4) {
                    Image(systemName: "star")
                    Text("Star the project on GitHub")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func supportTile(_ title: String, symbol: String, tint: Color, url: URL) -> some View {
        Link(destination: url) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.Palette.tileRest))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Button(action: dismiss) {
                Text("Close")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            Button("Don't show this after updates") {
                Preferences.shared.supportThanks = false
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}
