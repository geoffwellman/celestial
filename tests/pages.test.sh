# shellcheck shell=bash
source "$CEL_ROOT/lib/common.sh"
source "$CEL_ROOT/lib/pages.sh"

# stdout is the machine-readable URL and nothing else - agents paste it
# straight to the user - and the same name must map to the same URL forever.
test_publish_prints_url_and_copies_file() {
  local T; T="$(mktemp -d)"
  printf '<h1>hi</h1>' > "$T/My Report.html"
  local url
  url="$(CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=10.0.0.1 CEL_PAGES_PORT=7780 \
         cmd_publish "$T/My Report.html" 2>/dev/null)"
  assert_eq "$url" "http://10.0.0.1:7780/my-report.html"
  assert_eq "$(cat "$T/root/my-report.html")" '<h1>hi</h1>'
  rm -rf "$T"
}
test_publish_sanitises_explicit_names_and_republish_overwrites() {
  local T; T="$(mktemp -d)"
  printf 'v1' > "$T/x.html"
  local url
  url="$(CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
         cmd_publish "$T/x.html" 'Weekly Report!' 2>/dev/null)"
  assert_eq "$url" "http://h:1/weekly-report.html"
  printf 'v2' > "$T/x.html"
  CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
    cmd_publish "$T/x.html" 'Weekly Report!' >/dev/null 2>&1
  assert_eq "$(cat "$T/root/weekly-report.html")" 'v2'
  rm -rf "$T"
}
test_publish_keeps_non_html_extensions() {
  local T; T="$(mktemp -d)"
  printf 'a,b\n' > "$T/data.csv"
  local url
  url="$(CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
         cmd_publish "$T/data.csv" 2>/dev/null)"
  assert_eq "$url" "http://h:1/data.csv"
  rm -rf "$T"
}
# publishing records who published (the herdr pane) so feedback on the page
# can find its way back; .meta is dot-prefixed so the server never serves it
test_publish_writes_routing_meta() {
  local T; T="$(mktemp -d)"
  printf 'x' > "$T/r.html"
  CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 HERDR_PANE_ID=w9:p9 \
    cmd_publish "$T/r.html" >/dev/null 2>&1
  assert_eq "$(jq -r .pane "$T/root/.meta/r.html.json")" "w9:p9"
  rm -rf "$T"
}
# --public is a different root AND a different URL authority; nothing lands
# there without the flag.
test_publish_public_uses_own_root_and_url() {
  local T; T="$(mktemp -d)"
  printf 'p' > "$T/x.html"
  local url
  url="$(CEL_PAGES_ROOT="$T/priv" CEL_PAGES_PUBLIC_ROOT="$T/pub" \
         CEL_PAGES_PUBLIC_URL='https://pages.example.com' \
         cmd_publish --public "$T/x.html" 2>/dev/null)"
  # public shares land in an unguessable token dir with an expiry manifest
  local token; token="$(printf '%s' "$url" | sed -E 's#.*/([a-f0-9]{16,})/.*#\1#')"
  [ ${#token} -ge 16 ] || { echo "no share token in $url"; return 1; }
  assert_eq "$url" "https://pages.example.com/$token/x.html"
  [ -f "$T/pub/$token/x.html" ]
  [ -f "$T/pub/$token/.share.json" ]
  [ ! -e "$T/priv/x.html" ]
  rm -rf "$T"
}
# Public sharing must not require tailscale: an explicit hostname wins, then a
# live tunnel URL file, then a tailnet name, then honest loopback.
test_public_url_prefers_override_then_tunnel_then_loopback() {
  local T; T="$(mktemp -d)"
  assert_eq "$(CEL_PAGES_PUBLIC_URL='https://docs.example.com/' _pages_public_url)" "https://docs.example.com"
  printf 'https://random-words.trycloudflare.com\n' > "$T/tunnel.url"
  assert_eq "$(CEL_PAGES_TUNNEL_URL_FILE="$T/tunnel.url" _pages_public_url)" "https://random-words.trycloudflare.com"
  # no override, no tunnel, no tailscale on PATH -> loopback, never a lie
  local out
  out="$(PATH=/usr/bin:/bin CEL_PAGES_TUNNEL_URL_FILE="$T/none" CEL_PAGES_PUBLIC_PORT=7781 _pages_public_url)"
  case "$out" in http://127.0.0.1:7781|https://*) ;; *) echo "unexpected fallback: $out"; return 1;; esac
  rm -rf "$T"
}

_publish_in_subshell() { ( cmd_publish "$@" ); }
test_publish_requires_an_existing_file() {
  assert_fails _publish_in_subshell /nonexistent/nope.html
}

# --- workspace attribution -------------------------------------------------
# The document root stays flat and box-wide, so a page has to say where it came
# from: it is what the index filters on, and the only thing standing between
# two workspaces' identically-named reports.

# A registry + two workspaces, one of which declares a repo.
_pages_ws_fixture() { # sets T, CEL_REGISTRY
  T="$(mktemp -d)"
  mkdir -p "$T/ws/alpha" "$T/ws/beta"
  printf 'name: alpha\nrepos:\n  - { name: widget, url: u, prefix: WG }\n' > "$T/ws/alpha/workspace.yaml"
  printf 'name: beta\nrepos: []\n' > "$T/ws/beta/workspace.yaml"
  export CEL_REGISTRY="$T/registry.yaml"
  printf 'workspaces:\n  alpha: { path: %s/ws/alpha }\n  beta: { path: %s/ws/beta }\n' "$T" "$T" > "$CEL_REGISTRY"
  export CEL_WORKTREES="$T/worktrees"
  mkdir -p "$CEL_WORKTREES/widget/wg-1-x"
}
test_workspace_is_derived_from_the_publishing_directory() {
  _pages_ws_fixture
  assert_eq "$(_pages_workspace "$T/ws/alpha")" alpha
  assert_eq "$(_pages_workspace "$T/ws/beta")" beta
  rm -rf "$T"
}
# A worker publishes from its worktree, which is nowhere near the workspace -
# the repo name in the path is the only link back, and exactly one workspace
# declares it.
test_workspace_is_derived_from_a_worktree_via_its_repo() {
  _pages_ws_fixture
  assert_eq "$(_pages_workspace "$CEL_WORKTREES/widget/wg-1-x")" alpha
  rm -rf "$T"
}
# Agents build pages in a harness scratchpad, which mangles the project path
# into one segment. Matching the mangled form of a KNOWN path is exact.
test_workspace_is_derived_from_a_mangled_scratchpad_path() {
  _pages_ws_fixture
  local mang; mang="$(printf '%s' "$T/ws/beta" | tr '/' '-')"
  assert_eq "$(_pages_workspace "/tmp/claude-1000/$mang/sess/scratchpad")" beta
  rm -rf "$T"
}
test_unknown_directory_has_no_workspace() {
  _pages_ws_fixture
  assert_eq "$(_pages_workspace "$T/nowhere")" ""
  rm -rf "$T"
}
test_publish_records_the_workspace_in_the_sidecar() {
  _pages_ws_fixture
  printf 'v1' > "$T/x.html"
  (cd "$T/ws/alpha" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
     cmd_publish "$T/x.html" report >/dev/null 2>&1)
  assert_eq "$(jq -r .workspace "$T/root/.meta/report.html.json")" alpha
  rm -rf "$T"
}
# THE CLOBBER THAT MATTERS. Republishing your own page in place is the design -
# the URL must stay stable across revisions - so the suffix appears only when
# the name already belongs to somebody else, and names the workspace rather
# than the moment, so beta's own republishes stay stable too.
test_another_workspaces_name_is_suffixed_not_overwritten() {
  _pages_ws_fixture
  printf 'alpha-doc' > "$T/a.html"; printf 'beta-doc' > "$T/b.html"
  (cd "$T/ws/alpha" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
     cmd_publish "$T/a.html" report >/dev/null 2>&1)
  local url
  url="$(cd "$T/ws/beta" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
     cmd_publish "$T/b.html" report 2>/dev/null)"
  assert_eq "$url" "http://h:1/report-beta.html"
  assert_eq "$(cat "$T/root/report.html")" 'alpha-doc'
  assert_eq "$(cat "$T/root/report-beta.html")" 'beta-doc'
  # and beta republishing is still in place, not report-beta-beta.html
  printf 'beta-v2' > "$T/b.html"
  url="$(cd "$T/ws/beta" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
     cmd_publish "$T/b.html" report 2>/dev/null)"
  assert_eq "$url" "http://h:1/report-beta.html"
  assert_eq "$(cat "$T/root/report-beta.html")" 'beta-v2'
  rm -rf "$T"
}
test_republishing_your_own_page_keeps_the_url() {
  _pages_ws_fixture
  printf 'v1' > "$T/x.html"
  (cd "$T/ws/alpha" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
     cmd_publish "$T/x.html" report >/dev/null 2>&1)
  printf 'v2' > "$T/x.html"
  local url
  url="$(cd "$T/ws/alpha" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 \
     cmd_publish "$T/x.html" report 2>/dev/null)"
  assert_eq "$url" "http://h:1/report.html"
  assert_eq "$(cat "$T/root/report.html")" 'v2'
  rm -rf "$T"
}
# Documents published before attribution existed still recorded their cwd, so
# the workspace is re-derivable rather than lost.
test_reindex_backfills_the_workspace_from_the_recorded_cwd() {
  _pages_ws_fixture
  mkdir -p "$T/root/.meta"
  printf '<h1>old</h1>' > "$T/root/legacy.html"
  jq -n --arg c "$T/ws/alpha" '{pane:"w1:p1", cwd:$c, published:"2026-09-01T00:00:00+10:00"}' \
    > "$T/root/.meta/legacy.html.json"
  printf '<h1>orphan</h1>' > "$T/root/orphan.html"
  jq -n '{pane:"", cwd:"/var/tmp", published:"2026-09-01T00:00:00+10:00"}' \
    > "$T/root/.meta/orphan.html.json"
  CEL_PAGES_ROOT="$T/root" cmd_pages --reindex >/dev/null 2>&1
  assert_eq "$(jq -r .workspace "$T/root/.meta/legacy.html.json")" alpha
  assert_eq "$(jq -r '.workspace // "absent"' "$T/root/.meta/orphan.html.json")" absent
  rm -rf "$T"
}

# --- Codex review, PR #9 ----------------------------------------------------

# `/home/me/ws/a` mangles to `-home-me-ws-a`, which is a PREFIX of alpha's
# `-home-me-ws-alpha`. A substring match handed alpha's pages to workspace `a`,
# depending only on registry order.
test_a_mangled_path_matches_a_whole_segment_not_a_prefix() {
  T="$(mktemp -d)"
  mkdir -p "$T/ws/a" "$T/ws/alpha"
  printf 'name: a\nrepos: []\n' > "$T/ws/a/workspace.yaml"
  printf 'name: alpha\nrepos: []\n' > "$T/ws/alpha/workspace.yaml"
  export CEL_REGISTRY="$T/registry.yaml"
  # `a` deliberately FIRST, which is the order that used to decide it
  printf 'workspaces:\n  a: { path: %s/ws/a }\n  alpha: { path: %s/ws/alpha }\n' "$T" "$T" > "$CEL_REGISTRY"
  local mang; mang="$(printf '%s' "$T/ws/alpha" | tr '/' '-')"
  assert_eq "$(_pages_workspace "/tmp/claude-1000/$mang/sess/scratchpad")" alpha
  rm -rf "$T"
}
# The suffixed fallback can itself already belong to somebody - a third
# workspace that simply published a document with that name - and taking it
# would reintroduce the clobber one name along.
test_the_fallback_name_is_checked_for_an_owner_too() {
  _pages_ws_fixture
  mkdir -p "$T/ws/gamma"; printf 'name: gamma\nrepos: []\n' > "$T/ws/gamma/workspace.yaml"
  printf 'workspaces:\n  alpha: { path: %s/ws/alpha }\n  beta: { path: %s/ws/beta }\n  gamma: { path: %s/ws/gamma }\n' "$T" "$T" "$T" > "$CEL_REGISTRY"
  printf 'x\n' > "$T/f.html"
  # alpha owns report.html; gamma owns the name beta's fallback would want
  (cd "$T/ws/alpha" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/f.html" report >/dev/null 2>&1)
  (cd "$T/ws/gamma" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/f.html" report-beta >/dev/null 2>&1)
  printf 'betas-own\n' > "$T/b.html"
  local url
  url="$(cd "$T/ws/beta" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/b.html" report 2>/dev/null)"
  assert_eq "$url" "http://h:1/report-beta-2.html"
  assert_eq "$(jq -r .workspace "$T/root/.meta/report-beta.html.json")" gamma
  assert_eq "$(cat "$T/root/report-beta-2.html")" "betas-own"
  rm -rf "$T"
}

# Worktrees are global - one directory per repo NAME - so when two workspaces
# declare the same repo, the path cannot say which one spawned the worker.
# Guessing would attribute a page to a workspace that never saw it.
test_an_ambiguous_repo_name_attributes_to_nobody() {
  _pages_ws_fixture
  printf 'name: beta\nrepos:\n  - { name: widget, url: u, prefix: WG }\n' > "$T/ws/beta/workspace.yaml"
  assert_eq "$(_pages_workspace "$CEL_WORKTREES/widget/wg-1-x")" ""
  rm -rf "$T"
}
# A workspace name is not filename-safe, and the suffix is appended AFTER the
# document name has been sanitised.
test_the_workspace_suffix_is_sanitised_like_the_name() {
  _pages_ws_fixture
  mkdir -p "$T/ws/slashy"
  printf 'name: team/docs\nrepos: []\n' > "$T/ws/slashy/workspace.yaml"
  printf 'workspaces:\n  alpha: { path: %s/ws/alpha }\n  slashy: { path: %s/ws/slashy }\n' "$T" "$T" > "$CEL_REGISTRY"
  printf 'a\n' > "$T/f.html"
  (cd "$T/ws/alpha" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/f.html" report >/dev/null 2>&1)
  local url
  url="$(cd "$T/ws/slashy" && CEL_PAGES_ROOT="$T/root" CEL_PAGES_HOST=h CEL_PAGES_PORT=1 cmd_publish "$T/f.html" report 2>/dev/null)"
  assert_eq "$url" "http://h:1/report-team-docs.html"
  [ -f "$T/root/report-team-docs.html" ] || { echo "suffix produced a path, not a name"; rm -rf "$T"; return 1; }
  rm -rf "$T"
}
