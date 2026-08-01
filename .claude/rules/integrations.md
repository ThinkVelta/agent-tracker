---
description: Conventions for the agent-CLI integrations — the hook script, onboarding CLI, and installers.
paths:
  - "integrations/**"
---

## Python (`agent-tracker-hook.py`, `onboard.py`)

- **Stdlib only**, and compatible with the macOS *system* `python3` (an older 3.x) — no
  third-party imports, no syntax newer than what `/usr/bin/python3` accepts. Users run these
  without any environment setup.
- The hook must **never block or break an agent session**: always exit 0, print nothing on
  success, wrap `main()` so every exception still exits 0.
- `onboard.py` must degrade gracefully without a TTY: flag-driven fallback, no hangs, no
  tracebacks.

## Shell installers (`install-*.sh`, `uninstall.sh`)

- **Shellcheck-clean**, POSIX-leaning bash: `set -euo pipefail`, quoted expansions, no bashisms
  beyond what shellcheck accepts silently. Run `shellcheck integrations/*.sh` before finishing.
- **Idempotent** — safe to re-run: detect an existing registration and no-op instead of
  duplicating it, and refuse (with a manual-merge hint) rather than clobber an unrelated
  user setting.
- Back up user configs (`settings.json`, `config.toml`) before editing them.
- **Never store secrets** — the scripts touch user config files; they must not read, write, or
  echo tokens/keys, and nothing secret belongs under `~/.agent-tracker/`.

## Keep the docs honest

- Any change to install/uninstall behavior or flags must update the README's install
  instructions in the same commit.
