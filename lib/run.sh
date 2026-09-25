# shellcheck shell=bash
# cel run - start an agent pane for a role, wired to a workspace via herdr.
# Architecture and trust boundaries: docs/architecture.md.
[ -n "${_CEL_RUN:-}" ] && return 0
_CEL_RUN=1
# shellcheck source=lib/registry.sh
. "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
# shellcheck source=lib/workspace.sh
. "$(dirname "${BASH_SOURCE[0]}")/workspace.sh"
# shellcheck source=lib/manifest.sh
. "$(dirname "${BASH_SOURCE[0]}")/manifest.sh"
# shellcheck source=lib/profiles.sh
. "$(dirname "${BASH_SOURCE[0]}")/profiles.sh"
# shellcheck source=lib/gateway.sh
. "$(dirname "${BASH_SOURCE[0]}")/gateway.sh"

# Where a role's body is written for a runtime that injects it from a file.
#
# Every orchestrator launch used to overwrite $wsdir/.cel/role-orchestrator.md,
# which was harmless while there was one orchestrator per workspace and is not
# now: two products' orchestrators would trade role bodies underneath each
# other. A DECLARED product gets its own directory; an implicit one keeps the
# original path so nothing about an existing workspace moves.
#
# The filename must keep ending in `role-orchestrator.md`: lib/gc.sh tells a
# long-lived agent from a stray one by that substring in the cmdline, and a
# renamed file would have the reaper collecting orchestrators.
_run_role_file() { # <wsdir> <tag> [product]
  local wsdir="$1" tag="$2" p="${3:-}"
  if [ -n "$p" ] && ws_product_declared "$wsdir" "$p"; then
    printf '%s' "$wsdir/.cel/products/$p/role-$tag.md"
  else
    printf '%s' "$wsdir/.cel/role-$tag.md"
  fi
}

# Fills the global AGENT_ARGS array per the runtime's role_injection strategy
# in agents.yaml. File writes are real side effects, so they are skipped on a dry
# run - only the herdr command line is ever a preview.
#
# AGENT_ROLE_FILE is set to the path the role travelled as, or emptied: the
# launch environment below carries it, and `cel gc` proves ownership with it.
# KEEP THE MODEL THE LAUNCH NAMED (CEL-68). OMP prewalk swaps to the box's
# `smol` model after the first edit/write, so a profile's model would silently
# become another one - and the ledger's provenance would lie. Every omp launch
# (cel run of any role, cel-fanout delegate/scout) goes through here; other
# runtimes get nothing. Prepends to AGENT_ARGS.
_run_keep_model_args() { # <runtime>
  [ "$1" != omp ] || AGENT_ARGS=(--no-prewalk "${AGENT_ARGS[@]}")
}

_run_agent_args() { # <runtime> <tag> <body> <dry-run 0|1> <wsdir> [rolefile]
  local rt="$1" tag="$2" body="$3" dry="$4" wsdir="$5" rolefile="${6:-}" strategy
  AGENT_ROLE_FILE=""
  strategy="$(agent_injection "$rt" strategy)"
  case "$strategy" in
    append_flag)
      AGENT_ARGS=("$(agent_injection "$rt" flag)" "$body")
      ;;
    append_flag_file)
      # herdr agent start types the launch line into a shell pane and refuses
      # any argument it cannot encode on one line (newlines, control chars),
      # so a multi-line role body travels as a file and only its path goes on
      # the command line.
      local file="${rolefile:-$wsdir/.cel/role-$tag.md}"
      if [ "$dry" -eq 0 ]; then
        mkdir -p "$(dirname "$file")"
        printf '%s\n' "$body" > "$file"
      fi
      AGENT_ARGS=("$(agent_injection "$rt" flag)" "$file")
      AGENT_ROLE_FILE="$file"
      ;;
    prompt_arg)
      c_warn "runtime $rt injects the role as a prompt argument - it may not survive compaction"
      AGENT_ARGS=("$body")
      ;;
    agent_file)
      local dir file
      dir="$(expand "$(agent_injection "$rt" dir)")"
      file="$dir/cel-$tag.md"
      if [ "$dry" -eq 0 ]; then
        mkdir -p "$dir"
        { printf -- '---\ndescription: celestial plane %s (materialised by cel run)\n---\n' "$tag"
          printf '%s\n' "$body"; } > "$file"
      fi
      AGENT_ARGS=(--agent "cel-$tag")
      AGENT_ROLE_FILE="$file"
      ;;
    *)
      die "cel run: runtime '$rt' has no known role_injection strategy"
      ;;
  esac
}

# THE LAUNCHER MARKS ITS CHILDREN. `cel gc` used to prove a process was a
# plane worker by finding the role file path in /proc/<pid>/cmdline. pi
# rewrites its own argv (process.title), so a live pi worker's cmdline is the
# two bytes `pi` and padding: every pi worker on the box read as unidentified,
# GC kept their worktrees whole, and for weeks the steward journal printed
# `0 worktrees removed, 0 agents reaped` without anyone noticing.
# /proc/<pid>/environ is fixed at exec and no runtime rewrites it, so
# ownership travels there instead.
#
# `herdr agent start` has no --env option (checked against `--help`), so the
# variables go on as an `env K=V ...` PREFIX to the launch line it types. That
# is deliberately scoped to the launch: an `export` in the pane would outlive
# the agent and mark every later command in that shell as a plane worker.
_run_launch_env() { # <role> <wsdir> [rolefile] [inbox-me] -> `env K=V K=V K=V `
  local role="$1" wsdir="$2" file="${3:-}" me="${4:-}" out
  printf -v out 'env CEL_ROLE=%q CEL_WORKSPACE=%q' "$role" "$wsdir"
  # WHOSE MAILBOX (CEL-65). `cel inbox` derives the reader from cwd, and an
  # orchestrator that cd's to its workspace root read ROOT's mail for days.
  # Root and orchestrators carry their identity from the launch instead.
  [ -z "$me" ] || printf -v out '%s CEL_INBOX_ME=%q CEL_INBOX_WS=%q' "$out" "$me" "$(ws_name "$wsdir")"
  # A runtime whose role is injected as a prompt argument has no file to name;
  # the other two still say whose the process is.
  [ -z "$file" ] || printf -v out '%s CEL_ROLE_FILE=%q' "$out" "$file"
  # ...and, for a workspace with `github.user`, the account it acts as: the
  # token is a substitution the PANE evaluates (lib/workspace.sh), never a value.
  # The guard goes AHEAD of `env`, so the agent's start is chained on it.
  local ghw="" ghg=""
  if [ -f "$wsdir/workspace.yaml" ]; then
    ghw="$(ws_github_env_word "$wsdir")"; ghg="$(ws_github_launch_guard "$wsdir")"
  fi
  [ -z "$ghw" ] || out="$ghg$out $ghw"
  printf '%s ' "$out"
}

# The prefix is TYPED, not run: `herdr pane run` would execute it as its own
# command and the variables would be gone before the agent started. send-text
# leaves it on the shell's input line for `herdr agent start` to complete.
# A pane that refuses the text still gets its agent - an unmarked worker is a
# kept worktree, which is the safe direction.
_run_mark_launch() { # <pane> <env-prefix>
  local pane="$1" prefix="$2"
  [ -n "$pane" ] && [ -n "$prefix" ] || return 0
  herdr pane send-text "$pane" "$prefix" >/dev/null 2>&1 \
    || c_warn "could not mark $pane with its role environment - cel gc will not recognise it"
  return 0
}

# The herdr-workspace-manager CLI ships inside the plugin and is not put on
# PATH by `herdr plugin install`, so fall back to its install location.
_run_wsm_bin() {
  if have herdr-workspace-manager; then
    command -v herdr-workspace-manager
    return 0
  fi
  local b
  for b in "$HOME"/.config/herdr/plugins/github/herdr-plugin-workspace-manager-*/bin/herdr-workspace-manager; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

# Layouts resolve WORKSPACE FIRST: a workspace's own layouts.yml (beside
# workspace.yaml, like the externals.yaml overlay) beats the plane's generic
# file, so workspace content never has to live in the public plane repo. The
# wsm CLI takes exactly one config file, so resolution picks whichever file
# defines the id - no merging.
_run_layout_config() { # <wsdir> <layout-id> -> config path, or fail
  local f
  for f in "$1/layouts.yml" "$CEL_ROOT/tools/herdr/layouts/config.yml"; do
    [ -f "$f" ] && grep -q "id: $2\$" "$f" && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# Applies the workspace's declared layout (workspace.yaml `layout:`) to a
# freshly created herdr workspace, and prints the pane the root agent should
# start in. The apply REPLACES the workspace's first tab, so it must run
# before agent start; its JSON hands back the new panes as handles, and t0p0
# (first pane, first tab) is where the agent belongs. Standalone the CLI does
# not resolve the plugin's config dir, so the config path travels explicitly.
_run_apply_layout() { # <layout> <ws_id> <wsdir> <fallback-pane> -> pane id
  local layout="$1" ws_id="$2" wsdir="$3" fallback="$4"
  local wsm out pane cfg
  if ! wsm="$(_run_wsm_bin)"; then
    c_warn "workspace declares layout '$layout' but herdr-workspace-manager is not installed - layout skipped"
    printf '%s' "$fallback"; return 0
  fi
  if ! cfg="$(_run_layout_config "$wsdir" "$layout")"; then
    c_warn "layout '$layout' not defined in $wsdir/layouts.yml or the plane config - skipped"
    printf '%s' "$fallback"; return 0
  fi
  if ! out="$(HERDR_WSM_CONFIG="$cfg" \
              HERDR_WSM_WORKSPACE="$ws_id" HERDR_WSM_CWD="$wsdir" \
              "$wsm" apply "$layout" 2>&1)"; then
    c_warn "layout '$layout' failed to apply: $(printf '%s' "$out" | tail -1)"
    printf '%s' "$fallback"; return 0
  fi
  pane="$(printf '%s' "$out" | tail -1 | jq -r '.handles.t0p0 // empty' 2>/dev/null)"
  [ -n "$pane" ] && printf '%s' "$pane" || printf '%s' "$fallback"
}

# Reviewer panes live in the CALLER's herdr view (the orchestrator runs this
# from its own pane), in tabs labelled "PR reviewer". Panes are smart-sized:
# each new reviewer splits the tab's current largest pane along its longer
# visual edge. Six panes fill a tab; the seventh PR opens a fresh
# "PR reviewer" tab and the count restarts. No new workspace, no worktree -
# the reviewer only reads.
_RUN_REVIEW_TAB_CAP=6
_run_reviewer_pane() { # <cwd> -> pane id
  local ws="${HERDR_WORKSPACE_ID:-}" cwd="$1" tab pane resp n first
  [ -n "$ws" ] || die "cel run reviewer: not inside a herdr pane (no HERDR_WORKSPACE_ID)"
  # newest "PR reviewer" tab: earlier ones are already full
  tab="$(herdr tab list --workspace "$ws" \
         | jq -r '.result.tabs[] | select(.label == "PR reviewer") | .tab_id' | tail -1)"
  n=0
  if [ -n "$tab" ]; then
    read -r n first < <(herdr pane list --workspace "$ws" \
      | jq -r --arg t "$tab" '[.result.panes[] | select(.tab_id == $t)]
                              | "\(length) \(.[0].pane_id // "")"')
  fi
  if [ -z "$tab" ] || [ "$n" -ge "$_RUN_REVIEW_TAB_CAP" ]; then
    resp="$(herdr tab create --workspace "$ws" --label "PR reviewer" --cwd "$cwd" --no-focus)" \
      || die "cel run reviewer: tab create failed"
    pane="$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id // empty')"
  else
    # Largest pane by area gets the split, along its longer visual edge - a
    # terminal cell is roughly twice as tall as it is wide, hence the 2x.
    local target dir
    read -r target dir < <(herdr pane layout --pane "$first" \
      | jq -r '.result.layout.panes | max_by(.rect.width * .rect.height)
               | "\(.pane_id) \(if .rect.width >= 2 * .rect.height then "right" else "down" end)"')
    [ -n "$target" ] || die "cel run reviewer: could not read the PR reviewer tab layout"
    resp="$(herdr pane split --pane "$target" --direction "$dir" --cwd "$cwd" --no-focus)" \
      || die "cel run reviewer: pane split failed"
    pane="$(printf '%s' "$resp" | jq -r '.result.pane.pane_id // empty')"
  fi
  [ -n "$pane" ] || die "cel run reviewer: no pane id in herdr response"
  printf '%s' "$pane"
}

# THE TREE A REVIEWER READS. Until CEL-55 a reviewer pane opened in the
# ORCHESTRATOR'S OWN CHECKOUT ($ws/repos/<repo>) and was then told a PR
# number: nothing guaranteed that directory had any relationship to the pull
# request, and nothing kept it current. On 2026-09-21 it sat at d2da692 while
# main was at 81022b5 - eighteen commits and a whole day behind - and produced
# three wrong conclusions before lunch: a branch measured as 3x slower than a
# "main" that predated lib/orphans.sh, and a reviewer of #75 reporting that
# lib/wslife.sh "does not exist on this branch" hours after it landed. Both
# answers were truthful about the wrong tree.
#
# So a reviewer gets a checkout of its own, DETACHED at the PR's head, in the
# manner scouts already get a worktree: a linked git worktree of the
# orchestrator's clone, which costs a fetch rather than a clone and which the
# orchestrator cannot move underneath it. Detached on purpose - nothing in it
# is a branch, so there is nothing there to push.
_run_review_dir() { printf '%s' "${CEL_REVIEW_DIR:-$HOME/.local/state/cel/reviews}"; }

reviewer_checkout_path() { # <repo> <pr>
  printf '%s/%s-pr-%s' "$(_run_review_dir)" "$1" "$2"
}

# What GitHub says this PR is, asked once at launch: the head we are about to
# check out and the base branch the diff is against. Both travel into the
# brief, because a review whose "main" is a directory is not a review.
_run_reviewer_pr_facts() { # <repodir> <slug> <pr> [wsdir] -> head<TAB>base
  local out
  [ -n "$2" ] || return 1
  if [ -n "${4:-}" ]; then
    out="$(ws_gh "$4" pr view "$3" --repo "$2" --json headRefOid,baseRefName 2>/dev/null)" || return 1
  else
    out="$(gh pr view "$3" --repo "$2" --json headRefOid,baseRefName 2>/dev/null)" || return 1
  fi
  printf '%s' "$out" | jq -re '[.headRefOid, .baseRefName] | @tsv' 2>/dev/null
}

# The PR head reaches a fork's commits too, which is why this fetches
# `pull/<n>/head` rather than the branch name: a contributor's branch does not
# exist in origin at all.
reviewer_checkout_make() { # <repodir> <repo> <pr> <head> -> path
  local repodir="$1" repo="$2" pr="$3" head="$4" path
  path="$(reviewer_checkout_path "$repo" "$pr")"
  mkdir -p "$(dirname "$path")" || return 1
  # A leftover from a previous round is removed rather than reused: it is at
  # the head the PR had then, which is the staleness this ticket is about.
  _reviewer_worktree_drop "$repodir" "$path"
  git -C "$repodir" fetch -q origin "pull/$pr/head" 2>/dev/null || true
  git -C "$repodir" worktree add -q --detach "$path" "$head" 2>/dev/null || return 1
  printf '%s' "$path"
}

_reviewer_worktree_drop() { # <repodir> <path>
  [ -n "${2:-}" ] || return 0
  [ -e "$2" ] || [ -n "$1" ] || return 0
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || rm -rf -- "$2"
  git -C "$1" worktree prune >/dev/null 2>&1 || true
  return 0
}

# CEL-52 made a reviewer's pane close when its PR closes. A checkout that
# outlives the pane is the same litter in a new form, so whatever closes the
# reviewer calls this - `cel gc` does, right after the pane goes.
reviewer_checkout_release() { # <repo> <pr>
  local row path repodir
  row="$(reviewers_find "$1" "$2")" || return 0
  path="$(printf '%s' "$row" | jq -r '.checkout // ""')"
  repodir="$(printf '%s' "$row" | jq -r '.repodir // ""')"
  [ -n "$path" ] || return 0
  _reviewer_worktree_drop "$repodir" "$path"
  rm -rf -- "$path"
  return 0
}

# WHAT THE REVIEWER IS TOLD IT IS READING. Appended to the role body so the
# facts arrive with the agent rather than in whatever an orchestrator happens
# to type: the head SHA, the base it compares against, and the command that
# tells it the head has moved since this pane started - reviewing an older
# head is fine, reviewing one silently is how #75 happened.
_run_reviewer_brief() { # <repo> <pr> <head> <base> <path>
  cat <<EOF

## This review
You are reading a checkout of your own, detached at this pull request's head.
It is not the orchestrator's working copy and nothing moves it under you.

- repo: \`$1\`, pull request: #$2
- head you are reading: \`$3\` (in \`$5\`)
- base you compare against: \`origin/$4\` - say "origin/$4", never "main" as a
  directory, and anchor every claim about the base to that ref.

Before you conclude anything, check the head has not moved:
\`gh pr view $2 --repo $1 --json headRefOid\`. If it differs from \`$3\`, say so
in your verdict - you are reviewing an older head, which is a fact about the
review, not a detail. Nothing here is a branch, so there is nothing to push.
EOF
}

# THE REVIEWER REGISTRY. A worker is a DELEGATION: it has a ledger row, a
# worktree, a `release` verb and a gc pass, because something recorded that it
# exists. A reviewer was started by `cel run reviewer --repo r --pr n` and
# recorded NOWHERE, so nothing could know it was finished - measured on this
# box on 2026-09-21, seven idle `<repo>-pr-N-review` panes, six of them for
# PRs that had already merged, holding ~3.0 GB of RSS between them. `cel gc`
# could not even see them: it considers only panes under ~/.herdr/worktrees,
# and a reviewer runs in the orchestrator's own checkout.
#
# Deliberately NOT the delegation ledger: a reviewer is not a delegation and
# must not appear in `cel-fanout status`. It is box-level state, so it lives
# where the rest of the box's state does, beside gc-kept.json.
_reviewers_state() { printf '%s' "${CEL_REVIEWERS_STATE:-$HOME/.local/state/cel/reviewers.json}"; }

# A missing or corrupt file is an EMPTY registry, never an error: a stale file
# must break neither the launcher nor the sweep that reads it.
reviewers_rows() { # -> JSON array
  local f rows
  f="$(_reviewers_state)"
  [ -r "$f" ] || { printf '[]'; return 0; }
  rows="$(jq -ce 'if type == "array" and all(.[];
      (.repo | type == "string") and (.pane | type == "string") and (.pr != null))
    then . else [] end' "$f" 2>/dev/null)" || rows='[]'
  printf '%s' "$rows"
}

reviewers_write() { # <json-array> - the whole file, under the lock
  reviewers_update --argjson rows "$1" '$rows'
}

_reviewers_write_raw() { # <json-array> - the write itself; callers hold the lock
  local f tmp
  f="$(_reviewers_state)"
  mkdir -p "$(dirname "$f")" || return 1
  tmp="$(mktemp "$f.tmp.XXXXXX")" || return 1
  printf '%s\n' "$1" > "$tmp" && mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
}

# EVERY READ-MODIFY-WRITE OF THE REGISTRY HAPPENS HERE, UNDER A LOCK. The
# rename at the end is atomic, but the read before it is not: `cel gc` reads
# the rows, spends seconds in `gh` per reviewer and writes back, and a
# `cel run reviewer` that recorded a row in that window was simply gone -
# last write wins, so the next call for that PR split a duplicate pane and
# the one-reviewer-per-PR guarantee this file exists to give was lost.
#
# A registry somebody else is holding is REFUSED, never clobbered: the
# caller is told, and the worst case is a reviewer that is not indexed,
# which the gc pass discovers and adopts anyway.
reviewers_update() { # [jq-args...] <filter>
  local f lock fd="" rows next rc=0
  f="$(_reviewers_state)"; lock="$f.lock"
  mkdir -p "$(dirname "$f")" || return 1
  if have flock && exec {fd}>"$lock" 2>/dev/null; then
    if ! flock -w "${CEL_REVIEWERS_LOCK_WAIT:-10}" "$fd"; then
      exec {fd}>&-
      c_warn "the reviewer registry is held by another writer - not updated"
      return 1
    fi
  else
    fd=""
  fi
  rows="$(reviewers_rows)"
  if next="$(printf '%s' "$rows" | jq -c "$@")"; then
    _reviewers_write_raw "$next" || rc=1
  else
    rc=1
  fi
  if [ -n "$fd" ]; then flock -u "$fd"; exec {fd}>&-; fi
  return "$rc"
}

reviewers_find() { # <repo> <pr> -> the row, or fail
  local row
  row="$(reviewers_rows | jq -c --arg r "$1" --arg p "$2" \
    '[.[] | select(.repo == $r and ((.pr | tostring) == $p))][0] // empty')" || return 1
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# Replaces any row for the same repo+PR rather than appending: one pull
# request has one reviewer, and two rows for it are two panes nobody can tell
# apart.
#
# The checkout, the clone it was cut from and the head it was cut at are
# carried with the row because the sweep that closes the reviewer is the only
# thing left that can remove the worktree, and it knows nothing else about it.
reviewers_record() { # <repo> <pr> <pane> <agent> [checkout] [repodir] [head]
  reviewers_update --arg r "$1" --arg p "$2" --arg pane "$3" --arg a "$4" \
    --arg co "${5:-}" --arg rd "${6:-}" --arg head "${7:-}" \
    --argjson t "$(date +%s)" \
    'map(select(.repo != $r or ((.pr | tostring) != $p)))
     + [{repo:$r, pr:$p, pane:$pane, agent:$a, started_at:$t,
         checkout:$co, repodir:$rd, head:$head}]'
}

reviewers_drop() { # <repo> <pr>
  reviewers_update --arg r "$1" --arg p "$2" \
    'map(select(.repo != $r or ((.pr | tostring) != $p)))'
}

# THE REGISTRY IS AN INDEX, NOT THE DEFINITION OF EXISTENCE. Every reviewer
# that predates the registry - and on the box that produced this rule that
# was all seven of them - has no row and would be invisible to anything that
# only read the file. What it does have is the NAME `cel run reviewer` gave
# it (_run_agent_name of "<repo>/pr-<n>-review"), so the roster itself says
# which panes are reviewers and which pull request each is for.
#
# The repo comes from the pane's cwd when there is one: the agent name has
# been through the herdr name sanitiser (lowercased, truncated to 32) and is
# not reliably the repo's real name, while a reviewer's cwd is its checkout.
reviewers_discover() { # <agents-json> -> repo<TAB>pr<TAB>pane<TAB>agent<TAB>status
  local name pane cwd status pr repo
  while IFS=$'\t' read -r name pane cwd status; do
    [ -n "$name" ] && [ -n "$pane" ] || continue
    pr="${name##*-pr-}"; pr="${pr%-review}"
    case "$pr" in ''|*[!0-9]*) continue;; esac
    repo="${cwd##*/}"
    [ -n "$repo" ] || repo="${name%-pr-*}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$repo" "$pr" "$pane" "$name" "$status"
  done < <(printf '%s' "${1:-}" | jq -r '.result.agents[]?
    | select(((.name // "") | test("^.+-pr-[0-9]+-review$")) and ((.pane_id // "") != ""))
    | [(.name // ""), .pane_id, (.cwd // ""), (.agent_status // "unknown")] | @tsv' 2>/dev/null)
  return 0
}

# herdr agent names must match [a-z][a-z0-9_-]{0,31} - no slash, no uppercase.
# The readable `repo/role` form survives as the herdr workspace label; this is
# only what the agent answers to.
_run_agent_name() { # <alias>
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
  n="${n#"${n%%[a-z]*}"}"   # must start with a letter
  n="${n%-}"
  printf '%.32s' "$n"
}

# WHO IS ALREADY STANDING HERE. An orchestrator's identity in this plane is a
# DIRECTORY, not a name: on 2026-09-18 herdr cleared `widget-orch`'s name
# when it restarted and every surface that resolves an orchestrator by its
# alias then read the live pane as dead - which invites starting a second one
# on top of it. The roster carries each agent's cwd, so the question "is
# anything alive in this product's directory" has an answer that survives a
# lost name. Empty when herdr cannot be asked: silence from the observer is
# not evidence about the observed, and a refusal on it would block every
# launch on a box whose herdr is restarting.
#
# A NAMELESS AGENT REPORTS ITS NAME AS `-`, never as an empty field: tab is an
# IFS whitespace character, so a leading empty column collapses under `read`
# and the pane id would arrive in the name's place.
_run_live_agent_in_cwd() { # <cwd> -> name<TAB>pane<TAB>status, or nothing
  local cwd="$1" roster
  have herdr && have jq || return 0
  roster="$(herdr agent list 2>/dev/null)" || return 0
  [ -n "$roster" ] || return 0
  printf '%s' "$roster" | jq -r --arg c "$cwd" \
    '[.result.agents[]? | select((.cwd // "") == $c)
      | select((.agent_status // "") != "")][0] // empty
     | [((.name // "") | if . == "" then "-" else . end),
        (.pane_id // ""), (.agent_status // "")] | @tsv' 2>/dev/null || true
}

# Renders AGENT_ARGS for a --dry-run preview: whichever element IS the body
# verbatim is replaced with its length, everything else prints as-is.
_run_dry_agent_args() {
  local out=() a
  for a in "${AGENT_ARGS[@]}"; do
    if [ "$a" = "$RUN_BODY" ]; then
      out+=("<body:${#RUN_BODY} chars>")
    else
      out+=("$a")
    fi
  done
  printf '%s' "${out[*]}"
}

# --- the console ----------------------------------------------------------
# The console is the one pane that is not IN a workspace. It routes across all
# of them, so resolving a workspace for it would be arbitrary: whichever
# directory the operator happened to start it from would silently become the
# default for every command that takes a --workspace. It gets a directory of
# its own instead, outside every checkout, where its notes and its role file
# live and where the guard lets it write.
_run_console_dir() { printf '%s' "${CEL_CONSOLE_DIR:-$HOME/.local/share/cel/console}"; }

# No policy block. Every other role's body ends with the workspace's policy
# because the workspace is the thing it is bound to; the console is bound to
# the box, and a policy block from an arbitrary workspace would read as
# authority it does not have.
#
# The vocabulary table is INCLUDED rather than carried: the TUI's translator
# puts the same table in its system message (tools/console/translate.mjs), and
# two copies of it would mean the two consoles disagreeing about what the
# console may do the first time someone edited one of them.
_run_console_body() {
  local f="$CEL_ROOT/core/roles/console.md" vocab="$CEL_ROOT/tools/console/vocabulary.md"
  local line
  while IFS= read -r line; do
    case "$line" in
      '<!-- cel:include tools/console/vocabulary.md -->')
        # Strip the file's own explanatory comment: it is addressed to whoever
        # edits the table, not to the agent reading the prompt.
        sed '/^<!--/,/-->$/d' "$vocab" | sed '/^$/{ /./!d }'
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$f"
}

# The console's launch settings come from agents.yaml `defaults.console`.
_run_console_default() { # <runtime|model|thinking>
  manifest_default console | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

_run_console() { # <profile> <model-opt> <thinking-opt> <dry-run> <agent 0|1>
  local profile="$1" model_opt="$2" thinking_opt="$3" dry="$4" agent="${5:-1}"
  # THE DEFAULT CONSOLE IS NOT AN AGENT ANY MORE. `cel console` is the plane's
  # own interface (lib/console.sh): deterministic panels and a small model
  # wired into one job. The Claude pane survives behind --agent for people who
  # want to talk to a full agent, but a bare `cel run console` must not
  # silently start the expensive thing when the cheap thing is what the README
  # now leads with.
  if [ "$agent" -ne 1 ]; then
    printf 'cel run console now starts an AGENT pane; the console itself is `cel console`.\n' >&2
    printf 'Use `cel console` for the TUI, or `cel run console --agent` for the agent pane.\n' >&2
    return 2
  fi
  [ -z "$profile" ] || die "cel run console: --profile is meaningless without a workspace (profiles are bound per workspace) - use --model/--thinking"
  have jq || die "cel run console: jq is not on PATH"

  local cwd runtime model thinking
  cwd="$(_run_console_dir)"
  runtime="$(_run_console_default runtime)"
  [ -n "$runtime" ] || die "cel run console: agents.yaml declares no defaults.console.runtime"
  model="$(_run_console_default model)"; thinking="$(_run_console_default thinking)"
  [ -z "$model_opt" ]    || model="$model_opt"
  [ -z "$thinking_opt" ] || thinking="$thinking_opt"

  [ "$dry" -eq 1 ] || mkdir -p "$cwd"

  local RUN_BODY; RUN_BODY="$(_run_console_body)"
  local AGENT_ARGS=() AGENT_ROLE_FILE=""
  # The role file keeps the `role-*.md` shape on purpose: lib/gc.sh tells a
  # long-lived agent from a stray one by that substring in the cmdline, and
  # the console is the longest-lived pane on the box.
  _run_agent_args "$runtime" console "$RUN_BODY" "$dry" "$cwd" "$cwd/role-console.md"

  local -a PROFILE_ARGS=()
  profile_launch_args "$runtime" "$model" "$thinking"
  [ "${#PROFILE_ARGS[@]}" -eq 0 ] || AGENT_ARGS=("${PROFILE_ARGS[@]}" "${AGENT_ARGS[@]}")

  # Same guard hook as root and the orchestrators - for the console it carries
  # an allowlist rather than a deny list (lib/guard.sh).
  local gflag gfile
  gflag="$(agent_guard_hook "$runtime" flag)"; gfile="$(agent_guard_hook "$runtime" file)"
  if [ -n "$gflag" ] && [ -n "$gfile" ]; then
    AGENT_ARGS=("$gflag" "$CEL_ROOT/$gfile" "${AGENT_ARGS[@]}")
  fi
  _run_keep_model_args "$runtime"

  local -a launch_args=()
  mapfile -t launch_args < <(agent_launch_args "$runtime")
  [ "${#launch_args[@]}" -eq 0 ] || AGENT_ARGS=("${launch_args[@]}" "${AGENT_ARGS[@]}")

  local -a CREATE_ARGS=(workspace create --cwd "$cwd" --label celestial/console)
  local envprefix; envprefix="$(_run_launch_env console "$cwd" "$AGENT_ROLE_FILE")"
  if [ "$dry" -eq 1 ]; then
    printf 'herdr %s\n' "${CREATE_ARGS[*]}"
    printf 'herdr pane send-text <pane> %s\n' "$envprefix"
    printf 'herdr agent start console --kind %s --pane <pane> -- %s\n' \
      "$runtime" "$(_run_dry_agent_args)"
    return 0
  fi

  have herdr || die "cel run: herdr is not on PATH"
  local resp ws_id pane_id
  resp="$(herdr "${CREATE_ARGS[@]}")"
  ws_id="$(printf '%s' "$resp" | jq -r '.. | .workspace_id? // empty' | head -1)"
  pane_id="$(printf '%s' "$resp" | jq -r '.. | .pane_id? // empty' | head -1)"
  [ -n "$pane_id" ] && [ "$pane_id" != "null" ] || pane_id="${ws_id}:p1"
  _run_mark_launch "$pane_id" "$envprefix"
  herdr agent start console --kind "$runtime" --pane "$pane_id" -- "${AGENT_ARGS[@]}"
}

# --- resuming root and the orchestrators (CEL-63) --------------------------
# Restarting an orchestrator to pick up new launch flags used to throw its
# conversation away: `cel run orchestrator` always started fresh, and the only
# way to keep context was a hand-written script. And omp's --continue is not
# a substitute - three omp sessions shared the celestial checkout's cwd and
# --continue takes the newest, not the orchestrator's. So a resume always
# names the exact session herdr recorded for the pane.

# The last session seen for each root/orchestrator DIRECTORY - identity here
# is a directory, not a name (see _run_live_agent_in_cwd) - so an
# orchestrator that died can be brought back into its own conversation.
_run_sessions_file() {
  if [ -n "${CEL_ORCH_SESSIONS:-}" ]; then printf '%s' "$CEL_ORCH_SESSIONS"
  elif [ -n "${CEL_TESTING:-}" ]; then printf '%s' "${TMPDIR:-/tmp}/cel-orch-sessions.json"
  else printf '%s' "$HOME/.local/state/cel/orch-sessions.json"; fi
}

_run_sessions_record() { # <cwd> <session>
  local f tmp cur
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  f="$(_run_sessions_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  cur="$(jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null)" || cur='{}'
  [ -n "$cur" ] || cur='{}'
  tmp="$(mktemp "$f.tmp.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s' "$cur" | jq -c --arg c "$1" --arg s "$2" '.[$c] = $s' > "$tmp"; then
    mv -f -- "$tmp" "$f"
  else
    rm -f -- "$tmp"
  fi
  return 0
}

_run_sessions_last() { # <cwd> -> session, or nothing
  jq -r --arg c "$1" '.[$c] // empty' "$(_run_sessions_file)" 2>/dev/null || true
}

# Remember the session of every live root/orchestrator in a roster. Cheap, so
# the steward calls it every tick: the record is what makes "resume the last
# session" possible after the agent is gone.
run_sessions_note_roster() { # <agents-json>
  local cwd sess
  while IFS=$'\t' read -r cwd sess; do
    [ -n "$cwd" ] && [ -n "$sess" ] && _run_sessions_record "$cwd" "$sess"
  done < <(printf '%s' "${1:-}" | jq -r '.result.agents[]?
    | select((.name // "") | test("(-orch|-root)$"))
    | select((.agent_session.value // "") != "")
    | [(.cwd // ""), .agent_session.value] | @tsv' 2>/dev/null)
  return 0
}

# The live agent for a root/orchestrator, BY HERDR NAME. The owner's
# hand-written restart script chose by cwd and took the FIRST omp in the
# celestial checkout: that was another session in another pane, which it
# relaunched as `celestial-orch` with the inbox hook while the real
# orchestrator lost its name. So cwd+runtime is a fallback ONLY when exactly
# one agent there matches; several is an ambiguity the operator settles with
# --pane. A missing name or session is `-` so tab-splitting keeps columns.
#
# Status: 0 found (one row), 1 none, 3 ambiguous (every candidate row),
# 4 the named --pane holds an agent under ANOTHER name (that row) - which is
# never relaunched: that pane is not this orchestrator.
_run_orch_agent() { # <name> <cwd> <runtime> [pane] -> name<TAB>pane<TAB>status<TAB>session
  local roster rows n
  roster="$(herdr agent list 2>/dev/null)" || return 1
  rows="$(printf '%s' "$roster" | jq -r --arg n "$1" --arg c "$2" --arg r "$3" --arg p "${4:-}" '
    def row: [((.name // "") | if . == "" then "-" else . end), .pane_id,
              (.agent_status // "unknown"),
              ((.agent_session.value // "") | if . == "" then "-" else . end)] | @tsv;
    [.result.agents[]? | select((.pane_id // "") != "")] as $a
    | if $p != "" then ($a[] | select(.pane_id == $p) | row)
      elif ([$a[] | select(.name == $n)] | length) > 0 then ([$a[] | select(.name == $n)][0] | row)
      else ($a[] | select((.cwd // "") == $c and (.agent // "") == $r) | row) end' 2>/dev/null)" || rows=""
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows"
  if [ -n "${4:-}" ]; then
    n="$(printf '%s' "$rows" | cut -f1)"
    [ "$n" = "-" ] || [ "$n" = "$1" ] || return 4
    return 0
  fi
  [ "$(printf '%s\n' "$rows" | wc -l)" -eq 1 ] || return 3
  return 0
}

_run_proc_root() { printf '%s' "${CEL_PROC_ROOT:-/proc}"; }

# THE PROCESS BEHIND A ROOT/ORCHESTRATOR. herdr's roster carries no pid, but
# the launch marks the process's environment with CEL_INBOX_ME and
# CEL_WORKSPACE (_run_launch_env), which nothing rewrites. Its own tool
# shells inherit that environment too, so the runtime binary must be argv[0].
_run_orch_pid() { # <inbox-me> <wsdir> <runtime> -> newest pid, or fail
  local d pid best="" env a0
  for d in "$(_run_proc_root)"/[0-9]*; do
    [ -r "$d/environ" ] || continue
    env="$(tr '\0' '\n' < "$d/environ" 2>/dev/null)" || continue
    printf '%s\n' "$env" | grep -qxF "CEL_INBOX_ME=$1" || continue
    printf '%s\n' "$env" | grep -qxF "CEL_WORKSPACE=$2" || continue
    a0="$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | sed -n 1p)" || continue
    [ "${a0##*/}" = "$3" ] || continue
    pid="${d##*/}"
    if [ -z "$best" ] || [ "$pid" -gt "$best" ]; then best="$pid"; fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

_run_cmdline() { # <pid> -> argv, one per line
  tr '\0' '\n' < "$(_run_proc_root)/$1/cmdline" 2>/dev/null || true
}

# What a launch line is made of, for comparing two of them: each flag with the
# value that follows it. The role prompt's PATH does not count (a product can
# move its role file without its launch being stale), nor does a resume.
run_launch_items() { # <argv, one per line on stdin> -> items, one per line
  local -a v; mapfile -t v
  local i=1 n="${#v[@]}" a b
  while [ "$i" -lt "$n" ]; do
    a="${v[$i]}"; b="${v[$((i+1))]:-}"
    case "$a" in
      --*)
        if [ -n "$b" ] && [ "${b#--}" = "$b" ]; then i=$((i+2)); else b=""; i=$((i+1)); fi
        case "$a" in --resume|--continue) continue ;; esac
        case "$b" in *role-*.md|'<body:'*) continue ;; esac
        if [ -n "$b" ]; then printf '%s %s\n' "$a" "$b"; else printf '%s\n' "$a"; fi ;;
      *) i=$((i+1)) ;;
    esac
  done
}

_run_item_label() { # <item> -> how a human names it
  case "$1" in
    *inbox.omp.ts|*inbox*.ts) printf 'inbox hook' ;;
    *orchestrator-guard*) printf 'guard hook' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Expected items the actual argv lacks, as a comma-separated human list.
run_launch_missing() { # <expected-argv-file> <actual-argv-file>
  local item out=""
  local have_items; have_items="$(run_launch_items < "$2")"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    printf '%s\n' "$have_items" | grep -qxF -- "$item" && continue
    out="${out:+$out, }$(_run_item_label "$item")"
  done < <(run_launch_items < "$1")
  printf '%s' "$out"
}

# Both directions of the difference (Sourcery on #98): a flag the current
# launch has DROPPED is as stale as one it added, so the old line carries
# something the plane decided to stop passing. Empty when the lines agree.
run_launch_diff() { # <expected-argv-file> <actual-argv-file> -> "missing: ...; extra: ..."
  local missing extra out=""
  missing="$(run_launch_missing "$1" "$2")"
  extra="$(run_launch_missing "$2" "$1")"
  [ -z "$missing" ] || out="missing: $missing"
  [ -z "$extra" ] || out="${out:+$out; }extra: $extra"
  printf '%s' "$out"
}

_run_restart_wait() { # <pane>: until no agent is live in it
  local i=0
  while [ "$i" -lt "${CEL_RESTART_WAIT:-20}" ]; do
    herdr agent list 2>/dev/null | jq -e --arg p "$1" \
      'any(.result.agents[]?; .pane_id == $p)' >/dev/null 2>&1 || return 0
    sleep "${CEL_RESTART_SLEEP:-1}"; i=$((i+1))
  done
  return 1
}

# Did the new process come up with the hooks this launch asked for?
_run_restart_confirm() { # <inbox-me> <wsdir> <runtime> <name> <argv...>
  local me="$1" wsdir="$2" rt="$3" name="$4"; shift 4
  local i=0 pid="" exp act missing
  while [ "$i" -lt "${CEL_RESTART_WAIT:-20}" ]; do
    pid="$(_run_orch_pid "$me" "$wsdir" "$rt")" && break
    sleep "${CEL_RESTART_SLEEP:-1}"; i=$((i+1))
  done
  if [ -z "$pid" ]; then
    c_warn "$name was started but its process could not be found - check the pane"
    return 0
  fi
  exp="$(mktemp)"; act="$(mktemp)"
  printf '%s\n' "$rt" "$@" > "$exp"; _run_cmdline "$pid" > "$act"
  missing="$(run_launch_missing "$exp" "$act")"
  rm -f -- "$exp" "$act"
  if [ -n "$missing" ]; then
    c_warn "$name restarted (pid $pid) but its process lacks: $missing"
  else
    local hooks="" a
    for a in "$@"; do case "$a" in *.ts) hooks="${hooks:+$hooks, }$(_run_item_label "$a")" ;; esac; done
    c_ok "$name restarted (pid $pid)${hooks:+ with $hooks}"
  fi
  return 0
}

cmd_run() { # [role] [--repo r] [--product p] [--workspace w] [--branch b] [--pr n] [--profile p] [--model m] [--thinking l] [--dry-run] [--restart [--pane p]] [--fresh] [--force]
  local role="" repo="" product="" workspace="" branch="" pr="" dry_run=0 agent=0 force=0
  local restart=0 fresh=0 pane_opt=""
  local profile="" model_opt="" thinking_opt=""

  if [ $# -gt 0 ]; then
    case "$1" in
      root|orchestrator|worker|reviewer|console) role="$1"; shift ;;
      --*) : ;;
      *) die "cel run: unknown role '$1' (want root, orchestrator, worker, reviewer or console; omit for direct)" ;;
    esac
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      repo="$2"; shift 2 ;;
      --product)   product="$2"; shift 2 ;;
      --workspace) workspace="$2"; shift 2 ;;
      --branch)    branch="$2"; shift 2 ;;
      --pr)        pr="$2"; shift 2 ;;
      --profile)   profile="$2"; shift 2 ;;
      --model)     model_opt="$2"; shift 2 ;;
      --thinking)  thinking_opt="$2"; shift 2 ;;
      --dry-run)   dry_run=1; shift ;;
      --force)     force=1; shift ;;
      --restart)   restart=1; shift ;;
      --fresh)     fresh=1; shift ;;
      --pane)      pane_opt="$2"; restart=1; shift 2 ;;
      --agent)     agent=1; shift ;;
      *) die "cel run: unknown argument '$1'" ;;
    esac
  done

  # The console resolves NO workspace - see _run_console. It has to return
  # before the resolution below, which would otherwise die for want of one.
  case "$role" in
    root|orchestrator) ;;
    *) [ "$restart" -eq 0 ] && [ "$fresh" -eq 0 ] \
         || die "cel run: --restart and --fresh are for root and orchestrator only - workers and reviewers never resume" ;;
  esac
  if [ "$role" = console ]; then
    _run_console "$profile" "$model_opt" "$thinking_opt" "$dry_run" "$agent"
    return $?
  fi

  local wsdir
  if [ -n "$workspace" ]; then
    wsdir="$(registry_require "$workspace")"
  else
    wsdir="$(ws_current)" || die "cel run: not inside a workspace (cd into one, or pass --workspace <name>)"
  fi

  # FAIL CLOSED ON IDENTITY (CEL-70). A pane whose declared GitHub account
  # cannot produce a token would act as whichever account is active - the
  # exact mistake the github: block exists to prevent. Dry runs too: a
  # preview of a launch that would refuse must not look like a success.
  ws_github_ready "$wsdir" \
    || die "cel run: refusing to launch for workspace '$(ws_name "$wsdir")': $(ws_github_fix "$(ws_github_user "$wsdir")")"

  # --repo is required for every mode but root, unless there is exactly one
  # thing to default to. For an orchestrator that thing is a PRODUCT: a
  # workspace of two repos in one declared product has one orchestrator, and
  # making it name a repo would be asking for information it does not have.
  if [ "$role" != "root" ] && [ -z "$repo" ] && [ -z "$product" ]; then
    local repos prods; mapfile -t repos < <(ws_repo_names "$wsdir")
    mapfile -t prods < <(ws_product_names "$wsdir")
    if [ "$role" = "orchestrator" ] && [ "${#prods[@]}" -eq 1 ]; then
      product="${prods[0]}"
    elif [ "${#repos[@]}" -eq 1 ]; then
      repo="${repos[0]}"
    elif [ "$role" = "orchestrator" ]; then
      die "cel run: --product or --repo is required (workspace '$(ws_name "$wsdir")' has ${#prods[@]} products)"
    else
      die "cel run: --repo is required (workspace '$(ws_name "$wsdir")' has ${#repos[@]} repos)"
    fi
  fi
  # --product is an orchestrator's flag; every other role works in a checkout.
  [ "$role" = "orchestrator" ] || [ -n "$repo" ] || [ "$role" = "root" ] \
    || die "cel run: --repo is required for $role (--product names a product, which has no checkout of its own)"

  local tag="${role:-direct}" alias_name cwd runtime rolefile="" bind="$repo"
  local review_head="" review_base="" review_path="" repodir=""
  case "$role" in
    "")
      alias_name="$repo/direct"
      cwd="$wsdir/repos/$repo"
      runtime="$(ws_runtime "$wsdir" orchestrator)"
      ;;
    root)
      alias_name="$(ws_name "$wsdir")/root"
      cwd="$wsdir"
      runtime="$(ws_runtime "$wsdir" root)"
      rolefile="$CEL_ROOT/core/roles/root-orchestrator.md"
      ;;
    orchestrator)
      # --repo still works and means "the product this repo belongs to", so a
      # member repo never opens an orchestrator of its own.
      [ -n "$product" ] || product="$(ws_product_of_repo "$wsdir" "$repo")"
      bind="$product"
      alias_name="$product/orch"
      cwd="$(ws_product_dir "$wsdir" "$product")"
      runtime="$(ws_runtime "$wsdir" orchestrator)"
      rolefile="$CEL_ROOT/core/roles/project-orchestrator.md"
      ;;
    worker)
      [ -n "$branch" ] || die "cel run worker: --branch is required"
      alias_name="$repo/$branch"
      runtime="$(ws_runtime "$wsdir" worker)"
      rolefile="$CEL_ROOT/core/roles/worker.md"
      ;;
    reviewer)
      [ -n "$pr" ] || die "cel run reviewer: --pr is required"
      runtime="$(ws_review "$wsdir" runtime)"
      [ -n "$runtime" ] || die "cel run reviewer: workspace '$(ws_name "$wsdir")' declares no review: block"
      alias_name="$repo/pr-$pr-review"
      cwd="$wsdir/repos/$repo"
      rolefile="$CEL_ROOT/core/roles/pr-reviewer.md"
      # ONE PULL REQUEST, ONE REVIEWER. Asking for a reviewer that is already
      # standing gets that one back; before this, a second `cel run reviewer
      # --pr 71` split another pane over the same PR and left no way to tell
      # the two apart. Checked before anything is created, so a dry run
      # previews the reuse honestly and no row is written twice.
      local existing
      if existing="$(reviewers_find "$repo" "$pr")"; then
        c_ok "reviewer for $repo#$pr is already running as $(printf '%s' "$existing" | jq -r '.agent // "?"') in pane $(printf '%s' "$existing" | jq -r .pane) - reusing it"
        return 0
      fi
      # AND THE TREE IT READS IS THE PR'S, not this directory's. A dry run
      # asks GitHub nothing and creates nothing: it is a preview of a launch,
      # and a preview that fetches is a side effect.
      repodir="$cwd"
      review_path="$(reviewer_checkout_path "$repo" "$pr")"
      if [ "$dry_run" -eq 0 ]; then
        have gh || die "cel run reviewer: gh is not on PATH - the PR's head cannot be resolved"
        have jq || die "cel run reviewer: jq is not on PATH"
        local facts slug
        slug="$(ws_repo_github_slug "$wsdir" "$repo" "$repodir")" || slug=""
        facts="$(_run_reviewer_pr_facts "$repodir" "$slug" "$pr" "$wsdir")" \
          || die "cel run reviewer: cannot read $repo#$pr from GitHub - a reviewer without a head SHA would review whatever tree it stood in, which is the bug this refuses"
        IFS=$'\t' read -r review_head review_base <<< "$facts"
        [ -n "$review_head" ] \
          || die "cel run reviewer: GitHub returned no head SHA for $repo#$pr"
        review_path="$(reviewer_checkout_make "$repodir" "$repo" "$pr" "$review_head")" \
          || die "cel run reviewer: could not check out $repo#$pr at $review_head (is $repodir a clone of $repo?)"
        cwd="$review_path"
      fi
      ;;
  esac

  # ONE ORCHESTRATOR PER PRODUCT, AND THE DUPLICATE IS REFUSED HERE. This is
  # the only door that starts one, so it is the only place the refusal cannot
  # be routed around. A live agent in the product's own directory IS its
  # orchestrator whether or not herdr still knows its name - a nameless one is
  # a fault with a cure (`cel ws up` renames it), never an absence. The check
  # runs on a dry run too: a preview of a launch that would be refused is a
  # preview of something that will not happen.
  if [ "$role" = orchestrator ] && [ "$force" -eq 0 ] && [ "$restart" -eq 0 ]; then
    local occupant oname opane
    occupant="$(_run_live_agent_in_cwd "$cwd")"
    if [ -n "$occupant" ]; then
      IFS=$'\t' read -r oname opane _ <<< "$occupant"
      [ "$oname" != "-" ] || oname="<unnamed>"
      die "cel run orchestrator: an agent is already live in $cwd (pane ${opane:-?}, name $oname)
  Starting a second orchestrator over a live one is the duplicate this refusal exists to prevent.
  Name it and adopt it:  cel ws up $(ws_name "$wsdir")
  Or say you mean it:    cel run orchestrator --product ${product:-$repo} --force"
    fi
  fi

  # Model and reasoning level, resolved before the role body is rendered
  # because a profile may CHANGE THE RUNTIME - and the runtime decides how the
  # role is injected, so picking it late would inject the role in the
  # wrong shape. Precedence, weakest first: the workspace default level, then
  # the named profile, then explicit flags.
  local model="" thinking
  thinking="$(ws_thinking "$wsdir")"
  # A reviewer's model has always come from the `review:` block; a profile or
  # an explicit --model still overrides it.
  [ "$role" = "reviewer" ] && model="$(ws_review "$wsdir" model)"

  # No --profile? The workspace may still bind one to this role. That binding
  # is what makes root and the orchestrators configurable at all: neither is
  # launched by hand, so a flag would never reach them.
  # A repo or product may narrow that binding for itself; see role_profile_for.
  [ -n "$profile" ] || profile="$(role_profile_for "$wsdir" "$tag" "$bind")"

  local PROFILE_RUNTIME PROFILE_MODEL PROFILE_THINKING PROFILE_NOTE PROFILE_ISOLATE="" PROFILE_VETO=""
  local PROFILE_VIA="" PROFILE_WSDIR="" PROFILE_GATEWAY_ACCOUNTS=0
  if [ -n "$profile" ]; then
    profile_resolve "$wsdir" "$profile" "$runtime"
    [ -z "$PROFILE_VETO" ] || die "cel run: profile '$profile' is vetoed - $PROFILE_VETO"
    runtime="$PROFILE_RUNTIME"; thinking="$PROFILE_THINKING"
    # A profile that names no model leaves the model alone, so binding a
    # reviewer to a profile for its RUNTIME or effort does not quietly discard
    # the `review:` block's model.
    [ -z "$PROFILE_MODEL" ] || model="$PROFILE_MODEL"
  fi
  [ -z "$model_opt" ]    || model="$model_opt"
  [ -z "$thinking_opt" ] || thinking="$thinking_opt"

  local RUN_BODY
  if [ -n "$rolefile" ]; then
    RUN_BODY="$(ws_render_role "$wsdir" "$rolefile" "${product:-}")"
  else
    RUN_BODY="$(ws_policy_block "$wsdir")"
  fi
  # The facts about THIS pull request ride with the role body rather than
  # waiting for an orchestrator to type them.
  if [ "$role" = "reviewer" ] && [ "$dry_run" -eq 0 ]; then
    RUN_BODY="$RUN_BODY
$(_run_reviewer_brief "$repo" "$pr" "$review_head" "$review_base" "$review_path")"
  fi

  local AGENT_ARGS=() AGENT_ROLE_FILE="" bodyfile
  bodyfile="$(_run_role_file "$wsdir" "$tag" "${product:-}")"
  # ONE ROLE FILE PER PULL REQUEST. The body now carries a head SHA, so a
  # shared $ws/.cel/role-reviewer.md would have two reviewers overwriting each
  # other's brief and one of them reading a SHA from the other's PR. The name
  # still ENDS in role-reviewer.md: lib/gc.sh tells a long-lived agent from a
  # stray one by that substring.
  [ "$role" = "reviewer" ] && bodyfile="$wsdir/.cel/reviews/pr-$pr/role-reviewer.md"
  _run_agent_args "$runtime" "$tag" "$RUN_BODY" "$dry_run" "$wsdir" "$bodyfile"

  # Model and thinking flags ride ahead of the role injection, spelled the way
  # THIS runtime spells them (agents.yaml model_flag / thinking) rather than
  # assuming --model, which is what limited this to claude and omp before.
  local -a PROFILE_ARGS=()
  profile_launch_args "$runtime" "$model" "$thinking" "${PROFILE_ISOLATE:-}"
  [ "${#PROFILE_ARGS[@]}" -eq 0 ] || AGENT_ARGS=("${PROFILE_ARGS[@]}" "${AGENT_ARGS[@]}")

  # READ-ONLY ORCHESTRATORS. Root and the sub-orchestrators get the runtime's
  # guard hook so repository writes from their panes are refused at the tool
  # call; workers and reviewers do not - writing is a worker's whole job, and a
  # reviewer only reads. Enforced here rather than requested in the role text,
  # because a prompt was what caused the incident this exists to prevent.
  case "$role" in
    root|orchestrator)
      local gflag gfile
      gflag="$(agent_guard_hook "$runtime" flag)"; gfile="$(agent_guard_hook "$runtime" file)"
      if [ -n "$gflag" ] && [ -n "$gfile" ]; then
        AGENT_ARGS=("$gflag" "$CEL_ROOT/$gfile" "${AGENT_ARGS[@]}")
      fi
      # Out-of-band inbox delivery for runtimes without Monitor/UserPromptSubmit.
      gflag="$(agent_inbox_hook "$runtime" flag)"; gfile="$(agent_inbox_hook "$runtime" file)"
      if [ -n "$gflag" ] && [ -n "$gfile" ]; then
        AGENT_ARGS=("$gflag" "$CEL_ROOT/$gfile" "${AGENT_ARGS[@]}")
      fi ;;
  esac
  _run_keep_model_args "$runtime"

  # Runtime-wide launch flags (agents.yaml launch_args) go ahead of the
  # role-injection args on every launch of that runtime.
  local -a launch_args=()
  mapfile -t launch_args < <(agent_launch_args "$runtime")
  [ "${#launch_args[@]}" -eq 0 ] || AGENT_ARGS=("${launch_args[@]}" "${AGENT_ARGS[@]}")

  local agent_name; agent_name="$(_run_agent_name "$alias_name")"
  local envprefix; local inbox_me=""
  case "$role" in root) inbox_me=root ;; orchestrator) inbox_me="$product-orch" ;; esac
  envprefix="$(_run_launch_env "$tag" "$wsdir" "$AGENT_ROLE_FILE" "$inbox_me")"

  # RESUME (CEL-63). Root and the orchestrators carry their conversation
  # across a restart; workers and reviewers never do - each is one ticket or
  # one PR, and a resumed one would carry the last job's context into this.
  local resume_session="" restart_pane=""
  if [ "$role" = root ] || [ "$role" = orchestrator ]; then
    local live="" lname lpane lstatus lsession
    local lrc=1
    if have herdr && have jq; then
      live="$(_run_orch_agent "$agent_name" "$cwd" "$runtime" "$pane_opt")" && lrc=0 || lrc=$?
    fi
    case "$lrc" in
      0) ;;
      3)
        if [ "$restart" -eq 1 ]; then
          c_err "cel run $role --restart: no agent is named $agent_name and $(printf '%s\n' "$live" | wc -l | tr -d ' ') $runtime agents share $cwd - refusing to guess which is the orchestrator:" >&2
          printf '%s\n' "$live" | awk -F '\t' '{ printf "    pane %s  name %s  status %s  session %s\n", $2, $1, $3, $4 }' >&2
          die "  pass the right one: cel run $role${product:+ --product $product} --workspace $(ws_name "$wsdir") --restart --pane <pane>"
        fi
        live="" ;;
      4)
        die "cel run $role --restart: pane $pane_opt runs $(printf '%s' "$live" | cut -f1), not $agent_name - it will not be renamed or relaunched" ;;
      *)
        [ -z "$pane_opt" ] || die "cel run $role --restart: no agent is live in pane $pane_opt"
        live="" ;;
    esac
    if [ -n "$live" ]; then
      IFS=$'\t' read -r lname lpane lstatus lsession <<< "$live"
      [ "$lsession" != "-" ] || lsession=""
      _run_sessions_record "$cwd" "$lsession"
    fi
    if [ "$restart" -eq 1 ]; then
      if [ -z "$live" ]; then
        printf '  no live agent for %s in %s - launching it\n' "$agent_name" "$cwd" >&2
      else
        # Never kill a turn in progress by default: the owner may be mid-way
        # through something the plane cannot see.
        if [ "$lstatus" = working ] && [ "$force" -eq 0 ]; then
          die "cel run $role --restart: $agent_name (pane $lpane) is working - a restart now would kill its turn. Wait for it to go idle, or pass --force"
        fi
        restart_pane="$lpane"
        [ "$fresh" -eq 1 ] || resume_session="$lsession"
      fi
    fi
    # Over a dead or absent agent, come back into the last recorded session.
    if [ "$fresh" -eq 0 ] && [ -z "$resume_session" ] && [ -z "$live" ]; then
      resume_session="$(_run_sessions_last "$cwd")"
    fi
    if [ -n "$resume_session" ]; then
      local rflag; rflag="$(agent_resume "$runtime" flag)"
      if [ -n "$rflag" ]; then
        AGENT_ARGS+=("$rflag" "$resume_session")
        printf '  resuming %s from %s\n' "$agent_name" "$resume_session" >&2
      else
        printf '  runtime %s cannot resume a session - %s is starting fresh\n' "$runtime" "$agent_name" >&2
        resume_session=""
      fi
    elif [ "$fresh" -eq 0 ]; then
      printf '  no previous session recorded for %s - starting fresh\n' "$agent_name" >&2
    fi
  fi

  # THROUGH THE GATEWAY. A `via: gateway` profile does not reach a provider:
  # it reaches this box's auth-gateway, which holds several subscriptions per
  # provider and picks one BY SESSION KEY. pi sends no session identity of its
  # own (proved with a logging proxy in SPIKE-gateway), so the only lever is a
  # provider `headers` entry bound to an environment variable - which means
  # the pane needs two variables set before the agent starts:
  #
  #   OMP_GATEWAY_TOKEN  the bearer, READ IN THE PANE by omp itself. The plane
  #                      never handles the value: it types a line containing a
  #                      command substitution, so no token reaches a launch
  #                      line, a log, a pane's scrollback or this process.
  #   CEL_SESSION_ID     the balancer's key. One worker, one key, one account
  #                      for its life; the next worker may land on another.
  local -a GATEWAY_ENV=()
  if [ "${PROFILE_VIA:-}" = gateway ]; then
    GATEWAY_ENV=(export 'OMP_GATEWAY_TOKEN=$(omp auth-gateway token)' "CEL_SESSION_ID=${CEL_SESSION_ID:-$agent_name}")
    # models.json is the owner's file, so a dry run must not touch it.
    if [ "$dry_run" -eq 0 ]; then
      gateway_pi_models_write \
        || die "cel run: could not read the gateway's model list - cel gateway status"
    fi
  fi


  # Reviewer panes join the caller's own view instead of creating one.
  if [ "$role" = "reviewer" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'git worktree add --detach %s <head of %s#%s>\n' "$review_path" "$repo" "$pr"
      printf 'herdr tab "PR reviewer": split its largest pane, or a new tab per %s panes\n' "$_RUN_REVIEW_TAB_CAP"
      printf 'herdr pane send-text <pane> %s\n' "$envprefix"
      printf 'herdr agent start %s --kind %s --pane <pane> -- %s\n' \
        "$agent_name" "$runtime" "$(_run_dry_agent_args)"
      return 0
    fi
    have herdr || die "cel run: herdr is not on PATH"
    have jq    || die "cel run: jq is not on PATH"
    local pane_id; pane_id="$(_run_reviewer_pane "$cwd")"
    _run_mark_launch "$pane_id" "$envprefix"
    herdr agent start "$agent_name" --kind "$runtime" --pane "$pane_id" -- "${AGENT_ARGS[@]}"
    # Recorded AFTER the launch: a row for a pane that never started is a row
    # `cel gc` would carry forever. A failed record is a warning, not a
    # failure - the reviewer is alive and reviewing either way.
    reviewers_record "$repo" "$pr" "$pane_id" "$agent_name" "$review_path" "$repodir" "$review_head" \
      || c_warn "could not record the reviewer for $repo#$pr - cel gc will not close it, and its checkout at $review_path will outlive it"
    return 0
  fi

  # RESTART IN PLACE: exit the agent in its pane, leaving the pane and its
  # shell, and start the current launch line there under the same name.
  if [ -n "$restart_pane" ]; then
    if [ "$dry_run" -eq 1 ]; then
      printf 'herdr pane send-keys %s esc ctrl+c ctrl+c\n' "$restart_pane"
      printf 'herdr pane send-text %s %s\n' "$restart_pane" "$envprefix"
      printf 'herdr agent start %s --kind %s --pane %s -- %s\n' \
        "$agent_name" "$runtime" "$restart_pane" "$(_run_dry_agent_args)"
      return 0
    fi
    herdr pane send-keys "$restart_pane" esc ctrl+c ctrl+c >/dev/null 2>&1 \
      || die "cel run $role --restart: could not send the exit keys to pane $restart_pane"
    _run_restart_wait "$restart_pane" \
      || die "cel run $role --restart: $agent_name is still running in $restart_pane - exit it by hand and re-run"
    [ "${#GATEWAY_ENV[@]}" -eq 0 ] || herdr pane run "$restart_pane" "${GATEWAY_ENV[@]}"
    _run_mark_launch "$restart_pane" "$envprefix"
    herdr agent start "$agent_name" --kind "$runtime" --pane "$restart_pane" -- "${AGENT_ARGS[@]}" >/dev/null
    _run_restart_confirm "$inbox_me" "$wsdir" "$runtime" "$agent_name" "${AGENT_ARGS[@]}"
    return 0
  fi

  local -a CREATE_ARGS
  if [ "$role" = "worker" ]; then
    local repodir="$wsdir/repos/$repo"
    CREATE_ARGS=(worktree create --cwd "$repodir" --branch "$branch" --label "$branch" --no-focus)
  else
    # A declared product's directory is cel's to make: it is not a checkout,
    # so nothing else ever creates it and herdr would refuse a missing cwd.
    if [ "$role" = "orchestrator" ] && [ "$dry_run" -eq 0 ] \
       && ws_product_declared "$wsdir" "$product"; then
      mkdir -p "$cwd"
    fi
    CREATE_ARGS=(workspace create --cwd "$cwd" --label "$alias_name")
  fi

  # Root mode is the workspace's whole working view, so it also applies the
  # workspace's declared herdr layout (services, watch panes, ...) - the other
  # modes are single panes inside views that already exist.
  local layout=""
  [ "$role" = "root" ] && layout="$(ws_layout "$wsdir")"

  if [ "$dry_run" -eq 1 ]; then
    printf 'herdr %s\n' "${CREATE_ARGS[*]}"
    [ -n "$layout" ] && printf 'herdr-workspace-manager apply %s\n' "$layout"
    # Values MASKED: the session id is not a secret but the bearer beside it
    # is, and a preview that prints one teaches people to paste both.
    [ "${#GATEWAY_ENV[@]}" -eq 0 ] \
      || printf 'herdr pane run <pane> export OMP_GATEWAY_TOKEN=**** CEL_SESSION_ID=****\n'
    printf 'herdr pane send-text <pane> %s\n' "$envprefix"
    printf 'herdr agent start %s --kind %s --pane <pane> -- %s\n' \
      "$agent_name" "$runtime" "$(_run_dry_agent_args)"
    return 0
  fi

  have herdr || die "cel run: herdr is not on PATH"
  have jq    || die "cel run: jq is not on PATH"

  local resp ws_id pane_id
  resp="$(herdr "${CREATE_ARGS[@]}")"
  ws_id="$(printf '%s' "$resp" | jq -r '.. | .workspace_id? // empty' | head -1)"
  pane_id="$(printf '%s' "$resp" | jq -r '.. | .pane_id? // empty' | head -1)"
  [ -n "$pane_id" ] && [ "$pane_id" != "null" ] || pane_id="${ws_id}:p1"

  if [ -n "$layout" ]; then
    pane_id="$(_run_apply_layout "$layout" "$ws_id" "$wsdir" "$pane_id")"
  fi

  # Typed into the pane's own shell, so the export survives into the agent the
  # next command starts - and the bearer is expanded there, by omp, never here.
  [ "${#GATEWAY_ENV[@]}" -eq 0 ] || herdr pane run "$pane_id" "${GATEWAY_ENV[@]}"

  # ...and the role mark goes on the launch LINE, after any pane run above:
  # it must not outlive the command it marks.
  _run_mark_launch "$pane_id" "$envprefix"
  herdr agent start "$agent_name" --kind "$runtime" --pane "$pane_id" -- "${AGENT_ARGS[@]}"
}

# STALE LAUNCH LINES. `cel update` changes hooks and launch flags, but a
# running orchestrator keeps the command line it started with: the inbox hook
# (CEL-65) and --no-prewalk (CEL-68) silently did not apply to any
# orchestrator that was already up. So compare each live one's actual argv
# (/proc/<pid>/cmdline) with what `cel run --dry-run` would launch now.
#
# One row per stale root/orchestrator:
#   name<TAB>workspace<TAB>diff<TAB>restart-command<TAB>status<TAB>role<TAB>product
# (product is `-` for root). The command is for humans to read; callers that
# run it rebuild the argv from role/workspace/product, never by re-splitting.
run_stale_orchestrators() {
  local roster ws wsdir p role me name cwd rt live pid line exp act missing cmd
  local lname lpane lstatus lsession
  have herdr && have jq || return 0
  roster="$(herdr agent list 2>/dev/null)" || return 0
  for ws in $(registry_names 2>/dev/null); do
    wsdir="$(registry_path "$ws" 2>/dev/null)" || continue
    [ -f "$wsdir/workspace.yaml" ] || continue
    for p in "" $(ws_product_names "$wsdir" 2>/dev/null); do
      if [ -z "$p" ]; then
        role=root; me=root; name="$(_run_agent_name "$ws/root")"; cwd="$wsdir"
        rt="$(ws_runtime "$wsdir" root)"; cmd="cel run root --workspace $ws --restart"
      else
        role=orchestrator; me="$p-orch"; name="$(_run_agent_name "$p/orch")"
        cwd="$(ws_product_dir "$wsdir" "$p")"; rt="$(ws_runtime "$wsdir" orchestrator)"
        cmd="cel run orchestrator --product $p --workspace $ws --restart"
      fi
      live="$(printf '%s' "$roster" | jq -r --arg n "$name" --arg c "$cwd" '
        [.result.agents[]? | select((.pane_id // "") != "")] as $a
        | [$a[] | select(.name == $n)] as $byname
        | [$a[] | select((.cwd // "") == $c)] as $bycwd
        # by name; cwd only when exactly one agent stands there (CEL-63)
        | (if ($byname | length) > 0 then $byname[0]
           elif ($bycwd | length) == 1 then $bycwd[0] else empty end)
        | [((.name // "") | if . == "" then "-" else . end), .pane_id,
           (.agent_status // "unknown"), (.agent // ""),
           ((.agent_session.value // "") | if . == "" then "-" else . end)] | @tsv' 2>/dev/null)" || live=""
      [ -n "$live" ] || continue
      IFS=$'\t' read -r lname lpane lstatus rt lsession <<< "$live"
      [ "$lsession" = "-" ] || _run_sessions_record "$cwd" "$lsession"
      pid="$(_run_orch_pid "$me" "$wsdir" "$rt")" || continue
      if [ "$role" = root ]; then
        line="$( (cmd_run root --workspace "$ws" --fresh --force --dry-run) 2>/dev/null)" || continue
      else
        line="$( (cmd_run orchestrator --product "$p" --workspace "$ws" --fresh --force --dry-run) 2>/dev/null)" || continue
      fi
      line="$(printf '%s\n' "$line" | sed -n 's/^herdr agent start [^ ]* --kind [^ ]* --pane <pane> -- //p')"
      [ -n "$line" ] || continue
      exp="$(mktemp)"; act="$(mktemp)"
      # shellcheck disable=SC2086
      printf '%s\n' "$rt" $line > "$exp"
      _run_cmdline "$pid" > "$act"
      missing="$(run_launch_diff "$exp" "$act")"
      rm -f -- "$exp" "$act"
      [ -n "$missing" ] || continue
      [ "$lname" != "-" ] || lname="$name"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$lname" "$ws" "$missing" "$cmd" "$lstatus" "$role" "${p:--}"
    done
  done
  return 0
}
