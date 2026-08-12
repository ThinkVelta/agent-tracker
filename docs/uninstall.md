# Uninstalling

```sh
integrations/uninstall.sh              # keeps your session data
integrations/uninstall.sh --purge      # removes ~/.agent-tracker too
```

Idempotent, so running it twice is safe, and running it when nothing is installed
just says so.

Settings › Advanced › *Uninstall* has a **Copy command** button, which puts that
first line on your clipboard. It copies rather than runs: uninstalling deletes
the app that would be doing the deleting, and a button that removes itself
mid-click is not a thing to build.

## What it does, precisely

It is **surgical rather than wholesale**: it edits your config files at the level
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
- **Removes your preferences** — the `com.thinkvelta.agent-tracker` defaults
  domain, which holds the onboarding-completed flag and every Settings choice.

Each section is independent, on purpose: a config file that has become
unparseable in one place never blocks the others from being cleaned.

## Session data is kept unless you ask

`~/.agent-tracker` holds the installed hook scripts and one JSON file per
session. It survives a plain uninstall and is removed by `--purge`.

Nothing in there is precious — session files are rewritten constantly and pruned
when their process ends — but removing a directory is not this script's decision
to make silently.

## It also cleans up Codex

If you ever installed a version before v0.2.0, when this tracked Codex as well,
the uninstaller still removes `~/.codex/hooks.json` entries and the
`~/.codex/config.toml` notify setting.

This is deliberate and is not leftover code. Agent Tracker no longer tracks
Codex, but a user who installed it back then still has those hooks on disk, and
dropping the cleanup would strand them forever — pointing at a script that
uninstalling has just deleted.

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
**already-running Claude sessions do not pick up hooks** — they read their hook
configuration at startup, so they will not appear until they restart. That is the
most common reason a fresh install looks like it did nothing; see
[troubleshooting](troubleshooting.md).
