# shellcheck shell=bash
# cel people - who is who in a team workspace, and which person this login is.
#
# `people:` in workspace.yaml (committed) names each person: an id, their
# forge login, roles held workspace-wide and per product. `me: <id>` in this
# login's own workspace.local.yaml (gitignored) says which of them this login
# is. `products[].home: <id>` names the person whose login runs a product's
# agents. The readers are in lib/workspace.sh (ws_people_json, ws_me,
# ws_person_holds, ws_role_holders, ws_product_home, ws_product_home_check);
# this file shows them, and asks the forge who this login is for doctor.
[ -n "${_CEL_PEOPLE:-}" ] && return 0
_CEL_PEOPLE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/forge.sh
. "${BASH_SOURCE[0]%/*}/forge.sh"

# THIS LOGIN'S OWN FORGE ACCOUNT - what `me:` is checked against. Never the
# workspace's `github.user`: that is the account the workspace's AGENTS act
# as, shared by every teammate who sets it, so it cannot tell two people
# apart. GitHub is asked with GH_TOKEN and GITHUB_TOKEN removed, so gh
# answers with this box's active account; Forgejo is asked with this login's
# own token (lib/forge.sh: one per unix login). The forge is the one of the
# workspace's first repo. Prints nothing when it cannot tell.
people_forge_login() { # <wsdir> -> login, or nothing
  local wsdir="$1" repo="" provider="" bin repos
  mapfile -t repos < <(ws_repo_names "$wsdir" 2>/dev/null)
  [ "${#repos[@]}" -eq 0 ] || repo="${repos[0]}"
  if [ -n "$repo" ]; then
    provider="$(forge_repo "$wsdir" "$repo" "$wsdir/repos/$repo" 2>/dev/null | jq -r '.provider // ""' 2>/dev/null)" || provider=""
  fi
  case "$provider" in
    forgejo)
      forge_whoami "$wsdir" "$repo" 2>/dev/null | jq -r '.login // ""' 2>/dev/null || true ;;
    *)
      bin="$(cel_gh_bin 2>/dev/null)" || return 0
      ( unset GH_TOKEN GITHUB_TOKEN; cel_gh_run "$bin" api user --jq .login 2>/dev/null ) || true ;;
  esac
}

# The document both views print: every person with this login marked, the
# products each one is home of, and every product's home (null: no home, so
# any login may start it).
_people_json() { # <wsdir>
  local wsdir="$1" homes='[]' p h
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    h="$(ws_product_home "$wsdir" "$p")"
    homes="$(jq -c --arg p "$p" --arg h "$h" '. + [{product: $p, home: (if $h == "" then null else $h end)}]' <<< "$homes")"
  done < <(ws_product_names "$wsdir")
  jq -n --arg ws "$(ws_name "$wsdir")" --arg me "$(ws_me "$wsdir")" \
    --argjson people "$(ws_people_json "$wsdir")" --argjson homes "$homes" '
    ($homes | map(select(.home != null))) as $h
    | {workspace: $ws,
       me: (if $me == "" then null else $me end),
       people: [$people[] | {id, login: (.login // null), roles: (.roles // []), products: (.products // {}),
                             me: (.id == $me),
                             home_of: [.id as $i | $h[] | select(.home == $i) | .product]}],
       homes: $homes}'
}

_people_usage() {
  cat <<'EOS'
usage: cel people [--workspace <name>] [--json]

  who is who in this workspace: each person in workspace.yaml's people:, their
  forge login and roles (workspace-wide, then per product), which person this
  login is (me: in its own workspace.local.yaml), and which login runs each
  product's agents (products[].home). Read-only.
EOS
}

cmd_people() { # [--workspace w] [--json]
  local workspace="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) [ $# -ge 2 ] || die "cel people: --workspace needs a name"; workspace="$2"; shift 2 ;;
      --json) json=1; shift ;;
      -h|--help) _people_usage; return 0 ;;
      *) die "cel people: unknown argument '$1' (see cel people --help)" ;;
    esac
  done
  have jq || die "cel people: jq is not on PATH"
  local wsdir
  if [ -n "$workspace" ]; then
    wsdir="$(registry_require "$workspace")"
  else
    wsdir="$(ws_current)" || die "cel people: not inside a workspace (cd into one, or pass --workspace <name>)"
  fi
  local doc; doc="$(_people_json "$wsdir")"
  if [ "$json" -eq 1 ]; then printf '%s\n' "$doc"; return 0; fi

  local name me n
  name="$(jq -r .workspace <<< "$doc")"
  me="$(jq -r '.me // ""' <<< "$doc")"
  n="$(jq -r '.people | length' <<< "$doc")"
  if [ "$n" -eq 0 ]; then
    c_warn "workspace '$name' declares no people"
    printf '\nAdd them to %s/workspace.yaml, and say which one you are in\nyour own workspace.local.yaml (me: sam):\n\n' "$wsdir"
    cat <<'EOS'
  people:
    - id: sam                     # what homes, decisions and sign-offs name
      login: sam-example          # their forge login
      roles: [owner, approver]    # workspace-wide: owner product-lead qa design release approver
      products: { atlas: [qa] }   # per product
  products:
    - name: atlas
      home: sam                   # only sam's login starts atlas's agents
EOS
    [ -z "$me" ] || printf '\nThis login says it is %s (workspace.local.yaml me:), but nobody is declared.\n' "$me"
    return 0
  fi
  if [ -z "$me" ]; then
    printf '%s: %s people; this login names no person (set me: <id> in %s/workspace.local.yaml)\n\n' "$name" "$n" "$wsdir"
  elif jq -e --arg m "$me" 'any(.people[]; .id == $m)' <<< "$doc" >/dev/null; then
    printf '%s: %s people; this login is %s\n\n' "$name" "$n" "$me"
  else
    printf "%s: %s people; this login says it is %s (me:), who is not in people: - run cel doctor\n\n" "$name" "$n" "$me"
  fi
  # One line per person: '*' marks this login; roles workspace-wide first,
  # then per product.
  jq -r '.people[] | [(if .me then "*" else " " end), .id, (.login // "-"),
      ([(if (.roles | length) > 0 then (.roles | join(", ")) else empty end),
        (.products | to_entries[] | "\(.key): \(.value | join(", "))")] | join("; ") | if . == "" then "-" else . end)]
    | @tsv' <<< "$doc" | while IFS=$'\t' read -r mark id login roles; do
      printf '  %s %-16s %-24s %s\n' "$mark" "$id" "$login" "$roles"
    done
  printf '\nwho runs each product'"'"'s agents (products[].home):\n'
  jq -r --arg m "$me" '.homes[] | [.product, (.home // "")] | @tsv' <<< "$doc" | while IFS=$'\t' read -r p h; do
    if [ -z "$h" ]; then
      printf '  %-16s any login (no home)\n' "$p"
    elif [ "$h" = "$me" ]; then
      printf '  %-16s this login (%s)\n' "$p" "$h"
    else
      printf "  %-16s runs on %s's login - not started here\n" "$p" "$h"
    fi
  done
}
