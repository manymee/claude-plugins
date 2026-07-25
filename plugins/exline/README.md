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

## Installing as a plugin

Requirements on PATH: `elixir`/`mix` (Elixir ~> 1.19 / OTP 28 — `mise.toml`
records the tested versions), `jq`, `nc`.

1. Install the plugin from the marketplace.
2. Run `/exline:setup` — it checks dependencies, builds the release into the
   plugin data dir, starts the daemon (launchd or manual), and registers the
   client as `statusLine.command` in your settings.

Re-run `/exline:setup` after a plugin update: the statusline shows a warning
line whenever the installed plugin version differs from the running daemon.

## Running from a working copy

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

Realtime loop against your live statusline — safe to run alongside the
production daemon:

```sh
iex -S mix          # dev daemon on /tmp/exline-dev.sock
```

The client prefers the dev socket whenever it accepts connections, so the
statusline switches to the dev daemon the moment it starts (marked by a
bold-yellow `dev` badge on line 3) and falls back to the production daemon the
moment it stops. Edit code, run `recompile` in iex, watch the statusline.
`EXLINE_SOCKET` overrides the socket path in any env.

```sh
mix test                              # regression harness
UPDATE_EXPECTED=1 mix test            # accept new output as expected
```

A render crash never blanks the statusline silently: the daemon replies
`exline: render crashed — <path>` and saves the payload plus stacktrace under
`examples/crashes/` (last 20 kept — unlike `examples/captures/`, which rolls
over within seconds under statusline polling). To debug one, replay it:

```elixir
Exline.Captures.crashes() |> hd() |> File.read!() |> JSON.decode!() |> Exline.format()
```

Additional mix tasks (ccstatusline reference rendering, fixture timestamp refresh) are listed under `mix help` with the `exline.` prefix.
