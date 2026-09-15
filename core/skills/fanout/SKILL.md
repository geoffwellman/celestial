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
- `release <id>` removes the herdr worktree (or keeps it with
  `--keep-worktree` for a post-mortem) and marks the ledger entry released.
  **It refuses a worktree that still holds work** — uncommitted changes or
  commits not on origin — and names exactly what would be lost. Releasing is
  not landing. `--discard` is the only way past that refusal, and it is
  logged; nothing snapshots the work first, so say it only when you mean it.

Rules
- ≤ `policy.workers` concurrent delegations (`cel-fanout status` shows the
  running count).
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

