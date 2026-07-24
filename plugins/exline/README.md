# exline

A custom Claude Code statusline. Renders cwd, git state, model and context info, and rate-limit windows in a compact multi-line layout.

## What it looks like

```
.../custom/exline
dotfiles  𖠰 dotfiles  ⎇ main  *?  ↑2
v2.1.143  Opus 4.7  concise-omit  Ctx Used: 7.0%
Session: 1.0%  3h15m  |  Weekly: 1.0%  134h45m
```

Line 1: truncated cwd. Line 2: git — repo, worktree, branch, dirty flags, ahead/behind. Line 3: Claude Code version, model, output style, context usage. Line 4: rate-limit windows with reset countdowns.

## Architecture

A long-lived Elixir daemon listens on a Unix socket. A small shell client pipes Claude Code's JSON payload to the socket on every statusline tick and prints the reply. The daemon is launchd-managed; the client is registered as Claude Code's `statusLine.command`.

## Running

The daemon runs from a Mix release that launchd boots at login.

Deploy after changes:

```sh
MIX_ENV=prod mix release --overwrite
launchctl kickstart -k gui/$(id -u)/com.manymee.exline
```

First time on a fresh clone:

```sh
mix deps.get
MIX_ENV=prod mix release
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.manymee.exline.plist
```

## Development

```sh
mix test                              # regression harness
UPDATE_EXPECTED=1 mix test            # accept new output as expected
```

Additional mix tasks (ccstatusline reference rendering, fixture timestamp refresh) are listed under `mix help` with the `exline.` prefix.
