# Architecture

Celestial is an AI software factory implemented as a GNU/Linux command-line
control plane around Git worktrees, [herdr](https://herdr.dev), coding-agent CLIs and a small pair of Node HTTP
servers. It is not a scheduler with its own worker runtime or an isolation
boundary against the local user.

## Code and state

- `bin/cel` performs the platform check, loads shell modules and dispatches
  commands. `lib/` owns the mechanisms; `agents.yaml` describes agent commands,
  injection strategies and fresh-install pins.
- `core/roles/` contains role prompts. `core/skills/` contains reusable workflows
  and their executables, including `cel-fanout` and `cel-linear`.
- A separately owned workspace contains `workspace.yaml`, optional layouts,
  skills and dependency overlays, plus product clones under `repos/`.
  Workspace content and credentials do not belong in this repository.
- `~/.local/share/cel/registry.yaml` locates workspaces. A workspace's
  `.cel/delegations.json` records delegated work; `.cel/delegations.lock` fences
  cooperating admission, reconciliation, collection and release operations.
- `~/.local/share/cel/` also holds pages, logs and steward bookkeeping.
  `~/.local/state/cel/gc-idle.json` holds observed-idle evidence. These paths
  are machine state, not publication inputs.

## Launch and lifecycle

Workspace resolution supplies policy, role, runtime, profile and environment.
`cel run` starts the selected role in a visible herdr pane. Fanout creates a
Git worktree for a delegated worker, starts the pane and records the resulting
identity. Worker/reviewer roles use the same GitHub and ticket interfaces that
an operator can invoke directly.

Launch environment is scoped to the launched process: `_run_launch_env` is the
single construction (used by `cel run` and `cel-fanout`) and renders role
marks, gateway credentials, the per-agent `CEL_SESSION_ID` and the agent root as
one `env K=V ...` prefix - never an `export` into the pane shell, which outlives
the agent. Pi and OMP agent roots are resolved once (`gateway_pi_dir`,
`gateway_omp_dir`; custom roots via `CEL_PI_AGENT_DIR` / `CEL_OMP_AGENT_DIR`),
shared by the models writers, the child and `cel doctor`, and pinned into the
child as `PI_CODING_AGENT_DIR`; an inherited value is ignored. They must not
overlap (`agent_roots_check`): OMP's startup renames Pi-style session
directories under its root with no liveness check. This prevents new
collisions only; it does not repair already-relocated sessions or running
processes, which belong to the retained-runtime lifecycle.

Prompt policy guides agents; it is not a sandbox. Agent commands run with the
launching user's filesystem and account privileges. Several runtime launch
strategies pre-approve tool permissions. Only use trusted workspace content,
skills and dependencies, and understand the accounts available to each agent.

The steward performs a deterministic sweep: cleanup, review/ticket/mailbox
nudges, stalled-worker reporting, server maintenance and update checks. The
optional systemd user timer defaults to five minutes. A sweep itself makes no
model call, but a prompted agent may start paid work.

## Preservation before cleanup

Every GC deletion path checks registry/delegation/process evidence and Git
state. Dirty work, running delegations, incomplete discovery and unknown
comparisons are retained. An attached clean HEAD must be proven contained in
the verified default branch, or match the exact head of a GitHub-merged PR;
additional local commits invalidate that proof. Fanout release reports unknown
work as held, with explicit keep/discard decisions rather than a zero count.

### Gateway credentials for an omp that starts native

An omp session can switch models in flight, and its launch environment is the
only place it reads the gateway client key (`OMP_GATEWAY_TOKEN`) and the
per-agent `CEL_SESSION_ID`. So `cel run` exports them for every omp launch on a
box with a configured gateway and a readable, non-empty key - even when the
starting model is Codex or another direct provider. Nothing is written to
models files, no gateway is required or started, and a box with no gateway (or
an unreadable key) launches exactly as before. A `via: gateway` profile still
refuses when the key is missing. Limitation: a session already running keeps
the environment it was launched with; it gains the credential only on its next
`cel run --restart`. pi is unchanged.

### Launch readiness (`cel run`)

The launch line (role environment and, for gateway profiles, the credential
substitution) is typed into a pane before `herdr agent start`, which itself
requires the pane's shell to own the foreground. A fresh pane's shell is still
reading its rc files, so `cel run` first waits, on herdr's structured state
only (`pane get`: terminal id and agent; `pane process-info`: shell pid and
foreground processes), for `CEL_PANE_READY_STABLE` (3) consecutive probes of
the same terminal and shell with no agent and the shell alone in the foreground,
within `CEL_PANE_READY_MS` (30000). Past the deadline, or when herdr cannot
describe the pane, or an agent occupies it, the launch dies before anything is
typed: no prefix, no agent start, no reviewer record. A terminal or shell that
changes while waiting, or after the text is typed, is refused as a change of
owner. The same gate covers console, root, orchestrator, worker, reviewer,
`--restart` and `cel-fanout delegate` (which has its own launch sequence).
Limit: herdr 0.9.1 exposes no structured "prompt drawn" field, so the 3-probe
stability is a mitigation, not proof the prompt is ready; a supported herdr
field is the upstream prerequisite. The foreground process group must equal the
shell pid, as herdr's own prompt predicate requires. `herdr agent start` is attempted once and never retried; if it is
refused after the line was typed, the error names the pane, says the line (never
printed) is pending and unsubmitted, and leaves clearing it to the owner - `cel`
sends no Enter and no keys.

Reaping is separate from worktree deletion. It requires a named plane-owned
worker, proof of the role it was launched for, inherited pane identity,
herdr's foreground-process attestation, and the same `/proc` PID/start time.
That role proof is read from the launch environment (`CEL_ROLE`,
`CEL_ROLE_FILE`, `CEL_WORKSPACE`, set as a prefix on the launch line by `cel
run` and fanout), because a runtime may rewrite its own argv and leave nothing
recognisable in `/proc/<pid>/cmdline`; the older role-file argument scan
remains as a fallback for panes started by an earlier build. The idle clock
additionally binds boot, session, terminal and state-change sequence. First
observation never reaps; active or unverifiable state resets eligibility.
Root/orchestrators, manual launches and unsupported ownership stamps remain.
A runtime declaring `signal: int` in `agents.yaml` is asked to stop with
SIGINT, then SIGTERM after `CEL_GC_GRACE`, and is otherwise reported and kept;
GC never sends SIGKILL. The summary line splits `kept` by reason, and names
the directories it could not identify, so a blind sweep cannot read as an idle
one.

Locks serialize cooperating Celestial lifecycle writers. Registry and ledger
updates use temporary files beside their destination followed by atomic
rename, so readers do not see a partial replacement. This is not fsync-based
power-loss durability, nor an atomic transaction with arbitrary external
Git/herdr writers. Keep independent backups of important work.

### Replacing a published PR (`cel-fanout replace`)

A published branch is never rewritten; a PR opened outside the fleet has no
delegation row. `replace reserve` / `replace attach` are the two durable,
individually atomic stages that give a clean candidate a row of its own. The
child row carries `replacement.{role:child, of, original_head, original_pr,
target_head, stage}`; the original carries `replacement.{role:source, child}`.
The `replacement` namespace is separate from any recovery metadata. Consumers
treat a `source` row as history only: capacity, fleet rows, gc pane handling
and the held-work refusal skip it, `release` refuses to remove the worktree
the child now owns, and `_ledger_append` keeps lineage across a re-delegation.
No new ledger state exists - the child is an ordinary `running` row whose
collect/review/land are gated on `stage: attached`.

### Gateway transports, agent updates and runtime retirement (AH-261018)

- **Codex over Responses.** The gateway serves Chat Completions, Anthropic Messages and OpenAI Responses (`/v1/responses`, `/v1/responses/compact`, and the Responses websocket upgrade on the same path) over one vault. Claude uses `anthropic-messages`; Codex-family ids use `openai-responses` (pi provider `ompgw-codex`, omp provider `celgw-codex`) so compaction and reasoning items are not dropped by a chat-completions substitution. Which transport a live turn actually negotiates (SSE or websocket) is a property of the runtime and is proven with an authenticated turn, not asserted by the writer.
- **Native start, gateway later.** An omp launched on a native model still receives the gateway client environment and the registered gateway providers; a running process's environment is fixed, so a session started earlier is recovered through its own native session resume (`cel run <role> --restart`, which passes `--resume` for omp and `--session` for pi), never by pretending new variables reach it.
- **`cel update`** runs the agent and gateway components on every update (agents.yaml `update:`), each through the agent's own installer, with an honest per-component report. A component that fails, or that is still behind the published latest after its updater ran, makes the update a non-success; rerun is the recovery.
- **Runtime retirement is not worktree deletion.** `cel gc` closes the pane of an idle, clean, pushed agent proven to be this plane's own (exact pid, birth, pane, role; foreground group = the runtime plus its declared direct helper only). Worktree, branch, session file and the delegation row are untouched.

## Credentials

Workspace `env:` and gitignored `env.local` layer over the caller's environment.
Each steward workspace sweep has its own subshell: one workspace's override
cannot become another's fallback or mutate the parent. Provider quota caches
are keyed by provider and credential fingerprint rather than workspace order.
Linear and quota HTTP requests keep credential headers out of curl's argument
list. A signed-in subscription is identified by where the credential lives
(`claude/pi`, `claude/claude-code`, `codex/<account id>`,
`gateway/<provider>/<id>`), never by a hash of the token, so a token refresh
overwrites one cache entry instead of inventing an account; `cel quota`,
`cel fleet --json`, the console's QUOTA view and the dashboard all render that
one list, and no token is ever printed. Credentials still exist in process environments/memory; the local user
and root are trusted. Linear's private temporary header file is removed on
normal exit and handled signals, but cannot promise cleanup after SIGKILL.

## HTTP surfaces

`tools/pages/server.mjs` runs in two distinct modes. The private listener
provides a document shell, revisions, feedback and promotion/revocation.
Published HTML runs in a same-origin iframe and is trusted active content.
Feedback strings are rendered as text, not HTML. The public listener serves
only a live token/document pair; no directory listing, session or control API
is available there. Public links are bearer capabilities: anyone holding one
can read it until expiry/revocation, and revocation cannot retract saved copies.

`tools/dash/server.mjs` is one server for the box: it renders every
registered workspace (`/api/state?ws=<name>` reads one; `/classic` redirects
to `/`), and invokes existing CLIs for
state and control. An absent inbox produces a complete empty state. Fallible
response construction finishes before headers; late failures are contained
without trying to send a second status line.

Both private surfaces use `tools/http-security.mjs`: exact configured
Host/Origin checks and a per-process CSRF token. `GET /api/session` is the
trusted automation handshake, not a login. The public pages tier intentionally
accepts dynamic tunnel hostnames but never exposes those controls. See the
[README](../README.md#private-http-services) for configuration and the
[security policy](../SECURITY.md) for the trust boundary.

## Installation and release

Fresh installs consume explicit versions/checksums and plugin Git commits.
Existing executables and unrelated plugin installs are retained. Distribution
packages, transitive/build dependencies and future upstream self-updates are
not a hermetic lock. Source/ref overlay conflicts and installation failures
are reported to the caller rather than silently skipped.

The public release gate combines behavioral tests, a generic source/history
scanner, an independent credential scanner, and an external private vocabulary
scan performed by the release owner. GitHub discussions, pull-request refs,
release assets and metadata need separate inspection: a clean current tree
cannot establish that old repository surfaces are safe to publish.

Only one test suite runs on a box at a time. `tests/run.sh` takes an exclusive
`flock` (`$CEL_SUITE_LOCK`, else `$XDG_RUNTIME_DIR/cel-suite.lock`, else a
per-user file under the temporary directory) before the first test file and
names the holder while it waits; `cel-verify` queues on the same lock and
starts its `--gate-timeout` clock only after acquiring it, recording the wait
as `gate.waited_secs`. The lock is held by an open descriptor, so process exit
releases it and no stale state survives an interrupted run. `--no-lock` and
`CEL_SUITE_LOCK=none` opt out; a filtered run does not. The steward reports a
lock held past `CEL_SUITE_HOLD_WARN_SECS` and never breaks it.
