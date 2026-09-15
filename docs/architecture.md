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

Reaping is separate from worktree deletion. It requires a named plane-owned
worker, a matching role-file argument and inherited pane identity, herdr's
foreground-process attestation, and the same `/proc` PID/start time. The idle
clock additionally binds boot, session, terminal and state-change sequence.
First observation never reaps; active or unverifiable state resets eligibility.
Root/orchestrators, manual launches and unsupported ownership stamps remain.

Locks serialize cooperating Celestial lifecycle writers. Registry and ledger
updates use temporary files beside their destination followed by atomic
rename, so readers do not see a partial replacement. This is not fsync-based
power-loss durability, nor an atomic transaction with arbitrary external
Git/herdr writers. Keep independent backups of important work.

## Credentials

Workspace `env:` and gitignored `env.local` layer over the caller's environment.
Each steward workspace sweep has its own subshell: one workspace's override
cannot become another's fallback or mutate the parent. Provider quota caches
are keyed by provider and credential fingerprint rather than workspace order.
Linear and quota HTTP requests keep credential headers out of curl's argument
list. Credentials still exist in process environments/memory; the local user
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

`tools/dash/server.mjs` renders one workspace and invokes existing CLIs for
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
