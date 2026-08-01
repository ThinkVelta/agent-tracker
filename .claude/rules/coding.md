---
description: Behavioral guidelines to reduce common LLM coding mistakes, plus this repo's Swift conventions.
paths:
  - "Sources/**"
  - "Tests/**"
---

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## Comments

**Default to no comment. Multi-line preambles are a smell.**

- Don't re-state what self-evident code already shows.
- Reserve comments for non-obvious WHY: workarounds, subtle invariants, surprising behavior.
- If removing the comment wouldn't confuse a future reader, don't write it.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

- Don't "improve" adjacent code, comments, or formatting; don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- Remove imports/variables/functions that YOUR changes made unused; leave pre-existing dead code.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan with a verify check per step.

## 5. Swift conventions

- **Concurrency:** UI-facing state lives in `@MainActor final class … : ObservableObject` stores
  (`SessionStore`, `CodexSessionScanner`). Heavy/background work goes in a plain worker class
  confined to a private serial `DispatchQueue` (marked `@unchecked Sendable`, queue-confined
  methods carry a `…Locked` suffix — see `CodexScanWorker`), publishing back to the main actor
  via `Task { @MainActor in … }`. Don't introduce new concurrency patterns beside these.
- **SwiftUI:** the menu bar is a raw `NSStatusItem` + `NSPopover` owned by the `AppDelegate`
  (per-dot click zones — `MenuBarExtra`'s label is a single click target), hosting SwiftUI
  content via `NSHostingController`; `@ObservedObject` passed down. Build views from small
  `private var` computed subviews rather than nested closures or per-view view-model classes.
- **Error handling:** degrade gracefully instead of throwing — `guard`/early-return with `try?`
  for I/O, and parsers that never throw (unknown input maps to an "insignificant"/nil case, see
  `CodexRolloutParser`). Malformed external input (state files, rollouts, tool output) must
  never crash the app. No force-unwraps.
- **Organization:** flat `Sources/AgentTracker/`, one concern per file. Stateless helpers are
  caseless `enum` namespaces with static methods (`StatusIconRenderer`, `TerminalFocuser`).
  Keep pure parsing/derivation logic I/O-free and separate from watchers (`CodexRollout.swift`
  vs `CodexSessionScanner.swift`) so it stays unit-testable.
- **Dependencies:** none. Swift stdlib + Apple frameworks only; `Package.swift` declares no
  external packages and must stay that way.
- **Formatting:** `swift format` with the repo's `.swift-format` — 4-space indent, 100 columns.
- **Tests:** prefer Swift Testing (`import Testing`, `#expect`) for new tests under
  `Tests/AgentTrackerTests/`; target the pure logic (parsers, accumulators, groupers), not UI.
