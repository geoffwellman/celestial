# shellcheck shell=bash
# A Forgejo for tests: a curl stub that answers the REST paths lib/forge.sh
# uses, for the repo geoff/gizmo on http://forgejo.internal, from
# tests/fixtures/forge/forgejo (spec-derived - see PROVENANCE there), and the
# token file the backend reads. Per call it records:
#   $FJ_ARGV_LOG   curl's argv, one line per call (the token must never be here)
#   $FJ_STDIN_LOG  the config curl read from its stdin (where the token is)
#   $FJ_LOG        "<METHOD> <url>"
#   $FJ_BODY_LOG   each request body, one line
#
# Knobs, read on every call:
#   STUB_FJ_HEAD       the PR's head sha (default: the fixture's, $FJ_FIXTURE_HEAD)
#   STUB_FJ_LOGIN      the PR author (default geoff, who is also GET /user)
#   STUB_FJ_STATE      open (default) | closed | merged
#   STUB_FJ_MERGEABLE  true | false (default the fixture's, true)
#   STUB_FJ_STATUSES   a JSON array of CommitStatus replacing the fixture's
#   STUB_FJ_PROT       main (an exact rule requiring `ci / test (pull_request)`,
#                      the default) | none (genuine 404, no matching glob) |
#                      glob | unreadable-glob | unnamed | denied | broken-404 |
#                      error | list-denied (genuine 404, rule list refused)
#   STUB_FJ_MERGE      ok (default) | conflict
#
# The token is minted per harness from /dev/urandom - a synthetic value, never
# a committed literal. CEL_FORGE_CURL is honoured only under CEL_TESTING,
# which tests/run.sh sets.
FJ_FIXTURE_HEAD=3c1f0e9a8b7d6c5e4f3a2b1c0d9e8f7a6b5c4d3e
_forgejo_stub() { # <dir>
  local d="$1"
  mkdir -p "$d/bin" "$d/config/cel/forge"
  FJ_TOKEN="synthetic-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s\n' "$FJ_TOKEN" > "$d/config/cel/forge/forgejo.internal.token"
  chmod 600 "$d/config/cel/forge/forgejo.internal.token"
  export CEL_TESTING=1 XDG_CONFIG_HOME="$d/config" FJX="$CEL_ROOT/tests/fixtures/forge/forgejo" FJ_TOKEN FJ_FIXTURE_HEAD
  export FJ_LOG="$d/fj.log" FJ_ARGV_LOG="$d/fj-argv.log" FJ_STDIN_LOG="$d/fj-stdin.log" FJ_BODY_LOG="$d/fj-body.log"
  : > "$FJ_LOG"; : > "$FJ_ARGV_LOG"; : > "$FJ_STDIN_LOG"; : > "$FJ_BODY_LOG"
  cat > "$d/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FJ_ARGV_LOG"
cat >> "$FJ_STDIN_LOG"
method=GET url="" body=""
while [ $# -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --data-binary) body="$(cat "${2#@}")"; shift 2 ;;
    --config|--proto|--max-time|--header|--write-out) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$FJ_LOG"
[ -z "$body" ] || printf '%s\n' "$body" >> "$FJ_BODY_LOG"
API=http://forgejo.internal/api/v1
R="$API/repos/geoff/gizmo"
path="${url%%\?*}" query=""
[ "$path" = "$url" ] || query="${url#*\?}"
page=1 state=open
[[ "$query" =~ (^|&)page=([0-9]+) ]] && page="${BASH_REMATCH[2]}"
[[ "$query" =~ (^|&)state=([a-z]+) ]] && state="${BASH_REMATCH[2]}"
say() { printf '%s\n%s' "$2" "$1"; exit 0; }   # <code> <body>, as --write-out '\n%{http_code}' would
pr() {
  jq -c --arg n "$1" --arg h "${STUB_FJ_HEAD:-}" --arg u "${STUB_FJ_LOGIN:-}" --arg s "${STUB_FJ_STATE:-open}" --arg m "${STUB_FJ_MERGEABLE:-}" '
    .number = ($n | tonumber) | .html_url = "http://forgejo.internal/geoff/gizmo/pulls/\($n)"
    | if $h != "" then .head.sha = $h else . end
    | if $u != "" then .user.login = $u else . end
    | if $s == "merged" then .state = "closed" | .merged = true elif $s == "closed" then .state = "closed" else . end
    | if $m != "" then .mergeable = ($m == "true") else . end' "$FJX/pull.json"
}
prot="${STUB_FJ_PROT:-main}"
case "$method $path" in
  "GET $API/user") say 200 "$(cat "$FJX/user.json")" ;;
  "GET $R/pulls")
    # three a page whatever `limit` asks, as a server with a lower
    # MAX_RESPONSE_ITEMS answers: a short page is not the last one
    say 200 "$(jq -cs --arg s "$state" --argjson p "$page" 'add | map(select($s == "all" or .state == $s)) | .[($p - 1) * 3:$p * 3]' \
      "$FJX/pulls-page1.json" "$FJX/pulls-page2.json")" ;;
  "POST $R/pulls")
    say 201 "$(jq -c --argjson b "$body" '.number = 32 | .title = $b.title | .head.ref = $b.head | .base.ref = $b.base
      | .draft = ($b.title | test("^(wip:|\\[wip\\])"; "i")) | .html_url = "http://forgejo.internal/geoff/gizmo/pulls/32"' "$FJX/pull.json")" ;;
  "GET $R/pulls/"*/reviews) [ "$page" = 1 ] && say 200 "$(cat "$FJX/reviews.json")"; say 200 '[]' ;;
  "POST $R/pulls/"*/merge) [ "${STUB_FJ_MERGE:-ok}" = ok ] && say 200 ''; say 409 "$(cat "$FJX/merge-conflict.json")" ;;
  "GET $R/pulls/"*) say 200 "$(pr "${path##*/}")" ;;
  "GET $R/commits/"*/status)
    [ "$page" = 1 ] || say 200 '{"statuses":[]}'
    [ -z "${STUB_FJ_STATUSES:-}" ] || say 200 "$(jq -c --argjson s "$STUB_FJ_STATUSES" '.statuses = $s' "$FJX/status.json")"
    say 200 "$(cat "$FJX/status.json")" ;;
  "GET $R/branch_protections/main")
    case "$prot" in
      main)       say 200 "$(cat "$FJX/protection-main.json")" ;;
      unnamed)    say 200 "$(cat "$FJX/protection-unnamed.json")" ;;
      denied)     say 403 "$(cat "$FJX/forbidden.json")" ;;
      broken-404) say 404 '<html><body>404 page not found</body></html>' ;;
      error)      say 500 '{"message":"database is locked"}' ;;
      *)          say 404 "$(cat "$FJX/not-found.json")" ;;
    esac ;;
  "GET $R/branch_protections")
    case "$prot" in
      none|broken-404) say 200 "$(cat "$FJX/protections-other.json")" ;;
      glob)            say 200 "$(cat "$FJX/protections-glob.json")" ;;
      unreadable-glob) say 200 "$(cat "$FJX/protections-unreadable-glob.json")" ;;
      unnamed)         say 200 "$(cat "$FJX/protections-unnamed.json")" ;;
      denied|list-denied) say 403 "$(cat "$FJX/forbidden.json")" ;;
      *)               say 200 "$(cat "$FJX/protections-main.json")" ;;
    esac ;;
esac
say 404 "$(cat "$FJX/not-found.json")"
SH
  chmod +x "$d/bin/curl"
  export CEL_FORGE_CURL="$d/bin/curl"
}
