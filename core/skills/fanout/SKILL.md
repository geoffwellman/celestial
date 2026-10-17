---
name: fanout
description: Team conventions for spawning and collecting worker agents in herdr. Use when acting as a project orchestrator.
---
Naming
- Worktree and branch: `<PREFIX>-<n>-slug`, e.g. `WG-12-approval-token-retry`.
- Herdr agent alias: `<repo>/<PREFIX>-<n>`.

**The branch name IS the ticket link.** On a workspace using Linear,
`cel-fanout delegate` REFUSES a branch whose name carries no ticket id, because
Linear attaches a PR to its ticket from the branch name and nothing else — an
unticketed branch can never appear on the board, no matter what any agent does
afterwards. Before delegating:

```
cel-linear search '<a few words from the task>' --team <PREFIX>   # ALWAYS first
cel-linear create --team <PREFIX> --title '<title>' --description '<why>'
```

Reuse an existing id rather than creating a second ticket for the same work —
that is what stops two agents working the same thing. `delegate` deliberately
does not auto-create: a tool that creates a ticket per delegation manufactures
duplicates. For genuinely throwaway work, pass `--adhoc` to opt out on purpose.

Status is moved by the mechanism, not by agents remembering:
`delegate` sets **In Progress**, `collect` sets **In Review** and comments the
PR link, `release` sets **Done** — but only when the PR actually merged, since
releasing a worktree is not the same as landing the work.

Loop (mechanics live in `cel-fanout`, not hand-rolled herdr calls)

```
spawn:    cel-fanout delegate <repo> <PREFIX>-<n>-slug <spec-file>
fan-in:   id="$(cel-fanout wait)"; cel-fanout collect "$id"  → review skill → accept/revise
teardown: after merge, cel-fanout release <id>
```

- `delegate` creates the herdr worktree, starts the worker with its
  role_injection strategy from agents.yaml (e.g. omp: `--append-system-prompt
  <role file>`), sends the task spec as its first prompt, and records the
  delegation in the workspace's ledger (`<wsdir>/.cel/delegations.json`).

Moving a retained worktree to ONE replacement runtime (`handoff`, orchestrator only)

```
cel-fanout handoff inspect <id> --pane <pane> --profile P         # read-only plan + refusals + the exact apply line
cel-fanout handoff apply   <id> --profile P --pane <pane> --shell-pid N --agent-pid N \
    --agent-start TICKS --head SHA --source-digest HEX --evidence "<what you checked>" [--reissue-retire]
cel-fanout handoff status  <id|opid>                               # phase, evidence, next action
cel-fanout handoff hold    <id> --kind launch-unknown --evidence "<facts>"   # record launch debt you cannot settle
```

- For a delegation whose worktree is intact but whose runtime must change (an
  old OMP to Pi Sonnet 5.5, say) and for which `delegate --reuse` refuses
  (alias already held, local-ahead or diverged dirty work). `apply` is bound to
  the inspected plan: pane, shell pid, agent pid + start generation, HEAD and a
  digest over every dirty/untracked byte and the private `.agent/` files.
  Anything stale, busy, changed or unsettled refuses with **zero mutation**.
- It is an admitted, replayable operation: the record, ledger mark and a
  per-target lock exist BEFORE the old runtime is retired; each later phase is
  written BEFORE its call; a lost response or a rerun finds the same operation
  (id from the bound coordinates) and continues from its phase - it never stops,
  starts or prompts twice. `status` names the exact next action.
- **Retirement needs herdr `agent.stop`** (process-only: end one agent by name,
  keep the pane, shell and every other process). herdr 0.9.1 does not have it
  (`herdr api schema --json`), so there `inspect`/`apply` refuse and name that
  exact call. `pane close`, `release-agent`, keystrokes, raw kills, renaming the
  alias and ledger edits are never used. Source-vs-installed: this verb exists
  in the source checkout; an installed `cel-fanout` does not have it until it is deployed.
- The source is never touched (no reset/stash/checkout/rebase/fetch/push);
  ahead, behind and diverged are classified with git, local ahead/diverged
  dirty work is supported. The replacement starts in the same worktree with
  the profile's exact model and thinking, normal env/inbox/role, and is
  verified (process model/args/env, one agent) before it is prompted ONCE. It
  is `running` only after an assistant turn AND a successful tool call are
  visible; an ack alone stays `unconfirmed`.
- **Context transfer is truthful:** cross-harness (OMP to Pi) is NOT a lossless
  session resume, and same-harness native resume is not performed either. The
  replacement is told the spec, a handoff brief and a copy of the old pane text
  (kept with the old session path/digest under `<wsdir>/.cel/handoffs/`). Prior
  review/gate approval is NOT carried over (kept as `handoff.prior_review`).
- **Session safety (fails closed):** an unknown or missing recorded session
  refuses retirement even with a named `--preserved-export` archive (evidence
  only); every tool call of the last assistant message must have a result
  (parallel calls by id; an unparseable tail is unsettled). `--resume-session
  FILE --resume-sha SHA` (pi only) is accepted only for the old runtime's OWN
  recorded session file by real path - symlinks, hardlinks, copies and archives
  are refused - with header uuid and cwd = the worktree, bound by bytes, started
  as `pi --session FILE`. Only "launched on that file" is claimed. Else
  UNAVAILABLE, zero mutation.
- **Capability = contract:** `agent.stop` must take the name plus
  `expected_pid` + `expected_start`; the call passes them. `handoff settle <id>`
  is the only exit from a hold and is UNAVAILABLE until herdr has a launch
  receipt query; held rows keep occupying worker slots.
- `hold` records launch debt you cannot settle (e.g. a `delegate --reuse` that
  timed out UNKNOWN). It fences retirement, restart, collect, release, land,
  handback and `recover abandon`, and is settled only by a herdr launch receipt
  (an API reporting the outcome of `agent.start` by launch id, plus a supported
  cancel) - never by a missing process or null ledger fields.

Registering a worker whose launch was only partly recorded (NOT resuming it)

```
cel-fanout recover inspect  <repo> <branch> --pane <pane>          # read-only
cel-fanout recover register <repo> <branch> <spec> --profile P --pane <pane> \
    --shell-pid N --agent-pid N --agent-start TICKS --evidence "<facts>" --attest-legacy
cel-fanout recover continue <id>
cel-fanout recover abandon  <id> --reason "<what you found>"
```

- For a live agent in a pane with NO ledger row (the delegating process died
  or timed out between `herdr agent start` and the ledger write). Orchestrator
  only. It never starts an agent, types, presses Enter, edits herdr state or
  falls back to another model.
- **UPSTREAM BLOCKED for a worker herdr still reports `launch_pending`.**
  No SUPPORTED completer was found in herdr 0.9.1's exposed surfaces
  (agent.start/prompt/wait/explain/rename,
  pane.report_agent/report_agent_session/clear_agent_authority/release_agent);
  that is what the installed binary shows, not proof the capability cannot
  exist, and the only things that would change a pending launch (report-agent,
  release-agent, Enter) are forbidden. The prerequisite is (1) a diagnostic
  reason why the launch is pending, (2) a supported way to complete it or mark
  the agent ready with no keystrokes or metadata forgery, and (3) prompt-delivery
  receipt semantics. Until then `register` records the row and
  `continue` refuses: such a worker is registered, not resumed.
- `register` validates the exact pane, shell, agent process generation
  (`/proc` start ticks - read them from `inspect`), environment, the exact
  model and thinking-level launch arguments, branch, worktree, an unstarted
  pane (context zero, no turn) and herdr's own `launch_pending`/idle report,
  refusing with zero mutation on any mismatch, a live original delegate, a held
  ledger lock, or a conflicting row. It writes one row in state `unconfirmed`
  with a `recovery` record (`legacy-operator-attested`; what is NOT proven is
  in `recovery.unproven`). Retrying it is idempotent.
- `continue` sends the task prompt at most once, only to an agent herdr reports
  interactive_ready and not launch_pending and whose pane is still unstarted.
  A row moves to `running` (and the ticket to In Progress) only after the
  pane shows the agent took a turn; an ambiguous or crashed submit is never
  resubmitted - the next `continue` only looks.
- An `unconfirmed` row that may hold a live agent (a recovery row, or a
  delegate receipt at launch.phase starting/start-failed/started) counts toward
  the worker cap and is fenced: `release`, `collect`, `land`, `review
  approved`, `request-review` and `handback` refuse it, `release --all` skips
  it, `gc` keeps its worktree. `recover abandon` is the bounded way out for a launch where NO task was ever submitted (an uncertain, possibly delivered dispatch is refused and stays fenced): it
  records the operator's reason, moves the row to `abandoned` and touches
  nothing else (agent, pane and worktree stay as found).
- A delegate row is now written BEFORE `herdr agent start`. A failed start is
  kept as launch.phase `start-failed` (no automatic continuation: look at the
  pane, then `recover abandon`). `delegate --reuse` over an existing row marks
  it instead of replacing it, so a failed start keeps its verdict and PR.

Running a worker on a different model or CLI

```
cel-fanout delegate <repo> <branch> <spec> --profile astra
```

- `--profile <name>` picks one of the workspace's `worker_profiles` - a named
  (runtime, model, thinking) triple. It can change the CLI, not just the model,
  so a profile may hand the ticket to codex or opencode instead of the
  workspace's usual worker runtime. `--model` and `--thinking` override a
  profile, or work on their own.
- **You usually do not need the flag.** If the workspace sets
  `role_profiles: { worker: <name> }`, every delegation already uses it. Pass
  `--profile` only when you mean *this ticket specifically* to differ.
- Run `cel profiles` to see what each name resolves to on this box before you
  use it - including whether its provider key is actually present.
- The profile, runtime, model and level are written into the ledger, so
  `cel-fanout status` shows which model built which branch. **When you delegate
  the same kind of ticket to two profiles to compare them, say so in both specs
  and read both results before judging** - otherwise the ledger records a
  comparison nobody actually made.
- `wait` blocks until the next delegated worker goes idle, blocked, or done,
  then prints its id.
- `collect <id>` prints `.agent/result.md` from the worker's worktree; if the
  worker never wrote one, it salvages the pane's recent output instead and
  warns.
- `cel-fanout status` lists every delegation with its ledger state and live
  herdr agent status.
- `cel-fanout status --json` prints the same rows as one JSON object per line
  — every state, `released` included — with the id, ticket, repo, branch,
  shape, state, live agent status, `quiet_secs`, stall `verdict`/`severity`,
  `ahead`, PR, alias, pane and worktree. It is the same object `cel fleet
  --json` puts in `units[].workers_list`, rendered by the same function, so
  the console and the fleet view can never describe one worker two ways.
  `cel-fanout why <id>` answers the question a count cannot: the verdict, how
  long it has been quiet and whether that costs work, the pane's last 25
  lines, the last five messages it sent, its PR, and ONE next act. Both are
  reads — they never prompt, release or write the ledger.
- `release <id>` removes the herdr worktree (or keeps it with
  `--keep-worktree` for a post-mortem) and marks the ledger entry released.
  **It refuses a worktree that still holds work** — uncommitted changes or
  commits not on origin — and names exactly what would be lost. Releasing is
  not landing. `--discard` is the only way past that refusal, and it is
  logged; nothing snapshots the work first, so say it only when you mean it.
  `release --all` takes only the rows the world has finished with - `landed`
  and `abandoned` - and `--merged` ADDS the rows GitHub says are merged to
  that same pass; `running`, `finished`, `collected` and `reported` are
  somebody's open work and are never taken in bulk (one explicit
  `release <id>` each, or name the states with `--state`). Every `--all` run
  prints its plan first - what it will take, and every row it skips with the
  state that spared it - and `--dry-run` stops there. Releasing the last child
  under a `<repo>/workers` container leaves that container standing, and
  recreates it if herdr closed it, so the next delegate still has a home;
  `status` shows `detached` for a worker whose container went anyway (herdr
  0.9 has no re-parent verb, so that is a report, not a fix).
- `collect` and `land` run `cel-verify` with the workspace's `env:` block
  applied, so a declared `CEL_VERIFY_GATE_TIMEOUT` (or TMPDIR, or any other
  gate setting) actually reaches the gate; `--gate-timeout <secs>` on either
  command still wins over the file. Neither holds the ledger lock across the
  gate - it is released before `cel-verify` and retaken to write the verdict,
  because that lock serialises ledger writes, not gates - so a row that moved
  while the gate ran is refused ("re-run collect") instead of overwritten.
- `reconcile` closes the rows the world already closed. One `gh pr list` per
  repo (never one call per row) over everything `finished`, `collected`, or
  `running` with no pane left: a **merged** PR gets `land`'s bookkeeping
  without the merge - ticket **Done**, row `landed`, worktree released with
  `--discard`, because the branch is already in main; a PR **closed unmerged**
  more than `CEL_RECONCILE_GRACE_HOURS` (default 24) ago becomes `abandoned`
  with the branch named out loud and the ticket left to whoever closed it; a
  scout or spike whose report has sat unread that long raises ONE rolled-up
  item to the product's orchestrator and is never released, because the report
  is the deliverable; a ship row with no PR and no worktree is simply
  `released`. Everything else is untouched, and `--dry-run` prints the same
  pass without doing any of it. The steward runs it once per tick per
  workspace, so the ledger is not a list of work someone already merged
  through GitHub by hand. `release --all --merged` is the same read on its own:
  release exactly the rows GitHub has merged.

Shapes: what a delegation is for

```
cel-fanout delegate <repo> <branch> <spec>   # worker: the deliverable is a PR
cel-fanout scout <repo> <brief>              # scout:  a report; may not write code
cel-fanout spike <repo> <brief>              # spike:  a report, backed by throwaway code
```

- A **spike** answers "try it and tell me if it works", which is neither a
  worker's job nor a scout's. It writes code freely in its worktree and may
  commit locally, but never pushes, opens a PR or creates a ticket; its
  deliverable is `.agent/report.md`. `collect` prints that report and marks the
  row `reported` without running the verifier, and `release` throws the
  worktree away without `--discard` — dirty and unpushed are a spike's expected
  end state — while naming what went.

Local config, and running a ticket

```yaml
repos:
  - name: widget
    seed:
      - apps/builder/.dev.vars                  # symlinked into every worktree
      - { path: apps/pf/src/wasm, copy: true }  # copied instead
    preview:
      cmd: "pnpm --filter builder dev"
      env: { API_PORT: "{port}", UI_PORT: "{port+1}" }
      url: "http://localhost:{port+1}"
```

- `seed:` names the gitignored files a fresh checkout does not have but the
  app needs to RUN. `delegate`, `scout` and `spike` place them in the worktree
  before the agent starts - symlinked to the workspace checkout, or copied with
  `copy: true` for a directory a build rewrites in place - and the worker's
  first prompt says which ones are there and that they are not its to commit. A
  missing source is a warning, never a failed delegation; a target that already
  exists is left alone.
- `cel-fanout try <id>` runs the ticket's branch from its own worktree on a
  free block of ten ports (from `CEL_TRY_PORT_BASE`, default 4400), in a pane
  split under the worker's, and prints the url as its last line. `--stop`
  closes that pane; `release` stops a running preview before it removes the
  worktree; `status` shows the port in the `TRY` column. Trying a ticket twice
  just prints the url it is already on - it is one branch, so it is one
  instance.

Products and the review verdict

- The worker's completion notice goes to the **product's** orchestrator
  (`<product>-orch`), and the worker cap counts every running row across the
  product's repos, from `products[].workers` or `policy.workers`. A repo in no
  declared product is its own product, so nothing changes for one.
- `--workspace <name>` on `delegate`, `scout`, `spike`, `status`, `collect`,
  `release`, `land` resolves the workspace from the registry instead of the
  cwd — for driving a fleet from outside its tree.
- `cel-fanout review <id> <approved|changes> --head <full-sha> --by <reviewer-alias> [--note …]`
  records the verdict on the ledger row, bound to the 40-character commit the
  reviewer names in `--head` (never inferred from a worktree; an `approved`
  must equal the PR's current remote head on a PR this fleet owns, else nothing
  is recorded; `head_source: explicit` marks such records, and an older record
  without it no longer satisfies `land`; a `changes` verdict is also marked explicit but its SHA is the reviewer's unverified claim, and it never authorizes anything; `land` merges with `--match-head-commit` so a push after its checks lands nothing); `status` shows it in the REVIEW
  column. On a repo whose PR author and reviewer are one GitHub account,
  GitHub refuses approval outright, so `land` accepts an `approved` ledger
  verdict **only there** — everywhere else GitHub's decision remains the
  authority — and writes `Reviewed-by: <by> (<verdict>)` into the squash-merge
  body so the record is public in the log.

- `cel-fanout replace reserve <id> --original-head <sha40> --pr <n> --alias <worker> --worktree <path> --branch <new-branch> --head <sha40>`
  then `cel-fanout replace attach <new-branch> --head <sha40>` (orchestrator
  only) is the one audited way to publish a CLEAN replacement for a PR whose
  branch carried what must not be published (e.g. private `.agent/` handoffs).
  `reserve` refuses, with nothing written, unless the source is this fleet's
  own finished/collected ship row (alias and worktree as stated), its open
  same-repo PR is `--pr` at exactly `--original-head`, the new branch is
  absent on the remote, and git agrees the candidate descends from the default
  branch *without* the original head, no commit in it touches a path the
  release hygiene scan calls private, and every other path is byte-identical
  to the original. It then writes the child row (`replacement` metadata, no
  review or gate evidence) and marks the original, in ONE ledger write, and
  tells the worker by inbox to push exactly that head and open a READY PR.
  The worker is handed to the child: the original keeps its state and history
  but stops counting as a worker, and its worktree cannot be released through
  it. `attach` re-reads GitHub (original head unchanged; candidate PR open,
  ready, this fleet's, not a fork, head and remote ref == the reserved head)
  and marks the child attached; until then collect, approval and land refuse
  it. Then collect, `review --head`, `land` work on the child as on any row -
  no approval carries over. Either stage may be replayed with the same
  arguments after a lost response; a different replacement of the same
  original is refused. It never writes to GitHub or touches the original PR.

- `cel-fanout request-review <id> --head <full-40-char-sha> [--reviewer <login>] [--dry-run]`
  is the one supported way to request the external GitHub reviewer named by
  `policy.reviewer` (raw `gh pr edit --add-reviewer` stays guard-refused). It
  acts as the workspace's `github.user` and refuses, before any write, unless:
  `--head` is a full sha; the ledger review is `approved`, has
  `head_source: explicit` and covers exactly that head; the PR is this fleet's
  own open, non-draft, same-repo PR for the delegation's branch; and both the
  PR head and the remote branch ref equal `--head`. `--reviewer` may only
  restate the configured reviewer. It adds that one reviewer (nothing else is
  written - not the ledger, labels, base or markers), then reads
  `requested_reviewers` back; a pending request or a review of this exact head
  is left alone. GitHub cannot head-compare-and-set a request, so a head that
  moves during the call is reported as a failure and the request is *not* an
  approval of the new head. It never grants permission to land. Orchestrator
  verb: workers are refused. `--dry-run` runs every check and requests nothing.

Rules
- ≤ the product's worker cap concurrent delegations (`cel-fanout status` shows
  the running count per product).
- One ticket per worker; never reuse a worker pane for a second ticket.
- The task spec always travels as a FILE, never pasted prose: workers can
  re-read it after compaction.

Binary reference: `$CEL_ROOT/core/skills/fanout/bin/cel-fanout` - on PATH once
`cel shellenv` adds it.

When you establish a durable fact - a runtime quirk, a provider behaviour, a
team convention, a decision and the reason for it - record it with
`cel learn add "<fact>"` (`--pin` for a standing rule, `--perishable` for one
with a known expiry). It reaches every agent's policy block from then on. Do
NOT record task status there; that is the ledger and the inbox.

