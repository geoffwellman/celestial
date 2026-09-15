# shellcheck shell=bash
# The pages server is a real HTTP surface, so its contract is tested by
# booting it on a scratch root and talking to it.
source "$CEL_ROOT/lib/common.sh"

_pages_boot() { # <feedback 0|1> -> sets PT (port), PROOT, SRV_PID, PNONCE
  PROOT="$(mktemp -d)"
  mkdir -p "$PROOT/pub"
  printf '<!doctype html><title>T</title><body>hello' > "$PROOT/t.html"
  printf 'a,b\n' > "$PROOT/d.csv"
  PT=$(( 17820 + RANDOM % 400 ))
  CEL_PAGES_ROOT="$PROOT" CEL_PAGES_PORT="$PT" CEL_PAGES_HOST=127.0.0.1 \
  CEL_PAGES_FEEDBACK="$1" CEL_PAGES_PUBLIC_ROOT="$PROOT/pub" \
  CEL_PAGES_PUBLIC_URL=https://pub.example \
    node "$CEL_ROOT/tools/pages/server.mjs" >"$PROOT/log" 2>&1 &
  SRV_PID=$!
  local i
  for i in $(seq 1 80); do
    if curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PT/"; then
      if [ "$1" = 1 ]; then PNONCE="$(curl -sf "http://127.0.0.1:$PT/api/session" | jq -er .csrfToken)"; fi
      return 0
    fi
    sleep 0.5
  done
  echo "server did not come up: $(cat "$PROOT/log")"; return 1
}
_pages_stop() { kill "$SRV_PID" 2>/dev/null; rm -rf "$PROOT"; }

# Private tier: HTML arrives inside the chrome shell (nav bar + iframe), and
# ?raw=1 serves the document itself - that is what the iframe loads, and what
# a reader gets if they strip the shell.
test_pages_private_wraps_html_in_chrome() {
  _pages_boot 1 || return 1
  local page raw
  page="$(curl -s "http://127.0.0.1:$PT/t.html")"
  raw="$(curl -s "http://127.0.0.1:$PT/t.html?raw=1")"
  assert_contains "$page" 'id="cel-nav"'
  assert_contains "$page" 'share publicly'
  assert_contains "$page" '?raw=1'
  assert_contains "$raw" '<!doctype html><title>T</title>'
  ! printf '%s' "$raw" | grep -q 'cel-nav' || { echo "raw served with chrome"; _pages_stop; return 1; }
  assert_eq "$(curl -s "http://127.0.0.1:$PT/d.csv")" "a,b"
  _pages_stop
}

# Public tier (no feedback flag): no chrome, no nav, no promote endpoint - the
# internet gets the document and nothing that can change what is published.
test_pages_public_tier_has_no_chrome_or_controls() {
  _pages_boot 0 || return 1
  local code
  # a flat document name is not readable on the public tier at all
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/t.html")" "404"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PT/api/promote" \
    -H 'content-type: application/json' -d '{"doc":"t.html"}')"
  assert_eq "$code" "405"
  ! curl -s "http://127.0.0.1:$PT/" | grep -q 'cel-nav' || { echo "public tier served chrome"; _pages_stop; return 1; }
  _pages_stop
}

# The nav bar's publish button round-trips: promote copies into the public
# root and hands back the public URL, revoke removes it, both audited.
test_pages_promote_round_trip() {
  _pages_boot 1 || return 1
  local out
  out="$(curl -s -X POST "http://127.0.0.1:$PT/api/promote" -H 'content-type: application/json' \
    -H "origin: http://127.0.0.1:$PT" -H "x-cel-csrf: $PNONCE" -d '{"doc":"t.html"}')"
  local token; token="$(printf '%s' "$out" | jq -r '.public' | sed -E 's#.*/([a-f0-9]{16,})/.*#\1#')"
  assert_contains "$out" "https://pub.example/$token/t.html"
  [ -f "$PROOT/pub/$token/t.html" ] || { echo "not copied to the public root"; _pages_stop; return 1; }
  curl -s -X POST "http://127.0.0.1:$PT/api/revoke" -H 'content-type: application/json' \
    -H "origin: http://127.0.0.1:$PT" -H "x-cel-csrf: $PNONCE" -d '{"doc":"t.html"}' >/dev/null
  [ ! -e "$PROOT/pub/$token" ] || { echo "not removed on revoke"; _pages_stop; return 1; }
  assert_contains "$(tr -d ' ' < "$PROOT/.meta/promotions.log")" '"action":"public"'
  _pages_stop
}

# Once public, the URL must be visible without opening anything: the index
# badge links to it and the nav bar renders it into the bar. The link itself
# is an unguessable token path, never the document name.
test_pages_public_url_is_surfaced_and_tokenised() {
  _pages_boot 1 || return 1
  local out token
  out="$(curl -s -X POST "http://127.0.0.1:$PT/api/promote" -H 'content-type: application/json' \
    -H "origin: http://127.0.0.1:$PT" -H "x-cel-csrf: $PNONCE" -d '{"doc":"t.html","ttlHours":24}')"
  token="$(printf '%s' "$out" | jq -r '.public' | sed -E 's#.*/([a-f0-9]{16,})/.*#\1#')"
  [ ${#token} -ge 16 ] || { echo "no token in $out"; _pages_stop; return 1; }
  assert_contains "$out" "https://pub.example/$token/t.html"
  [ -f "$PROOT/pub/$token/t.html" ] || { echo "share dir not written"; _pages_stop; return 1; }
  assert_contains "$(cat "$PROOT/pub/$token/.share.json")" '"doc": "t.html"' \
    || assert_contains "$(cat "$PROOT/pub/$token/.share.json")" '"doc":"t.html"'
  assert_contains "$(curl -s "http://127.0.0.1:$PT/")" "$token"
  assert_contains "$(curl -s "http://127.0.0.1:$PT/t.html")" 'id="puburl"'
  # re-sharing rotates the token and kills the old dir
  local out2 token2
  out2="$(curl -s -X POST "http://127.0.0.1:$PT/api/promote" -H 'content-type: application/json' \
    -H "origin: http://127.0.0.1:$PT" -H "x-cel-csrf: $PNONCE" -d '{"doc":"t.html"}')"
  token2="$(printf '%s' "$out2" | jq -r '.public' | sed -E 's#.*/([a-f0-9]{16,})/.*#\1#')"
  [ "$token" != "$token2" ] || { echo "token not rotated"; _pages_stop; return 1; }
  [ ! -d "$PROOT/pub/$token" ] || { echo "old share dir survived a re-share"; _pages_stop; return 1; }
  _pages_stop
}

# The public tier reads token paths only, refuses flat document names, and
# returns 410 once a share has expired.
test_pages_public_tier_tokens_and_expiry() {
  PROOT="$(mktemp -d)"; mkdir -p "$PROOT/live/x" "$PROOT/dead/y"
  local live dead
  live=aaaaaaaaaaaaaaaaaaaaaaaa; dead=bbbbbbbbbbbbbbbbbbbbbbbb
  mkdir -p "$PROOT/$live" "$PROOT/$dead"
  printf 'shared' > "$PROOT/$live/t.html"
  printf '{"doc":"t.html","expires":null}' > "$PROOT/$live/.share.json"
  printf 'gone' > "$PROOT/$dead/t.html"
  printf '{"doc":"t.html","expires":"2020-01-01T00:00:00Z"}' > "$PROOT/$dead/.share.json"
  printf 'flat' > "$PROOT/flat.html"
  local PT; PT=$(( 18700 + RANDOM % 400 ))
  CEL_PAGES_ROOT="$PROOT" CEL_PAGES_PORT="$PT" CEL_PAGES_HOST=127.0.0.1 CEL_PAGES_FEEDBACK=0 \
    node "$CEL_ROOT/tools/pages/server.mjs" >"$PROOT/log" 2>&1 &
  local pid=$! i
  for i in $(seq 1 80); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PT/" && break; sleep 0.5; done
  assert_eq "$(curl -s "http://127.0.0.1:$PT/$live/t.html")" "shared"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/$dead/t.html")" "410"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/flat.html")" "404"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/$live/other.html")" "404"
  # no directory listing on the internet-facing tier
  ! curl -s "http://127.0.0.1:$PT/" | grep -q "$live" || { echo "public index leaked a token"; kill "$pid"; return 1; }
  kill "$pid" 2>/dev/null; rm -rf "$PROOT"
}

# The index is the only way to find a document you did not publish yourself, so
# it has to answer "whose is this?" and stay usable past a screenful.
test_index_carries_workspace_filter_and_pagination() {
  _pages_boot 1 || return 1
  mkdir -p "$PROOT/.meta"
  printf '{"pane":"","cwd":"/x","workspace":"alpha","published":"2026-09-01T00:00:00+10:00"}' \
    > "$PROOT/.meta/t.html.json"
  local ix; ix="$(curl -s "http://127.0.0.1:$PT/")"
  assert_contains "$ix" 'id="ws"'
  assert_contains "$ix" 'id="q"'
  assert_contains "$ix" 'data-w="alpha"'
  # the document with no sidecar is shown as unfiled, never hidden
  assert_contains "$ix" 'data-w="unfiled"'
  assert_contains "$ix" 'id="pager"'
  # client JS in this server is written without template literals - a backtick
  # inside would terminate the server-side literal that renders the page
  case "$ix" in *'`'*) echo "backtick reached the rendered index"; _pages_stop; return 1;; esac
  _pages_stop
}
