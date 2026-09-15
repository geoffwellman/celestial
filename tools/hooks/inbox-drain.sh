#!/usr/bin/env bash
# UserPromptSubmit hook: drain the workspace inbox into the turn the human
# just started. This is the GUARANTEED half of inbox delivery - a Monitor
# background task wakes an agent instantly, but only while it is running;
# this catches everything a restart, compaction or missing monitor lost.
#
# Never writes to the pane, never fails the prompt: any error exits 0 silent.
set -uo pipefail
CEL_ROOT="${CEL_ROOT:-$HOME/celestial-plane}"
[ -x "$CEL_ROOT/bin/cel" ] || exit 0

# The hook runs in the agent's cwd, so `cel inbox read` derives BOTH the
# workspace and the recipient from where this pane is standing. It must not
# name a recipient: assuming "root" here meant every pane drained root's
# queue and advanced root's cursor, so root lost mail it had never seen.
mail="$("$CEL_ROOT/bin/cel" inbox read 2>/dev/null)" || exit 0
[ -n "$mail" ] || exit 0

jq -nc --arg m "$mail" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ("Messages waiting in your celestial inbox (delivered once):\n" + $m +
      "\nAct on them as part of this turn, or say why not.")
  }
}'
