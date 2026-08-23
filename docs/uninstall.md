# Uninstalling

```sh
integrations/uninstall.sh              # keeps your session data
integrations/uninstall.sh --purge      # removes ~/.agent-tracker too
```

Idempotent, so running it twice is safe, and running it when nothing is installed
just says so.

Settings › Advanced › *Uninstall* runs the same script for you, from the copy
every app bundle carries, then removes the login item and the app itself (a
Homebrew install is removed through `brew uninstall`, a direct one goes to the
Trash). A running app can outlive its own bundle on disk, which is what makes
the button safe to build; it quits as its last act. The terminal route above
stays for anyone who prefers it, and is the fallback if the button reports a
failure.

## What it does, precisely

It is **surgical rather than wholesale**; it edits your config files at the level
of individual entries so that anything else in them survives.

- **Removes the Agent Tracker hooks** from `~/.claude/settings.json`, at
  hook level rather than event level, so a third-party hook sharing an entry with
  it is left alone.
- **Restores your status line.** Whatever the wrapper displaced goes back exactly
  as it was, read from `~/.agent-tracker/claude-statusline-wrapped.json`. If
  there was no status line before Agent Tracker, the entry is removed rather than
  left pointing at nothing.
- **Backs up every file before editing it**, to `<file>.agent-tracker-uninstall-backup`.
- **Quits the app if it is running**, then removes it from `/Applications` *and*
  `~/Applications`, warning rather than failing if it cannot. Removing the bundle
  also drops its start-at-login registration, because launchd discards a login
  item whose bundle is gone.
- **Removes your preferences**: the `com.thinkvelta.agent-tracker` defaults
  domain, which holds the onboarding-completed flag and every Settings choice.

Each section is independent, on purpose; a config file that has become
unparseable in one place never blocks the others from being cleaned.

## Session data is kept unless you ask

`~/.agent-tracker` holds the installed hook scripts and one JSON file per
session. It survives a plain uninstall and is removed by `--purge`.

Nothing in there is precious (session files are rewritten constantly and pruned
when their process ends), but removing a directory is not this script's decision
to make silently.

## It also cleans up Codex

The uninstaller removes `~/.codex/hooks.json` entries and the
`~/.codex/config.toml` notify setting, even though this app no longer tracks
Codex.

That is deliberate rather than leftover, and it applies to more people than it
sounds: Codex support was removed on 2026-08-10, *after* v0.2.0 was released on
2026-08-03. So **every released version so far installed those hooks**. Dropping
the cleanup would strand them on every machine that has ever run this, pointing
at a script the same uninstall has just deleted.

Removing what we once installed is a different question from what we install
now.

## Verifying it worked

```sh
python3 -c "
import json, os
s = json.load(open(os.path.expanduser('~/.claude/settings.json')))
print('hooks:', sorted(e for e, v in s.get('hooks', {}).items()
                       if any('agent-tracker' in x.get('command', '')
                              for c in v for x in c.get('hooks', []))))
print('statusLine:', s.get('statusLine'))"
```

An empty hook list, and a `statusLine` that is either your own or absent.

## Reinstalling later

`./install.sh` puts everything back and is likewise idempotent. Note that
**already-running Claude sessions do not pick up hooks**; they read their hook
configuration at startup, so they will not appear until they restart. That is the
most common reason a fresh install looks like it did nothing; see
[troubleshooting](troubleshooting.md).
