# shellcheck shell=bash
# Republishing is how a page gets revised, so the bytes it replaces must
# survive as an archived revision and the server must serve them read-only.
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/pages.sh"

test_publish_archives_the_outgoing_revision() {
  local T; T="$(mktemp -d)"
  printf 'v1' > "$T/x.html"
  CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/x.html" doc >/dev/null 2>&1
  # first publish has nothing to archive
  [ ! -d "$T/root/.versions/doc.html" ] || { echo "archived on first publish"; return 1; }
  printf 'v2' > "$T/x.html"
  CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/x.html" doc >/dev/null 2>&1
  assert_eq "$(cat "$T/root/doc.html")" "v2"
  assert_eq "$(cat "$T/root"/.versions/doc.html/*.html)" "v1"
  assert_eq "$(wc -l < "$T/root/.meta/revisions.log" | tr -d ' ')" "2"
  # republishing identical bytes is not a revision
  CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/x.html" doc >/dev/null 2>&1
  assert_eq "$(ls "$T/root"/.versions/doc.html | wc -l | tr -d ' ')" "1"
  rm -rf "$T"
}

test_pages_serves_archived_revisions_and_rejects_bad_ids() {
  PROOT="$(mktemp -d)"; mkdir -p "$PROOT/pub" "$PROOT/.versions/t.html"
  printf 'live' > "$PROOT/t.html"
  printf 'old' > "$PROOT/.versions/t.html/1700000000.html"
  local PT; PT=$(( 18300 + RANDOM % 400 ))
  CEL_PAGES_ROOT="$PROOT" CEL_PAGES_PORT="$PT" CEL_PAGES_HOST=127.0.0.1 \
  CEL_PAGES_FEEDBACK=1 CEL_PAGES_PUBLIC_ROOT="$PROOT/pub" \
    node "$CEL_ROOT/tools/pages/server.mjs" >"$PROOT/log" 2>&1 &
  local pid=$! i
  for i in $(seq 1 80); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PT/" && break; sleep 0.5; done
  assert_eq "$(curl -s "http://127.0.0.1:$PT/t.html?rev=1700000000.html")" "old"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/t.html?rev=../../etc/passwd")" "400"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/t.html?rev=1.html")" "404"
  # the timeline data the history panel reads
  assert_contains "$(curl -s "http://127.0.0.1:$PT/api/doc?name=t.html")" '1700000000.html'
  kill "$pid" 2>/dev/null; rm -rf "$PROOT"
}
