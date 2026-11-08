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
# of agent the entry starts and defaults to `review`: a PR reviewer with the
# focus pack core/roles/focus/reviewer/<focus>.md appended to its role.
# `review` is the only kind there is.
#
# THIS IS POLICY. It is read from workspace.yaml alone (_yqr, never the
# workspace.local.yaml overlay of _yqr_ws), so a per-person file can neither
# add nor drop a required reviewer. Nothing malformed is skipped - a typo
# must not quietly drop a required review: an entry that is not exactly as
# above, a `review:` that is not a map, a key in it this code does not read
# (workspace-wide: runtime, model, post, extra; on a repo: extra - so
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
# Each extra reviewer has a SLOT, `<kind>-<focus>` (`review-security`): its
# alias is `<repo>-pr-<n>-<slot>` (cut to 32 characters by cel_alias_norm),
# its checkout `<reviews>/<repo>-pr-<n>-<slot>`, and its verdict is recorded
# under `<repo>#<n>/<slot>` in .cel/solo-reviews.json (lib/solo.sh).
[ -n "${_CEL_REVIEW_POLICY:-}" ] && return 0
_CEL_REVIEW_POLICY=1
# shellcheck source=lib/workspace.sh
. "${BASH_SOURCE[0]%/*}/workspace.sh"
# shellcheck source=lib/forge.sh
. "${BASH_SOURCE[0]%/*}/forge.sh"   # forge_pr_files: what a PR touches

review_focus_dir() { printf '%s/core/roles/focus/reviewer' "$CEL_ROOT"; }

# The reviewer focus packs there are, one name per line, sorted.
review_focus_names() {
  local f
  for f in "$(review_focus_dir)"/*.md; do
    [ -f "$f" ] || continue
    f="${f##*/}"; printf '%s\n' "${f%.md}"
  done | LC_ALL=C sort
}

review_focus_valid() { # <focus>
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ -f "$(review_focus_dir)/$1.md" ]
}

review_focus_refusal() { # <focus> -> the sentence naming the packs there are
  printf "no reviewer focus '%s' - have: %s" "$1" "$(review_focus_names | paste -sd' ' -)"
}

review_slot() { printf 'review-%s' "$1"; }   # <focus>

# The agent name (and mailbox) of a PR's reviewer: the plain one with no
# focus, `<repo>-pr-<n>-review-<focus>` with one.
review_alias() { # <repo> <pr> [focus]
  if [ -n "${3:-}" ]; then cel_alias_norm "$1/pr-$2-$(review_slot "$3")"
  else cel_alias_norm "$1/pr-$2-review"; fi
}

# A focus whose alias would be another reviewer's - the plain one's, or a
# different focus's once both are cut to 32 characters - is refused: two
# reviewers answering to one name share a mailbox and a verdict.
review_alias_free() { # <repo> <pr> <focus> -> 0, or the reason on stdout
  local mine other f
  mine="$(review_alias "$1" "$2" "$3")"
  [ "$mine" != "$(review_alias "$1" "$2")" ] \
    || { printf "the %s reviewer's name '%s' is the plain reviewer's (names are cut to 32 characters)" "$3" "$mine"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] && [ "$f" != "$3" ] || continue
    other="$(review_alias "$1" "$2" "$f")"
    [ "$other" != "$mine" ] \
      || { printf "the %s and %s reviewers would both be named '%s' (names are cut to 32 characters)" "$3" "$f" "$mine"; return 1; }
  done < <(review_focus_names)
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

# The `review:` keys this code reads (lib/workspace.sh ws_review; extra here).
_REVIEW_KEYS_WS='["runtime","model","post","extra"]'
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
       elif (.kind // "review") != "review" then "\($w): kind \(.kind | tojson) is not a kind of reviewer there is - the only kind is review"
       elif (.focus | type) != "string" or .focus == "" then "\($w): an entry needs a focus"
       elif (.paths | type) != "array" or (.paths | length) == 0 then "\($w): focus \(.focus) needs paths - a list of globs"
       elif any(.paths[]; glob_ok | not) then "\($w): focus \(.focus) has a path that is not a repo-relative glob (\([.paths[] | select(glob_ok | not)] | map(tojson) | join(", ")))"
       else empty end][0] // ""')"
  [ -z "$bad" ] || { printf 'workspace.yaml %s\n' "$bad" >&2; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    review_focus_valid "$f" || { printf 'workspace.yaml review.extra: %s\n' "$(review_focus_refusal "$f")" >&2; return 1; }
  done < <(printf '%s' "$raw" | jq -r '.[].e.focus')
  printf '%s' "$raw" | jq -c '
    [.[].e | {kind: (.kind // "review"), focus, paths}]
    | group_by(.focus) | map({kind: .[0].kind, focus: .[0].focus, slot: "\(.[0].kind)-\(.[0].focus)",
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
