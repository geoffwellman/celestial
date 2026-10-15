#!/usr/bin/env bash
# Claude's UserPromptSubmit hook drains mail into the next submitted turn. It
# does not wake idle sessions; Pi/OMP use their inbox extension for idle wake.
# This also catches mail missed by a restart or compaction.
#
# Never writes to the pane, never fails the prompt: any error exits 0 silent.
set -uo pipefail
# The hooks run in place under <CEL_ROOT>/tools/hooks, so the plane's root is
# two directories up from this file. Guessing a folder name instead meant a
# reader who cloned anywhere else got a hook that silently drained nothing -
# and silence is exactly what this hook looks like when it works.
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)}"
[ -x "$CEL_ROOT/bin/cel" ] || exit 0

# Launches provide explicit mailbox identity because reviewers share a tab
# cwd outside their workspace. Standalone sessions retain cwd-derived routing.
args=(inbox read)
[ -z "${CEL_INBOX_ME:-}" ] || args+=(--for "$CEL_INBOX_ME")
[ -z "${CEL_INBOX_WS:-}" ] || args+=(--workspace "$CEL_INBOX_WS")
mail="$("$CEL_ROOT/bin/cel" "${args[@]}" 2>/dev/null)" || exit 0
[ -n "$mail" ] || exit 0

jq -nc --arg m "$mail" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ("Messages waiting in your celestial inbox (delivered once):\n" + $m +
      "\nAct on them as part of this turn, or say why not.")
  }
}'
