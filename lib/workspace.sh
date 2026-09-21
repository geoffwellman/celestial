# shellcheck shell=bash
# Reads workspace.yaml and renders everything derived from it: the policy block
# injected into agents, the CLAUDE.md block rendered into repos, and the
# per-repo skill symlinks. A "wsdir" is the directory holding workspace.yaml.
[ -n "${_CEL_WORKSPACE:-}" ] && return 0
_CEL_WORKSPACE=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# shellcheck source=lib/yaml.sh
. "$(dirname "${BASH_SOURCE[0]}")/yaml.sh"


_wsy() { # _wsy <wsdir> <program>  - yq over the workspace file, "" for absent
  _yqr -r "$2 // \"\" | tostring" "$1/workspace.yaml"
}

ws_current() {
  local d; d="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || return 1
  while [ "$d" != "/" ]; do
    [ -f "$d/workspace.yaml" ] && { printf '%s' "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

ws_name()   { _wsy "$1" '.name'; }
ws_kind()   { _wsy "$1" '.kind'; }
ws_org()    { _wsy "$1" '.org'; }
# THE LAYOUT, IN TWO SHAPES THAT MUST NOT COLLIDE. `layout: dev` has always
# named the herdr workspace-manager layout `cel run root` applies. CEL-44 gives
# a workspace a DECLARED SHAPE under the same key - what should be running in
# it - so the value may now be a map:
#
#   layout:
#     orchestrators: auto      # auto | manual | none
#     panes:
#       - { label: dash, cwd: ., cmd: cel dash --ensure }
#
# A map has no workspace-manager id unless it says `id:`, and a scalar declares
# no shape. Reading one as the other is how `cel run root` would hand herdr a
# block of yaml as a layout name, so each accessor answers for its own shape
# and returns nothing for the other.
ws_layout() { # <wsdir> - the workspace-manager layout id, or ""
  _yqr -r '.layout as $l
    | (if ($l | type) == "string" then $l
       elif ($l | type) == "object" then ($l.id // "")
       else "" end) | tostring' "$1/workspace.yaml"
}

# WHAT SILENCE MEANS, IN ONE PLACE. A workspace with no `layout:` block behaves
# as `orchestrators: manual` and no extra panes - exactly what every workspace
# did before CEL-44. The default lives here so `up`, `status`, the steward and
# the doctor line cannot each invent their own idea of what silence means.
#
# THE DEFAULT IS THE SAME FOR ALL THREE SHAPES OF SILENCE. 2026-09-21: a
# workspace declaring `layout: <string>` - a herdr layout id, which says
# nothing whatever about orchestrators - fell through this function's key read
# and landed on a hardcoded `manual` nobody had written anywhere, and the
# product's own `orchestrator: auto` could not overrule it. The operator ran
# `cel ws up` and was told "already right" while the steward said the same
# orchestrator would not start, 24 times. A string layout, an object layout
# with the key absent, and no layout at all now answer identically, and the
# one word they answer is written once, here.
ws_orchestrators_default() { printf 'manual'; }

# The DECLARED value of a layout key, or "" when the block is absent, is a
# scalar layout id, or simply does not say. No default: a caller that needs to
# tell "declared manual" from "said nothing" has to be able to see the silence.
ws_layout_declared() { # <wsdir> <key>
  _yqr -r --arg k "$2" '.layout as $l
    | (if ($l | type) == "object" then ($l[$k] // "") else "" end) | tostring' "$1/workspace.yaml"
}

ws_layout_get() { # <wsdir> <key>
  local v
  v="$(ws_layout_declared "$1" "$2")"
  if [ -z "$v" ] && [ "$2" = orchestrators ]; then ws_orchestrators_default; return 0; fi
  printf '%s' "$v"
}

# One declared pane per line as `label\tcwd\tcmd`, IN FILE ORDER: the order is
# the declaration - a dashboard above its notes - and a set would lose it.
# `cwd` defaults to the workspace dir itself; an absent `cmd` is an empty pane.
ws_layout_panes() { # <wsdir>
  _yqr -r '.layout as $l
    | (if ($l | type) == "object" then ($l.panes // []) else [] end)
    | .[] | [(.label // ""), (.cwd // "."), (.cmd // "")] | @tsv' "$1/workspace.yaml"
}
ws_ticket() { _yqr -r --arg k "$2" '.tickets[$k] // "" | tostring' "$1/workspace.yaml"; }
ws_policy() { _yqr -r --arg k "$2" '.policy[$k]  // "" | tostring' "$1/workspace.yaml"; }

# Default runtimes: claude orchestrators, omp workers.
ws_runtime() {
  local r
  r="$(_yqr -r --arg k "$2" '.runtime[$k] // ""' "$1/workspace.yaml")"
  [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  case "$2" in worker) printf 'omp';; *) printf 'claude';; esac
}

ws_env_names() { _yqr -r '.env // {} | keys[]' "$1/workspace.yaml"; }
ws_env_get()   { _yqr -r --arg k "$2" '.env[$k] // "" | tostring' "$1/workspace.yaml"; }

# Workspace env as eval-able shell: the committed `env:` map first, then a
# source of the gitignored env.local so secrets and per-box overrides win.
# Values are single-quoted and keys validated, so a stray yaml entry can never
# inject shell into the caller's eval.
ws_env_exports() { # <wsdir>
  local d="$1" k v
  for k in $(ws_env_names "$d"); do
    if ! printf '%s' "$k" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
      # stdout is eval'd by the caller, so the warning must ride stderr
      c_warn "workspace env: skipping invalid variable name '$k'" >&2
      continue
    fi
    v="$(ws_env_get "$d" "$k")"
    v=${v//"'"/"'\\''"}
    printf "export %s='%s'\n" "$k" "$v"
  done
  if [ -f "$d/env.local" ]; then
    # `set -a` around the source so a plain `KEY=value` line is exported too.
    # env.local is SOURCED, and without export an assignment makes a shell
    # variable that child processes do not inherit - so the key would be
    # visible to your shell and invisible to every agent launched from it.
    # That failure is silent and looks like a bad key rather than a missing
    # export, so the file is treated as what it is: an environment file.
    # Restored rather than left on, so nothing after this is auto-exported.
    local p="$d/env.local"; p=${p//"'"/"'\\''"}
    printf 'set -a; . %s; set +a\n' "'$p'"
  fi
}

# The `review:` block configures local PR reviewer panes (cel run reviewer).
# Distinct from policy.reviewer, which names an EXTERNAL GitHub reviewer for
# the pr-loop skill; a workspace can have either, both, or neither.
ws_review() { _yqr -r --arg k "$2" '.review[$k] // "" | tostring' "$1/workspace.yaml"; }

# Where a reviewer's verdict is published. On a public repo whose only GitHub
# identity is the owner's, a reviewer agent posting a review is the owner
# reviewing his own PR in public - and GitHub refuses the approval anyway. So
# the review is recorded in the ledger and reported by inbox, and `github` is
# opt-in for repos where the reviewer has an identity of its own (a GitHub App
# or a second account). The default lives HERE and nowhere else: a second
# copy of it in a role file or a launch path is how the two drift apart.
ws_review_post() { # <wsdir>
  local p; p="$(ws_review "$1" post)"
  [ "$p" = "github" ] && { printf 'github\n'; return 0; }
  printf 'inbox\n'
}

# Every ticket prefix this repo answers to, CURRENT ONE FIRST then any
# `prefix_aliases`. Aliases exist because a Linear team can be re-keyed
# (ABC -> ABCD) without renumbering its issues: Linear still resolves the old
# identifiers, but branches and worktrees cut before the rename keep their old
# names forever. Without the alias every in-flight branch would suddenly read
# as unticketed - refused by the delegate gate and nagged by the steward.
ws_repo_prefixes() { # <wsdir> <repo>
  _yqr -r --arg n "$2" '.repos // [] | map(select(.name == $n))[0] as $r
    | ([$r.prefix // empty] + ($r.prefix_aliases // [])) | .[]' "$1/workspace.yaml"
}

ws_repo_names() { _yqr -r '.repos // [] | .[].name' "$1/workspace.yaml"; }
ws_repo_get() {
  _yqr -r --arg n "$2" --arg k "$3" \
    '.repos // [] | map(select(.name == $n))[0][$k] // "" | tostring' \
    "$1/workspace.yaml"
}

# RELEASE: how this repo is released, if it is at all.
#
#   release:
#     workflow: release.yaml     # file name in .github/workflows/
#     input: bump                # the dispatch input's NAME
#     accepts: [major, minor, patch]   # or the literal word `semver`
#     tag: "v{version}"          # how the resulting tag is named
#     version_file: VERSION      # what `status` reads as "current"
#     changelog: changelog.d/    # fragment dir, for --dry-run's pending section
#
# The plane owns none of these semantics on purpose: the products on one box
# release four different ways - a bump input deriving the version from the
# newest tag, an exact version with a VERSION file, plain tags with no script,
# nothing at all - and a plane that hardcodes one of them is useful to exactly
# one person. Before this existed, `cel release` assumed every repo was
# celestial: every local refusal passed for anyone else and `gh workflow run`
# then returned 403, failing at the last step looking like it should have
# worked. A repo with no block is NOT releasable, and says so first.
#
# A list value (`accepts`) comes back space separated so `case` and `for` both
# work on it without the caller learning jq.
ws_repo_release() { # <wsdir> <repo> <key>
  _yqr -r --arg n "$2" --arg k "$3" \
    '.repos // [] | map(select(.name == $n))[0].release[$k] // ""
     | if type == "array" then map(tostring) | join(" ") else tostring end' \
    "$1/workspace.yaml"
}

# Releasable means there is something to dispatch. A block carrying everything
# but a `workflow` names no run, so it is not a release declaration however
# much else it holds.
ws_repo_releasable() { # <wsdir> <repo>
  [ -n "$(ws_repo_release "$1" "$2" workflow)" ]
}

# SEED: the gitignored local files a worktree needs before it can RUN. A
# worktree is a fresh checkout, so every file git was told to ignore - the keys
# file, a built wasm directory - is simply absent, and the ticket cannot be
# tested where it was written. On 2026-09-17 seven worktrees were symlinked by
# hand in one evening for exactly this. Declared per repo:
#
#   seed:
#     - apps/builder/.dev.vars                  # symlinked (the common case)
#     - { path: apps/pf/src/wasm, copy: true }   # copied, for what a link cannot be
#
# One entry per line as `<path>\t<link|copy>`; absent prints nothing. A plain
# string is a link because that is what a shared secret wants: edit it once in
# the checkout and every worktree sees it. `copy` exists for directories a
# build rewrites in place, where a link would write back into the checkout.
ws_repo_seed() { # <wsdir> <repo>
  _yqr -r --arg n "$2" '.repos // [] | map(select(.name == $n))[0].seed // []
    | .[]
    | if type == "string" then . + "\tlink"
      else ((.path // "") + (if .copy then "\tcopy" else "\tlink" end)) end' \
    "$1/workspace.yaml"
}

# PREVIEW: how to run this repo from a worktree, on ports nobody else holds.
#
#   preview:
#     cmd: "pnpm --filter builder dev"
#     env: { API_PORT: "{port}", UI_PORT: "{port+1}" }
#     url: "http://localhost:{port+1}"
#
# `{port}` and `{port+N}` are substituted by `cel-fanout try`, which allocates
# the block. Values are returned RAW, placeholders and all: substitution needs
# the allocated base, which only the caller has.
ws_repo_preview() { # <wsdir> <repo> <cmd|url>
  _yqr -r --arg n "$2" --arg k "$3" \
    '.repos // [] | map(select(.name == $n))[0].preview[$k] // "" | tostring' \
    "$1/workspace.yaml"
}

ws_repo_preview_env() { # <wsdir> <repo> - one KEY=VALUE per line, raw
  _yqr -r --arg n "$2" '.repos // [] | map(select(.name == $n))[0].preview.env // {}
    | to_entries[] | "\(.key)=\(.value)"' "$1/workspace.yaml"
}

# PRODUCTS. An orchestrator used to be bound to exactly one repo, so two repos
# that are really one system - a platform and the things that consume it -
# needed two orchestrators and a tier above them purely to sequence work that
# crossed the line between them. That hop is where most of a workspace's mail
# went, and a hop exists to be removed. A product is one or more repos with one
# orchestrator; a repo named in no declared product is its own IMPLICIT
# product, in place, so a workspace written before any of this behaves exactly
# as it did.
#
# A repo named in two declared products is a config error that belongs to
# `cel doctor`, not here: these helpers just resolve the FIRST declaration so
# the same file always produces the same panes.

ws_product_names() { # <wsdir> - declared in file order, then implicit ones
  _yqr -r '(.products // []) as $ps
    | ([$ps[].repos // []] | flatten) as $used
    | (($ps | map(.name)) + ((.repos // [] | map(.name)) - $used))[]' \
    "$1/workspace.yaml"
}

ws_product_repos() { # <wsdir> <product> - an implicit product is its own repo
  local r
  r="$(_yqr -r --arg p "$2" '.products // [] | map(select(.name == $p))[0].repos // [] | .[]' \
    "$1/workspace.yaml")"
  [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
  printf '%s\n' "$2"
}

ws_product_of_repo() { # <wsdir> <repo> - its product, else the repo itself
  _yqr -r --arg n "$2" '.products // []
    | map(select((.repos // []) | index($n)))[0].name // $n | tostring' \
    "$1/workspace.yaml"
}

ws_product_declared() { # <wsdir> <product> - 0 declared, 1 implicit or unknown
  [ "$(_yqr -r --arg p "$2" '(.products // []) | map(select(.name == $p)) | length' \
    "$1/workspace.yaml")" != "0" ]
}

ws_product_get() { # <wsdir> <product> <key>
  _yqr -r --arg p "$2" --arg k "$3" \
    '.products // [] | map(select(.name == $p))[0][$k] // "" | tostring' \
    "$1/workspace.yaml"
}

# THE EFFECTIVE ORCHESTRATOR MODE FOR ONE PRODUCT, AND WHERE IT CAME FROM.
# `up`, `status`, the dry run and the steward all ask this and nothing else:
# two components deriving one fact by different routes, neither saying which
# route it used, is the 2026-09-21 incident in full.
#
# A PRODUCT MAY OPT IN, NOT ONLY OUT. The old merge rule let
# `products[].orchestrator` override the workspace mode only when it said
# `manual` or `none`, so `auto` under a workspace that was not auto was
# unreachable config - it read as a declaration and behaved as nothing. All
# three values now win, because a per-product declaration that cannot turn
# something ON is a trap.
#
# The source is returned beside the mode because the owner could not tell
# where `manual` had come from, and neither could anyone reading three files.
ws_orchestrator_mode() { # <wsdir> <product> -> "<mode>\t<product|layout|default>"
  local own lay
  own="$(ws_product_get "$1" "$2" orchestrator)"
  case "$own" in auto|manual|none) printf '%s\tproduct' "$own"; return 0 ;; esac
  lay="$(ws_layout_declared "$1" orchestrators)"
  case "$lay" in auto|manual|none) printf '%s\tlayout' "$lay"; return 0 ;; esac
  printf '%s\tdefault' "$(ws_orchestrators_default)"
}

# Where that product's orchestrator stands. A declared product has no checkout
# of its own - it is the directory ABOVE its repos' worktrees - so it gets a
# products/ dir; an implicit one keeps standing in its repo, unchanged.
ws_product_dir() { # <wsdir> <product>
  if ws_product_declared "$1" "$2"; then
    printf '%s' "$1/products/$2"
  else
    printf '%s' "$1/repos/$2"
  fi
}

# The single source for every injection surface: cel run, cel-fanout, and the
# rendered CLAUDE.md block all call this, so policy is worded exactly once.
# The optional product argument adds one line and changes nothing else: an
# agent launched for a product has to be told the cross-repo hop is its own.
ws_policy_block() { # <wsdir> [product]
  local d="$1" product="${2:-}" name kind org tsys tadhoc merge pr workers reviewer r
  name="$(ws_name "$d")"; kind="$(ws_kind "$d")"; org="$(ws_org "$d")"
  tsys="$(ws_ticket "$d" system)"; tadhoc="$(ws_ticket "$d" adhoc)"
  merge="$(ws_policy "$d" merge)"; pr="$(ws_policy "$d" pr)"
  workers="$(ws_policy "$d" workers)"; reviewer="$(ws_policy "$d" reviewer)"
  printf '## Workspace policy\n'
  printf -- '- workspace: %s (kind: %s, org: %s)\n' "$name" "${kind:-unset}" "${org:-unset}"
  if [ -n "$product" ]; then
    printf -- '- product: %s (repos: %s) - cross-repo sequencing inside this product is yours; there is no tier above you for it\n' \
      "$product" "$(ws_product_repos "$d" "$product" | paste -sd, - | sed 's/,/, /g')"
  fi
  if [ "$tsys" = "none" ]; then
    printf -- '- tickets: none - never invent ticket references; ad-hoc refs look like %s\n' "${tadhoc:-AH-<yymmdd>}"
  elif [ "$tsys" = "linear" ]; then
    printf -- '- tickets: linear (use the linear skill; MCP tools if present, else `cel-linear`). ONE ticket per work package, and SEARCH BEFORE CREATE - never start work on a ticket someone else has In Progress. THE BRANCH NAME CARRIES THE TICKET ID (`<PREFIX>-<n>-<slug>`): Linear links a PR to its ticket from the branch name alone, so a branch without one is invisible on the board and `cel-fanout delegate` will refuse it. The lifecycle is then automatic - delegate sets In Progress, collect sets In Review and comments the PR link, release sets Done on a merged PR - so do not hand-drive states for delegated work. Ad-hoc refs (%s) are for throwaway work only and need `--adhoc`\n' "${tadhoc:-unset}"
  else
    printf -- '- tickets: %s; ad-hoc refs look like %s\n' "${tsys:-unset}" "${tadhoc:-unset}"
  fi
  if [ "$merge" = "self" ]; then
    printf -- '- merge: self - you may merge after the review skill passes\n'
  else
    printf -- '- merge: humans-only - open a PR and stop; only humans merge\n'
  fi
  local pr_open; pr_open="$(ws_policy "$d" pr_open)"
  if [ "${pr_open:-draft}" = "ready" ]; then
    printf -- '- pr: %s, opened READY FOR REVIEW (never draft; a draft is invisible to the reviewer); max concurrent workers: %s\n' "${pr:-required}" "${workers:-4}"
  else
    printf -- '- pr: %s, opened as a draft; max concurrent workers: %s\n' "${pr:-required}" "${workers:-4}"
  fi
  printf -- '- worker runtime: %s - spawn workers via `cel-fanout delegate` (or `herdr agent start <name> --kind %s`); never start workers on the orchestrator runtime (%s)\n' \
    "$(ws_runtime "$d" worker)" "$(ws_runtime "$d" worker)" "$(ws_runtime "$d" orchestrator)"
  # Profiles are read straight from the file rather than through lib/profiles.sh:
  # that file sources THIS one, and a policy block is not worth a source cycle.
  local profs wbound
  profs="$(_yqr -r '.worker_profiles // {} | keys_unsorted | join(", ")' "$d/workspace.yaml")"
  wbound="$(_yqr -r '.role_profiles.worker // "" | tostring' "$d/workspace.yaml")"
  if [ -n "$profs" ]; then
    printf -- '- worker profiles: %s. `cel-fanout delegate ... --profile <name> --because "<why>"` runs a worker on a different CLI/model/effort%s. CHOOSE PER TICKET from the descriptions below and say why; default only when nothing fits. Do NOT switch profiles to work around a stuck worker - a profile is for trying a model deliberately, and the ledger records which one built which branch and why\n' \
      "$profs" "${wbound:+ (default here: $wbound, applied automatically)}"
    _yqr -r '.worker_profiles // {} | to_entries[] | select(.value.for != null) | "  - \(.key): \(.value.for)"' "$d/workspace.yaml" 2>/dev/null || true
    local sbound; sbound="$(_yqr -r '.role_profiles.scout // "" | tostring' "$d/workspace.yaml")"
    printf -- '- investigations are SCOUTS: `cel-fanout scout <repo> <brief-file>` gives a read-only worktree and expects .agent/report.md - no ticket, no PR%s. Never force an investigation into an ad-hoc branch or do it in your own checkout\n' \
      "${sbound:+ (scouts run on profile $sbound automatically - do not pass --profile unless the brief needs something else)}"
  fi
  if [ -n "$reviewer" ]; then
    printf -- '- reviewer: %s (pr-loop requests this reviewer)\n' "$reviewer"
  else
    printf -- '- reviewer: none (the pr-loop skill is disabled here)\n'
  fi
  local rrt rmodel
  rrt="$(ws_review "$d" runtime)"; rmodel="$(ws_review "$d" model)"
  if [ -n "$rrt" ]; then
    printf -- '- pr review: after opening a PR, start a reviewer pane with `cel run reviewer --repo <repo> --pr <n>` (%s%s, one pane per PR in the "PR reviewer" tab); its first prompt names the repo, PR number, ticket scope, the worker'\''s herdr alias and your own alias - reviewer and worker then hand off to each other directly, and you hear back only on approval or escalation\n' \
      "$rrt" "${rmodel:+ model $rmodel}"
    if [ "$(ws_review_post "$d")" = "github" ]; then
      printf -- '- review verdicts: recorded with `cel-fanout review <id> <approved|changes> --by <reviewer-alias> --note "<one line>"`, reported by inbox, and posted as a GitHub review\n'
    else
      printf -- '- review verdicts: recorded with `cel-fanout review <id> <approved|changes> --by <reviewer-alias> --note "<one line>"` and reported by inbox; GitHub is **not** posted to\n'
    fi
  fi
  local lt
  for r in $(ws_repo_names "$d"); do
    lt="$(ws_repo_get "$d" "$r" linear_team)"
    printf -- '- repo %s: branch prefix %s, gate `%s`%s\n' \
      "$r" "$(ws_repo_get "$d" "$r" prefix)" "$(ws_repo_get "$d" "$r" gate)" \
      "${lt:+, linear team $lt}"
  done
  # What this workspace has learned, budgeted (lib/learn.sh). Rendered by a
  # CHILD `cel learn render` rather than by sourcing learn.sh here: learn.sh
  # sources this file for ws_current, and a source cycle for a paragraph is a
  # bad trade. Empty output when there is nothing to say.
  local learned
  learned="$("$CEL_ROOT/bin/cel" learn render --dir "$d" 2>/dev/null || true)"
  [ -z "$learned" ] || printf '\n%s' "$learned"
}

ws_render_role() { # <wsdir> <rolefile> [product]
  [ -f "$2" ] || die "role file not found: $2"
  cat "$2"; printf '\n'; ws_policy_block "$1" "${3:-}"
}

# Replace-or-append the marked block. Body travels via the environment, not
# awk -v: -v would interpret backslash escapes inside the rendered text.
ws_render_claude_block() { # <wsdir> <targetdir>
  local f="$2/CLAUDE.md" block
  block="$(BODY="$(ws_policy_block "$1")" \
    awk '{ if ($0 == "{{POLICY_BLOCK}}") printf "%s\n", ENVIRON["BODY"]; else print }' \
    "$CEL_ROOT/templates/CLAUDE.md.tmpl")"
  if [ -f "$f" ] && grep -q 'cel:policy:begin' "$f"; then
    BLK="$block" awk '
      /cel:policy:begin/ { inblk=1; printf "%s\n", ENVIRON["BLK"]; next }
      /cel:policy:end/   { inblk=0; next }
      !inblk { print }' "$f" > "$f.cel-tmp" && mv "$f.cel-tmp" "$f"
  else
    { [ -f "$f" ] && cat "$f" && printf '\n'; printf '%s\n' "$block"; } \
      > "$f.cel-tmp" && mv "$f.cel-tmp" "$f"
  fi
}

# Workspace skills are scoped: linked into this workspace's checkouts only, and
# the links are gitignored - they point into $HOME and must never be committed.
ws_link_skills() { # <wsdir> <targetdir>
  local s t="$2/.claude/skills"
  mkdir -p "$t"
  # Self-heal: a skill deleted from the workspace must take its repo links
  # with it, or the dangling link keeps shadowing the plane copy of the same
  # name (observed: stale pr-loop/fanout shadows outliving their source).
  # Only links that point into THIS workspace's skills dir are ours to prune.
  for s in "$t"/*; do
    [ -L "$s" ] && [ ! -e "$s" ] || continue
    case "$(readlink "$s")" in "$1"/skills/*) rm -f "$s";; esac
  done
  for s in "$1"/skills/*/; do
    [ -f "$s/SKILL.md" ] || continue
    ln -sfn "${s%/}" "$t/$(basename "${s%/}")"
  done
  grep -qxF '.claude/skills' "$2/.gitignore" 2>/dev/null \
    || printf '.claude/skills\n' >> "$2/.gitignore"
}
