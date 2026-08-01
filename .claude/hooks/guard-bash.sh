#!/usr/bin/env bash
# PreToolUse guard for Bash: enforces the repo git and secrets rules mechanically.
# Exit 2 blocks the tool call (stderr is fed back to Claude); exit 0 proceeds.
set -euo pipefail

# The heredoc below occupies python's stdin with the program itself, so the
# hook payload is handed over via the environment instead.
GUARD_INPUT=$(cat 2>/dev/null || true)
export GUARD_INPUT

python3 - <<'PY'
import fnmatch
import json
import os
import re
import shlex
import sys
from collections import deque

try:
    cmd = json.loads(os.environ.get("GUARD_INPUT", "")).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(0)

READERS = {
    "cat", "head", "tail", "less", "more", "sed", "awk", "grep", "cut",
    "sort", "strings", "bat", "xxd", "od", "wc", "base64", "rg",
}
# Wrappers that hand off to another program: unwrap them so `command git push`
# or `nohup git push` is judged by the wrapped program, not the wrapper.
WRAPPERS = {"command", "builtin", "nohup", "exec", "time", "timeout", "stdbuf", "xargs"}
# Wrapper options that take a separate argument (skipped as a pair in unwrap).
WRAPPER_OPTS_WITH_ARG = {
    "time": {"-f", "--format", "-o", "--output"},
    "timeout": {"-k", "--kill-after", "-s", "--signal"},
    "xargs": {"-I", "-n", "-P", "-d", "-s"},
}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
OPERATORS = re.compile(r"^[;&|()\n]+$")
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
ALLOWED_ENV = re.compile(r"^\.env(\.[A-Za-z0-9_-]+)*\.example$")
ENV_FILE = re.compile(r"^\.env(\.[A-Za-z0-9_.-]+)?$")
# .env-looking literal inside an opaque interpreter payload (python -c "...").
ENV_LITERAL = re.compile(r"\.env(\.[A-Za-z0-9_-]+)*\b")
# Shell expansions whose result the tokenizer can't see ($(...), `...`, $VAR,
# positional/special parameters).
DYNAMIC = re.compile(r"\$\(|`|\$\{|\$[A-Za-z_]|\$\d|\$[@*#?$!-]")
# Command/process substitution specifically — opaque even to assignment tracking.
SUBSTITUTION = re.compile(r"\$\(|`")
# Positional/special parameters in a bare path-like token (no script syntax) —
# `cat $1` is opaque, but `awk '{print $1}'` is a program text, not a path.
POSITIONAL_PATH = re.compile(r"\$(?:\d+|[@*])")
SCRIPT_SYNTAX = re.compile(r"[{}\s;]")


def env_literal_hit(text: str) -> bool:
    """True when text references a .env variant that isn't an example file."""
    return any(
        not ALLOWED_ENV.match(m.group(0)) for m in ENV_LITERAL.finditer(text)
    )


# A glob operand can read a secret without ever spelling ".env": the shell
# expands `.e[n]v`, `.env*`, or `*` to the real file. Test the pattern against
# representative forbidden names instead of substring-matching the literal.
GLOB_META = re.compile(r"[*?\[]")
ENV_GLOB_PROBES = (
    ".env", ".env.local", ".env.production", ".env.development",
    ".env.dev", ".env.prod", ".env.staging", ".env.test",
)


def glob_targets_env(token: str) -> bool:
    base = os.path.basename(token.strip("\"'"))
    if not GLOB_META.search(base):
        return False
    # Dangerous only if it would match a real .env name. A glob that resolves
    # exclusively to example files (e.g. `.env.*.example`) stays allowed.
    return any(fnmatch.fnmatchcase(name, base) for name in ENV_GLOB_PROBES)


# A brace that bash actually expands needs a comma list or a `..` range —
# `{it}` is left literal. Used to fail closed on braced command identity.
BRACE_EXPR = re.compile(r"\{[^{}]*(?:,|\.\.)[^{}]*\}")


def brace_expand(token: str, _depth: int = 0) -> list:
    """Expand bash brace lists/sequences a token would produce at the shell.

    `.e{n,}v` -> ['.env', '.ev']; `x.{js,ts}` -> ['x.js', 'x.ts']. A single
    element with no comma or range (`.e{n}v`) is NOT a brace expansion in bash —
    it stays literal, matching real shell behaviour. Bounded against blow-up.
    """
    if _depth > 6:
        return [token]
    m = re.search(r"\{([^{}]*)\}", token)
    if not m:
        return [token]
    inner = m.group(1)
    pre, post = token[: m.start()], token[m.end() :]
    if "," in inner:
        options = inner.split(",")
    else:
        seq = re.fullmatch(r"(-?\d+)\.\.(-?\d+)", inner)
        if seq:
            a, b = int(seq.group(1)), int(seq.group(2))
            step = 1 if b >= a else -1
            options = [str(x) for x in range(a, b + step, step)]
        else:
            options = None  # `{it}` — not a valid expansion; leave literal
    results = []
    if options is None:
        for tail in brace_expand(post, _depth + 1):
            results.append(pre + "{" + inner + "}" + tail)
    else:
        for opt in options:
            results.extend(brace_expand(pre + opt + post, _depth + 1))
    return results[:64]


def has_no_verify_alias(argv: list) -> bool:
    """--no-verify or its -n short alias, including clustered short flags."""
    return "--no-verify" in argv or any(
        re.fullmatch(r"-[A-Za-z]+", t) and "n" in t for t in argv
    )


def git_subcommand(args: list):
    """Locate the git subcommand, skipping global options and their values."""
    i = 0
    while i < len(args):
        tok = args[i]
        if tok in ("-C", "-c", "--git-dir", "--work-tree", "--exec-path"):
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        return tok, i
    return None, i


def is_git_commit_noverify(argv: list) -> bool:
    """True only for an actual `git commit` argv carrying --no-verify / -n.

    -n alone is far too common (`echo -n`, `grep -n`, `head -n`) to treat as
    a no-verify tripwire on arbitrary commands.
    """
    t = unwrap(list(argv))
    if not t or os.path.basename(t[0]) != "git":
        return False
    sub, i = git_subcommand(t[1:])
    return sub == "commit" and has_no_verify_alias(t[1:][i + 1 :])


def block(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(2)


def split_commands(text: str) -> list[list[str]]:
    """Tokenize shell text, then split the token stream into simple commands.

    Tokenizing before splitting keeps quoted strings intact, so operators
    inside quotes (e.g. parens in `python -c "open(...)"`) don't fragment
    the payload.
    """
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()\n")
    lex.whitespace = " \t\r"  # newline is a command separator, not whitespace
    lex.whitespace_split = True
    try:
        toks = list(lex)
    except ValueError:
        # Unbalanced quotes — fall back to whitespace splitting.
        toks = text.split()
    commands: list[list[str]] = []
    current: list[str] = []
    for tok in toks:
        if tok and OPERATORS.match(tok):
            if current:
                commands.append(current)
                current = []
        else:
            current.append(tok)
    if current:
        commands.append(current)
    return commands


def unwrap(tokens: list[str]) -> list[str]:
    """Strip wrapper programs/env assignments so the real program is tokens[0]."""
    while tokens:
        prog = os.path.basename(tokens[0])
        if ENV_ASSIGN.match(tokens[0]):
            tokens = tokens[1:]
            continue
        if prog == "env":
            tokens = tokens[1:]
            while tokens:
                if ENV_ASSIGN.match(tokens[0]):
                    tokens = tokens[1:]
                elif tokens[0] == "-u" and len(tokens) >= 2:
                    tokens = tokens[2:]
                # `env -S 'git push ...'` re-splits its payload at exec time, so
                # the guarded command hides inside one opaque token and never
                # reaches the prog checks below. Fail closed on every spelling:
                # -S, --split-string[=..], attached (-S'..'), and short-option
                # clusters (-vS'..').
                elif re.match(r"^-[A-Za-z0-9]*S", tokens[0]) or tokens[0].startswith(
                    "--split-string"
                ):
                    block(
                        "BLOCKED: env -S/--split-string obscures the real command. "
                        "Invoke the command directly instead."
                    )
                elif tokens[0].startswith("-"):
                    tokens = tokens[1:]
                else:
                    break
            continue
        if prog in WRAPPERS:
            # Wrapper options that consume a separate argument must be skipped
            # as pairs, or the option argument is misparsed as the executable
            # (`time -f %E git push` would judge `%E`).
            opts_with_arg = WRAPPER_OPTS_WITH_ARG.get(prog, set())
            is_timeout = prog == "timeout"
            tokens = tokens[1:]
            while tokens:
                tok = tokens[0]
                if tok == "--":
                    tokens = tokens[1:]
                    break
                if tok in opts_with_arg and len(tokens) >= 2:
                    tokens = tokens[2:]
                    continue
                if tok.startswith("-"):
                    tokens = tokens[1:]
                    continue
                break
            if is_timeout and tokens:
                tokens = tokens[1:]  # drop the duration argument
            if tokens and tokens[0] == "--":
                tokens = tokens[1:]  # `timeout -s KILL 5 -- cmd` form
            continue
        if prog in ("uv", "uvx", "pipx") and len(tokens) >= 2:
            # `uv run <cmd>` / `uvx <cmd>` / `pipx run <cmd>` launch programs
            # too. All three accept a `--` separator before the command
            # (`uv run -- git push`) — strip it so the real program is judged.
            tokens = tokens[2:] if tokens[1] == "run" else tokens[1:]
            if tokens and tokens[0] == "--":
                tokens = tokens[1:]
            continue
        break
    return tokens


def payload_after_dash_c(tokens: list[str]) -> str | None:
    if "-c" in tokens:
        idx = tokens.index("-c")
        if idx + 1 < len(tokens):
            return tokens[idx + 1]
    return None


# Variables assigned within this command line. Shell state does not persist
# across Bash tool calls in this harness, so in-line assignments are the only
# way a variable can carry a dangerous value — resolving them here closes
# `F=.env; cat "$F"` and `S=push; git $S ...` without blocking legitimate
# unresolvable expansions (loop variables, profile vars).
var_env: dict = {}
VAR_REF = re.compile(r"\$\{(\w+)\}|\$(\w+)")


def resolve(tok: str) -> str:
    def sub_one(m):
        name = m.group(1) or m.group(2)
        return var_env.get(name, m.group(0))

    prev = None
    for _ in range(5):
        if tok == prev:
            break
        prev = tok
        tok = VAR_REF.sub(sub_one, tok)
    return tok


# Evaluate each command in the (possibly compound) line independently so an
# env-assignment prefix, a wrapper, or chaining can't hide a guarded command.
# `sh -c '...'` payloads are re-queued and scanned recursively.
queue = deque(split_commands(cmd))
while queue:
    tokens = [resolve(t) for t in queue.popleft()]

    # Peel leading shell-level env assignments (FOO=bar git push ...),
    # recording them for resolution in later segments. Only these count
    # toward the sanctioned-push check — assignments smuggled in via `env`
    # do not.
    assigns = []
    while tokens and ENV_ASSIGN.match(tokens[0]):
        assign = tokens.pop(0)
        name, _, value = assign.partition("=")
        var_env[name] = value
        assigns.append(assign)
    tokens = unwrap(tokens)
    if not tokens:
        continue
    prog = os.path.basename(tokens[0])

    if prog == "set" and "--" in tokens:
        # `set -- a b c` rebinds positional parameters — record them so $1/$2
        # in later segments resolve exactly like variable assignments do.
        for idx, val in enumerate(tokens[tokens.index("--") + 1 :], start=1):
            var_env[str(idx)] = val
        continue

    if BRACE_EXPR.search(tokens[0]):
        # A brace LIST/range in the program token itself (`comm{,}it`, `gi{t,}`)
        # rewrites the command identity at the shell. There is no legitimate
        # reason to brace-expand a program name, so fail closed.
        block(
            "BLOCKED: brace expansion obscures the program identity of a "
            "guarded command. Use the literal program name."
        )

    if DYNAMIC.search(tokens[0]):
        # The program identity is a shell expansion the tokenizer can't
        # resolve (`$G push`, `$(which git) push`). Fail closed whenever the
        # segment touches a guarded surface; plain dynamic invocations (a
        # script path held in a variable) stay allowed.
        joined = " ".join(tokens)
        if (
            "push" in tokens[1:]
            or "--no-verify" in tokens[1:]
            or ("commit" in tokens[1:] and has_no_verify_alias(tokens[1:]))
            or env_literal_hit(joined)
        ):
            block(
                "BLOCKED: dynamic shell expansion hides the program of a "
                "guarded command (push / no-verify / .env access). Use the "
                "literal program name."
            )

    if prog == "eval":
        # eval re-runs its argument as shell in the current context — re-queue
        # the payload so the full guard (variable resolution, dynamic-subcommand
        # detection, reader checks) applies, exactly as for `sh -c`. This also
        # catches indirect forms like `eval "C=commit; git $C -n"`.
        queue.extend(split_commands(" ".join(tokens[1:])))
        continue

    if prog in SHELLS:
        # Recursively scan `sh -c '...'` / `bash -c '...'` command strings.
        payload = payload_after_dash_c(tokens)
        if payload is not None:
            queue.extend(split_commands(payload))
        continue

    if prog.startswith("python") or prog in ("node", "perl", "ruby"):
        # Opaque interpreter payloads can't be parsed as shell — tripwire on
        # any non-example .env literal inside them instead.
        payload = payload_after_dash_c(tokens) or " ".join(tokens[1:])
        for m in ENV_LITERAL.finditer(payload):
            if not ALLOWED_ENV.match(m.group(0)):
                block(
                    "BLOCKED: interpreter payload references a .env file, which "
                    "may leak secrets. Only .env.example and .env.*.example are "
                    "readable; ask the human for specific values if needed."
                )

    if prog == "git":
        args = tokens[1:]
        sub, i = git_subcommand(args)
        rest = args[i + 1 :] if sub is not None else []

        if sub is not None and DYNAMIC.search(sub):
            # The git subcommand must be literal — `git $S ...` with an
            # unresolvable variable could be push/commit at runtime.
            block(
                "BLOCKED: dynamic git subcommand is opaque to the guard. "
                "Spell out the subcommand literally."
            )

        if sub is not None and BRACE_EXPR.search(sub):
            # `git comm{,}it -n` / `git pu{,}sh ...` expand to commit/push at
            # the shell while reading as a non-matching subcommand here.
            block(
                "BLOCKED: brace expansion obscures the git subcommand. "
                "Spell it out literally."
            )

        if sub == "push":
            # Push policy: a push is allowed only when every refspec names an
            # explicit, non-protected destination branch (e.g.
            # `git push origin HEAD:refs/heads/<feature>` or
            # `git push -u origin <feature>`). Everything whose destination the
            # guard can't statically prove safe is blocked: bare `git push`,
            # `git push origin` (upstream config decides the target), pushes to
            # main/master, force pushes, deletions, and bulk modes.
            FORBIDDEN_FLAGS = {
                "--force", "-f", "--force-with-lease", "--force-if-includes",
                "--all", "--branches", "--mirror", "--tags", "--prune",
                "--delete", "-d",
            }
            OPTS_WITH_VALUE = {
                "--receive-pack", "--exec", "-o", "--push-option", "--repo",
            }
            positionals = []
            j = 0
            while j < len(rest):
                tok = rest[j]
                if tok == "--":
                    positionals.extend(rest[j + 1 :])
                    break
                if tok.startswith("-") and not tok.startswith("--") and len(tok) > 2:
                    # Compact short-option bundle (e.g. -fu, -du). Walk left to
                    # right: a forbidden constituent blocks; a value-taking one
                    # (-o) ends the bundle — the rest of the token is its value,
                    # or the next token when nothing follows.
                    consumed_next = False
                    for pos, ch in enumerate(tok[1:], start=2):
                        opt = f"-{ch}"
                        if opt in FORBIDDEN_FLAGS:
                            block(
                                f"BLOCKED: git push {opt} (bundled in {tok}) is "
                                "forbidden. Only plain pushes to an explicit "
                                "feature branch are allowed."
                            )
                        if opt in OPTS_WITH_VALUE:
                            consumed_next = pos == len(tok)
                            break
                    j += 2 if consumed_next else 1
                    continue
                if tok.startswith("-"):
                    name = tok.split("=", 1)[0]
                    if name in FORBIDDEN_FLAGS:
                        block(
                            f"BLOCKED: git push {name} is forbidden. Only plain "
                            "pushes to an explicit feature branch are allowed."
                        )
                    if name in OPTS_WITH_VALUE and "=" not in tok:
                        j += 2
                        continue
                    j += 1
                    continue
                positionals.append(tok)
                j += 1

            refspecs = positionals[1:]  # positionals[0] is the remote
            if not refspecs:
                block(
                    "BLOCKED: git push without an explicit target branch — the "
                    "guard can't prove it won't hit a protected branch. Use "
                    "git push origin HEAD:refs/heads/<feature-branch> (or "
                    "git push -u origin <feature-branch>)."
                )
            for spec in refspecs:
                if spec.startswith("+"):
                    block("BLOCKED: force-push refspecs (+ref) are forbidden.")
                if spec.startswith(":"):
                    block(
                        "BLOCKED: pushing an empty source (:<branch>) deletes "
                        "the remote branch — deletions are forbidden."
                    )
                dst = spec.split(":", 1)[1] if ":" in spec else spec
                if dst.startswith("refs/") and not dst.startswith("refs/heads/"):
                    block(
                        f"BLOCKED: git push target '{spec}' isn't a branch — "
                        "only refs/heads/<feature-branch> destinations are "
                        "allowed (no tags, notes, or other ref namespaces)."
                    )
                short = dst.removeprefix("refs/heads/")
                if not short or "*" in short or short in ("HEAD", "@"):
                    block(
                        f"BLOCKED: git push target '{spec}' isn't an explicit "
                        "branch name. Use HEAD:refs/heads/<feature-branch>."
                    )
                if short in ("main", "master"):
                    block(
                        f"BLOCKED: pushing to '{short}' is forbidden — protected "
                        "branches only move via reviewed PRs merged by the human."
                    )

        if sub == "commit" and has_no_verify_alias(rest):
            block(
                "BLOCKED: git commit --no-verify (or -n) is forbidden. "
                "Fix the failing pre-commit hook and commit again."
            )

    if prog == "gh":
        # Merging a PR into a protected branch is the human's decision. Skip
        # the values of value-taking global options (-R/--repo/--hostname) so
        # they can't shift `pr merge` out of the scanned positions, and match
        # the pair anywhere in the remaining command words (gh accepts flags
        # between `pr` and `merge`).
        words = []
        k = 1
        while k < len(tokens):
            tok = tokens[k]
            if tok in ("-R", "--repo", "--hostname"):
                k += 2
                continue
            if tok.startswith("-"):
                k += 1
                continue
            words.append(tok)
            k += 1
        if any(words[j : j + 2] == ["pr", "merge"] for j in range(len(words) - 1)):
            block(
                "BLOCKED: gh pr merge is forbidden — merging a PR is the "
                "human's call. Leave the PR open for review."
            )

    if prog in READERS:
        # Mirror guard-env.sh on the Bash side: file-reading commands must not
        # touch any .env variant except *.example. Path-like operands are
        # brace-expanded first so `cat .e{n,}v` (-> .env .ev) can't smuggle a
        # read; program-text / dynamic operands (awk scripts, $-expansions)
        # are left intact — expanding `{print $1,$2}` would shatter it into
        # pseudo-paths and false-positive on the positional-parameter check.
        reader_operands = []
        for raw in tokens[1:]:
            if " " in raw or "\t" in raw or "$" in raw:
                reader_operands.append(raw)
            else:
                reader_operands.extend(brace_expand(raw))
        for tok in reader_operands:
            # A .env literal anywhere in the operand (e.g. `$(echo .env)`,
            # `sub/.env.local`) is blocked, not just bare basenames.
            if env_literal_hit(tok):
                block(
                    "BLOCKED: reading .env files may leak secrets. Only "
                    ".env.example and .env.*.example are readable; ask the "
                    "human for specific values if needed."
                )
            # Command/process substitution in a reader operand is opaque —
            # fail closed. Plain $VAR operands (loop variables, in-line paths)
            # stay allowed.
            if SUBSTITUTION.search(tok):
                block(
                    "BLOCKED: command substitution in a file-reading command "
                    "is opaque to the .env guard. Use a literal path."
                )
            # Unresolved positional parameters in a path-like operand are
            # opaque too (`cat $1`); program-text operands carrying script
            # syntax (awk '{print $1}') stay allowed.
            if POSITIONAL_PATH.search(tok) and not SCRIPT_SYNTAX.search(tok):
                block(
                    "BLOCKED: positional-parameter expansion in a file-reading "
                    "command is opaque to the .env guard. Use a literal path."
                )
            # A glob operand that would expand onto a real .env file
            # (`.e[n]v`, `.env*`, `*`) leaks it without naming it literally.
            if glob_targets_env(tok):
                block(
                    "BLOCKED: glob operand could match a .env file. Only "
                    ".env.example and .env.*.example are readable; name the "
                    "literal path."
                )
            base = os.path.basename(tok.strip("\"'"))
            if ENV_FILE.match(base) and not ALLOWED_ENV.match(base):
                block(
                    f"BLOCKED: reading {base} may leak secrets. Only .env.example "
                    "and .env.*.example are readable; ask the human for specific "
                    "values if needed."
                )

sys.exit(0)
PY
