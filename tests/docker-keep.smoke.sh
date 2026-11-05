#!/usr/bin/env bash
# Opt-in real-daemon proof: only fresh, uniquely tagged scratch imports are
# exposed to the consumer. Existing images and build cache cannot be deleted.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_bin="$(command -v docker)"
"$docker_bin" info >/dev/null
scratch="$(mktemp -d)"
lock="${XDG_STATE_HOME:-$HOME/.local/state}/cel/docker-images.lock"
mkdir -p "${lock%/*}" "$scratch/root" "$scratch/config/cel/docker-keep-patterns.d"
nonce="cel-retention-smoke-$(date +%s)-$$"
declare -A ids=() tags=()
container=""
cleanup() {
  local name id actual
  if [ -n "$container" ]; then flock -o "$lock" "$docker_bin" container rm "$container" >/dev/null; fi
  for name in "${!ids[@]}"; do
    id="${ids[$name]}"
    actual="$("$docker_bin" image inspect --format '{{.Id}}' "${tags[$name]}" 2>/dev/null)" || continue
    [ "$actual" = "$id" ] || { printf 'refusing cleanup of changed scratch tag %s\n' "$name" >&2; continue; }
    flock -o "$lock" "$docker_bin" image rm "${tags[$name]}" >/dev/null
  done
  rm -rf -- "$scratch"
}
trap cleanup EXIT
for name in labelled rollback current base other disposable referenced; do
  case "$name" in
    rollback|current|disposable|referenced) tags[$name]="slot-studio-local/media-executor:$nonce-$name" ;;
    base) tags[$name]="slot-studio-media-executor-base:$nonce" ;;
    *) tags[$name]="$nonce:$name" ;;
  esac
  printf '%s\n' "${tags[$name]}" > "$scratch/root/identity"
  tar -C "$scratch/root" -cf "$scratch/root.tar" identity
  if [ "$name" = labelled ]; then
    id="$(flock -o "$lock" "$docker_bin" image import --change 'LABEL cel.keep=true' "$scratch/root.tar" "${tags[$name]}")"
  else
    id="$(flock -o "$lock" "$docker_bin" image import "$scratch/root.tar" "${tags[$name]}")"
  fi
  [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || { printf 'unknown imported ID\n' >&2; exit 1; }
  ids[$name]="$id"
done
container="$(flock -o "$lock" "$docker_bin" container create --name "$nonce" --entrypoint /not-executed "${tags[referenced]}")"
(
  flock -x 9
  printf '%s\n' "${tags[current]}" "${tags[rollback]}" > "$scratch/config/cel/docker-keep-patterns.d/.follow-main.next"
  mv "$scratch/config/cel/docker-keep-patterns.d/.follow-main.next" "$scratch/config/cel/docker-keep-patterns.d/follow-main.patterns"
  printf '%s\n' "${tags[other]}" > "$scratch/config/cel/docker-keep-patterns.d/other.patterns"
) 9>>"$lock"
export SMOKE_DOCKER="$docker_bin" SMOKE_IDS="${ids[*]}" SMOKE_LOG="$scratch/calls"
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
  'builder prune') printf 'Total reclaimed space: 0B\n' ;;
  *) exit 92 ;;
esac
EOS
chmod +x "$scratch/docker"
XDG_CONFIG_HOME="$scratch/config" CEL_BOX_DOCKER="$scratch/docker" CEL_BOX_DOCKER_KEEP_FILE="$scratch/legacy" CEL_BOX_DOCKER_KEEP_DIR="$scratch/config/cel/docker-keep-patterns.d" "$root/bin/cel" box docker-safety >/dev/null
# Legacy operator file remains supported and independent of producer files.
printf '# operator-owned\n' > "$scratch/legacy"
XDG_CONFIG_HOME="$scratch/config" CEL_BOX_DOCKER="$scratch/docker" CEL_BOX_DOCKER_KEEP_FILE="$scratch/legacy" CEL_BOX_DOCKER_KEEP_DIR="$scratch/config/cel/docker-keep-patterns.d" "$root/bin/cel" box sweep-docker >/dev/null
for name in labelled rollback current base other referenced; do
  "$docker_bin" image inspect "${ids[$name]}" >/dev/null
done
if "$docker_bin" image inspect "${ids[disposable]}" >/dev/null 2>&1; then
  printf 'superseded scratch executor survived\n' >&2; exit 1
fi
removals="$(grep '^image rm ' "$SMOKE_LOG")"
[ "$removals" = "image rm ${ids[disposable]}" ] || { printf 'unexpected mutation: %s\n' "$removals" >&2; exit 1; }
printf 'PASS real Docker consumer: current, rollback, immutable base, other producer, label and stopped-container references survive; superseded executor removed; no existing images/cache touched\n'
