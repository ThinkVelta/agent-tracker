# `.claude/` — Claude Code configuration

This directory configures how Claude Code interacts with the project: rules it follows, skills
(slash commands) it can invoke, guard hooks, and permission settings.

## Layout

| Path | Role |
| - | - |
| `CLAUDE.md` (repo root) | Project orientation — loaded into every Claude session |
| `settings.json` | Project-shared permissions, hooks wiring, env defaults (committed) |
| `settings.local.json` | Per-developer overrides (gitignored, do NOT commit) |
| `rules/` | Always-on, path-scoped rules layered into the system prompt |
| `hooks/` | Guard scripts wired in `settings.json` that mechanically enforce repo rules |
| `skills/` | Slash commands, one folder with a `SKILL.md` each |
| `agents/` | Subagent definitions (model, tools, playbook) skills delegate to via `agent:` |
| `worktrees/` | Parallel-branch checkouts managed by the `/wt-*` skills (gitignored) |
| `agent-memory/` | Machine-local agent scratch state (gitignored) |

Everything in `.claude/` is committed and shared **except** the machine-local state:
`settings.local.json`, `agent-memory/`, `worktrees/`, and `*.lock` are gitignored.

The contents of each directory are self-describing — every skill carries its own frontmatter
(`name`, `description`) and every rule file opens with its scope. Browse the directory rather
than relying on an inventory here; a listing would go stale the moment something is added or
renamed.

## How the pieces fit

- **`CLAUDE.md`** is loaded by Claude Code at session start. Think of it as the README a
  teammate would skim before touching the codebase.
- **`rules/*.md`** are *always-on* context. Every rule is layered into the system prompt for the
  paths it declares. Keep them short and durable — they cost tokens on every interaction.
- **`hooks/`** holds guard scripts (wired in `settings.json`) that enforce repo rules
  mechanically rather than by prose — a block takes effect before the tool call runs.
- **`skills/*/SKILL.md`** define slash commands that the user types.
- **`agents/*.md`** define the subagents some skills fork into: a skill whose frontmatter names
  an `agent:` (e.g. `/commit`, `/pr-open`, `/cleanup`) delegates its playbook to the matching
  file here, which pins the model and tool allowlist for that run.
- **`settings.json`** controls permissions (which tool calls run without prompting), hook
  wiring, and environment defaults. Per-project.
- **`settings.local.json`** is the same shape but per-developer and gitignored — for personal
  allow-lists.

## Scopes — which file wins

Claude Code merges config from several scopes:

1. `~/.claude/` — your personal global config
2. `.claude/settings.json` (this repo) — project-shared config
3. `.claude/settings.local.json` (this repo) — your personal project overrides
4. CLI flags

Higher numbers override lower. Project-shared config is the right place for rules every session
should follow; personal overrides go in `.local.json`.

## Editing this directory

- Always work in feature branches; never commit `.claude/` changes directly to `main`.
- Skill/hook edits take effect on the next Claude session — restart the conversation after
  changes to be sure.
- Test new rules in a throwaway conversation before relying on them.
