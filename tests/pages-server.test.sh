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

# The index lists documents only. Every image, video and audio file -
# referenced by a page or standalone - is left out of the rows and the
# workspace counts, yet each keeps serving at its URL.
test_index_lists_documents_never_media() {
  _pages_boot 1 || return 1
  mkdir -p "$PROOT/.meta"
  printf '<img src="chart.png"><img src="./fig.svg">' > "$PROOT/report.html"
  printf '<p>notes</p>' > "$PROOT/notes.html"
  printf '{"workspace":"orion"}' > "$PROOT/.meta/report.html.json"
  printf '{"workspace":"orion"}' > "$PROOT/.meta/notes.html.json"
  printf 'PNG' > "$PROOT/chart.png"; printf '<svg/>' > "$PROOT/fig.svg"
  local f
  for f in lonely.png pic.jpg pic2.jpeg anim.gif logo.webp favicon.ico clip.mp4 clip.webm voice.mp3 take.wav; do printf 'X' > "$PROOT/$f"; done
  printf '{"workspace":"orion"}' > "$PROOT/.meta/lonely.png.json"
  local idx; idx="$(curl -s "http://127.0.0.1:$PT/")"
  assert_contains "$idx" 'href="/report.html"'
  assert_contains "$idx" 'href="/notes.html"'
  assert_contains "$idx" 'orion (2)'
  for f in chart.png fig.svg lonely.png pic.jpg pic2.jpeg anim.gif logo.webp favicon.ico clip.mp4 clip.webm voice.mp3 take.wav; do
    if printf '%s' "$idx" | grep -qF "href=\"/$f\""; then
      echo "media $f listed"; _pages_stop; return 1; fi
    assert_eq "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/$f")" "200"
  done
  _pages_stop
}

# A SHARED PAGE CARRIES ITS OWN ASSETS, AND NOTHING ELSE. Its screenshots and
# a linked full-size image are bundled; a linked page is not (unless named);
# the public token serves exactly the manifest's list - never another private
# doc, a dotfile, a traversal, a symlink, or another token's asset.
_pages_bundle_fixture() {
  printf 'PNG-A' > "$PROOT/shot.png"; printf 'PNG-FULL' > "$PROOT/full.png"; printf 'PNG-M' > "$PROOT/m.png"
  printf '<html><img src="m.png"><a href="deeper.html">x</a></html>' > "$PROOT/m.html"
  printf 'deep' > "$PROOT/deeper.html"; printf 'secret' > "$PROOT/private.html"
  ln -s "$PROOT/private.html" "$PROOT/link.png"
  printf '<html><img src="./shot.png"><img src="link.png"><a href="full.png">big</a><a href="./m.html">mock</a><a href="https://x.example/a.png">ext</a><img src="../etc/x.png"></html>' > "$PROOT/page.html"
}
_pages_promote() { # <json body> -> response
  curl -s -X POST "http://127.0.0.1:$PT/api/promote" -H 'content-type: application/json' \
    -H "origin: http://127.0.0.1:$PT" -H "x-cel-csrf: $PNONCE" -d "$1"
}
test_pages_share_bundles_the_pages_assets_and_serves_only_them() {
  _pages_boot 1 || return 1
  _pages_bundle_fixture
  local out token
  out="$(_pages_promote '{"doc":"page.html"}')"
  token="$(printf '%s' "$out" | jq -r '.public' | sed -E 's#.*/([a-f0-9]{16,})/.*#\1#')"
  assert_eq "$(jq -c .assets <<<"$out")" '["full.png","shot.png"]'
  assert_eq "$(jq -c .assets "$PROOT/pub/$token/.share.json")" '["full.png","shot.png"]'
  # the public tier, on the share root
  local PP=$(( PT + 500 ))
  CEL_PAGES_ROOT="$PROOT/pub" CEL_PAGES_PORT="$PP" CEL_PAGES_HOST=127.0.0.1 CEL_PAGES_FEEDBACK=0 \
    node "$CEL_ROOT/tools/pages/server.mjs" >"$PROOT/publog" 2>&1 &
  local ppid=$! i
  for i in $(seq 1 80); do curl -sf -m 1 -o /dev/null "http://127.0.0.1:$PP/" && break; sleep 0.25; done
  local code; code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PP/$1"; }
  assert_eq "$(code "$token/page.html")" 200
  assert_eq "$(curl -s "http://127.0.0.1:$PP/$token/shot.png")" "PNG-A"
  assert_eq "$(code "$token/full.png")" 200
  assert_eq "$(code "$token/m.html")" 404          # a linked page is not intended by default
  assert_eq "$(code "$token/private.html")" 404    # an unrelated private doc
  assert_eq "$(code "$token/link.png")" 404        # a symlink is never bundled
  assert_eq "$(code "$token/.share.json")" 404
  assert_eq "$(code "$token/%2e%2e/private.html")" 404
  assert_eq "$(code "$token/%2e%2e/%2e%2e/etc/passwd")" 404
  assert_eq "$(code "$token/..%2fprivate.html")" 404
  # cross-token: another share's manifest does not unlock this one's files
  local other=cccccccccccccccccccccccc
  mkdir -p "$PROOT/pub/$other"; printf '{"doc":"x.html","assets":["shot.png"]}' > "$PROOT/pub/$other/.share.json"
  assert_eq "$(code "$other/shot.png")" 404
  # a symlink planted in the token dir under a listed name is refused
  rm -f "$PROOT/pub/$token/full.png"; ln -s "$PROOT/private.html" "$PROOT/pub/$token/full.png"
  assert_eq "$(code "$token/full.png")" 404
  kill "$ppid" 2>/dev/null
  _pages_stop
}

test_pages_share_includes_a_named_page_and_its_assets_one_level() {
  _pages_boot 1 || return 1
  _pages_bundle_fixture
  local out
  out="$(_pages_promote '{"doc":"page.html","include":["m.html"]}')"
  assert_eq "$(jq -c .assets <<<"$out")" '["full.png","m.html","m.png","shot.png"]'
  # an include that is not a published page in the same directory is refused, nothing written
  local before; before="$(ls "$PROOT/pub" | wc -l)"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PT/api/promote" -H 'content-type: application/json' \
    -H "origin: http://127.0.0.1:$PT" -H "x-cel-csrf: $PNONCE" -d '{"doc":"page.html","include":["../x.html"]}')" 400
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PT/api/promote" -H 'content-type: application/json' \
    -H "origin: http://127.0.0.1:$PT" -H "x-cel-csrf: $PNONCE" -d '{"doc":"page.html","include":["nope.html"]}')" 400
  assert_eq "$(ls "$PROOT/pub" | wc -l)" "$before"
  _pages_stop
}

# An existing share gets its assets IN PLACE: the link people already have
# keeps working, with the same expiry.
test_pages_bundle_extends_a_live_share_without_a_new_link() {
  PROOT="$(mktemp -d)"; mkdir -p "$PROOT/pub"
  local tok=dddddddddddddddddddddddd
  printf '<img src="shot.png"><a href="m.html">m</a>' > "$PROOT/page.html"; printf 'PNG' > "$PROOT/shot.png"
  printf '<p>mock</p>' > "$PROOT/m.html"
  mkdir -p "$PROOT/pub/$tok"; cp "$PROOT/page.html" "$PROOT/pub/$tok/"
  printf '{"doc":"page.html","created":"2026-10-28T04:14:59Z","expires":"2099-01-01T00:00:00Z"}' > "$PROOT/pub/$tok/.share.json"
  local out
  out="$(CEL_PAGES_ROOT="$PROOT" CEL_PAGES_PUBLIC_ROOT="$PROOT/pub" CEL_PAGES_PUBLIC_URL=https://pub.example \
    bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/pages.sh"; cmd_pages_bundle page.html --include m.html' 2>/dev/null)"
  assert_eq "$out" "https://pub.example/$tok/page.html"
  assert_eq "$(ls -d "$PROOT"/pub/*/ | wc -l)" 1
  assert_eq "$(jq -c '[.assets,.expires,.created]' "$PROOT/pub/$tok/.share.json")" '[["m.html","shot.png"],"2099-01-01T00:00:00Z","2026-10-28T04:14:59Z"]'
  [ -f "$PROOT/pub/$tok/shot.png" ] && [ -f "$PROOT/pub/$tok/m.html" ] || { echo "assets not copied"; rm -rf "$PROOT"; return 1; }
  assert_contains "$(cat "$PROOT/.meta/promotions.log")" '"action":"bundle"'
  rm -rf "$PROOT"
}
