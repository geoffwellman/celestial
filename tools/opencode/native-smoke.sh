#!/usr/bin/env bash
# Explicit owner-only disposable proof. Never run against the live native store.
set -euo pipefail
[ "${CEL_OPENCODE_ALLOW_NATIVE_SMOKE:-}" = 1 ] || { printf 'Owner opt-in required\n' >&2; exit 2; }
[ "$#" = 1 ] && [[ "$1" = /* ]] && [ -x "$1" ] || { printf 'Pass the exact verified native binary\n' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node="$(node -p process.execPath)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cel-opencode-isolated.XXXXXX")"
chmod 700 "$scratch"
# Capture the actual caller namespace before bwrap; bind its evidence read-only.
readlink /proc/self/ns/net > "$scratch/host-netns"
status=0
env -i PATH="${node%/*}:$PATH" HOME="$scratch" TMPDIR="$scratch" CEL_OPENCODE_ALLOW_NATIVE_SMOKE=1 CEL_SMOKE_HOST_NET_FILE="$scratch/host-netns" \
  /usr/bin/bwrap --unshare-user --unshare-net --unshare-pid \
    --ro-bind / / --bind "$scratch" "$scratch" \
    --ro-bind "$scratch/host-netns" "$scratch/host-netns" --proc /proc --dev /dev \
    --chdir "$scratch" --die-with-parent --new-session \
    "$node" "$root/tools/opencode/native-smoke.mjs" "$1" || status=$?
if [ "$status" = 0 ]; then rm -f "$scratch/host-netns"; rmdir "$scratch";
else printf 'Native proof artifacts retained under %s\n' "$scratch" >&2; fi
exit "$status"
