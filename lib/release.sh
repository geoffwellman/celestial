# shellcheck shell=bash
# `cel release <product> <value>` - the plane cuts a release of something the
# factory MAKES. Releasing the plane itself is one ordinary instance of that,
# not the only meaning.
#
# Permission is checked locally BEFORE dispatch: a caller with only READ is
# told where releases of that product actually come from, instead of
# `gh workflow run` failing with a 403 at the last step.
#
# The plane owns no versioning semantics. A repo declares how it is released
# (lib/workspace.sh, `release:`) - which workflow, which input, what values
# that input accepts - and this file's whole job is to know WHICH workflow,
# dispatch it, follow it, and report what came out. The order of the work
# happening on GitHub is not a preference, it is what branch protection
# permits: main takes no direct pushes, so a version bump arrives as a PR, the
# tag follows its squash merge, and the Release is cut from the tag by the
# action.
[ -n "${_CEL_RELEASE:-}" ] && return 0
_CEL_RELEASE=1
# shellcheck source=lib/common.sh
. "${BASH_SOURCE[0]%/*}/common.sh"
# shellcheck source=lib/version.sh
. "${BASH_SOURCE[0]%/*}/version.sh"
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh"

# `die` exits the process it runs in - and a helper whose answer is captured
# with $(...) runs in a SUBSHELL, so a die there kills only the substitution
# and the caller carries on with an empty string. Every helper below that is
# read through $(...) therefore refuses this way instead: message on stderr,
# non-zero return, and the caller exits.
_rrefuse() { c_err "$*" >&2; return 1; }

_release_is_semver() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

# `owner/name`, which is what every `gh --repo` wants. Derived from the
# declared url so a workspace whose org differs from the repo's owner still
# addresses the right repository; the workspace org is the fallback, not the
# answer.
_release_slug() { # <wsdir> <repo>
  local org
  github_slug_from_url "$(ws_repo_get "$1" "$2" url)" && return 0
  org="$(ws_org "$1")"
  [ -n "$org" ] || _rrefuse "cel release: $2 declares no url and the workspace no org - cannot address the repository" || return 1
  printf '%s/%s' "$org" "$2"
}

_release_repo_dir() { printf '%s/repos/%s' "$1" "$2"; }

# The current version as the repo itself defines it: its version_file if it
# declares one and the checkout is here, otherwise the newest tag GitHub
# knows. Prints nothing when neither answers - a first release has no
# predecessor, and refusing one would be wrong.
_release_current() { # <wsdir> <repo> <slug>
  local vf dir tag pat pre suf v
  vf="$(ws_repo_release "$1" "$2" version_file)"
  dir="$(_release_repo_dir "$1" "$2")"
  if [ -n "$vf" ] && [ -f "$dir/$vf" ]; then
    head -n1 "$dir/$vf" | tr -d ' \t\r'
    return 0
  fi
  have gh || return 0
  tag="$(ws_gh "$1" api "repos/$3/tags" --jq '.[0].name' 2>/dev/null)" || tag=""
  [ -n "$tag" ] || return 0
  # The version is what the declared tag shape puts around it, read through
  # the WHOLE shape: `release-{version}-prod` reads `release-0.2.0-prod` as
  # 0.2.0, and a tag of any other shape says nothing about the version. With
  # no shape declared, a leading `v` is dropped.
  pat="$(ws_repo_release "$1" "$2" tag)"
  if [ -z "$pat" ]; then printf '%s' "${tag#v}"; return 0; fi
  case "$pat" in *'{version}'*) ;; *) return 0 ;; esac
  pre="${pat%%\{version\}*}"; suf="${pat#*\{version\}}"
  case "$tag" in "$pre"*"$suf") ;; *) return 0 ;; esac
  v="${tag#"$pre"}"; v="${v%"$suf"}"
  printf '%s' "$v"
}

_release_tag_for() { # <wsdir> <repo> <version>
  local pat; pat="$(ws_repo_release "$1" "$2" tag)"
  [ -n "$pat" ] || { printf '%s' "$3"; return 0; }
  printf '%s' "${pat//\{version\}/$3}"
}

# Every refusal that can be made without spending a run is made here, in this
# order: what the repo accepts, then whether it can possibly be a new version.
_release_check_value() { # <wsdir> <repo> <slug> <value>
  local accepts cur w
  accepts="$(ws_repo_release "$1" "$2" accepts)"
  [ -n "$4" ] || die "cel release: want a value for $2's '$(ws_repo_release "$1" "$2" input)' input"
  [ -n "$accepts" ] || return 0
  if [ "$accepts" = "semver" ]; then
    _release_is_semver "$4" \
      || die "cel release: '$4' is not a semver x.y.z version (no leading v) - $2 takes one"
    cur="$(_release_current "$1" "$2" "$3")"
    if [ -n "$cur" ] && _release_is_semver "$cur"; then
      cel_version_lt "$cur" "$4" || die "cel release: $4 is not greater than $2's current $cur"
    fi
    return 0
  fi
  for w in $accepts; do [ "$w" = "$4" ] && return 0; done
  die "cel release: $2 accepts $(printf '%s' "$accepts" | sed 's/ /, /g') - '$4' is none of them"
}

# Every release call acts for the workspace that owns the repo: ws_gh gives it
# that workspace's `github.user`, or plain `gh` without one - the box's gh
# either way (cel_gh_bin), never one the caller's PATH offers.
_release_gh() { # <wsdir-or-empty> <gh args...>
  local w="$1" bin; shift
  if [ -n "$w" ]; then ws_gh "$w" "$@"; return; fi
  bin="$(cel_gh_bin)" || return 1
  "$bin" "$@"
}

# THE REFUSAL THIS FILE EXISTS FOR. `gh` answers who you are on that repo, so
# a 403 is never the way a user finds out they cannot release someone else's
# product.
_release_check_permission() { # <slug> <product> [wsdir]
  local perm
  perm="$(_release_gh "${3:-}" repo view "$1" --json viewerPermission --jq '.viewerPermission' 2>/dev/null)" || perm=""
  case "$perm" in
    WRITE|MAINTAIN|ADMIN) return 0 ;;
  esac
  die "cel release: you have ${perm:-no access} on $1 - releases of $2 are cut by its maintainers; new versions reach you through cel update"
}

# The pending section, read out of the repo that declares a changelog. Read
# only: notes.py assembles fragments without consuming them, which is what
# makes this safe to print from --dry-run.
_release_pending_notes() { # <wsdir> <repo>
  local frag dir args=()
  dir="$(_release_repo_dir "$1" "$2")"
  frag="$(ws_repo_release "$1" "$2" changelog)"
  [ -n "$frag" ] || return 1
  [ -f "$dir/CHANGELOG.md" ] || return 1
  args=(--changelog "$dir/CHANGELOG.md")
  [ -d "$dir/${frag%/}" ] && args+=(--fragments "$dir/${frag%/}")
  python3 "$CEL_ROOT/tools/release/notes.py" unreleased "${args[@]}"
}

_release_dry_run() { # <wsdir> <repo> <slug> <product> <value>
  local wf input section
  wf="$(ws_repo_release "$1" "$2" workflow)"; input="$(ws_repo_release "$1" "$2" input)"
  c_hd "$4 would dispatch"
  printf '  repo      %s\n  workflow  %s\n  input     %s=%s\n' "$3" "$wf" "$input" "$5"
  _release_is_semver "$5" && printf '  tag       %s\n' "$(_release_tag_for "$1" "$2" "$5")"
  # A dry run exists to be read before spending a run, so a changelog that
  # will not assemble is exactly what it must SAY - swallowing the error here
  # hides the one problem this output could have caught.
  local rc=0
  if [ -n "$(ws_repo_release "$1" "$2" changelog)" ]; then
    section="$(_release_pending_notes "$1" "$2" 2>&1)" || rc=$?
    c_hd "pending section"
    if [ "$rc" -ne 0 ]; then
      c_warn "the notes do not assemble yet: $section"
    elif [ -z "$section" ]; then
      c_warn "nothing pending - the [Unreleased] section and the fragments are empty"
    else
      printf '%s\n' "$section"
    fi
  fi
  c_hd "the run will check"
  printf '  %s\n' \
    'whatever the workflow itself enforces (hygiene, the private vocabulary scan, the suite)' \
    "the value it was given: $input=$5"
  printf '\n  nothing was dispatched (--dry-run).\n'
  return 0
}

# Tail the run to its conclusion and say which release IT cut, because "the
# run is queued" is not an answer anybody can act on - and "the newest release"
# may be somebody else's. A version under a declared tag shape names its tag;
# otherwise it is the first release published after the run was created.
_release_follow() { # <wsdir> <repo> <slug> <run-id> <value>
  ws_gh "$1" run watch "$4" --repo "$3" --exit-status >/dev/null 2>&1 || c_warn "the run did not finish green"
  local tag="" since rel=""
  if _release_is_semver "$5" && [ -n "$(ws_repo_release "$1" "$2" tag)" ]; then
    tag="$(_release_tag_for "$1" "$2" "$5")"
  else
    since="$(ws_gh "$1" run view "$4" --repo "$3" --json createdAt --jq .createdAt 2>/dev/null)" || since=""
    [ -z "$since" ] || tag="$(ws_gh "$1" release list --repo "$3" --limit 20 --json tagName,publishedAt \
      --jq "[.[] | select((.publishedAt // \"\") >= \"$since\")] | last | .tagName // empty" 2>/dev/null)" || tag=""
  fi
  [ -z "$tag" ] || rel="$(ws_gh "$1" release view "$tag" --repo "$3" --json tagName,url \
    --jq '"\(.tagName) \(.url)"' 2>/dev/null)" || rel=""
  if [ -n "$rel" ]; then printf '  released  %s\n' "$rel"; else printf '  no GitHub Release was published by that run\n'; fi
}

# WHICH RUN IS OURS. gh names the run its dispatch created when GitHub returns
# it; otherwise ours is the one workflow_dispatch run by this account that was
# not listed before the dispatch. None yet, or more than one new, is not
# guessed at: following another run would report another release.
_release_dispatch_runs() { # <wsdir> <slug> <workflow> <actor> -> "id url" per run
  local by=(); [ -z "$4" ] || by=(--user "$4")
  ws_gh "$1" run list --workflow "$3" --repo "$2" --event workflow_dispatch "${by[@]}" --limit 20 \
    --json databaseId,url --jq '.[] | "\(.databaseId) \(.url)"' 2>/dev/null || true
}
_release_poll_secs() { if [ -n "${CEL_TESTING:-}" ]; then printf 0; else printf 3; fi; }

_release_dispatch() { # <wsdir> <repo> <slug> <product> <value> <follow> -> 1 when nothing was dispatched
  local wf input actor before out run="" fresh tries id url
  wf="$(ws_repo_release "$1" "$2" workflow)"; input="$(ws_repo_release "$1" "$2" input)"
  actor="$(ws_gh "$1" api user --jq .login 2>/dev/null)" || actor=""
  before="$(_release_dispatch_runs "$1" "$3" "$wf" "$actor")"
  out="$(ws_gh "$1" workflow run "$wf" --repo "$3" -f "$input=$5")" \
    || { c_err "cel release: could not dispatch $wf in $3"; return 1; }
  c_ok "dispatched $wf in $3 with $input=$5"
  url="$(printf '%s\n' "$out" | grep -oE 'https://[^[:space:]]+/actions/runs/[0-9]+' | head -n1 || true)"
  if [ -n "$url" ]; then
    run="${url##*/} $url"
  else
    # Following waits a little for the run to register; a script asks once.
    tries=1; [ "$6" = "1" ] && tries=10
    while :; do
      fresh="$(_release_dispatch_runs "$1" "$3" "$wf" "$actor" | grep -vxF -f <(printf '%s\n' "$before") || true)"
      [ -z "$fresh" ] || break
      tries=$((tries - 1)); [ "$tries" -gt 0 ] || break
      sleep "$(_release_poll_secs)"
    done
    if [ "$(printf '%s\n' "$fresh" | grep -c .)" -eq 1 ]; then run="$fresh"
    elif [ -n "$fresh" ]; then c_warn "more than one new $wf run appeared in $3 - not guessing which one this dispatch started"; fi
  fi
  id="${run%% *}"; url="${run#* }"
  if [ -n "$run" ]; then printf '  %s\n' "$url"; else
    printf '  the run is queued; watch it with: gh run list --workflow %s --repo %s\n' "$wf" "$3"
  fi
  [ "$6" = "1" ] && [ -n "$id" ] && _release_follow "$1" "$2" "$3" "$id" "$5"
  return 0
}

# --- status ------------------------------------------------------------------

_release_status_rows() { # <wsdir> [product] -> one tab-separated row per repo
  local wsdir="$1" product="${2:-}" repos=() r slug cur tag ahead flight newest
  if [ -n "$product" ]; then
    mapfile -t repos < <(ws_product_repos "$wsdir" "$product")
  else
    mapfile -t repos < <(ws_repo_names "$wsdir")
  fi
  for r in "${repos[@]}"; do
    ws_repo_releasable "$wsdir" "$r" || continue
    slug="$(_release_slug "$wsdir" "$r")"
    cur="$(_release_current "$wsdir" "$r" "$slug")"
    tag="$(_release_tag_for "$wsdir" "$r" "${cur:-0.0.0}")"
    ahead="$(ws_gh "$wsdir" api "repos/$slug/compare/$tag...HEAD" --jq '.ahead_by' 2>/dev/null)" || ahead=""
    flight="$(ws_gh "$wsdir" run list --repo "$slug" --workflow "$(ws_repo_release "$wsdir" "$r" workflow)" \
      --status in_progress --limit 1 --json url --jq '.[0].url' 2>/dev/null)" || flight=""
    # `gh release list` has no url field (it refuses the whole call when asked
    # for one); a release page is addressed by its repo and tag.
    newest="$(ws_gh "$wsdir" release list --repo "$slug" --limit 1 --json tagName \
      --jq '.[0].tagName // empty' 2>/dev/null)" || newest=""
    [ -z "$newest" ] || newest="$newest https://github.com/$slug/releases/tag/$newest"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(ws_name "$wsdir")" "$(ws_product_of_repo "$wsdir" "$r")" "$r" "$slug" \
      "${cur:-unknown}" "${ahead:-?}" "${flight:-}" "${newest:-}"
  done
}

_release_status() { # [product] [--all-workspaces] [--json]
  local product="" every=0 json=0 wsdir rows="" n p
  while [ $# -gt 0 ]; do
    case "$1" in
      --all-workspaces) every=1; shift ;;
      --json)           json=1; shift ;;
      -*) die "cel release status: unknown argument '$1'" ;;
      *)  [ -z "$product" ] || die "cel release status: one product at a time"; product="$1"; shift ;;
    esac
  done
  have gh || die "cel release status: gh is required"
  if [ "$every" -eq 1 ]; then
    [ -z "$product" ] || die "cel release status: --all-workspaces takes no product"
    for n in $(registry_names); do
      p="$(registry_path "$n")"
      [ -n "$p" ] && [ -f "$p/workspace.yaml" ] || continue
      rows+="$(_release_status_rows "$p")"$'\n'
    done
  else
    wsdir="$(ws_current "$PWD")" || die "cel release status: not inside a workspace"
    rows="$(_release_status_rows "$wsdir" "$product")"$'\n'
  fi
  rows="$(printf '%s' "$rows" | grep -v '^$' || true)"
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$rows" | jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
      | {workspace: .[0], product: .[1], repo: .[2], slug: .[3],
         current: .[4], commits_since: .[5], in_flight: .[6], newest: .[7]})'
    return 0
  fi
  if [ -z "$rows" ]; then
    c_warn "no repo here declares a release: block - see README"
    return 0
  fi
  c_hd "Releases"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r ws prod repo slug cur ahead flight newest; do
    printf '  %-14s %-12s current %-10s +%s commits\n' "$ws/$prod" "$repo" "$cur" "$ahead"
    [ -n "$newest" ] && printf '  %-27s newest  %s\n' "" "$newest"
    [ -n "$flight" ] && printf '  %-27s in flight %s\n' "" "$flight"
  done
  return 0
}

# --- the verb ----------------------------------------------------------------

# Which repo IS this product's release? Exactly one releasable repo answers it;
# more than one is a question only the caller can settle, and none is the
# "this product does not release" refusal.
_release_resolve_repo() { # <wsdir> <product> <explicit-repo> <value>
  local wsdir="$1" product="$2" want="$3" value="$4" r found=()
  while read -r r; do
    [ -n "$r" ] || continue
    ws_repo_releasable "$wsdir" "$r" && found+=("$r")
  done < <(ws_product_repos "$wsdir" "$product")
  if [ -n "$want" ]; then
    for r in "${found[@]}"; do [ "$r" = "$want" ] && { printf '%s' "$r"; return 0; }; done
    _rrefuse "cel release: --repo $want is not a releasable repo of $product"; return 1
  fi
  case "${#found[@]}" in
    1) printf '%s' "${found[0]}"; return 0 ;;
    0) _rrefuse "cel release: $product declares no release: block - see README"; return 1 ;;
    *) _rrefuse "cel release: $product has ${#found[@]} releasable repos ($(printf '%s ' "${found[@]}" | sed 's/ $//;s/ /, /g')) - name one: cel release $product $value --repo <name>"; return 1 ;;
  esac
}

# SHORTHAND. `cel release 0.3.0` with no product works wherever the current
# workspace has exactly one releasable repo. Anywhere else it refuses and names
# the form to use, rather than guessing which product the owner meant.
_release_only_product() { # <wsdir> <value>
  local wsdir="$1" r found=()
  while read -r r; do
    [ -n "$r" ] || continue
    ws_repo_releasable "$wsdir" "$r" && found+=("$r")
  done < <(ws_repo_names "$wsdir")
  [ "${#found[@]}" -eq 1 ] \
    || { _rrefuse "cel release: name what you are releasing: cel release <product> $2 (this workspace has ${#found[@]} releasable repos)"; return 1; }
  ws_product_of_repo "$wsdir" "${found[0]}"
}

cmd_release() { # <product> <value> [--repo r] [--dry-run] [--follow|--no-follow] | status
  local product="" value="" want="" dry=0 follow=-1 wsdir repo slug
  while [ $# -gt 0 ]; do
    case "$1" in
      status)      shift; _release_status "$@"; return $? ;;
      --dry-run)   dry=1; shift ;;
      --repo)      want="$2"; shift 2 ;;
      --follow)    follow=1; shift ;;
      --no-follow) follow=0; shift ;;
      -h|--help)   printf 'usage: cel release <product> <version|bump> [--repo <name>] [--dry-run]\n       cel release status [<product>] [--all-workspaces] [--json]\n'; return 0 ;;
      -*)          die "cel release: unknown argument '$1' (want <product> <value> or status)" ;;
      *)
        if [ -z "$product" ]; then product="$1"
        elif [ -z "$value" ]; then value="$1"
        else die "cel release: one product and one value at a time"; fi
        shift ;;
    esac
  done
  [ -n "$product" ] || die "cel release: want a product and a value, e.g. cel release widget 0.3.0"
  wsdir="$(ws_current "$PWD")" || die "cel release: not inside a workspace (cel ws list)"
  if [ -z "$value" ]; then
    value="$product"
    product="$(_release_only_product "$wsdir" "$value")" || exit 1
  fi

  repo="$(_release_resolve_repo "$wsdir" "$product" "$want" "$value")" || exit 1
  slug="$(_release_slug "$wsdir" "$repo")" || exit 1
  _release_check_value "$wsdir" "$repo" "$slug" "$value"
  if [ "$dry" -eq 1 ]; then _release_dry_run "$wsdir" "$repo" "$slug" "$product" "$value"; return $?; fi

  have gh || die "cel release: gh is required to dispatch the workflow"
  _release_check_permission "$slug" "$product" "$wsdir"
  # UNDER AFK a release goes only where the owner named it first, and the log
  # records whether the dispatch happened, once it was tried.
  # shellcheck source=lib/afk.sh
  . "${BASH_SOURCE[0]%/*}/afk.sh"
  local afk=0 rc=0
  if afk_active; then
    afk_admit release "$(jq -nc --arg p "$product" --arg v "$value" '{product:$p, version:$v}')" \
      || die "cel release: AFK did not authorise this release - see the refusal above. Nothing dispatched."
    afk=1
  fi
  # Following is the useful default where someone is watching; in a script it
  # would just hold the pipeline open.
  [ "$follow" -eq -1 ] && { [ -t 1 ] && follow=1 || follow=0; }
  _release_dispatch "$wsdir" "$repo" "$slug" "$product" "$value" "$follow" || rc=$?
  if [ "$afk" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then
      afk_record release "$(afk_authorisation release)" "$product@$value dispatched" completed
    else
      afk_record release "$(afk_authorisation release)" "$product@$value - the dispatch failed; nothing was released" failed
    fi
  fi
  [ "$rc" -eq 0 ] || exit 1
}
