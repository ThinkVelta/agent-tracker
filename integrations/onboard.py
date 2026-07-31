#!/usr/bin/env python3
"""Interactive onboarding for agent-tracker.

A Copier-style CLI: tick the agent CLIs you use in a checkbox list, read a
short disclaimer of exactly what will be changed, confirm, and the existing
idempotent installers in this directory do the rest. Run it as ./install.sh
from the repo root.

Usage:
  onboard.py                              # interactive checkbox picker
  onboard.py --agents claude,codex --yes  # non-interactive (CI, scripts)

Design constraints: dependency-free (stdlib only) and must degrade gracefully
when stdin is not a TTY — no hangs, no tracebacks, flag-driven fallback.
"""

import argparse
import os
import select
import shutil
import subprocess
import sys
import textwrap

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
USE_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def tint(code, text):
    return f"\x1b[{code}m{text}\x1b[0m" if USE_COLOR else text


def red(text):
    return tint("31", text)


def green(text):
    return tint("32", text)


def yellow(text):
    return tint("33", text)


def grey(text):
    return tint("90", text)


def bold(text):
    return tint("1", text)


def dim(text):
    return tint("2", text)


AGENTS = [
    {
        "key": "claude",
        "name": "Claude Code",
        "script": "install-claude-code.sh",
        "detect": lambda: bool(shutil.which("claude"))
        or os.path.exists(os.path.expanduser("~/.claude")),
        "plan": [
            "copy the hook script to ~/.agent-tracker/bin/",
            "back up ~/.claude/settings.json to settings.json.agent-tracker-backup",
            "register agent-tracker hooks in settings.json — merge-only, your "
            "existing settings are untouched; the hooks always exit 0 and can "
            "never block or modify a session",
        ],
    },
    {
        "key": "codex",
        "name": "Codex CLI",
        "script": "install-codex.sh",
        "detect": lambda: bool(shutil.which("codex"))
        or os.path.exists(os.path.expanduser("~/.codex")),
        "plan": [
            "copy the hook script to ~/.agent-tracker/bin/",
            "back up ~/.codex/config.toml to config.toml.agent-tracker-backup",
            "prepend one 'notify = [...]' line to config.toml — note: live "
            "running/turn-complete tracking works even without this (the app "
            "watches ~/.codex/sessions read-only); notify just adds an extra "
            "push signal",
        ],
    },
]


def print_banner():
    print()
    print(f"  {red('●')} {green('●')} {grey('●')}  {bold('Agent Tracker')}")
    print(dim("  Know which agent session needs you, at a glance."))
    print()


def pick_agents():
    """Interactive checkbox list (arrow keys/j/k, space, enter, q).

    Renders with raw-mode + ANSI redraw; always restores the terminal, even
    on abort or Ctrl-C.
    """
    import termios
    import tty

    detected = [agent["detect"]() for agent in AGENTS]
    checked = list(detected)
    cursor = 0
    fd = sys.stdin.fileno()
    out = sys.stdout
    frame_lines = len(AGENTS) + 2

    def draw(first=False):
        if not first:
            out.write(f"\x1b[{frame_lines}F")  # back to the top of the frame
        out.write(bold("Which agent CLIs do you use?") + "\x1b[K\n")
        for i, agent in enumerate(AGENTS):
            marker = "❯" if i == cursor else " "
            box = green("[x]") if checked[i] else grey("[ ]")
            suffix = dim(" (detected)") if detected[i] else ""
            out.write(f"  {marker} {box} {agent['name']}{suffix}\x1b[K\n")
        out.write(
            dim("  ↑/↓ or j/k move · space toggle · enter confirm · q abort")
            + "\x1b[K\n"
        )
        out.flush()

    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        out.write("\x1b[?25l")  # hide cursor
        draw(first=True)
        while True:
            key = os.read(fd, 1).decode("utf-8", "ignore")
            if key == "\x1b" and select.select([fd], [], [], 0.05)[0]:
                key += os.read(fd, 2).decode("utf-8", "ignore")
            if key in ("\x1b[A", "k"):
                cursor = (cursor - 1) % len(AGENTS)
            elif key in ("\x1b[B", "j"):
                cursor = (cursor + 1) % len(AGENTS)
            elif key == " ":
                checked[cursor] = not checked[cursor]
            elif key in ("\r", "\n"):
                return [a for a, c in zip(AGENTS, checked) if c]
            elif key in ("q", "\x03", "\x1b"):
                print("\nAborted — nothing was changed.")
                raise SystemExit(130)
            draw()
    finally:
        out.write("\x1b[?25h")  # show cursor
        out.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def parse_agents_flag(value):
    by_key = {agent["key"]: agent for agent in AGENTS}
    selected = []
    for key in value.split(","):
        key = key.strip().lower()
        if not key:
            continue
        if key not in by_key:
            valid = ", ".join(by_key)
            print(f"Unknown agent '{key}' — valid values: {valid}", file=sys.stderr)
            raise SystemExit(2)
        if by_key[key] not in selected:
            selected.append(by_key[key])
    return selected


def show_plan(selected):
    print(bold("This will:"))
    for agent in selected:
        print(f"\n  {agent['name']}:")
        for item in agent["plan"]:
            print(textwrap.fill(item, width=78, initial_indent="    • ",
                                subsequent_indent="      "))
    print()
    print("  Nothing else on the system is touched.")
    print("  Uninstall any time with integrations/uninstall.sh.")
    print()


def confirm():
    try:
        answer = input(bold("Proceed?") + " [y/N] ")
    except EOFError:
        return False
    return answer.strip().lower() in ("y", "yes")


def run_installer(agent):
    """Run one install script, prefixing its output. Returns True on success.

    Special case: install-codex.sh exits 1 when an unrelated notify handler is
    already configured — that is a warning, not a failure, because Codex
    tracking works via read-only session monitoring regardless.
    """
    print(f"\n{bold(agent['name'])}")
    script = os.path.join(SCRIPT_DIR, agent["script"])
    proc = subprocess.run(["bash", script], capture_output=True, text=True)
    if proc.returncode == 0:
        for line in proc.stdout.strip().splitlines():
            print(f"  {green('✓')} {line}")
        return True
    if (agent["key"] == "codex" and proc.returncode == 1
            and "already sets 'notify'" in proc.stderr):
        print(f"  {yellow('!')} Skipped the notify line — ~/.codex/config.toml "
              "already sets 'notify'")
        print("    to something else (merge it manually if you want the extra "
              "push signal).")
        print("    Codex tracking still fully works: the app watches "
              "~/.codex/sessions")
        print("    (read-only) for live session state.")
        return True
    for line in (proc.stdout + proc.stderr).strip().splitlines():
        print(f"  {red('✗')} {line}")
    print(f"  {red('✗')} {agent['name']} installer failed "
          f"(exit {proc.returncode})")
    return False


def print_outro():
    print()
    print(bold("All set — next steps:"))
    print(f"  1. {bold('swift run AgentTracker')} — starts the menu bar app.")
    print("  2. On your first click-to-focus, macOS asks you to grant the app")
    print("     Accessibility permission.")
    print("  3. Only NEW agent sessions are tracked — restart any that are "
          "already running.")
    print(dim("     (Codex sessions are also tracked automatically by watching"))
    print(dim("     ~/.codex/sessions read-only — no Codex restart needed for "
              "that part.)"))
    print()


def main():
    parser = argparse.ArgumentParser(
        prog="onboard.py",
        description="Onboarding for agent-tracker: pick your agent CLIs and "
        "register the integrations (idempotent, configs backed up first).",
    )
    parser.add_argument(
        "--agents", metavar="LIST",
        help="comma-separated agents to set up (claude,codex); "
        "skips the interactive picker",
    )
    parser.add_argument(
        "--yes", "-y", action="store_true",
        help="skip the confirmation prompt",
    )
    args = parser.parse_args()

    print_banner()
    interactive = sys.stdin.isatty() and sys.stdout.isatty()

    if args.agents is not None:
        selected = parse_agents_flag(args.agents)
    elif interactive:
        selected = pick_agents()
        print()
    else:
        print(dim("stdin is not a TTY — running non-interactively with the "
                  "agents detected on this system."))
        selected = [agent for agent in AGENTS if agent["detect"]()]
        names = ", ".join(agent["name"] for agent in selected) or "none"
        print(f"Detected: {names}")
        print()

    if not selected:
        print("No agents selected — nothing to install.")
        return 0

    show_plan(selected)
    if not args.yes:
        if not interactive:
            print("stdin is not a TTY — re-run with --yes to proceed, e.g.:")
            keys = ",".join(agent["key"] for agent in selected)
            print(f"  ./install.sh --agents {keys} --yes")
            return 1
        if not confirm():
            print("Aborted — nothing was changed.")
            return 0

    ok = True
    for agent in selected:
        ok = run_installer(agent) and ok
    if not ok:
        print(red("\nSome integrations failed to install — see output above."))
        return 1
    print_outro()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(130)
