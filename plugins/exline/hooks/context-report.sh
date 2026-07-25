#!/bin/sh

# Forwards hook events to the exline daemon and prints whatever hook JSON
# comes back. Stop and PostToolBatch may answer with a context-threshold
# report; every event doubles as an activity beacon for the session board
# (Notification carries its message text so the daemon can tell a permission
# prompt from an idle notice). Fails open at every step: a missing dependency,
# a dead daemon or a malformed payload must never interrupt the user's session.

command -v jq >/dev/null 2>&1 || exit 0
command -v nc >/dev/null 2>&1 || exit 0

hook_input=$(cat)

query=$(printf '%s' "$hook_input" | jq -c '
  select((.session_id // "") != "" and (.hook_event_name // "") != "")
  | {exline: "hook", event: .hook_event_name, session_id: .session_id}
    + (if (.notification_type // "") != "" then {notification_type: .notification_type} else {} end)
    + (if (.message // "") != "" then {message: .message} else {} end)
' 2>/dev/null)

[ -n "$query" ] || exit 0

DEV_SOCK=/tmp/exline-dev.sock
PROD_SOCK=/tmp/exline.sock

ask() {
  printf '%s\0' "$query" | nc -w 2 -U "$1" 2>/dev/null
}

# Threshold state lives in whichever daemon the statusline feeds, and the
# statusline client picks its daemon by the same rule: EXLINE_SOCKET pins one,
# otherwise a dev daemon wins over the launchd one. The fallback here is
# connect-failure only (a stale dev socket file left by a crashed session) —
# an empty reply from a daemon that answered is the common "nothing to report"
# case, and retrying prod would query a daemon that never saw this session.
if [ -n "$EXLINE_SOCKET" ]; then
  response=$(ask "$EXLINE_SOCKET")
elif [ -S "$DEV_SOCK" ] && response=$(ask "$DEV_SOCK"); then
  : # the dev daemon answered, empty reply included
else
  response=$(ask "$PROD_SOCK")
fi

# Print only a hook answer: a daemon older than this hook replies to the query
# with a rendered statusline, which would land in the transcript as garbage.
if [ -n "$response" ] && printf '%s' "$response" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
  printf '%s' "$response"
fi

exit 0
