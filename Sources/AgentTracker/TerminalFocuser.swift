import AppKit
import ApplicationServices

/// Jumps to the terminal window a session lives in.
///
/// Strategy: activate the terminal app, then use the Accessibility API to find
/// the window whose title best matches the session (Claude Code sets window
/// titles to "✳ <task summary>"; plain shells show the working directory) and
/// raise it. Raising a window on another Space makes macOS switch to it.
enum TerminalFocuser {
    private static let bundleIdentifiers: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal",
        "wezterm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty",
    ]

    @discardableResult
    static func focus(_ session: AgentSession) -> Bool {
        guard let app = terminalApp(for: session) else { return false }
        app.activate()

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        guard trusted else { return false }  // app is frontmost; window matching needs AX

        guard let window = bestWindow(in: app, for: session) else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate()
        return true
    }

    private static func terminalApp(for session: AgentSession) -> NSRunningApplication? {
        if let termProgram = session.termProgram?.lowercased(),
           let bundleID = bundleIdentifiers[termProgram],
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        for bundleID in bundleIdentifiers.values {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }
        return nil
    }

    private static func bestWindow(in app: NSRunningApplication, for session: AgentSession) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        let candidates = titleCandidates(for: session)
        var best: (window: AXUIElement, score: Int)?
        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String else { continue }
            let score = matchScore(windowTitle: title, candidates: candidates)
            if score > (best?.score ?? 0) {
                best = (window, score)
            }
        }
        return best?.window
    }

    /// Ordered by reliability: the Claude task summary is near-unique per session,
    /// path fragments can collide across sessions in the same repo.
    private static func titleCandidates(for session: AgentSession) -> [(text: String, weight: Int)] {
        var candidates: [(String, Int)] = []
        if let summary = TranscriptTitle.latestSummary(atPath: session.transcriptPath) {
            candidates.append((summary, 100))
        }
        if let context = session.pathContext {
            candidates.append((context, 50))
        }
        if session.projectName != "Session" {
            candidates.append((session.projectName, 40))
        }
        return candidates
    }

    private static func matchScore(windowTitle: String, candidates: [(text: String, weight: Int)]) -> Int {
        let title = normalize(windowTitle)
        guard !title.isEmpty else { return 0 }
        var score = 0
        for candidate in candidates {
            let text = normalize(candidate.text)
            guard !text.isEmpty else { continue }
            if title == text {
                score = max(score, candidate.weight * 2)
            } else if title.contains(text) || text.contains(title) {
                score = max(score, candidate.weight)
            }
        }
        return score
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "✳·⚒ \t"))
            .trimmingCharacters(in: .whitespaces)
    }
}
