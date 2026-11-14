# shellcheck shell=bash
# cel solo - the review record and the merge door for a SOLO product's PRs.
#
# A solo product's PRs are opened directly by its one agent, and the PR itself
# is the key for the two acts on them:
#
#   cel solo review <repo>#<n> approved|changes|blocked --head <sha> --by <alias>
#   cel solo land   <repo>#<n>
#
# `land` proves policy, ownership, an approval for the exact head from every
# reviewer the workspace's review policy requires (the plain reviewer, and
# each extra one review.extra names for the files the PR touches -
# lib/review-policy.sh), no red check, no conflict, and every protected
# check green on that head, using the shared checks in lib/land.sh, and
# merges only that
# head. Protected CI on the exact head is the preferred evidence; when the base
# branch has no required checks, the repo gate runs locally in a clean
# checkout at exactly that head instead (_solo_local_gate).
#
# Both speak to the PR's forge through lib/forge.sh, so a repo on GitHub and
# a repo on Forgejo land the same way; the verdict itself lives here, in
# Celestial's own file, whichever forge serves the repo.
[ -n "${_CEL_SOLO:-}" ] && return 0
_CEL_SOLO=1
# shellcheck source=lib/mode.sh
. "${BASH_SOURCE[0]%/*}/mode.sh"   # _mode_product, ws_build_mode, cmd_run plumbing
# shellcheck source=lib/land.sh
. "${BASH_SOURCE[0]%/*}/land.sh"
# shellcheck source=lib/afk.sh
. "${BASH_SOURCE[0]%/*}/afk.sh"
# shellcheck source=lib/guard.sh
. "${BASH_SOURCE[0]%/*}/guard.sh"  # guard_role_of: who is asking to land
# shellcheck source=lib/forge.sh
. "${BASH_SOURCE[0]%/*}/forge.sh"  # forge_*: the PR, its checks, reviews and merge
# shellcheck source=lib/review-policy.sh
. "${BASH_SOURCE[0]%/*}/review-policy.sh"  # review_extra_required: the extra reviewers a PR needs
# shellcheck source=lib/preview.sh
. "${BASH_SOURCE[0]%/*}/preview.sh"  # _preview_name/_preview_meta: a QA agent's preview record

# Evidence whose name says it is an image must be one: its first bytes are
# that format's signature. Other files (logs, recordings) pass by name.
_solo_evidence_type_ok() { # <file>
  local magic
  magic="$(head -c 12 -- "$1" | od -An -tx1 | tr -d ' \n')"
  case "${1,,}" in
    *.png)         [[ "$magic" == 89504e470d0a1a0a* ]] ;;
    *.jpg|*.jpeg)  [[ "$magic" == ffd8ff* ]] ;;
    *.webp)        [[ "$magic" == 52494646????????57454250 ]] ;;
    *.gif)         [[ "$magic" == 47494638* ]] ;;
    *) return 0 ;;
  esac
}

# One verdict per reviewer of a PR, beside the workspace's other state: the
# plain reviewer's keyed `<repo>#<n>`, an extra agent's `<repo>#<n>/<slot>`
# (`widget#7/review-security`, `widget#7/qa-browser`, lib/review-policy.sh).
# A QA agent's verdict also lists its evidence, copied under
# .cel/qa-evidence/<repo>-pr-<n>/<slot>/ so it outlives the agent's checkout.
_solo_reviews() { printf '%s' "$1/.cel/solo-reviews.json"; }
_solo_review_key() { printf '%s#%s%s' "$1" "$2" "${3:+/$3}"; } # <repo> <pr> [slot]

# Every read-modify-write of the verdict file holds its lock, so two reviewers
# recording at once cannot drop each other's verdict. A file that does not
# parse as an object is NOT silently replaced - that would erase every other
# PR's verdict - it is moved aside to `.corrupt-<time>` and the refusal says so.
_solo_reviews_update() { # <wsdir> <jq args...> <program>
  local wsdir="$1"; shift
  local f; f="$(_solo_reviews "$wsdir")"
  mkdir -p "$(dirname "$f")" || return 1
  (
    flock -w 30 9 || { c_err "cel solo: $f is locked by another review - try again"; exit 1; }
    local cur='{}' tmp
    if [ -s "$f" ]; then
      cur="$(jq -ce 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null)" || {
        local aside; aside="$f.corrupt-$(date -u +%Y%m%dT%H%M%SZ)"
        mv -f -- "$f" "$aside"
        c_err "cel solo: $f did not parse - moved aside to $aside; nothing recorded, record the verdict again"
        exit 1
      }
    fi
    tmp="$(mktemp "$f.tmp.XXXXXX")" || exit 1
    printf '%s' "$cur" | jq "$@" > "$tmp" && [ -s "$tmp" ] && mv -f -- "$tmp" "$f" \
      || { rm -f -- "$tmp"; exit 1; }
  ) 9>"$f.lock"
}

solo_review_get() { # <wsdir> <repo> <pr> [slot] -> the verdict object, or nothing
  jq -c --arg k "$(_solo_review_key "$2" "$3" "${4:-}")" '.[$k] // empty' "$(_solo_reviews "$1")" 2>/dev/null || true
}

# THE PLAIN REVIEWER'S WORD ON <head>: `approved` when its recorded verdict
# approves exactly that head or the forge's own review decision is an
# approval, else `changes` (a recorded change request at that head, or the
# forge's), `stale` (a verdict for another head) or `none`. The forge is asked
# only when the recorded verdict is not an approval of the head.
solo_plain_approval() { # <wsdir> <repo> <pr> <head> -> approved|changes|stale|none
  local v rd
  v="$(solo_review_get "$1" "$2" "$3")"
  if [ "$(printf '%s' "$v" | jq -r 'if .verdict == "approved" then .head else "" end' 2>/dev/null)" = "$4" ]; then
    printf approved; return 0
  fi
  rd="$(_solo_forge forge_pr_reviews "$1" "$2" "$3" 2>/dev/null | jq -r '.decision // ""' 2>/dev/null)" || rd=""
  case "$rd" in approved) printf approved; return 0 ;; changes_requested) printf changes; return 0 ;; esac
  printf '%s' "$v" | jq -r --arg h "$4" 'if type != "object" then "none" elif .head != $h then "stale"
    elif .verdict == "changes" then "changes" else "none" end' 2>/dev/null || printf none
}

# THE EXTRA AGENTS' WORD ON <head>, by the review policy as it stands now
# and the files the PR touches now (review_extra_required) - never by what
# was started. Extra reviewers and QA agents alike (lib/review-policy.sh);
# a QA agent's `blocked` (it could not run the change) is never an approval.
# One object:
#   required  each extra agent the policy requires: its match (kind, slot,
#             focus, because, files), its alias, its recorded verdict (or
#             null) and `state`: approved | changes | blocked | stale (a
#             verdict for another head) | missing (none, or one recorded by
#             anyone but that agent)
#   advisory  each extra agent with a verdict on record that the policy
#             does not require (started by hand with --focus or --qa):
#             kind, slot, focus, alias, verdict, state
#   blocking  the advisory ones whose verdict is `changes` at <head>: a
#             specialist's finding at the head being merged is a finding,
#             whoever asked for the specialist (an advisory `blocked` says
#             nothing about the change, and holds nothing up)
#   ok        every required one approved <head>, and nothing blocks
# A policy, file list or verdict file that cannot be read fails (status 1,
# the reason on stderr): absence of evidence is not an approval.
solo_extra_approvals() { # <wsdir> <repo> <pr> <head> -> JSON
  local wsdir="$1" repo="$2" pr="$3" head="$4" req f verdicts='{}' slots s info='{}' kind focus clash
  req="$(_solo_forge review_extra_required "$wsdir" "$repo" "$pr")" || return 1
  f="$(_solo_reviews "$wsdir")"
  if [ -s "$f" ]; then
    verdicts="$(jq -ce 'if type == "object" then . else error("not an object") end' "$f" 2>/dev/null)" \
      || { printf '%s does not parse - no verdict on record can be read\n' "$f" >&2; return 1; }
  fi
  slots="$(jq -nr --argjson req "$req" --argjson v "$verdicts" --arg k "$(_solo_review_key "$repo" "$pr")/" '
    ([$req[].slot] + [$v | keys[] | select(startswith($k)) | ltrimstr($k)]) | unique[]')"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    kind="$(review_slot_kind "$s")" focus="$(review_slot_focus "$s")"
    # A reviewer whose alias is cut into another's can never be started
    # (cel run reviewer refuses it), so nothing can ever satisfy its slot.
    clash="$(review_alias_free "$repo" "$pr" "$focus" "$kind")" || true
    info="$(jq -c --arg s "$s" --arg k "$kind" --arg f "$focus" --arg a "$(review_alias "$repo" "$pr" "$focus" "$kind")" \
      --arg c "$clash" '.[$s] = {kind: $k, focus: $f, alias: $a} + (if $c != "" then {unstartable: $c} else {} end)' <<<"$info")"
  done <<<"$slots"
  jq -nc --argjson req "$req" --argjson v "$verdicts" --argjson in "$info" \
    --arg k "$(_solo_review_key "$repo" "$pr")/" --arg h "$head" '
    def st($r; $a): if ($r | type) != "object" or ($r.by // "") != $a then "missing"
      elif $r.head != $h then "stale"
      elif $r.verdict == "approved" then "approved"
      elif $r.verdict == "changes" then "changes"
      elif $r.verdict == "blocked" then "blocked" else "missing" end;
    ([$req[].slot]) as $rs
    | { required: [$req[] | ($v[$k + .slot]) as $r | $in[.slot] as $i
                   | . + {alias: $i.alias, verdict: $r, state: st($r; $i.alias)}
                   + (if $i.unstartable then {unstartable: $i.unstartable} else {} end)],
        advisory: [$v | to_entries[] | select(.key | startswith($k)) | (.key | ltrimstr($k)) as $s
                   | select($rs | index($s) | not) | $in[$s] as $i
                   | {kind: $i.kind, slot: $s, focus: $i.focus, alias: $i.alias, verdict: .value, state: st(.value; $i.alias)}] }
    | .blocking = [.advisory[] | select(.state == "changes")]
    | .ok = (all(.required[]; .state == "approved") and (.blocking | length) == 0)'
}

# What an extra agent is, in a refusal: `focus security` for a reviewer,
# `qa browser` for a QA agent.
_SOLO_JQ_WHAT='def extra_what: if .kind == "qa" then "qa \(.focus)" else "focus \(.focus)" end;
  def extra_start($repo; $n): if .kind == "qa" then "cel run reviewer --repo \($repo) --pr \($n) --qa \(.focus)"
    else "cel run reviewer --repo \($repo) --pr \($n) --focus \(.focus)" end;'

# What each extra agent that stands in the way still owes, one line each,
# with the command that starts it (or reuses it, when it is live).
solo_extra_gaps() { # <extra-approvals-json> <repo> <pr> <head>
  printf '%s' "$1" | jq -r --arg repo "$2" --arg n "$3" --arg h "${4:0:12}" "$_REVIEW_JQ_WHY$_SOLO_JQ_WHAT"'
    (.required[] | select(.state != "approved") | extra_start($repo; $n) as $start
       | "\(.alias) (\(extra_what); \(review_why)) "
         + (if .unstartable then "can never be started, so this PR cannot land: \(.unstartable). Shorten the repo name in workspace.yaml (or move the PR to a repo with a shorter one), or drop \(.focus) from review.extra for these paths"
            elif .state == "changes" then "asked for changes at \($h) - address its findings, push, and ask it to re-review the new head (cel inbox send \(.alias))"
            elif .state == "blocked" then "could not run the change at \($h): \(.verdict.note // "no reason given") - fix what stopped it (the repo'"'"'s preview: in workspace.yaml, the box) and ask it to try again (cel inbox send \(.alias)); blocked is not an approval"
            elif .state == "stale" then "has a verdict for head \((.verdict.head // "?")[0:12]), not \($h) - ask it to re-review the current head, or start it: \($start)"
            elif (.verdict | type) == "object" then "has no verdict of its own (the one on record is by \(.verdict.by // "nobody")) - start it: \($start)"
            else "has recorded no verdict - start it: \($start)" end)),
      (.blocking[] | "\(.alias) (\(extra_what); started by hand, not required by policy) asked for changes at \($h) - a finding at the head being merged blocks it: address it, push, and ask it to re-review")'
}

# A solo product's PRs that `cel solo land` would merge right now - by the
# same rules, never looser, or the steward would nag about a PR land refuses:
# merge: self, the PR opened by this workspace's account on its forge, open,
# not a draft, not conflicting, every check concluded and none red, approved
# at its exact current head by every reviewer the review policy requires (the
# plain one - the forge's review decision or the recorded verdict - and each
# extra one, solo_extra_approvals: the rule `cel solo land` applies), and
# land_ci_gate passing (every required check green on that
# head). GitHub and Forgejo repos alike, through lib/forge.sh. One
# `<repo><TAB><pr><TAB><head>` line each. The steward nudges the product's
# agent with these; it never lands them itself. A forge that cannot be read
# yields nothing for that repo - silence, never a guess.
solo_ready_prs() { # <wsdir> <product>
  local wsdir="$1" product="$2" repo prs pr num head checks
  [ "$(ws_policy "$wsdir" merge)" = self ] || return 0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    prs="$(_solo_forge forge_pr_list "$wsdir" "$repo" open --author @me --limit 50 2>/dev/null)" || continue
    while IFS= read -r pr; do
      [ -n "$pr" ] || continue
      num="$(printf '%s' "$pr" | jq -r .number)" head="$(printf '%s' "$pr" | jq -r .head_sha)"
      [ "$(solo_plain_approval "$wsdir" "$repo" "$num" "$head")" = approved ] || continue
      solo_extra_approvals "$wsdir" "$repo" "$num" "$head" 2>/dev/null | jq -e '.ok' >/dev/null 2>&1 || continue
      checks="$(_solo_forge forge_pr_checks "$wsdir" "$repo" "$num" 2>/dev/null)" || continue
      printf '%s' "$checks" | jq -e --arg h "$head" '.head_sha == $h and (.checks | length > 0)
        and all(.checks[]; .status == "completed" and (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral"))' >/dev/null 2>&1 \
        || continue
      land_ci_gate "$wsdir" "$repo" "$pr" >/dev/null || continue
      printf '%s\t%s\t%s\n' "$repo" "$num" "$head"
    done < <(printf '%s' "$prs" | jq -c '.[]? | select(.draft == false and .mergeable != "conflicting")
      | select((.head_sha // "") | test("^[0-9a-f]{40}$"))' 2>/dev/null || true)
  done < <(ws_product_repos "$wsdir" "$product")
}

# `<repo>#<n>` or a bare `<n>` when the product has exactly one repo. Sets
# SOLO_WSDIR, SOLO_PRODUCT, SOLO_REPO, SOLO_PR; refuses a repo that is not in
# a solo product.
_solo_resolve() { # <ref> <workspace-or-empty>
  local ref="$1" workspace="$2" repo="" pr=""
  if [ -n "$workspace" ]; then
    SOLO_WSDIR="$(registry_require "$workspace")"
  elif ! SOLO_WSDIR="$(ws_current)"; then
    [ -n "${CEL_INBOX_WS:-}" ] || die "cel solo: not inside a workspace (cd into one, or pass --workspace <name>)"
    SOLO_WSDIR="$(registry_require "$CEL_INBOX_WS")"
  fi
  case "$ref" in
    *#*) repo="${ref%%#*}"; pr="${ref#*#}" ;;
    *)   pr="$ref" ;;
  esac
  [[ "$pr" =~ ^[0-9]+$ ]] || die "cel solo: '$ref' is not <repo>#<pr-number>"
  if [ -z "$repo" ]; then
    local product; product="$(_mode_product "$SOLO_WSDIR")"
    [ -n "$product" ] || die "cel solo: which repo? write it as <repo>#$pr"
    local -a rs; mapfile -t rs < <(ws_product_repos "$SOLO_WSDIR" "$product")
    [ "${#rs[@]}" -eq 1 ] || die "cel solo: product '$product' has ${#rs[@]} repos - write it as <repo>#$pr"
    repo="${rs[0]}"
  fi
  ws_repo_names "$SOLO_WSDIR" | grep -qxF "$repo" \
    || die "cel solo: '$repo' is not a repo of workspace '$(ws_name "$SOLO_WSDIR")'"
  SOLO_PRODUCT="$(ws_product_of_repo "$SOLO_WSDIR" "$repo")"
  [ "$(ws_build_mode "$SOLO_WSDIR" "$SOLO_PRODUCT")" = solo ] \
    || die "cel solo: '$repo' belongs to '$SOLO_PRODUCT', which is not in solo mode - fan-out was retired on 2026-11-08: build in the product's solo agent (feature teams are coming)"
  SOLO_REPO="$repo"; SOLO_PR="$pr"
}

# Forge calls go through gh as GH when a caller (a test) set it,
# as lib/land.sh's do.
_solo_forge() { CEL_FORGE_GH="${GH:-gh}" "$@"; }

cmd_solo_review() { # <ref> <approved|changes|blocked> --head <sha> --by <alias> [--focus F | --qa F [--evidence FILE]...] [--note T] [--workspace W]
  local usage="usage: cel solo review <repo>#<pr> <approved|changes|blocked> --head <full-40-char-sha> --by <reviewer-alias> [--focus FOCUS | --qa FOCUS [--evidence FILE]...] [--note TEXT] [--workspace NAME]"
  [ $# -ge 2 ] || die "$usage"
  # THE AUTHOR DOES NOT APPROVE ITS OWN WORK. A solo agent wrote the PR; a
  # verdict it recorded itself would make the review a formality and let it
  # land unreviewed code. Its reviewer pane records the verdict.
  [ "${CEL_ROLE:-}" != solo ] \
    || die "cel solo review: a solo agent does not review its own PR - its reviewer (cel run reviewer --repo <repo> --pr <n>) records the verdict"
  local ref="$1" verdict="$2"; shift 2
  local by="" note="" workspace="" head="" head_given=0 focus="" qa=""
  local -a evidence=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --by)        [ $# -ge 2 ] || die "$usage"; by="$2"; shift 2 ;;
      --note)      [ $# -ge 2 ] || die "$usage"; note="$2"; shift 2 ;;
      --head)      [ $# -ge 2 ] || die "$usage"; head="$2"; head_given=1; shift 2 ;;
      --focus)     [ $# -ge 2 ] || die "$usage"; focus="$2"; shift 2 ;;
      --qa)        [ $# -ge 2 ] || die "$usage"; qa="$2"; shift 2 ;;
      --evidence)  [ $# -ge 2 ] || die "$usage"; evidence+=("$2"); shift 2 ;;
      --workspace) [ $# -ge 2 ] || die "$usage"; workspace="$2"; shift 2 ;;
      *) die "cel solo review: unknown argument: $1" ;;
    esac
  done
  # Attributed, and
  # bound to the exact commit the reviewer read - never inferred.
  case "$verdict" in approved|changes|blocked) ;; *) die "cel solo review: verdict must be approved, changes or blocked (got: $verdict)";; esac
  [ -z "$focus" ] || [ -z "$qa" ] || die "cel solo review: --focus and --qa name two different agents (an extra reviewer, a QA agent) - give the one you are. Nothing recorded"
  # BLOCKED is a QA agent's word: it could not run the change (no preview
  # declared, a build that will not start, no browser). A code reviewer can
  # always read the code, so it has no such verdict.
  [ "$verdict" != blocked ] || [ -n "$qa" ] \
    || die "cel solo review: blocked is a QA agent's verdict (--qa) - it could not run the change; a reviewer reads the code and says approved or changes. Nothing recorded"
  [ "${#evidence[@]}" -eq 0 ] || [ -n "$qa" ] \
    || die "cel solo review: --evidence is a QA agent's (--qa) - a reviewer's findings travel by inbox. Nothing recorded"
  [ -n "$by" ] || die "cel solo review: --by <reviewer-alias> is required - an unattributed verdict is not a review"
  [ "$head_given" -eq 1 ] || die "cel solo review: --head <full-40-char-commit-sha> is required - the verdict covers the commit you reviewed"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "cel solo review: --head must be a full 40-character lowercase commit SHA (got: '$head')"
  _solo_resolve "$ref" "$workspace"
  cel_assert_reviewer_identity "$by" "$SOLO_WSDIR" "$SOLO_REPO" "$SOLO_PR" \
    || die "cel solo review: caller does not match the reviewer identity - nothing recorded"
  # AN EXTRA REVIEWER'S VERDICT IS ITS OWN, from the reviewer launched for
  # that focus: `cel solo land` counts it only from exactly that alias, so it
  # is recorded only by a caller whose launch line said it is that reviewer
  # (CEL_ROLE=reviewer, CEL_INBOX_ME the alias). AND A REVIEWER SIGNS ONLY AS
  # ITSELF: on the plain slot too, a caller launched as a reviewer must give
  # --by equal to its own mailbox, so a focus reviewer cannot write the plain
  # verdict under the plain alias. On herdr this identity is the launch
  # environment - the same trust as the author guard above, which any process
  # on the box could imitate; a Rex reviewer is bound to its PR and alias by
  # cel_assert_reviewer_identity (its receipt).
  local slot="" f k
  if [ -n "$focus" ]; then
    review_focus_valid "$focus" || die "cel solo review: $(review_focus_refusal "$focus") - nothing recorded"
    [ "$by" = "$(review_alias "$SOLO_REPO" "$SOLO_PR" "$focus")" ] \
      || die "cel solo review: the $focus reviewer of $SOLO_REPO#$SOLO_PR is $(review_alias "$SOLO_REPO" "$SOLO_PR" "$focus"), not '$by' - nothing recorded"
    [ "${CEL_ROLE:-}" = reviewer ] && [ "${CEL_INBOX_ME:-}" = "$by" ] \
      || die "cel solo review: a $focus verdict is recorded by the reviewer started for it (cel run reviewer --repo $SOLO_REPO --pr $SOLO_PR --focus $focus), from its own pane - nothing recorded"
    slot="$(review_slot "$focus")"
  elif [ -n "$qa" ]; then
    # A QA AGENT'S VERDICT, by the same rule: only from the QA agent started
    # for that focus, under its alias (lib/review-policy.sh).
    review_focus_valid "$qa" qa || die "cel solo review: $(review_focus_refusal "$qa" qa) - nothing recorded"
    [ "$by" = "$(review_alias "$SOLO_REPO" "$SOLO_PR" "$qa" qa)" ] \
      || die "cel solo review: the $qa QA agent of $SOLO_REPO#$SOLO_PR is $(review_alias "$SOLO_REPO" "$SOLO_PR" "$qa" qa), not '$by' - nothing recorded"
    [ "${CEL_ROLE:-}" = reviewer ] && [ "${CEL_INBOX_ME:-}" = "$by" ] \
      || die "cel solo review: a $qa QA verdict is recorded by the QA agent started for it ($(review_start_cmd "$SOLO_REPO" "$SOLO_PR" "$qa" qa)), from its own pane - nothing recorded"
    slot="$(review_slot "$qa" qa)"
  else
    for k in $REVIEW_KINDS; do
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$by" != "$(review_alias "$SOLO_REPO" "$SOLO_PR" "$f" "$k")" ] || {
          [ "$k" = qa ] && die "cel solo review: $by is the $f QA agent - record its verdict with --qa $f. Nothing recorded"
          die "cel solo review: $by is the $f reviewer - record its verdict with --focus $f. Nothing recorded"
        }
      done < <(review_focus_names "$k")
    done
    if [ "${CEL_ROLE:-}" = reviewer ] && [ -n "${CEL_INBOX_ME:-}" ]; then
      [ "$by" = "$CEL_INBOX_ME" ] \
        || die "cel solo review: you are $CEL_INBOX_ME, not '$by' - a reviewer records only its own verdict (an extra reviewer's with --focus, a QA agent's with --qa). Nothing recorded"
    fi
  fi
  # A QA VERDICT SHOWS WHAT IT SAW. `approved` and `changes` carry at least
  # one evidence file (a screenshot, a recording, a log): a regular file, not
  # a symlink, not empty, an image in fact when its name says png/jpg/webp/gif,
  # and named with the head it shows. And they stand on a run of that head:
  # this slot's own preview (`cel preview --qa <focus> --head <sha>`, its
  # record's qa and head) must be on record when the verdict is. `blocked`
  # says why in --note instead.
  local h12="${head:0:12}" e
  if [ -n "$qa" ]; then
    [ "$verdict" != blocked ] || [ -n "$note" ] \
      || die "cel solo review: a blocked verdict says why - --note \"<what stopped you running the change>\". Nothing recorded"
    if [ "$verdict" != blocked ]; then
      [ "${#evidence[@]}" -gt 0 ] \
        || die "cel solo review: a QA $verdict verdict needs --evidence <file> (a screenshot or recording of what you saw, named with the head it shows, e.g. login-$h12.png). Nothing recorded"
      local pmeta; pmeta="$(_preview_meta "$(_preview_name "$SOLO_REPO" "$SOLO_PR" "$qa")")"
      jq -e --arg q "$qa" --arg h "$head" '.qa == $q and .head == $h' "$pmeta" >/dev/null 2>&1 \
        || die "cel solo review: no $qa QA preview of $SOLO_REPO#$SOLO_PR at $h12 is on record - a QA $verdict is of the head you ran: $(printf 'cel preview %s#%s --qa %s --head %s' "$SOLO_REPO" "$SOLO_PR" "$qa" "$head"), then record (or record blocked, saying why it would not run). Nothing recorded"
    fi
    for e in "${evidence[@]}"; do
      [ ! -L "$e" ] || die "cel solo review: evidence $e is a symlink - pass the file itself. Nothing recorded"
      [ -f "$e" ] || die "cel solo review: evidence $e is not a file. Nothing recorded"
      [ -s "$e" ] || die "cel solo review: evidence $e is empty. Nothing recorded"
      case "${e##*/}" in
        *"$h12"*) ;;
        *) die "cel solo review: evidence ${e##*/} is not named with the head it shows ($h12) - name each file with the head you ran. Nothing recorded" ;;
      esac
      _solo_evidence_type_ok "$e" || die "cel solo review: evidence ${e##*/} is not the image its name says it is. Nothing recorded"
    done
  fi

  if [ "$verdict" = approved ]; then
    # AN APPROVAL IS ONLY EVER FOR THE PR'S CURRENT REMOTE HEAD, on a PR this
    # workspace's account opened. The forge validates; it never supplies the SHA.
    local pr me author state rhead
    me="$(_solo_forge forge_whoami "$SOLO_WSDIR" "$SOLO_REPO")" \
      || die "cel solo review: cannot establish the account this workspace acts as on $SOLO_REPO's forge (see above) - an approval is not recorded unverified"
    me="$(printf '%s' "$me" | jq -r '.login // ""')"
    pr="$(_solo_forge forge_pr_view "$SOLO_WSDIR" "$SOLO_REPO" "$SOLO_PR")" || die "cel solo review: cannot read $SOLO_REPO#$SOLO_PR from its forge - nothing recorded"
    author="$(printf '%s' "$pr" | jq -r '.author // ""')"
    state="$(printf '%s' "$pr" | jq -r '.state // ""')"
    rhead="$(printf '%s' "$pr" | jq -r '.head_sha // ""')"
    [ -n "$me" ] && [ "$author" = "$me" ] \
      || die "cel solo review: #$SOLO_PR was opened by '${author:-?}', not this workspace's account ('${me:-?}') - nothing recorded"
    [ "$state" = open ] || die "cel solo review: #$SOLO_PR is ${state:-in no known state}, not open - nothing recorded"
    [ "$rhead" = "$head" ] \
      || die "cel solo review: --head $head is not #$SOLO_PR's current head (${rhead:-unknown}) - re-review the current head. Nothing recorded"
  fi

  # The evidence is copied beside the verdict - the bytes, never a link - with
  # its sha256 and size: the QA agent's checkout and preview go when it is
  # retired, its evidence does not.
  local evjson='[]'
  if [ "${#evidence[@]}" -gt 0 ]; then
    local evdir="$SOLO_WSDIR/.cel/qa-evidence/$SOLO_REPO-pr-$SOLO_PR/$slot" dest sum size
    mkdir -p "$evdir" || die "cel solo review: could not create $evdir - nothing recorded"
    for e in "${evidence[@]}"; do
      dest="$evdir/${e##*/}"
      if [ "$(readlink -f -- "$e")" != "$(readlink -f -- "$dest" 2>/dev/null)" ]; then
        rm -f -- "$dest"
        cp --no-dereference -- "$e" "$dest" || die "cel solo review: could not copy $e to $evdir - nothing recorded"
      fi
      sum="$(sha256sum -- "$dest" | cut -d' ' -f1)" size="$(stat -c %s -- "$dest")"
      evjson="$(jq -c --arg p "$dest" --arg s "$sum" --argjson n "$size" '. + [{path:$p, sha256:$s, size:$n}]' <<<"$evjson")"
    done
  fi
  _solo_reviews_update "$SOLO_WSDIR" --arg k "$(_solo_review_key "$SOLO_REPO" "$SOLO_PR" "$slot")" --arg v "$verdict" --arg by "$by" \
    --arg note "$note" --arg head "$head" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ev "$evjson" --arg qa "$qa" \
    '.[$k] = ({verdict:$v, by:$by, note:$note, head:$head, at:$at} + (if $qa != "" then {evidence:$ev} else {} end))' \
    || die "cel solo review: could not write $(_solo_reviews "$SOLO_WSDIR")"
  c_ok "$SOLO_REPO#$SOLO_PR reviewed: $verdict by $by${focus:+ ($focus)}${qa:+ (qa $qa${evidence[0]:+, ${#evidence[@]} evidence file(s)})} (head ${head:0:12})"
}

# THE REPO'S OWN GATE, AT EXACTLY THE HEAD BEING MERGED. Used only when the
# base branch gates nothing, so CI cannot stand in. It runs in a checkout of
# this repo whose HEAD is that commit with nothing modified, staged or
# untracked - the solo agent's own worktree for the branch (its dependencies
# installed). No such checkout is a
# refusal, never a guess. The commit is also fetched from the forge as the
# PR's own ref (refs/pull/<n>/head, which GitHub and Forgejo both serve): the
# head the gate passes must be the head the forge would merge. Prints the
# merge-body line on success, the reason on failure.
_solo_local_gate() { # <wsdir> <repo> <pr> <head> <gate>
  local wsdir="$1" repo="$2" pr="$3" head="$4" gate="$5" repodir wt="" w h rc=0 t0 secs
  repodir="$wsdir/repos/$repo"
  # WHICH checkout: the one the caller stands in when it qualifies (the solo
  # agent's prepared worktree, dependencies installed), else the first other
  # qualifying one - never a reviewer's read-only checkout, which has no
  # dependencies and belongs to the review.
  local here; here="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  local -a cands=()
  while read -r w h; do
    [ "$h" = "$head" ] || continue
    case "$w" in */cel/reviews/*) continue ;; esac
    # nothing modified, staged or untracked (ignored build output is fine):
    # anything else could change the gate's outcome at "exactly this head"
    [ -z "$(git -C "$w" status --porcelain 2>/dev/null)" ] || continue
    if [ -n "$here" ] && [ "$(readlink -f "$w")" = "$(readlink -f "$here")" ]; then cands=("$w" "${cands[@]}"); else cands+=("$w"); fi
  done < <(git -C "$repodir" worktree list --porcelain 2>/dev/null | awk '/^worktree /{w=$2} /^HEAD /{print w, $2}')
  wt="${cands[0]:-}"
  [ -n "$wt" ] || { printf '%s' "no clean checkout of $repo is at $head - the base branch gates nothing, so the repo gate (\`$gate\`) must run at exactly that head: check it out (your branch worktree, nothing modified or untracked) and land again"; return 1; }
  [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$head" ] || { printf '%s' "$wt moved off $head"; return 1; }
  local pref="refs/cel/land/pull-$pr" fetched
  git -C "$repodir" fetch -q origin "+refs/pull/$pr/head:$pref" 2>/dev/null \
    || { printf '%s' "could not fetch refs/pull/$pr/head from $repo's origin - nothing proves the forge would merge $head"; return 1; }
  fetched="$(git -C "$repodir" rev-parse "$pref" 2>/dev/null)"
  git -C "$repodir" update-ref -d "$pref" 2>/dev/null || true
  [ "$fetched" = "$head" ] \
    || { printf '%s' "the forge's refs/pull/$pr/head is ${fetched:-nothing}, not $head - the PR moved; land again"; return 1; }
  c_warn "cel solo land: the base branch gates nothing - running the repo gate \`$gate\` in $wt at ${head:0:12}" >&2
  t0="$(date +%s)"
  ( cd "$wt" && timeout "${CEL_SOLO_GATE_TIMEOUT:-5400}" bash -c "$gate" ) >&2 || rc=$?
  secs=$(( $(date +%s) - t0 ))
  [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$head" ] || { printf '%s' "the checkout moved off $head while the gate ran - nothing proven"; return 1; }
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] \
    || { printf '%s' "the gate changed files in $wt (git status is not clean afterwards) - what passed is not $head; make the gate leave the tree as it found it"; return 1; }
  [ "$rc" -eq 0 ] || { printf '%s' "the repo gate (\`$gate\`) did not pass at $head (exit $rc after ${secs}s) - a red gate is a finding, not a formality"; return 1; }
  printf 'Gate: local `%s` passed on %s (%ss; base branch has no required checks)' "$gate" "$head" "$secs"
}

cmd_solo_land() { # <ref> [--workspace W]
  [ $# -ge 1 ] || die "usage: cel solo land <repo>#<pr> [--workspace NAME]"
  # Landing is the solo agent's (or a person's) act, never a reviewer's: the
  # reviewer judges, it does not merge what it judged.
  case "${CEL_ROLE:-}" in
    reviewer) die "cel solo land: a ${CEL_ROLE} does not merge - the product's agent lands an approved PR" ;;
  esac
  local ref="$1" workspace=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) [ $# -ge 2 ] || die "cel solo land: --workspace needs a value"; workspace="$2"; shift 2 ;;
      *) die "cel solo land: unknown argument: $1" ;;
    esac
  done
  _solo_resolve "$ref" "$workspace"
  local wsdir="$SOLO_WSDIR" num="$SOLO_PR" desc provider forge slug
  desc="$(forge_repo "$wsdir" "$SOLO_REPO" "$wsdir/repos/$SOLO_REPO")" || die "cel solo land: cannot resolve the forge for '$SOLO_REPO'"
  provider="$(printf '%s' "$desc" | jq -r .provider)"
  slug="$(printf '%s' "$desc" | jq -r '"\(.owner)/\(.repo)"')"
  case "$provider" in github) forge=GitHub ;; forgejo) forge=Forgejo ;; *) forge="$provider" ;; esac

  local me
  me="$(_solo_forge forge_whoami "$wsdir" "$SOLO_REPO")" \
    || die "cel solo land: refusing to act for workspace '$(ws_name "$wsdir")': the account it acts as on $forge cannot be established (see above)"
  me="$(printf '%s' "$me" | jq -r '.login // ""')"
  [ "$(ws_policy "$wsdir" merge)" = self ] \
    || die "cel solo land: this workspace's policy.merge is humans-only - tell the owner #$num is ready; do not merge it"

  local pr; pr="$(_solo_forge forge_pr_view "$wsdir" "$SOLO_REPO" "$num")" || die "cel solo land: no PR #$num on $slug ($forge)"
  local author head
  author="$(printf '%s' "$pr" | jq -r '.author // ""')"
  head="$(printf '%s' "$pr" | jq -r '.head_sha // ""')"
  [ -n "$me" ] && [ "$author" = "$me" ] \
    || die "cel solo land: #$num was opened by '$author', not this workspace's account ('$me') - someone else's PR is theirs to land"
  [ "$(printf '%s' "$pr" | jq -r .state)" = open ] || die "cel solo land: #$num is not open"
  [ "$(printf '%s' "$pr" | jq -r .draft)" = false ] || die "cel solo land: #$num is still a draft"
  [ -n "$head" ] || die "cel solo land: #$num reports no head commit - cannot pin the merge to a reviewed head. Nothing merged."

  # WHO SAYS THIS IS APPROVED: the forge's own review decision where it can;
  # where the author would have to approve their own PR, the recorded
  # verdict - for this exact head.
  local reviews rd rv review_by="" review_note="" approved_via=""
  reviews="$(_solo_forge forge_pr_reviews "$wsdir" "$SOLO_REPO" "$num")" || die "cel solo land: cannot read #$num's reviews from $forge. Nothing merged."
  rd="$(printf '%s' "$reviews" | jq -r '.decision // "none"')"
  rv="$(solo_review_get "$wsdir" "$SOLO_REPO" "$num")"
  if [ "$rd" = approved ]; then
    approved_via="$forge approval"
  elif [ "$(printf '%s' "$rv" | jq -r '.verdict // ""')" = approved ]; then
    [ "$(printf '%s' "$rv" | jq -r '.head // ""')" = "$head" ] \
      || die "cel solo land: the recorded approval is for head $(printf '%s' "$rv" | jq -r '.head // "?"' | cut -c1-12), but #$num is at ${head:0:12} - the PR moved since its review; re-review it. Nothing merged."
    review_by="$(printf '%s' "$rv" | jq -r '.by // ""')"
    review_note="$(printf '%s' "$rv" | jq -r '.note // ""')"
    approved_via="verdict by $review_by ($forge cannot approve a PR its own author would review)"
  else
    die "cel solo land: #$num is not approved (review decision=$rd, recorded verdict=$(printf '%s' "$rv" | jq -r '.verdict // "none"' 2>/dev/null || printf none))"
  fi

  # AND EVERY EXTRA AGENT THE POLICY REQUIRES - extra reviewers and QA
  # agents, from the files the PR touches now, not from whoever was started.
  # Each counts only by a verdict its own alias recorded for exactly this
  # head (a QA agent's `blocked` never counts); one started by hand (--focus
  # or --qa, not required) is advisory, except that its `changes` at this
  # head blocks (solo_extra_approvals).
  local extra extra_err gaps
  extra_err="$(mktemp)"
  extra="$(solo_extra_approvals "$wsdir" "$SOLO_REPO" "$num" "$head" 2>"$extra_err")" \
    || { local why; why="$(head -c 600 "$extra_err")"; rm -f "$extra_err"
         die "cel solo land: ${why:-the review policy could not be read} - nothing proves #$num has every review the workspace requires. Nothing merged."; }
  rm -f "$extra_err"
  if ! printf '%s' "$extra" | jq -e '.ok' >/dev/null; then
    gaps="$(solo_extra_gaps "$extra" "$SOLO_REPO" "$num" "$head" | sed 's/^/  - /')"
    die "cel solo land: #$num at ${head:0:12} lacks a review the workspace's policy requires:
$gaps
Nothing merged."
  fi
  local extra_by
  extra_by="$(printf '%s' "$extra" | jq -r "$_SOLO_JQ_WHAT"'.required[] | "Reviewed-by: \(.alias) (approved, \(extra_what))"')"
  [ -z "$extra_by" ] || approved_via="$approved_via, and $(printf '%s' "$extra" | jq -r '[.required[].alias] | join(", ")')"

  # The latest run of each check, from the forge.
  local checks; checks="$(_solo_forge forge_pr_checks "$wsdir" "$SOLO_REPO" "$num")" || die "cel solo land: cannot read #$num's checks from $forge. Nothing merged."
  local red; red="$(printf '%s' "$checks" | jq '[.checks[] | select(.conclusion == "failure" or .conclusion == "error")] | length')"
  [ "$red" = 0 ] || die "cel solo land: #$num has $red failing check(s) - a red check is a finding, not a formality"
  # A latest run still going is not green yet (a re-run, a slow suite).
  local pending; pending="$(printf '%s' "$checks" | jq -r '[.checks[] | select(.status != "completed") | (.name // "?")] | join(", ")')"
  [ -z "$pending" ] || die "cel solo land: #$num still has check(s) running: $pending - land once they finish. Nothing merged."
  [ "$(printf '%s' "$pr" | jq -r .mergeable)" != conflicting ] \
    || die "cel solo land: #$num has conflicts - rebase it, then land again"
  # CI stands in for the gate when the base branch's required checks are all
  # green on this head. When the base branch gates nothing at all, the repo's
  # own gate (workspace.yaml `gate:`) runs instead, in a clean checkout at
  # exactly this head.
  local gate_body gate_out rc=0
  gate_out="$(mktemp)"
  land_ci_gate "$wsdir" "$SOLO_REPO" "$pr" > "$gate_out" || rc=$?
  gate_body="$(cat "$gate_out")"; rm -f "$gate_out"
  if [ "$rc" -ne 0 ]; then
    local gate; gate="$(ws_repo_get "$wsdir" "$SOLO_REPO" gate)"; [ "$gate" = null ] && gate=""
    [ "${LAND_CI_UNPROTECTED:-0}" = 1 ] && [ -n "$gate" ] || die "cel solo land: $gate_body. Nothing merged."
    gate_body="$(_solo_local_gate "$wsdir" "$SOLO_REPO" "$num" "$head" "$gate")" \
      || die "cel solo land: $gate_body. Nothing merged."
  fi

  # AFK admits here and records after the merge, saying whether it went through.
  if afk_active; then
    local afk_ev
    afk_ev="$(jq -n --arg ws "$(ws_name "$wsdir")" --arg slug "$slug" --arg num "$num" --arg via "$approved_via" \
      --arg gate "$(case "$gate_body" in "Gate: local"*) printf pass;; *) printf ci;; esac)" \
      '{review:"approved", checks:"green", gate:$gate, mergeable:true, author:"solo",
        workspace:$ws, pr:$num, slug:$slug, approved_via:$via}')"
    afk_begin land "$afk_ev" "$slug#$num (solo) - approved via $approved_via, checks green" \
      || die "cel solo land: AFK did not authorise this merge - see the refusal above. Nothing was merged."
  fi

  local body="$gate_body"
  [ -z "$extra_by" ] || body="$extra_by"$'\n'"$body"
  if [ -n "$review_by" ]; then
    body="Reviewed-by: $review_by (approved)${review_note:+$'\n'$review_note}"$'\n'"$body"
  fi
  local bad; bad="$(land_body_hygiene "$body")" || die "cel solo land: could not run the hygiene check on the commit body - nothing was merged"
  [ -z "$bad" ] || die "cel solo land: the review note carries a ticket-shaped token the hygiene scan rejects: $(printf '%s' "$bad" | tr '\n' ' ')- re-record the review without it. Nothing was merged."
  # MERGE ONLY THE HEAD THAT WAS CHECKED: the forge refuses if it moved since.
  if ! _solo_forge forge_pr_merge "$wsdir" "$SOLO_REPO" "$num" "$head" "$body" >/dev/null 2>&1; then
    afk_end failed "the merge did not go through"
    die "cel solo land: merge of #$num failed - check the PR page; nothing here retries a merge"
  fi
  afk_end completed "merged"
  c_ok "landed $SOLO_REPO#$num on $slug (approved via $approved_via)"
  _solo_land_retire_reviewer "$wsdir" "$SOLO_REPO" "$num" \
    "$(printf '%s' "$extra" | jq -r '[.required[].slot, .advisory[].slot] | unique[]')"
}

# THE MERGE ENDS THE REVIEW. That PR's Rex reviewers - the plain one and each
# extra one (reviewer or QA agent) with a verdict or a policy requirement -
# are retired through the one targeted path (gc.sh reviewer_retire_target):
# the same native proof and graceful shutdown `cel gc` uses, never a blind
# close. It is not part of the land's result - the PR is merged whatever
# happens here - and a reviewer kept now (mid-turn, mail owed, proof
# unknown) is retried by every `cel gc` sweep. An unknown answer here is the
# first attempt of the count gc carries on (gc.sh _gc_retire_note): a reason
# that keeps coming back reaches the product agent, once. A Herdr reviewer,
# or none, is left to that sweep as before.
_solo_land_retire_reviewer() { # <wsdir> <repo> <pr> [slot, one per line]
  local out rc reason pane slot who focus kind owner
  local -a slots=("")
  while IFS= read -r slot; do [ -z "$slot" ] || slots+=("$slot"); done <<<"${4:-}"
  for slot in "${slots[@]}"; do
    rc=0 focus="" kind=""
    [ -z "$slot" ] || { kind="$(review_slot_kind "$slot")"; focus="$(review_slot_focus "$slot")"; }
    who="$2#$3${slot:+ ($([ "$kind" = qa ] && printf 'qa ')$focus)}"
    if [ -n "$slot" ]; then
      out="$(. "$CEL_ROOT/lib/gc.sh" && reviewer_retire_target "$1" "$2" "$3" 0 "$focus" "$kind")" || rc=$?
    else
      out="$(. "$CEL_ROOT/lib/gc.sh" && reviewer_retire_target "$1" "$2" "$3" 0)" || rc=$?
    fi
    reason="$(printf '%s' "$out" | jq -r '.reason // empty' 2>/dev/null)" || reason=""
    pane="$(printf '%s' "$out" | jq -r '.pane // empty' 2>/dev/null)" || pane=""
    case "$rc" in
      0) c_ok "retired the Rex reviewer for $who${pane:+ (pane $pane)}; native evidence and checkout kept" ;;
      4) : ;;
      3) c_warn "kept the reviewer for $who: ${reason:-protected} - \`cel gc\` retires it once it settles" ;;
      *) owner="$(cel_alias_norm "$(ws_product_of_repo "$1" "$2" 2>/dev/null || printf '%s' "$2")-orch")"
         c_warn "reviewer retirement for $who is incomplete: ${reason:-unknown} - \`cel gc\` retries it every tick and tells $owner if it keeps failing" ;;
    esac
  done
  return 0
}

# EVERY REVIEWER A PR NEEDS AND WHAT EACH SAID, by the rule `cel solo land`
# applies (solo_plain_approval, solo_extra_approvals): for a view to show
# "approved" exactly when land would take the reviews. One object:
#   {ref: "<repo>#<n>", head, state: approved|changes|pending|unknown|n/a, reason,
#    reviewers: [{alias, kind, focus, required, why, state}]}
# `unknown` (with `reason`) when the PR, the policy or its files cannot be
# read; `n/a` for a ref that is not a solo product's PR in the workspace.
# Checks, conflicts and the gate are land's other questions, not this.
_solo_approvals_unknown() { # <ref> <reason> [head] [state]
  jq -nc --arg ref "$1" --arg why "$2" --arg h "${3:-}" --arg s "${4:-unknown}" \
    '{ref: $ref, head: (if $h == "" then null else $h end), state: $s, reason: $why, reviewers: []}'
}
solo_approvals_json() { # <wsdir> <repo> <pr>
  local wsdir="$1" repo="$2" pr="$3" view head plain extra
  view="$(_solo_forge forge_pr_view "$wsdir" "$repo" "$pr" 2>/dev/null)" \
    || { _solo_approvals_unknown "$repo#$pr" "cannot read $repo#$pr from its forge"; return 0; }
  head="$(printf '%s' "$view" | jq -r '.head_sha // ""')"
  [ -n "$head" ] || { _solo_approvals_unknown "$repo#$pr" "$repo#$pr reports no head commit"; return 0; }
  plain="$(solo_plain_approval "$wsdir" "$repo" "$pr" "$head")"
  extra="$(solo_extra_approvals "$wsdir" "$repo" "$pr" "$head" 2>&1)" \
    || { _solo_approvals_unknown "$repo#$pr" "$extra" "$head"; return 0; }
  jq -nc --arg ref "$repo#$pr" --arg h "$head" --arg plain "$plain" --arg pa "$(review_alias "$repo" "$pr")" \
    --argjson x "$extra" "$_REVIEW_JQ_WHY"'
    ([{alias: $pa, kind: "review", focus: null, required: true, why: "every pull request", state: $plain}]
     + [$x.required[] | {alias, kind, focus, required: true, why: review_why, state}]
     + [$x.advisory[] | {alias, kind, focus, required: false, why: "started by hand", state}]) as $rv
    | {ref: $ref, head: $h, reason: null, reviewers: $rv,
       state: (if any($rv[]; .state == "changes") then "changes"
               elif $plain == "approved" and $x.ok then "approved" else "pending" end)}'
}

cmd_solo_approvals() { # <ref>... [--workspace W] [--json]
  local usage="usage: cel solo approvals <repo>#<pr>... [--workspace NAME] [--json]"
  local workspace="" json=0 ref out all='[]'
  local -a refs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --workspace) [ $# -ge 2 ] || die "$usage"; workspace="$2"; shift 2 ;;
      --json) json=1; shift ;;
      -*) die "$usage" ;;
      *) refs+=("$1"); shift ;;
    esac
  done
  [ "${#refs[@]}" -gt 0 ] || die "$usage"
  for ref in "${refs[@]}"; do
    # A ref that is not a solo product's PR is said as such; the others are
    # still answered.
    out="$(_solo_resolve "$ref" "$workspace" 2>/dev/null && solo_approvals_json "$SOLO_WSDIR" "$SOLO_REPO" "$SOLO_PR")" \
      || out="$(_solo_approvals_unknown "$ref" "not a pull request of a solo product in this workspace" "" "n/a")"
    all="$(jq -c --argjson o "$out" '. + [$o]' <<<"$all")"
  done
  if [ "$json" = 1 ]; then printf '%s\n' "$all"; return 0; fi
  printf '%s' "$all" | jq -r '.[] | "\(.ref)\(if .head then " at " + .head[0:12] else "" end): \(.state)\(if .reason then " - " + .reason else "" end)",
    (.reviewers[] | "  \(.alias)\(if .focus then " (" + (if .kind == "qa" then "qa " else "" end) + .focus + ")" else "" end)  \(.state)  \(if .required then "required: " else "advisory: " end)\(.why)")'
}

cmd_solo() {
  case "${1:-}" in
    review)    shift; cmd_solo_review "$@" ;;
    land)      shift; cmd_solo_land "$@" ;;
    approvals) shift; cmd_solo_approvals "$@" ;;
    *) die "usage: cel solo review <repo>#<pr> approved|changes|blocked --head <sha> --by <alias> [--focus F | --qa F [--evidence FILE]...] | cel solo land <repo>#<pr> | cel solo approvals <repo>#<pr>... [--json]" ;;
  esac
}
