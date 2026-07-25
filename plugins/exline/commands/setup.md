---
description: Set up exline, or rebuild the daemon to match the installed plugin version — check deps, build, start, register
---

Set up (or update) the exline statusline daemon on this machine. This command is
idempotent: run it after installing the plugin, and again after every plugin
update (the statusline shows a "run /exline:setup" warning line when the
installed plugin version differs from the running daemon).

Work through the steps below in order. Stop and tell the user what's missing if
a prerequisite fails; don't half-install.

## 1. Resolve paths

- Plugin root: `${CLAUDE_PLUGIN_ROOT}`. If that literal string appears
  unexpanded above, resolve it instead from
  `~/.claude/plugins/installed_plugins.json`: the entry whose key starts with
  `exline@` has an `installPath`.
- Data dir (survives plugin updates; the versioned plugin root does not):
  `~/.claude/plugins/data/exline-<marketplace>` where `<marketplace>` is the
  part after `@` in that registry key. Create it if missing.

## 2. Check dependencies

- `jq` and `nc` must be on PATH (the client uses both).
- `elixir` and `mix` must be on PATH. Elixir ~> 1.19 on OTP 28 is what's
  tested (`mise.toml` records the exact versions); mix.exs rejects older
  Elixir at build time.
- Only check — never install anything on the user's behalf. If something is
  missing, report exactly what's needed (e.g. `brew install jq`; Elixir via
  brew/mise/asdf — their choice) and stop.

## 3. Build the release

From the plugin root:

```sh
mix deps.get --only prod
MIX_ENV=prod mix release --overwrite --path "<DATA>/rel"
```

Then install the client at a stable path:

```sh
install -m 755 "<PLUGIN_ROOT>/client" "<DATA>/client"
```

## 4. Start the daemon

If `~/Library/LaunchAgents/com.manymee.exline.plist` already exists, the user
has already chosen launchd: refresh and restart it (steps below) without
asking. Otherwise this is first-time setup — ask before touching launchd:
launchd (recommended — starts at login, restarts on crash) or a one-off manual
start, and respect a decline.

**launchd** (macOS): render `<PLUGIN_ROOT>/launchd/com.manymee.exline.plist.template`
— replace `__BIN__` with `<DATA>/rel/bin/exline`, `__WORKDIR__` with `<DATA>`,
`__LOG__` with `$HOME/Library/Logs/exline.launchd.log` (absolute paths, no `~`)
— and write it to `~/Library/LaunchAgents/com.manymee.exline.plist`. Then:

1. If the job is already loaded (`launchctl print gui/$(id -u)/com.manymee.exline`
   succeeds): `launchctl bootout gui/$(id -u)/com.manymee.exline`, then poll
   `launchctl print` until it reports the job is gone — bootstrapping while the
   old job is still draining fails with an I/O error.
2. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.manymee.exline.plist`
3. `launchctl enable gui/$(id -u)/com.manymee.exline`

**Manual**: `"<DATA>/rel/bin/exline" daemon` (does not survive reboot).

## 5. Register the statusline

Plugins can't set the main statusline, so this edits the user's
`~/.claude/settings.json` (ask first, and show the change):

```json
"statusLine": { "type": "command", "command": "<DATA>/client" }
```

Use the absolute expanded path — settings.json expands neither plugin-root
variables nor `~`. If `statusLine` is already set to something else, show the
current value and ask before replacing it.

## 6. Smoke test

```sh
"<DATA>/client" < "<PLUGIN_ROOT>/examples/input-example.json"
```

Show the rendered output. If it fails: `nc -U /tmp/exline.sock` failing means
the daemon isn't running — check `~/Library/Logs/exline.launchd.log`. Finally
remind the user that the statusline appears on the next statusline refresh; no
restart of Claude Code needed.
