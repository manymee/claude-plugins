#!/usr/bin/env bash
# Stop hook that uses tmux send-keys to inject /clear + continuation prompt.
#
# Two-phase stop:
#   1st stop (stop_hook_active=false): context-aware plugin blocks, Claude writes handoff
#   2nd stop (stop_hook_active=true): this hook backgrounds tmux injection, approves the stop
#
# After Claude stops, the backgrounded tmux commands:
#   - Send /clear to reset the session
#   - Send a continuation prompt (Claude reads the handoff file directly)
set -euo pipefail

LOG="/tmp/stop-tmux-inject.log"
HANDOFF_PATH="${CLAUDE_PROJECT_DIR:-.}/.claude/handoff.md"

log() {
  echo "[stop-tmux-inject] $(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG"
}

input=$(cat)

log "=== Stop hook triggered ==="
log "Input: $input"

stop_hook_active=$(echo "$input" | jq -r '.stop_hook_active // false')
log "stop_hook_active=$stop_hook_active"

# Only act on second stop (after context-aware has already blocked once)
if [[ "$stop_hook_active" != "true" ]]; then
  log "First stop — deferring to context-aware plugin"
  exit 0
fi

# Check if handoff file exists with status "continue"
if [[ ! -f "$HANDOFF_PATH" ]]; then
  log "No handoff file at $HANDOFF_PATH — letting Claude stop normally"
  exit 0
fi

# Check frontmatter for "continue: true"
# Handoff format:
#   ---
#   continue: true
#   ---
#   <markdown body>
handoff_continue=$(awk 'NR==1 && /^---$/{f=1; next} /^---$/ && f{exit} f' "$HANDOFF_PATH" | grep -c '^continue: *true' || true)
log "Handoff continue: '${handoff_continue:-<not set>}'"

if [[ "$handoff_continue" -eq 0 ]]; then
  log "Handoff does not have 'continue: true' — letting Claude stop normally"
  exit 0
fi

log "Handoff has continue=true and stop_hook_active=true — triggering tmux injection"

# Verify we're in tmux and have a pane target.
# $TMUX_PANE is set per-pane by tmux and inherited by child processes,
# making it more reliable than `tmux display-message` which depends on
# client context and may fail in iTerm2 tmux integration mode (-CC).
if [[ -z "${TMUX:-}" || -z "${TMUX_PANE:-}" ]]; then
  log "ERROR: Not running inside tmux (TMUX=${TMUX:-<unset>}, TMUX_PANE=${TMUX_PANE:-<unset>}) — cannot inject commands"
  exit 0
fi

current_pane="$TMUX_PANE"
log "Current tmux pane: $current_pane (from \$TMUX_PANE)"

# Background the tmux injection so we don't block the hook return.
# Delays give Claude time to fully stop and release the terminal.
(
  sleep 3
  log "Sending /clear to pane $current_pane"
  tmux send-keys -t "$current_pane" "/clear"
  tmux send-keys -t "$current_pane" Enter

  # Wait for /clear to complete and fresh session to be ready
  sleep 5
  log "Sending continuation prompt to pane $current_pane"
  tmux send-keys -t "$current_pane" "Continue from .claude/handoff.md"
  tmux send-keys -t "$current_pane" Enter

  log "tmux injection complete"
) >> "$LOG" 2>&1 &

log "Backgrounded tmux injection (PID: $!)"

# Approve the stop so Claude stops and the terminal is free for tmux keystrokes
jq -n '{"decision": "approve"}'
