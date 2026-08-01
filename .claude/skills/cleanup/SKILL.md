---
name: cleanup
description: Clean the codebase by making sure all lint checks and all tests pass. Invoke with `/cleanup`.
context: fork
agent: cleanup
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

Fix all lint errors and test failures in the codebase. Run lint and tests, fix any issues found, and repeat until everything passes.

IMPORTANT: Do NOT commit any changes — this skill only fixes code. The human handles committing (via `/commit`).

IMPORTANT: Launch the cleanup agent and let it run to completion autonomously. When the agent returns, relay its summary to the user.
