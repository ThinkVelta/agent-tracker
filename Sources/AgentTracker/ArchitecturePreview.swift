import SwiftUI

/// Debug-only diagram for `--render-preview --view architecture`: the README's
/// "how it works" picture, drawn from the same `Theme` tokens as the app so it
/// cannot drift out of style the way a hand-drawn image would.
///
/// Deliberately three columns — where state comes from, what holds it, what you
/// see — because that is the only structural claim worth making: the app owns
/// no process and polls nothing that matters, it watches files other tools
/// already write.
enum ArchitecturePreview {
    private struct Node: View {
        let title: String
        let detail: String?
        var accent: Color?

        var body: some View {
            HStack(spacing: 7) {
                if let accent {
                    RoundedRectangle(cornerRadius: Theme.Metrics.accentBarWidth / 2)
                        .fill(accent)
                        .frame(width: Theme.Metrics.accentBarWidth, height: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 208, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Metrics.tileCornerRadius)
                    .fill(Theme.Palette.tileRest)
            )
        }
    }

    private struct Arrow: View {
        var body: some View {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26)
        }
    }

    private struct Column: View {
        let heading: String
        let nodes: [Node]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(heading.uppercased())
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                    // Never truncate a heading to fit the node width below it.
                    .fixedSize(horizontal: true, vertical: false)
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                    node
                }
            }
        }
    }

    static func diagram() -> some View {
        HStack(alignment: .center, spacing: 0) {
            Column(
                heading: "Agents write",
                nodes: [
                    Node(
                        title: "Claude Code hooks",
                        detail: "lifecycle events, pushed", accent: nil),
                    Node(title: "Codex notify", detail: "turn complete, pushed", accent: nil),
                    Node(
                        title: "~/.codex/sessions",
                        detail: "rollout files, read-only", accent: nil),
                ]
            )
            Arrow()
            Column(
                heading: "Tracker keeps",
                nodes: [
                    Node(
                        title: "~/.agent-tracker/",
                        detail: "one JSON file per session", accent: nil),
                    Node(title: "Directory watchers", detail: "no daemon, no polling", accent: nil),
                    Node(
                        title: "Liveness check",
                        detail: "prunes sessions that died", accent: nil),
                ]
            )
            Arrow()
            Column(
                heading: "You see",
                nodes: [
                    Node(
                        title: "Menu bar dots",
                        detail: "needs you · running · idle",
                        accent: SessionState.needsYou.color),
                    Node(
                        title: "Session list",
                        detail: "grouped, filterable, searchable",
                        accent: SessionState.running.color),
                    Node(
                        title: "Click to focus",
                        detail: "raises the terminal, across Spaces",
                        accent: SessionState.idle.color),
                ]
            )
        }
        .padding(20)
    }
}
