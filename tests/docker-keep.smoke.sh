#!/usr/bin/env bash
# Opt-in real-daemon proof. Imports only fresh FROM-scratch equivalents: no
# downloads, provider calls, existing-image deletion or real cache pruning.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_bin="$(command -v docker)"
"$docker_bin" info >/dev/null
scratch="$(mktemp -d)"
lock="${XDG_STATE_HOME:-$HOME/.local/state}/cel/docker-images.lock"
mkdir -p "${lock%/*}" "$scratch/root"
nonce="cel-retention-smoke-$(date +%s)-$$"
labelled="" rollback="" disposable=""
cleanup() {
  local name id actual
  for name in labelled rollback disposable; do
    id="${!name}"
    [ -n "$id" ] || continue
    actual="$("$docker_bin" image inspect --format '{{.Id}}' "$nonce:$name" 2>/dev/null)" || continue
    [ "$actual" = "$id" ] || { printf 'refusing cleanup of changed scratch tag %s\n' "$name" >&2; continue; }
    flock -o "$lock" "$docker_bin" image rm "$nonce:$name" >/dev/null
  done
  rm -rf -- "$scratch"
}
trap cleanup EXIT
for name in labelled rollback disposable; do
  printf '%s\n' "$nonce:$name" > "$scratch/root/identity"
  tar -C "$scratch/root" -cf "$scratch/root.tar" identity
  if [ "$name" = labelled ]; then
    id="$(flock -o "$lock" "$docker_bin" image import --change 'LABEL cel.keep=true' "$scratch/root.tar" "$nonce:$name")"
  else
    id="$(flock -o "$lock" "$docker_bin" image import "$scratch/root.tar" "$nonce:$name")"
  fi
  [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf 'unknown imported ID\n' >&2; exit 1; }
  printf -v "$name" '%s' "$id"
done
printf '%s\n' "$nonce:rollback" > "$scratch/keep"
export SMOKE_DOCKER="$docker_bin" SMOKE_IDS="$labelled $rollback $disposable" SMOKE_LOG="$scratch/calls"
cat > "$scratch/docker" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SMOKE_LOG"
case "$1 $2" in
  'system df'|'container ls'|'container inspect') exec "$SMOKE_DOCKER" "$@" ;;
  'image ls')
    for id in $SMOKE_IDS; do
      if "$SMOKE_DOCKER" image inspect "$id" >/dev/null 2>&1; then printf '{"ID":"%s"}\n' "$id"; fi
    done ;;
  'image inspect'|'image rm')
    case " $SMOKE_IDS " in *" $3 "*) exec "$SMOKE_DOCKER" "$@" ;; *) exit 91 ;; esac ;;
  'builder prune') printf 'Total reclaimed space: 0B\n' ;; # existing cache is out of scope
  *) exit 92 ;;
esac
EOS
chmod +x "$scratch/docker"
CEL_BOX_DOCKER="$scratch/docker" CEL_BOX_DOCKER_KEEP_FILE="$scratch/keep" "$root/bin/cel" box sweep-docker >/dev/null
"$docker_bin" image inspect "$labelled" "$rollback" >/dev/null
if "$docker_bin" image inspect "$disposable" >/dev/null 2>&1; then
  printf 'unprotected scratch image survived: consumer did not run\n' >&2; exit 1
fi
removals="$(grep '^image rm ' "$SMOKE_LOG")"
[ "$removals" = "image rm $disposable" ] || { printf 'unexpected mutation: %s\n' "$removals" >&2; exit 1; }
printf 'PASS real Docker consumer: labelled=%s rollback=%s survived; disposable=%s removed without force; no existing images/cache touched\n' "$labelled" "$rollback" "$disposable"
