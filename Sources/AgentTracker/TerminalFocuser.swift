import AppKit
import ApplicationServices

/// Jumps to the terminal window a session lives in.
///
/// Strategy: verify Accessibility permission, then find the window whose title
/// best matches the session (Claude Code sets window titles to "✳ <task
/// summary>"; plain shells and the Codex TUI show the working directory or
/// project name) and raise it. Raising a window on another Space makes macOS
/// switch to it.
///
/// Every attempt prints a `[focus]` trace to stdout — visible in the terminal
/// running `swift run AgentTracker` — so misbehavior is diagnosable from a
/// single paste.
enum TerminalFocuser {
    enum Outcome {
        /// Raised a specific matching window.
        case focusedWindow(title: String)
        /// No window title matched; brought the terminal app forward instead.
        case activatedAppOnly
        /// No known terminal app is running.
        case noTerminalFound
        /// Accessibility permission missing — the system prompt was triggered.
        case needsPermission
    }

    private static let bundleIdentifiers: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal",
        "wezterm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty",
    ]

    /// True when the process can drive the Accessibility API. Does not prompt.
    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func focus(_ session: AgentSession) -> Outcome {
        log("focusing \(session.providerDisplayName) session \(session.sessionId) (cwd: \(session.cwd ?? "?"))")

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            log("no Accessibility permission — system prompt triggered. NOTE: when run via `swift run` from a terminal, macOS attributes the permission to that terminal (the responsible process). After granting, QUIT AND RE-RUN AgentTracker for it to take effect.")
            return .needsPermission
        }

        guard let app = terminalApp(for: session) else {
            log("no known terminal app is running (looked for: \(bundleIdentifiers.values.sorted().joined(separator: ", ")))")
            return .noTerminalFound
        }
        log("terminal app: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"), pid \(app.processIdentifier))")

        let candidates = titleCandidates(for: session)
        log("title candidates: \(candidates.map { "\"\($0.text)\" (w\($0.weight))" }.joined(separator: ", "))")

        guard let best = bestWindow(in: app, candidates: candidates) else {
            log("no window title matched — activating \(app.localizedName ?? "the app") without raising a specific window")
            app.activate()
            return .activatedAppOnly
        }
        log("raising window \"\(best.title)\" (score \(best.score))")
        AXUIElementPerformAction(best.window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(best.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate()
        return .focusedWindow(title: best.title)
    }

    private static func terminalApp(for session: AgentSession) -> NSRunningApplication? {
        if let termProgram = session.termProgram?.lowercased(),
           let bundleID = bundleIdentifiers[termProgram],
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        for bundleID in bundleIdentifiers.values.sorted() {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }
        }
        return nil
    }

    private static func bestWindow(
        in app: NSRunningApplication,
        candidates: [(text: String, weight: Int)]
    ) -> (window: AXUIElement, title: String, score: Int)? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard axResult == .success, let windows = value as? [AXUIElement] else {
            log("AXWindows query failed (\(axResult.rawValue)) — permission granted but not yet effective? Try restarting AgentTracker.")
            return nil
        }
        log("\(windows.count) window(s) visible via Accessibility:")

        var best: (window: AXUIElement, title: String, score: Int)?
        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String else { continue }
            let score = matchScore(windowTitle: title, candidates: candidates)
            log("  \"\(title)\" -> score \(score)")
            if score > (best?.score ?? 0) {
                best = (window, title, score)
            }
        }
        return best
    }

    /// Ordered by reliability: the Claude task summary is near-unique per session,
    /// path fragments can collide across sessions in the same repo.
    private static func titleCandidates(for session: AgentSession) -> [(text: String, weight: Int)] {
        var candidates: [(String, Int)] = []
        if let summary = TranscriptTitle.latestSummary(atPath: session.transcriptPath) {
            candidates.append((summary, 100))
        }
        if let cwd = session.cwd {
            candidates.append((cwd, 60)) // full path — some terminals title with it
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
            .trimmingCharacters(in: CharacterSet(charactersIn: "✳·⚒…~ \t"))
            .trimmingCharacters(in: .whitespaces)
    }

    static func openAccessibilitySettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func log(_ message: String) {
        print("[focus] \(message)")
    }
}
