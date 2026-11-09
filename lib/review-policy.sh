# shellcheck shell=bash
# WHICH REVIEWERS A PULL REQUEST NEEDS, and what each one is called.
#
# Every PR gets its plain reviewer (`cel run reviewer --repo r --pr n`). A
# workspace may also REQUIRE EXTRA REVIEWERS for the files a PR touches, in
# workspace.yaml - workspace-wide, per repo, or both (the two lists together):
#
#   review:
#     extra:
#       - focus: security
#         paths: ['lib/auth/**', '**/*token*']
#   repos:
#     - name: widget
#       review:
#         extra:
#           - focus: db-migration
#             paths: ['migrations/**']
#
# An entry is `kind`, `focus` and `paths`, nothing else. `kind` is what kind
# of agent the entry starts and defaults to `review`:
#   review  a PR reviewer with the focus pack
#           core/roles/focus/reviewer/<focus>.md appended to its role
#   qa      a QA agent (core/roles/pr-qa.md) with the focus pack
#           core/roles/focus/qa/<focus>.md: it does not read the code, it
#           runs the PR's head in a preview and uses it (`kind: qa, focus:
#           browser, paths: ['web/**', '**/*.tsx', '**/*.css']`)
# Those are the kinds there are.
#
# THIS IS POLICY. It is read from workspace.yaml alone (_yqr, never the
# workspace.local.yaml overlay of _yqr_ws), so a per-person file can neither
# add nor drop a required reviewer. Nothing malformed is skipped - a typo
# must not quietly drop a required review: an entry that is not exactly as
# above, a `review:` that is not a map, a key in it Celestial does not know
# (workspace-wide: runtime, model, thinking, the retired post, extra; on a repo: extra - so
# `extras:` is refused, not ignored), and two `repos:` entries of one name
# (which of the two holds the policy is unknown) each fail the read. `cel
# doctor` reports the same errors (review_policy_problems).
#
# PATH GLOBS match a PR's repo-relative file paths - both sides of a rename,
# so moving a file out of `migrations/` still touches `migrations/**`:
#   `*`    any run of characters inside one path segment (never a `/`)
#   `?`    one character other than `/`
#   `**`   as a whole segment, any number of directories (zero or more):
#          `**/*token*` matches `token.sh` and `a/b/api_token.ts`; a trailing
#          `/**` matches everything below that directory, at any depth
# Everything else is literal, and a glob matches the WHOLE path: `lib/auth`
# is that one file, `lib/auth/**` everything under it.
#
# Each extra agent has a SLOT, `<kind>-<focus>` (`review-security`,
# `qa-browser`): its alias is `<repo>-pr-<n>-<slot>` (cut to 32 characters by
# cel_alias_norm), its checkout `<reviews>/<repo>-pr-<n>-<slot>`, and its
# verdict is recorded under `<repo>#<n>/<slot>` in .cel/solo-reviews.json
# (lib/solo.sh). Both kinds run as reviewers (CEL_ROLE=reviewer): one guard
# class, one registry, one budget class, one retirement path.
[ -n "${_CEL_REVIEW_POLICY:-}" ] && return 0
_CEL_REVIEW_POLICY=1
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/forge.sh
. "${BASH_SOURCE[0]%/*}/forge.sh"   # forge_pr_files: what a PR touches

# The kinds of extra agent there are, and where each kind's focus packs live.
REVIEW_KINDS="review qa"
review_focus_dir() { # [kind]
  case "${1:-review}" in
    review) printf '%s/core/roles/focus/reviewer' "$CEL_ROOT" ;;
    qa)     printf '%s/core/roles/focus/qa' "$CEL_ROOT" ;;
    *)      return 1 ;;
  esac
}

# A kind's focus packs, one name per line, sorted.
review_focus_names() { # [kind]
  local f d
  d="$(review_focus_dir "${1:-review}")" || return 0
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    f="${f##*/}"; printf '%s\n' "${f%.md}"
  done | LC_ALL=C sort
}

review_focus_valid() { # <focus> [kind]
  local d
  d="$(review_focus_dir "${2:-review}")" || return 1
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -f "$d/$1.md" ]
}

# What a kind is called in a sentence.
review_kind_word() { case "${1:-review}" in qa) printf qa ;; *) printf reviewer ;; esac; }

review_focus_refusal() { # <focus> [kind] -> the sentence naming the packs there are
  printf "no %s focus '%s' - have: %s" "$(review_kind_word "${2:-review}")" "$1" "$(review_focus_names "${2:-review}" | paste -sd' ' -)"
}

review_slot() { printf '%s-%s' "${2:-review}" "$1"; }   # <focus> [kind]
# A slot's kind and focus: the kind is everything before the first `-`.
review_slot_kind()  { printf '%s' "${1%%-*}"; }   # <slot>
review_slot_focus() { printf '%s' "${1#*-}"; }    # <slot>

# The agent name (and mailbox) of a PR's reviewer: the plain one with no
# focus, `<repo>-pr-<n>-review-<focus>` for an extra reviewer and
# `<repo>-pr-<n>-qa-<focus>` for a QA agent.
review_alias() { # <repo> <pr> [focus] [kind]
  if [ -n "${3:-}" ]; then cel_alias_norm "$1/pr-$2-$(review_slot "$3" "${4:-review}")"
  else cel_alias_norm "$1/pr-$2-review"; fi
}

# The command that starts (or, when it is live, reuses) one extra agent.
review_start_cmd() { # <repo> <pr> <focus> [kind]
  case "${4:-review}" in
    qa) printf 'cel run reviewer --repo %s --pr %s --qa %s' "$1" "$2" "$3" ;;
    *)  printf 'cel run reviewer --repo %s --pr %s --focus %s' "$1" "$2" "$3" ;;
  esac
}

# A focus whose alias would be another agent's - the plain reviewer's, or
# any other extra one's of either kind once both are cut to 32 characters -
# is refused: two agents answering to one name share a mailbox and a verdict.
review_alias_free() { # <repo> <pr> <focus> [kind] -> 0, or the reason on stdout
  local kind="${4:-review}" mine other f k
  mine="$(review_alias "$1" "$2" "$3" "$kind")"
  [ "$mine" != "$(review_alias "$1" "$2")" ] \
    || { printf "the %s %s's name '%s' is the plain reviewer's (names are cut to 32 characters)" "$3" "$(review_kind_word "$kind")" "$mine"; return 1; }
  for k in $REVIEW_KINDS; do
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ "$k-$f" != "$kind-$3" ] || continue
      other="$(review_alias "$1" "$2" "$f" "$k")"
      [ "$other" != "$mine" ] \
        || { printf "the %s %s and the %s %s would both be named '%s' (names are cut to 32 characters)" "$3" "$(review_kind_word "$kind")" "$f" "$(review_kind_word "$k")" "$mine"; return 1; }
    done < <(review_focus_names "$k")
  done
  return 0
}

# A glob as an anchored regex, by the rules in the header. Callers prefix a
# jq program with this and call `review_glob_re` on the glob.
_REVIEW_JQ_GLOB='def review_glob_re:
  split("/") as $s | ($s | length) as $n
  | reduce range(0; $n) as $i (""; . + (
      $s[$i] as $g
      | if $g == "**" then (if $i == $n - 1 then ".+" else "(?:[^/]+/)*" end)
        else ($g | gsub("(?<c>[.+^$(){}\\[\\]|\\\\])"; "\\\(.c)") | gsub("\\*"; "[^/]*") | gsub("\\?"; "[^/]"))
             + (if $i < $n - 1 then "/" else "" end) end))
  | "^" + . + "$";'

# The `review:` keys Celestial knows (lib/workspace.sh ws_review; extra here).
# `post` is retired - cel doctor warns about it (doctor_review_post_line) -
# and is tolerated here so a leftover one does not refuse every land.
_REVIEW_KEYS_WS='["runtime","model","thinking","post","extra"]'
_REVIEW_KEYS_REPO='["extra"]'

# THE EXTRA REVIEWERS A REPO'S POLICY DECLARES, validated: a JSON array of
# {kind, focus, slot, paths} - the workspace-wide entries and the repo's own,
# one per slot (the paths of a slot named in both are joined). Anything
# malformed (see the header) fails the whole read with the reason on stderr.
review_extra_entries() { # <wsdir> <repo> -> JSON array
  local raw bad f
  raw="$(_yqr -c --arg r "$2" --argjson kw "$_REVIEW_KEYS_WS" --argjson kr "$_REVIEW_KEYS_REPO" '
    def block($where; $known):
      if . == null then []
      elif type != "object" then [{where: $where, e: "must be a map (of \($known | join(", ")))", bad: true}]
      elif (keys - $known) != [] then [{where: $where, e: "unknown key(s) \(keys - $known | join(", ")) - review: reads \($known | join(", "))", bad: true}]
      else (.extra | if . == null then [] elif type == "array" then map({where: ($where + ".extra"), e: .})
            else [{where: ($where + ".extra"), e: "not a list"}] end) end;
    ([(.repos // [])[] | select(.name == $r)]) as $mine
    | if ($mine | length) > 1 then [{where: "repos", e: "\($mine | length) entries are named \($r) - which one holds its review policy is unknown; keep one", bad: true}]
      else (.review | block("review"; $kw)) + (($mine[0] // {}).review | block("repos[\($r)].review"; $kr)) end' \
    "$1/workspace.yaml" 2>/dev/null)" \
    || { printf 'cannot read the review policy in %s/workspace.yaml\n' "$1" >&2; return 1; }
  [ -n "$raw" ] && [ "$raw" != null ] || raw='[]'
  bad="$(printf '%s' "$raw" | jq -r '[.[] | select(.bad) | "\(.where): \(.e)"][0] // ""')"
  [ -z "$bad" ] || { printf 'workspace.yaml %s\n' "$bad" >&2; return 1; }
  bad="$(printf '%s' "$raw" | jq -r '
    def glob_ok: type == "string" and length > 0 and (startswith("/") | not)
      and all(split("/")[]; . != "" and . != "." and . != "..");
    [.[] | .where as $w | .e
     | if type != "object" then "\($w): an entry must be a map of kind, focus and paths (got \(tojson))"
       elif (keys - ["kind", "focus", "paths"]) != [] then "\($w): unknown key(s) \(keys - ["kind", "focus", "paths"] | join(", ")) - an entry has kind, focus and paths"
       elif ((.kind // "review") | IN("review", "qa") | not) then "\($w): kind \(.kind | tojson) is not a kind there is - the kinds are review and qa"
       elif (.focus | type) != "string" or .focus == "" then "\($w): an entry needs a focus"
       elif (.paths | type) != "array" or (.paths | length) == 0 then "\($w): focus \(.focus) needs paths - a list of globs"
       elif any(.paths[]; glob_ok | not) then "\($w): focus \(.focus) has a path that is not a repo-relative glob (\([.paths[] | select(glob_ok | not)] | map(tojson) | join(", ")))"
       else empty end][0] // ""')"
  [ -z "$bad" ] || { printf 'workspace.yaml %s\n' "$bad" >&2; return 1; }
  local k
  while IFS=$'\t' read -r k f; do
    [ -n "$f" ] || continue
    review_focus_valid "$f" "$k" || { printf 'workspace.yaml review.extra: %s\n' "$(review_focus_refusal "$f" "$k")" >&2; return 1; }
  done < <(printf '%s' "$raw" | jq -r '.[].e | [(.kind // "review"), .focus] | @tsv')
  printf '%s' "$raw" | jq -c '
    [.[].e | {kind: (.kind // "review"), focus, paths} | .slot = "\(.kind)-\(.focus)"]
    | group_by(.slot) | map({kind: .[0].kind, focus: .[0].focus, slot: .[0].slot,
                             paths: ([.[].paths[]] | unique)})'
}

# EVERY REVIEW-POLICY ERROR IN A WORKSPACE, one line each (nothing when the
# policy reads cleanly): what `cel doctor` reports, by the same read land
# makes - the workspace-wide block, and each repo's.
# The repo names are read before the loop, not beside it: two concurrent
# first reads of one file race on its cache (lib/yaml.sh).
review_policy_problems() { # <wsdir>
  local r err names
  names="$(_yqr -r '(.repos // [])[] | .name // empty | tostring' "$1/workspace.yaml" 2>/dev/null | LC_ALL=C sort -u)"
  while IFS= read -r r; do
    err="$(review_extra_entries "$1" "$r" 2>&1 >/dev/null)" || printf '%s\n' "$err"
  done < <(printf '\n%s\n' "$names") | LC_ALL=C sort -u
}

# Which of <entries> the files of a PR touch: each matching entry with
# `because`, the first {glob, file} pair that matched, and `files`, how many
# of the PR's files match any of its globs.
review_extra_match() { # <entries-json> <files-json> -> JSON array
  jq -nc --argjson es "$1" --argjson fs "$2" "$_REVIEW_JQ_GLOB"'
    [$es[] | . as $e
     | [$e.paths[] as $g | ($g | review_glob_re) as $re | $fs[] | select(test($re)) | {glob: $g, file: .}] as $hits
     | select($hits | length > 0)
     | $e + {because: $hits[0], files: ([$hits[].file] | unique | length)}]'
}

# THE EXTRA REVIEWERS THIS PR NEEDS, from its touched files read now. A repo
# whose policy declares none asks the forge nothing. Fails, with the reason on
# stderr, when the policy or the PR's files cannot be read - never "none".
review_extra_required() { # <wsdir> <repo> <pr> -> JSON array (review_extra_match's shape)
  local entries files
  entries="$(review_extra_entries "$1" "$2")" || return 1
  [ "$entries" != '[]' ] || { printf '[]'; return 0; }
  files="$(forge_pr_files "$1" "$2" "$3")" \
    || { printf "cannot read the files %s#%s touches from its forge - which extra reviewers it needs is unknown\n" "$2" "$3" >&2; return 1; }
  review_extra_match "$entries" "$(printf '%s' "$files" | jq -c '.files')"
}

# Why an extra reviewer is required, as one clause: a jq def over one match
# (review_extra_match's shape), and the same sentence from the shell.
_REVIEW_JQ_WHY='def review_why: "review.extra: \(.because.file) matches \(.because.glob | tojson)"
  + (if .files > 1 then " (\(.files) files match)" else "" end);'
review_extra_why() { # <match-json>
  printf '%s' "$1" | jq -r "$_REVIEW_JQ_WHY"' review_why'
}
