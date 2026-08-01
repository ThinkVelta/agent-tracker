#!/usr/bin/env bash
# PostToolUse(Bash) hook: mask secrets in tool output before the model and the
# transcript see them. See redact-secrets.jq for the patterns.
#
# Scoped to Bash only (the main secret-dump vector) via the matcher in
# settings.json, so non-Bash tools never spawn this. One jq pass per Bash call,
# synchronous (required: an async hook would run too late to redact).
#
# Fails OPEN: if jq is missing OR the payload doesn't parse, the hook emits
# nothing and exits 0 — Claude Code then leaves the tool output unchanged (no
# redaction), with no jq parse error reaching the transcript. The hook can never
# blank or break a tool call (worst case: no redaction, never a stall/crash).
set -euo pipefail

# Buffer stdin so a jq failure can fall through to a clean no-op (empty output,
# exit 0) instead of a non-zero exit + stderr noise.
payload="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0
printf '%s' "$payload" | jq -cf "$(dirname "$0")/redact-secrets.jq" 2>/dev/null || exit 0
