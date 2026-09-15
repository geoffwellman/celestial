#!/usr/bin/env bash
# claude SessionEnd hook: decay and budget this workspace's learnings.
#
# `cel learn stow` moves stale entries (aging 30d, perishable 7d, unreinforced)
# to the cold archive with provenance and enforces the injected budget, so the
# learnings file cannot rot into a landfill nobody reads. Run at session end
# because that is when a session's facts have either been reinforced by use
# or not. Fails open on everything: a hook that broke a session over
# housekeeping would be exactly the wrong trade.
#
# Register in ~/.claude/settings.json under hooks.SessionEnd:
#   {"hooks":[{"type":"command","command":"bash <CEL_ROOT>/tools/hooks/learn-stow.sh","timeout":15}]}
set -uo pipefail
CEL_ROOT="${CEL_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
[ -x "$CEL_ROOT/bin/cel" ] || exit 0
# only inside a workspace, and only if it has learnings at all
d="$PWD"
while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -f "$d/workspace.yaml" ]; do d="${d%/*}"; done
[ -f "$d/workspace.yaml" ] || exit 0
[ -f "$d/learnings.md" ] || exit 0
"$CEL_ROOT/bin/cel" learn stow --dir "$d" >/dev/null 2>&1 || true
exit 0
