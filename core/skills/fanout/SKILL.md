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
- `cel-fanout review <id> <approved|changes> --by <reviewer-alias> [--note …]`
  records the verdict on the ledger row; `status` shows it in the REVIEW
  column. On a repo whose PR author and reviewer are one GitHub account,
  GitHub refuses approval outright, so `land` accepts an `approved` ledger
  verdict **only there** — everywhere else GitHub's decision remains the
  authority — and writes `Reviewed-by: <by> (<verdict>)` into the squash-merge
  body so the record is public in the log.

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

