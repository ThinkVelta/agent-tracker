#!/usr/bin/env python3
"""Interactive onboarding for agent-tracker.

A Copier-style CLI: tick the agent CLIs you use in a checkbox list, read a
short disclaimer of exactly what will be changed, confirm, and the existing
idempotent installers in this directory do the rest. Run it as ./install.sh
from the repo root.

Usage:
  onboard.py                              # interactive checkbox picker
  onboard.py --agents claude --yes  # non-interactive (CI, scripts)
  onboard.py --agents claude --statusline --yes   # …and capture usage windows
  onboard.py --agents claude --statusline-builtin --yes  # …showing agent-tracker's statusline

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
        "detect": lambda: (
            bool(shutil.which("claude"))
            or os.path.exists(os.path.expanduser("~/.claude"))
        ),
        "plan": [
            "copy the hook script to ~/.agent-tracker/bin/",
            "back up ~/.claude/settings.json to settings.json.agent-tracker-backup",
            (
                "register agent-tracker hooks in settings.json; merge-only, your "
                "existing settings are untouched; the hooks always exit 0 and can "
                "never block or modify a session"
            ),
        ],
    },
]


STATUSLINE_PLAN = [
    "copy the statusline wrapper to ~/.agent-tracker/bin/",
    (
        "point statusLine in settings.json at it; your own statusline keeps "
        "running behind it, unchanged, and is recorded so uninstall puts it back"
    ),
]

BUILTIN_PLAN_ITEM = (
    "show agent-tracker's own statusline (model, context %, 5h/7d usage, git "
    "branch, directory); whatever the slot held is recorded and restored on "
    "uninstall"
)

# Everything that makes this less than absolute, said before it is installed
# rather than discovered later.
STATUSLINE_CAVEATS = [
    (
        "Claude only reports the usage windows to a statusline script; there is "
        "no other place to read them before a request is actually refused."
    ),
    (
        "A statusLine set in a project's .claude/settings.json silently shadows "
        "the user-level one, so sessions in those projects report nothing."
    ),
    (
        "Nothing runs for -p/--print, --bg background agents, SDK sessions, "
        "--safe-mode, an untrusted workspace, or disableAllHooks."
    ),
    (
        "The numbers appear for Claude.ai subscription sessions, after the first "
        "response. When they are absent the app says it cannot tell, never that "
        "you have room left."
    ),
    (
        "If you have no statusline of your own and decline agent-tracker's, "
        "the line stays blank; the wrapper prints nothing by itself."
    ),
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
                print("\nAborted; nothing was changed.")
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
            print(f"Unknown agent '{key}'; valid values: {valid}", file=sys.stderr)
            raise SystemExit(2)
        if by_key[key] not in selected:
            selected.append(by_key[key])
    return selected


def wrap_bullet(item, indent="    • ", subsequent="      "):
    return textwrap.fill(
        item, width=78, initial_indent=indent, subsequent_indent=subsequent
    )


def ask_statusline():
    """Offer the statusline wrapper, with its limits stated first."""
    print(bold("Track how much of your Claude usage window is left?"))
    print(
        wrap_bullet(
            "Claude hands its status line a payload that says how much of the "
            "5-hour and 7-day windows you have used and when each resets. "
            "Capturing it means occupying the statusLine slot in "
            "~/.claude/settings.json, which is why this is a separate question.",
            indent="  ",
            subsequent="  ",
        )
    )
    print()
    for caveat in STATUSLINE_CAVEATS:
        print(wrap_bullet(caveat, indent="  - ", subsequent="    "))
    print()
    try:
        answer = input(bold("Capture the usage windows?") + " [Y/n] ")
    except EOFError:
        return False
    # Plain Enter means yes; anything else unrecognized stays no, including
    # whitespace-only input, so a mistyped answer cannot claim the statusLine
    # slot by accident.
    if answer == "":
        return True
    return answer.strip().lower() in ("y", "yes")


def own_statusline():
    """Whether settings.json holds a statusline that is the user's own.

    The wrapper's own registration does not count: what matters for the
    display question is whether there is anything of theirs to keep, which a
    previous install recorded in the wrapped file.
    """
    import json

    try:
        with open(os.path.expanduser("~/.claude/settings.json")) as f:
            settings = json.load(f)
    except (OSError, ValueError):
        return False
    current = settings.get("statusLine")
    command = current.get("command") if isinstance(current, dict) else None
    if not (isinstance(command, str) and command.strip()):
        return False
    if "agent-tracker-statusline" not in command:
        return True
    base = os.environ.get("AGENT_TRACKER_DIR") or os.path.expanduser("~/.agent-tracker")
    try:
        with open(os.path.join(base, "claude-statusline-wrapped.json")) as f:
            record = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(record, dict) and isinstance(record.get("wrapped"), dict)


def ask_display():
    """Which statusline to show behind the capture: theirs, or the built-in.

    Only reached interactively and only after yes to capturing. With nothing
    of their own to keep there is no choice to offer — the built-in is what
    makes the line non-blank, so it is applied with a note rather than asked.
    """
    if not own_statusline():
        print(
            wrap_bullet(
                "You have no statusline of your own, so agent-tracker's will "
                "show: model, context %, the 5h/7d usage windows, git branch "
                "and directory.",
                indent="  ",
                subsequent="  ",
            )
        )
        return "builtin"
    try:
        answer = input(
            bold("Keep your own statusline, or show agent-tracker's?") + " [K/a] "
        )
    except EOFError:
        return ""
    # Anything not explicitly choosing agent-tracker's keeps their own: the
    # conservative reading of a mistyped answer leaves their display alone.
    return "builtin" if answer.strip().lower() in ("a", "agent-tracker") else ""


def show_plan(selected, statusline=False, display=""):
    print(bold("This will:"))
    for agent in selected:
        print(f"\n  {agent['name']}:")
        plan = list(agent["plan"])
        if agent["key"] == "claude" and statusline:
            plan += STATUSLINE_PLAN
            if display == "builtin":
                # The built-in display replaces the keeps-running promise, so
                # say what actually happens instead of both.
                plan[-1] = BUILTIN_PLAN_ITEM
        for item in plan:
            print(wrap_bullet(item))
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


def run_installer(agent, statusline=False, display=""):
    """Run one install script, prefixing its output. Returns True on success.

    One exit code is a warning rather than a failure: install-claude-code.sh
    exits 3 when it refuses to clobber an unrecognized statusLine, and the hooks
    are registered either way.
    """
    print(f"\n{bold(agent['name'])}")
    script = os.path.join(SCRIPT_DIR, agent["script"])
    command = ["bash", script]
    if agent["key"] == "claude" and statusline:
        command.append(
            "--statusline-builtin" if display == "builtin" else "--statusline"
        )
    proc = subprocess.run(command, capture_output=True, text=True, check=False)
    if proc.returncode == 0:
        for line in proc.stdout.strip().splitlines():
            print(f"  {green('✓')} {line}")
        # Succeeded, but with something worth reading: an installer reports a
        # setting it declined to touch on stderr while still exiting 0, and
        # swallowing that would tell the user everything was registered.
        for line in proc.stderr.strip().splitlines():
            print(f"  {yellow('!')} {line}")
        return True
    if agent["key"] == "claude" and proc.returncode == 3:
        if display == "builtin":
            # An explicitly requested display that was not applied is a
            # failure, not a warning: exiting 0 here would tell automation
            # the built-in statusline is showing when it is not.
            for line in (proc.stdout + proc.stderr).strip().splitlines():
                print(f"  {red('✗')} {line}")
            print(
                f"  {red('✗')} Requested agent-tracker's statusline, but it was "
                "not applied; the hooks are installed."
            )
            return False
        for line in proc.stdout.strip().splitlines():
            print(f"  {green('✓')} {line}")
        print(f"  {yellow('!')} Left your statusLine setting alone; it is set to")
        print("    something the wrapper cannot forward. The usage windows stay")
        print("    unknown; everything else is installed.")
        for line in proc.stderr.strip().splitlines():
            print(dim(f"    {line}"))
        return True
    for line in (proc.stdout + proc.stderr).strip().splitlines():
        print(f"  {red('✗')} {line}")
    print(f"  {red('✗')} {agent['name']} installer failed (exit {proc.returncode})")
    return False


def print_outro():
    print()
    print(bold("All set; next steps:"))
    print(f"  1. {bold('swift run AgentTracker')} (starts the menu bar app).")
    print("  2. On your first click-to-focus, macOS asks you to grant the app")
    print("     Accessibility permission.")
    print(
        "  3. Only NEW agent sessions are tracked; restart any that are "
        "already running."
    )
    print()


def main():
    parser = argparse.ArgumentParser(
        prog="onboard.py",
        description="Onboarding for agent-tracker: pick your agent CLIs and "
        "register the integrations (idempotent, configs backed up first).",
    )
    parser.add_argument(
        "--agents",
        metavar="LIST",
        help="comma-separated agents to set up (claude); skips the interactive picker",
    )
    parser.add_argument(
        "--yes",
        "-y",
        action="store_true",
        help="skip the confirmation prompt",
    )
    parser.add_argument(
        "--statusline",
        action="store_true",
        default=None,
        help="also capture Claude's usage windows by wrapping the statusLine "
        "setting (asked interactively when neither flag is given)",
    )
    parser.add_argument(
        "--no-statusline",
        dest="statusline",
        action="store_false",
        help="leave the statusLine setting alone without being asked",
    )
    parser.add_argument(
        "--statusline-builtin",
        action="store_true",
        help="capture the usage windows AND show agent-tracker's own statusline "
        "(implies --statusline; your previous statusline is recorded and "
        "restored on uninstall)",
    )
    args = parser.parse_args()
    if args.statusline_builtin:
        if args.statusline is False:
            print(
                "--statusline-builtin conflicts with --no-statusline", file=sys.stderr
            )
            return 2
        args.statusline = True

    print_banner()
    interactive = sys.stdin.isatty() and sys.stdout.isatty()

    if args.agents is not None:
        selected = parse_agents_flag(args.agents)
    elif interactive:
        selected = pick_agents()
        print()
    else:
        print(
            dim(
                "stdin is not a TTY; running non-interactively with the "
                "agents detected on this system."
            )
        )
        selected = [agent for agent in AGENTS if agent["detect"]()]
        names = ", ".join(agent["name"] for agent in selected) or "none"
        print(f"Detected: {names}")
        print()

    if not selected:
        print("No agents selected; nothing to install.")
        return 0

    claude_selected = any(agent["key"] == "claude" for agent in selected)
    statusline = args.statusline
    display = "builtin" if args.statusline_builtin else ""
    if statusline and not claude_selected:
        print(dim("--statusline only applies to Claude Code, which is not selected."))
        print()
        statusline = False
    elif claude_selected and statusline is None:
        # Interactively the default answer is yes: the wrapper preserves
        # whatever script the slot held, and the app's usage strip and
        # per-row context readings only exist with it. Non-interactively it
        # stays off, because a pipe pressing Enter is not a person saying
        # yes; --statusline is the explicit route there.
        statusline = ask_statusline() if interactive else False
        if statusline and interactive:
            display = ask_display()
        print()

    show_plan(selected, statusline=bool(statusline), display=display)
    if not args.yes:
        if not interactive:
            print("stdin is not a TTY; re-run with --yes to proceed, e.g.:")
            keys = ",".join(agent["key"] for agent in selected)
            extra = ""
            if statusline:
                extra = (
                    " --statusline-builtin" if display == "builtin" else " --statusline"
                )
            print(f"  ./install.sh --agents {keys} --yes{extra}")
            return 1
        if not confirm():
            print("Aborted; nothing was changed.")
            return 0

    ok = True
    for agent in selected:
        ok = run_installer(agent, statusline=bool(statusline), display=display) and ok
    if not ok:
        print(red("\nSome integrations failed to install; see output above."))
        return 1
    print_outro()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nAborted.")
        sys.exit(130)
