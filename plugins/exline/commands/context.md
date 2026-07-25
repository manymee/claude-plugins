---
description: Turn exline's context-window reports on or off for this session, or show their state
---

Run exactly this command, then tell the user the resulting state in one line:

```sh
${CLAUDE_PLUGIN_ROOT}/bin/context-ctl --session ${CLAUDE_SESSION_ID} $ARGUMENTS
```

If nothing follows the session id on that line — the user passed no argument —
append `status` before running it. If the plugin-root placeholder appears
unexpanded in that command, resolve the plugin path instead from
`~/.claude/plugins/installed_plugins.json`: the entry whose key starts with
`exline@` has an `installPath`.

On success the script prints one JSON object, e.g.
`{"ok":true,"context_report":"on","used_percentage":62}`. Report it as a single
sentence such as "Context reports are on — session is at 62% of the context
window." A null usage means this session hasn't rendered a statusline yet; say
so instead of repeating the null.

A non-zero exit means the daemon is unreachable or a dependency is missing; the
reason is on stderr. Pass it along, suggest `/exline:setup`, and don't retry.
