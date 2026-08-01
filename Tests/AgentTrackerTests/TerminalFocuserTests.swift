import Foundation
import Testing

@testable import AgentTracker

final class TerminalFocuserTests {
    private func claudeSession(id: String, cwd: String) -> AgentSession {
        AgentSession(provider: "claude-code", sessionId: id, cwd: cwd, state: .needsYou)
    }

    @Test func exactTitleLeadsCandidatesAtTopWeight() {
        let session = claudeSession(id: "s1", cwd: "/Users/dev/planner")
        let candidates = TerminalFocuser.titleCandidates(
            for: session, exactTitle: "Fix the flaky scanner test")
        #expect(candidates.first?.text == "Fix the flaky scanner test")
        #expect(candidates.first?.weight == 150)
        #expect(candidates.first?.exactOnly == true)
        // Every fallback stays behind it and keeps substring matching.
        #expect(candidates.dropFirst().allSatisfy { $0.weight < 150 && !$0.exactOnly })
    }

    @Test func candidatesWithoutExactTitleKeepPathFallbacks() {
        let session = claudeSession(id: "s1", cwd: "/Users/dev/planner")
        let candidates = TerminalFocuser.titleCandidates(for: session, exactTitle: nil)
        #expect(candidates.map(\.text) == ["/Users/dev/planner", "dev/planner", "planner"])
        #expect(candidates.map(\.weight) == [60, 50, 40])
    }

    @Test func exactMatchOutscoresGlyphPrefixAndDoublesWeight() {
        let candidates = [
            TerminalFocuser.TitleCandidate(
                "Verify Planner secret redaction payload field", weight: 150, exactOnly: true)
        ]
        let exact = TerminalFocuser.matchScore(
            windowTitle: "⠐ Verify Planner secret redaction payload field",
            candidates: candidates
        )
        #expect(exact == 300)
        let unrelated = TerminalFocuser.matchScore(
            windowTitle: "✳ Port planner tooling", candidates: candidates)
        #expect(unrelated == 0)
    }

    @Test func exactOnlyCandidateNeverMatchesBySubstring() {
        // Regression: sessions "api refactor" and "api refactor tests" share a
        // prefix; a substring hit would confidently raise the sibling's
        // window. The exact-title candidate must score all-or-nothing.
        let candidates = [
            TerminalFocuser.TitleCandidate("api refactor", weight: 150, exactOnly: true)
        ]
        #expect(
            TerminalFocuser.matchScore(windowTitle: "⠐ api refactor tests", candidates: candidates)
                == 0)
        #expect(
            TerminalFocuser.matchScore(windowTitle: "⠐ api refactor", candidates: candidates)
                == 300)
        // Fallback candidates keep substring behavior.
        let fallback = [TerminalFocuser.TitleCandidate("planner", weight: 40)]
        #expect(
            TerminalFocuser.matchScore(windowTitle: "dev/planner — zsh", candidates: fallback)
                == 40)
    }

    /// The real repro: two Claude sessions plus a Codex session sharing one
    /// repo directory — every session's best-scoring window must be its own.
    @Test func threeSessionsOneRepoEachMatchTheirOwnWindow() {
        let cwd = "/Users/dev/planner"
        let windowTitles = [
            "⠐ Fix the flaky scanner test",
            "✳ Port planner tooling",
            "planner",
        ]
        let exactTitles: [String?] = [
            "Fix the flaky scanner test",  // claude, named via statusline
            "Port planner tooling",  // claude, named via statusline
            nil,  // codex — bare project-name tab title
        ]
        for (sessionIndex, exactTitle) in exactTitles.enumerated() {
            let session = AgentSession(
                provider: exactTitle == nil ? "codex" : "claude-code",
                sessionId: "s\(sessionIndex)", cwd: cwd, state: .running
            )
            let candidates = TerminalFocuser.titleCandidates(for: session, exactTitle: exactTitle)
            let scores = windowTitles.map {
                TerminalFocuser.matchScore(windowTitle: $0, candidates: candidates)
            }
            let best = scores.enumerated().max { $0.element < $1.element }?.offset
            #expect(best == sessionIndex, "session \(sessionIndex) matched window \(best ?? -1)")
        }
    }
}
