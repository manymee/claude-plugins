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

## Context monitoring

Besides rendering the statusline, the daemon watches how full each session's
context window is and speaks up as it fills. Two thin hooks — on `Stop` and
`PostToolBatch` — ask the daemon whether the session has crossed a threshold;
the daemon answers with ready-to-print hook JSON, at most once per threshold per
session. A session stays silent until it crosses the first threshold. When usage
drops — after a compaction, say — the reported mark follows it down to the
highest threshold at or below the new usage, so every threshold above that one
reports again on the way back up: after 55% → 45% the 40 threshold stays
claimed, while 50 reports again once usage reaches it.

Thresholds are configured in `~/.claude/exline.json` (`EXLINE_CONFIG` overrides
the path):

```json
{
  "context_thresholds": [
    { "percent": 40, "message": "Context at {percent}% — consider wrapping up soon." },
    { "percent": 70, "message": "Context at {percent}% — compact or start a fresh session." }
  ],
  "context_repeat_every": 5
}
```

`{percent}` is replaced with the session's current usage. Without a config file
the thresholds are 40, 50, 60 and 70 percent.

`context_repeat_every` (optional) keeps the top threshold's message coming past
its percent — every that many points (at 70+5k in the example above), with the
updated percentage — so a session that sails past the last tier isn't left in
silence. Omit it for one final report at the top threshold.

`/exline:context on|off|status` toggles the reports for the current session
only; the statusline carries a badge while they're off.

The hooks fail open: no daemon, no socket, no `jq`/`nc` means no output and a
clean exit, so a stopped daemon can never break a session. This feature replaces
the retired `context-aware` plugin.

## Session board

The daemon can serve a small web page with one row per open session — name,
repo, state (working / needs you / ready / stale / gone) and context usage —
meant for a phone on a desk stand (add to Home Screen for a chrome-less
kiosk). Enable it with a port in `~/.claude/exline.json`; without the key the
HTTP server does not start:

```json
{ "board_http_port": 8631 }
```

`GET /` serves the page, `GET /board.json` the roster it polls (every 3 s).

A session's status comes first from the status file Claude Code writes for
itself (`~/.claude/sessions/<pid>.json`, rooted at `CLAUDE_CONFIG_DIR` when
set): busy / idle / waiting, straight from the session, so an Esc interrupt or
a permission approval shows up without waiting for a hook. Sessions with no
usable file — older CLI, unparseable — fall back to a heuristic over two feeds:
statusline renders carry name, cwd, model, context % and cumulative API time,
while hooks (`UserPromptSubmit`, `PostToolBatch`, `Stop`, `Notification`) track
whether a turn is open and whether Claude is waiting on a permission prompt.
When the two disagree the row quotes the heuristic's verdict in parentheses.

Status files are written only on a transition, never as a heartbeat, so
liveness stays with renders: sessions that stop rendering dim after a few
seconds (`stale`, then `gone`) whatever their file last said, but stay listed
until the 6 h prune, so parked tmux sessions remain visible. The classification
rules live in `Exline.Board.State`; an interactive workbench walks the
heuristic through canned scenarios:

```sh
mix run --no-start proto/board_state.exs
```

Note: hook registrations load when a Claude Code session starts, so after a
plugin update the turn-tracking only works in sessions started since — the
status file covers the older ones in the meantime.

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

When no daemon answers at all — connection refused, timed out, or the daemon
is mid-restart — the client reprints the session's last successful render with
a red ⚠ appended to its first line. The cached render lives under `$TMPDIR`,
one file per session, written on every successful render. A ⚠ in the
statusline therefore means: this is stale, the daemon is unreachable.

A render crash never blanks the statusline silently: the daemon replies
`exline: render crashed — <path>` and saves the payload plus stacktrace under
`examples/crashes/` (last 20 kept — unlike `examples/captures/`, which rolls
over within seconds under statusline polling). To debug one, replay it:

```elixir
Exline.Captures.crashes() |> hd() |> File.read!() |> JSON.decode!() |> Exline.format()
```

Additional mix tasks (ccstatusline reference rendering, fixture timestamp refresh) are listed under `mix help` with the `exline.` prefix.
