#!/bin/bash
# Onboarding entry point — thin wrapper around integrations/onboard.py.
# Run ./install.sh for the interactive picker, or pass flags for automation:
#   ./install.sh --agents claude,codex --yes
#   ./install.sh --agents claude --statusline --yes   # + capture usage windows
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/integrations/onboard.py" "$@"
