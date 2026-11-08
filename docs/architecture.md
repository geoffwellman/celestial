# Architecture

Celestial is an AI software factory implemented as a GNU/Linux command-line
control plane around Git worktrees, [herdr](https://herdr.dev), coding-agent CLIs and a small pair of Node HTTP
servers. It is not a scheduler with its own agent runtime or an isolation
boundary against the local user.

## Code and state

- `bin/cel` performs the platform check, loads shell modules and dispatches
  commands. `lib/` owns the mechanisms; `agents.yaml` describes agent commands,
  injection strategies and fresh-install pins.
- `core/roles/` contains role prompts. `core/skills/` contains reusable workflows
  and their executables, including `cel-verify` and `cel-linear`.
- A separately owned workspace contains `workspace.yaml`, optional layouts,
  skills and dependency overlays, plus product clones under `repos/`.
  Workspace content and credentials do not belong in this repository.
- `~/.local/share/cel/registry.yaml` locates workspaces. A workspace's `.cel/`
  holds its own machine state: solo review verdicts in `.cel/solo-reviews.json`,
  solo worktrees and lane directories under `.cel/solo/<product>/`.
- `~/.local/share/cel/` also holds pages, logs and steward bookkeeping.
  `~/.local/state/cel/gc-idle.json` holds observed-idle evidence. These paths
  are machine state, not publication inputs.

## Launch and lifecycle

Workspace resolution supplies policy, role, runtime, profile and environment.
`cel run` starts the selected role in a visible Herdr pane by default, or an
explicitly selected managed Rex session. Solo agents and reviewers use the
same GitHub and ticket interfaces that an operator can invoke directly.

A product's build mode (`ws_build_mode`) is `solo` when the product declares
no `mode:`, and `mode: solo` is valid as written. Every launch path for a
product agent - `cel run orchestrator`, `cel run solo`, `cel ws up` and the
steward's `orchestrator: auto` - starts the solo role. A legacy explicit
`mode: fleet` is still read back as `fleet`, but `cel run orchestrator`
refuses to launch it and names `cel mode <p> solo`. A solo agent reuses the
orchestrator's launch plumbing - product directory, alias, mailbox, resume,
the one-agent-per-product refusal, and a role file still named
`role-orchestrator.md` so GC never reaps it - and differs in its role body
(`core/roles/solo.md`) and in `CEL_ROLE=solo`, which `lib/guard.sh` reads to
allow repository writes while refusing agent starts and manual merges.
`cel mode` (lib/mode.sh) edits the one `mode:` line in place, verifies the
result as data, and hands the restart to a transient user unit that waits
for the agent to leave its turn before `cel run orchestrator --restart`;
`cel mode <p> fleet` is refused and writes nothing. The orchestrator role file
(`core/roles/project-orchestrator.md`) carries no body: the orchestrator is the
solo role, which also leads feature teams.

People are declared in the committed `workspace.yaml` (`people:`: id, forge
login, roles workspace-wide and per product), and a login names the person
it is with `me:` in its gitignored `workspace.local.yaml` - the one key that
file may set besides routing (`_WS_LOCAL_KEYS`, `lib/yaml.sh`). `ws_me` reads
`me` from `workspace.local.yaml` alone, never from the merged view: a local
file that fails the merge falls back to `workspace.yaml`, and a committed `me`
must not become this login's. `lib/workspace.sh` also reads
`ws_people_json`, `ws_person_holds` and `ws_role_holders`. A product
may name its `home:` (`products[].home`, or `repos[].home` for an implicit
product; `ws_product_home`), the person whose login runs its agents.
`ws_product_home_check` is the one test: true with no home or when `me` is
the home, false otherwise - including a login with no `me` (fail closed). `cel
run orchestrator|solo` and lanes die on false unless `--force`; `cel ws up`
(`wslife_orchestrators`), the steward (`_steward_orchestrators`) and the
missing-orchestrator rows (`run_orchestrator_rows`) skip the product without
raising anything. `me` is self-asserted and drives only who starts what;
`cel doctor` (`doctor_people_lines`) checks the schema and warns when
`people_forge_login` (`lib/people.sh`: GitHub's active account without the
workspace's `github.user` token, or the login's own Forgejo token) differs
from the person's `login`. `cel people` prints the same data.

Launch environment is scoped to the launched process: `_run_launch_env` is the
single construction (used by every `cel run` launch) and renders role
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

One box-wide helper budget (`lib/budget.sh`) admits team members and new
reviewers: `budget_admit <kind>` counts the native inventory
(`cel_agent_list`) by role; the HELPERS (reviewers, team members, any other
agent) are held under `budget.max_live_agents` (default 8) and the members
under `budget.max_team_members` (default 4) in the box config, then
`boxguard_admit` answers for the memory floor; an unreadable inventory
refuses. Product agents (`*-orch`, solo lanes) and core/root are shown by
`cel budget` but never counted - a box running ten products keeps the whole
helper budget for their reviewers - and a product launch is never blocked,
only warned by the memory floor. Team members start through one door,
`cel team add`, which reserves the member row and writes a one-time launch
token that `cel run member` spends before any check (the guard refuses every
agent both `cel run member` and the token directory). The launcher admits the
member under the same launch lock as every `cel run`, gives a builder its own
worktree on `team/<feature>/<name>` at the recorded base, marks the process
`CEL_ROLE=member` with `CEL_TEAM`, `CEL_TEAM_ROLE`, `CEL_TEAM_MEMBER` (and a
builder's `CEL_TEAM_BRANCH`), and reports success only when the inventory
shows that agent in that pane. `member_retire` closes a member's pane only
after the pane's process proves that launch identity - the same
`/proc/<pid>/environ` proof that attributes a reviewer to its workspace.
The member guard compares paths resolved (realpath against the pane's
directory and every `cd` in the line), runs git only from known verbs and
options, lets a builder push only `origin <its branch>`, confines writes to
the builder's worktree or a read-only role's `artifacts/<role>/` and
`notes/<alias>/`, gives a member no one-off override and fails closed. Like
every guard rule it is a tripwire: an interpreter or a script it does not
parse still runs.

Prompt policy guides agents; it is not a sandbox. Agent commands run with the
launching user's filesystem and account privileges. Several runtime launch
strategies pre-approve tool permissions. Only use trusted workspace content,
skills and dependencies, and understand the accounts available to each agent.

The steward performs a deterministic sweep: cleanup, review/ticket/mailbox
nudges, stalled-agent reporting, server maintenance and update checks. The
optional systemd user timer defaults to five minutes. A sweep itself makes no
model call, but a prompted agent may start paid work.

### Launch environment by role

A runtime inherits its pane's shell: the environment Herdr or Rex was started
with, the workspace's `env:` and `env.local` (loaded by `cel shellenv` in a
Herdr pane's shell, exported by the private Rex launch script), and then the
launch line's own `K=V` words. Reviewers and team members are helpers and get
only what their role needs: their line ends in a scrub (`_run_launch_scrub`),
run after every `K=V` word and immediately before the runtime, that unsets
each inherited variable whose NAME looks like a credential - `*_TOKEN`,
`*_API_KEY`, `*_KEY`, `*_SECRET`, `*_PASSWORD`, `*_CREDENTIALS`, `*_PAT`,
`*_DSN`, `DATABASE_URL`, `AWS_*`, `CLOUDFLARE_*`, `CF_API_*`, `OPENROUTER_*`
and their plural/short forms (`_RUN_SECRET_NAMES`, case-insensitive). Kept:
every name the launch line itself sets, plus `LAUNCH_ENV_KEEP`. The scrub's
argv carries names, never values.

| Role | Secret-named variables it keeps | Why |
|---|---|---|
| reviewer | `OMP_GATEWAY_TOKEN`, `CEL_SESSION_ID` | always gateway-routed (Claude or Codex through `cel gateway`): the client key and the affinity key the provider block names |
| reviewer, member | `GH_TOKEN`, only for a workspace with `github.user` | the workspace's account, produced by `gh auth token --user` in the pane (`ws_github_env_word`); a caller's `GH_TOKEN`/`GITHUB_TOKEN` is dropped |
| member | `OMP_GATEWAY_TOKEN`, `CEL_SESSION_ID`, when `_run_profile_gateway_setup` sets them (a `via: gateway` profile, or omp on a box with a gateway key) | as for a reviewer |
| member | the provider `key_env` of a direct profile's model (e.g. `OPENROUTER_API_KEY` for `openrouter/...`), from `_run_provider_key_env` | the one key that profile authenticates with; none for a gateway route, a CLI-signed-in provider, or a model naming no provider |

Everything else secret-named - an owner's Cloudflare, AWS or deploy tokens,
other providers' keys, an inherited gateway key on a launch that is not
gateway-routed - is gone from the runtime. Non-secret names (`PATH`, `HOME`,
`HERDR_PANE_ID`, the `CEL_*` role marks) are untouched. This is environment
containment, not a sandbox: a helper runs as the same user and can still read
`env.local` or a key file from disk, and `cel-linear` loads the workspace env
itself when its key is absent.

Product agents (`solo`, `orchestrator`, lanes, `root`, a role-less `direct`
agent) and core are NOT scrubbed. Today they inherit the whole pane
environment above - every owner credential the launching shell, the Herdr or
Rex server, `env:` and `env.local` carry - plus the gateway words and the
workspace `GH_TOKEN`. They may legitimately deploy, so narrowing them is the
owner's decision. Proposed: the same scrub, with a per-workspace declared
allowlist for product agents (the deploy credentials the owner grants them by
name) and, for core, the gateway words and provider keys only.

### Feature teams (`lib/team.sh`)

A team is one folder, `<ws>/.cel/teams/<feature>/`, and nothing else: no
ledger, no state inferred from branches. `team.json` is the roster (members
with role, focus, repo, branch, worktree, base commit, owned globs and state
`reserved|ready|working|done|retired`), `events.jsonl` an append-only log,
`verdicts.json` an array of head-bound verdicts, `members/<alias>.md` each
member's scope packet. Every write holds the folder's `.lock` (flock) and
calls nothing external while holding it - the budget, git, the launcher,
herdr and the inbox are all called outside it - and JSON is written temp +
rename. `cel team start` builds the folder aside and renames it into place,
so a half-made team is never visible and a second start of the id fails.
Authority is checked in `cel team` itself, and only positively: start, add,
retire, close and `cap` belong to `<product>-orch` (the lead: `CEL_ROLE` solo
or orchestrator, its product from `CEL_PRODUCT` and/or its mailbox, agreeing
and naming the team's product); a `decision` event and the spend cap
(`team.json` `spend_cap`) are the lead's only, so nothing a member writes -
brief.md included - can grant spend or authority. There is no owner path: a
process with no agent role (an agent can shed one with `env -u` or `setsid`)
is refused and the owner asks the lead by `cel inbox` or `cel decide`.
Members act by their member identity (ack, event, verdict). Every writing
verb also checks that identity against the agent's launch
(`cel_launch_identity`, lib/identity.sh): the nearest process above `cel` whose
`/proc/<pid>/environ` - fixed at exec, the marks `cel gc` proves agents by -
carries `CEL_ROLE` must agree on `CEL_ROLE`, `CEL_PRODUCT`, `CEL_INBOX_ME`,
`CEL_INBOX_WS` and the `CEL_TEAM*` variables, so a shell re-dressed with
`export` or a variable-held name is refused, and so is a role with no launch
above it (detached by `setsid` or a double fork). A process that execs a
fresh environment carrying `CEL_ROLE` is its own nearest launch; that
spelling is the guard's to refuse. `cel forge`'s writes run the same check.
Nothing in the environment skips or redirects it: its test seam, a fixture
proc root in `CEL_PROC_DIR` (also read by lib/inbox.sh and lib/run.sh), is
honoured only for a process under that checkout's own `tests/run.sh`
(`cel_under_suite`, lib/common.sh), decided from the process's ancestry in
`/proc` - an ancestor that is the same bash running that `run.sh` as its
script - which no exported variable changes. The forge's curl seam
(`CEL_FORGE_CURL`) is gated the same way. The check reads `/proc` with shell
builtins only, so a `PATH` with other binaries first cannot feed it a forged
environ, and it runs in a clean process: before loading anything, `bin/cel`
re-executes itself without `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS` and
every exported function (`BASH_FUNC_*`) unless the environ it started with
carries none of them, so smuggled shell code (an exported `exit` that
returns, a function that shadows the check) never reaches cel's checks.

The limit, plainly: the test seams - `CEL_PROC_DIR`, `CEL_FORGE_CURL` and the
gh stubs (`CEL_WS_GH_BIN`, fed from `CEL_FORGE_GH`, `GH` or `CEL_AFK_GH`) -
are trusted for every process beneath that checkout's `tests/run.sh`, not
only for its tests, and for nothing outside it. Agent code the suite runs - a
test file, or a tool a test calls that a `PATH` put first - can point them at
a tree that vouches for a forged identity, or at a binary that then receives
the forge token or a workspace's GitHub token. This is accepted: agents run as the owner's Unix user, so they can
read the token file and call the forge API directly; nothing in-process stops a
determined one. What the checks stop is the easy route. `tests/run.sh` refuses
to start with `BASH_ENV` or `ENV` set, and the guard refuses an agent line that
runs the suite with `BASH_ENV`, `ENV`, `PATH` or an exported function set.
Like the rest of the guard, these are tripwires, not a boundary.

`cel team add` validates first (role, focus, repo, builder `--owns`), then
asks `budget_admit team-member --pending N` (lib/budget.sh) BEFORE any write,
so a refusal leaves nothing behind; N counts team-member rows that are
reserved but not yet launched in every registered workspace, which the live
inventory cannot see. Under the lock it counts the team's non-retired rows
against `budget.max_team_members`, so two adds to one team cannot both pass
at the limit (two adds to different teams at once can still both pass the
box-wide check - the window is the admission call). It then re-checks
ownership, writes the reserved row, the packet and a one-time token
`launch/<alias>.token` (mode 600, random hex), and outside the lock runs `cel
run member --workspace <name> --team <f> --member <alias>`, which consumes
the token before it launches. Exit 0 marks the row `launched` (retried, and
reported as a running member to retire if it cannot be written); exit 1 is a
refusal that may still have left a worktree, branch or pane, so
`member_retire` clears what it can prove is ours before the row is retired;
anything else leaves it `reserved` and never relaunches. `ready` needs both
`launched` and the member's own `cel team ack`, whichever lands second.
Retirement goes through `member_retire` (lib/run.sh), which confirms the
pane's identity. Keeping a builder's worktree is decided here: `cel team
retire` checks it for uncommitted changes or commits on no origin ref and
passes `--keep` when it finds any; `cel team close` checks every live
builder first, refuses before retiring anyone, and with `--force-keep`
passes `--keep` for every builder.

Builder ownership: each glob is split into `/` segments with an implicit
trailing `**` (a path owns its subtree). Two globs overlap when some path
matches both: `**` matches zero or more segments, literal segments compare
exactly, a literal against a pattern is a bash pattern match, and two
`*`-only patterns overlap exactly when their fixed prefixes and suffixes are
compatible. Anything else (`?`, `[..]`, braces on both sides) cannot be
decided here and is refused as overlapping, with the reason.

### Preview server ownership

Long-running preview and development servers belong in `cel serve`'s per-user
ledger. `cel serve start <name> --owner <alias> --workspace <workspace>
[--ttl 8h] [--port N] -- <command>` launches a transient `cel-serve-<name>`
systemd user unit with memory accounting and records its worktree. `cel serve
list [--json]`, `stop <name>`, and read-only `adopt` expose tracked and
untracked processes; untracked processes are never stopped automatically.
Request activity is refreshed from established listener connections and can
also be marked by `cel serve request <name>`. Set `serve.idle_hours` (default
6) and `serve.pressure_idle_hours` (default 1) in the Cel config to tune idle
retention. The steward stops only ledgered servers after TTL, idle timeout, or
worktree removal, and mails their owner with the recorded restart command.

## Preservation before cleanup

Every GC deletion path checks registry/process evidence and Git state. Dirty
work, incomplete discovery and unknown comparisons are retained. An attached
clean HEAD must be proven contained in the verified default branch, or match
the exact head of a GitHub-merged PR; additional local commits invalidate
that proof.

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
owner. The same gate covers core, root, orchestrator, solo, reviewer and
`--restart`.
Limit: herdr 0.9.1 exposes no structured "prompt drawn" field, so the 3-probe
stability is a mitigation, not proof the prompt is ready; a supported herdr
field is the upstream prerequisite. The foreground process group must equal the
shell pid, as herdr's own prompt predicate requires. `herdr agent start` is attempted once and never retried; if it is
refused after the line was typed, the error names the pane, says the line (never
printed) is pending and unsubmitted, and leaves clearing it to the owner - `cel`
sends no Enter and no keys.

Inventory consumers use `cel_agent_list` to merge Herdr and managed Rex
agents. Inbox discovery/pruning, status views and GC share that roster, but
control APIs remain backend-specific: `rex/<session>/<block>` is an identity,
never a Herdr pane argument. Rex presence protects its checkout; GC does not
infer retirement eligibility from a Rex idle status or missing screen output.
Failed discovery is unknown, not an empty fleet or permission to prune mail.

A product's team is one Rex session group. A product agent (and core, root, a
lane) opens a session of its own (`rex_scope: "session"` in its receipt). A
Rex reviewer, and a team member whose lead runs in Rex, opens instead as a
window labelled with its alias, never focused (`rex window new -s <session>
<alias> --focus=false`), in its product agent's session - the team's `lead`,
else `<product>-orch` - and its receipt records `rex_scope: "window"`,
`rex_window` and `rex_host` beside the session and block. The host session is
used only when proven the way any managed agent is: its receipt (name,
workspace, a product-agent role, a session of its own), its live PID/start
generation, and Rex reporting that PID as the child of the receipt's block in
that session. Otherwise the reviewer or member opens a session of its own, as
before, and the launch says so in one line. Retirement closes only the
agent's own container: a window-scoped reviewer's (`tools/reviewers/retire.mjs`)
or member's (`rex_agent_close`) proof is its window holding exactly its one
block, queried window-scoped (`rex window inspect`, `rex block call process
-w`), before `rex window close` and a check that the window is gone; the host
session and its other windows are never closed, and a window anyone added a
terminal to is protected. Session IDs, window IDs and block IDs survive a Rex
server restart (a restored terminal runs a fresh shell, not the agent).
Reviewers and members never resume from a receipt: after a restart the product
agent resumes through its recorded line, and a reviewer relaunched by `cel run
reviewer` (or a member re-added by `cel team add`) opens as a window in the
resumed product agent's session.

Known Rex API limits (revision 10): Rex has no compare-and-swap for these
calls, so two check-then-act gaps remain and are narrowed, not closed. (1)
Between the host-session proof and `rex window new` the product agent can
exit or its session can change; `session.new_window` takes no expected
revision or owner, so the guest may open in a session whose agent has just
gone. The guest's own identity is its own receipt either way, and nothing is
closed on the strength of the host proof. (2) Between the last container
proof (re-run immediately before the close) and `rex window close` / `rex
kill`, someone can add a terminal to that window or session;
`session.close_window` (session and window id only; extra fields are
rejected) and `session.destroy` (an unknown `if_revision` is ignored, not
enforced) take no revision guard, so that terminal would close with it. Both
gaps close once Rex offers a conditional create/close.
Members and reviewers are guarded to read-only `rex` commands (`ls`,
`inspect`, `capture`, `block call process`), so neither can type into or
close its product agent's window.

`cel ws down` (and therefore `reset`) explicitly stops managed Rex agents whose
receipt names that exact workspace, after the existing held-work check; the
box-wide core and other workspaces are excluded. A failed stop prevents reset
from launching replacements. This stops runtimes without deleting worktrees.

Rex verdict recording binds the calling process's live PID ancestry to its
reviewer receipt, including alias, workspace, repository and PR. Solo
verdicts validate that exact target before writing; a reviewer for one PR
cannot attribute a verdict on another PR to itself.

Reaping is separate from worktree deletion. It requires a named plane-owned
agent, proof of the role it was launched for, inherited pane identity,
herdr's foreground-process attestation, and the same `/proc` PID/start time.
That role proof is read from the launch environment (`CEL_ROLE`,
`CEL_ROLE_FILE`, `CEL_WORKSPACE`, set as a prefix on the launch line by `cel
run`), because a runtime may rewrite its own argv and leave nothing
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

Locks serialize cooperating Celestial lifecycle writers. Registry and state
file updates use temporary files beside their destination followed by atomic
rename, so readers do not see a partial replacement. This is not fsync-based
power-loss durability, nor an atomic transaction with arbitrary external
Git/herdr writers. Keep independent backups of important work.

### Gateway transports, agent updates and runtime retirement

- **Codex over Responses.** The gateway serves Chat Completions, Anthropic Messages and OpenAI Responses (`/v1/responses`, `/v1/responses/compact`, and the Responses websocket upgrade on the same path) over one vault. Claude uses `anthropic-messages`; Codex-family ids use `openai-responses` (pi provider `ompgw-codex`, omp provider `celgw-codex`) so compaction and reasoning items are not dropped by a chat-completions substitution. Which transport a live turn actually negotiates (SSE or websocket) is a property of the runtime and is proven with an authenticated turn, not asserted by the writer.
- **Native start, gateway later.** An omp launched on a native model still receives the gateway client environment and the registered gateway providers; a running process's environment is fixed, so a session started earlier is recovered through its own native session resume (`cel run <role> --restart`, which passes `--resume` for omp and `--session` for pi), never by pretending new variables reach it.
- **`cel update`** runs the agent and gateway components on every update (agents.yaml `update:`), each through the agent's own installer, with an honest per-component report. A component that fails, or that is still behind the published latest after its updater ran, makes the update a non-success; rerun is the recovery.
- **Runtime retirement is not worktree deletion.** `cel gc` closes the pane of an idle, clean, pushed agent proven to be this plane's own (exact pid, birth, pane, role; foreground group = the runtime plus its declared direct helper only). Worktree, branch and session file are untouched.

### Gateway client key rotation (`cel gateway rotate-key`, `lib/gateway-rotate.sh`)

The client key (`<gateway state>/api-key`, 0600) reaches an agent once, at
launch, as `OMP_GATEWAY_TOKEN`, and a running process's environment cannot be
changed. A key replaced in place would 401 every agent already running, so
rotation relies on CLIProxyAPI accepting a list of `api-keys` and reloading
`config.yaml` when it changes. `_gateway_config_write` lists every key file
present, oldest first: `api-key.previous`, `api-key`, `api-key.next`. A refresh
during a rotation (`cel update`) therefore keeps both keys.

1. `--stage` (owner) mints `api-key.next`, rewrites the config with old and
   new, and waits until `/v1/models` answers 200 to both. Then it writes the
   old key to `api-key.previous` and renames `api-key.next` over `api-key`.
   Both writes are atomic and 0600. From here every launch gets the new key.
   If either key is not accepted in time, `api-key.next` is removed and the
   config goes back to the old key alone.
2. `--status` (open to agents) shows the keys the config accepts, by sha256
   fingerprint. It lists every live process of this user whose environ
   carries the old key, matched by sha256, grouped into launches: the topmost
   holder stands for the children that inherited it. For each launch it names
   the restart: `cel run orchestrator|solo ... --restart` for product agents
   and lanes, a note for reviewers (they finish their round; a later round
   starts a fresh one), and `cel run root` and `cel core --restart` last.
3. `--finish` (owner) is refused while any launch still holds the old key.
   `--force` cuts those launches off. It then rewrites the config with the
   current key alone, waits for old 401 and new 200, and only then deletes
   `api-key.previous` (and a leftover `api-key.next`). If the gateway does
   not drop the old key in time, the two-key config is written again and the
   rotation stays staged.
4. `--abort` (owner, before `--finish`) restores the old key as the only key.
   Like `--finish`, it is refused while launches started since `--stage` hold
   the new key, unless `--force`. It also clears an interrupted `--stage`.
   It writes `api-key` back first, then the one-key config (proven), and
   deletes the rotation files last.

Crash safety: every verb changes the config before it deletes a key file, so
a kill at any point leaves files that say what is left to do. A `--stage`
killed before the rename leaves `api-key.next`, or `api-key.previous` equal to
`api-key`. `--status` reports that as INTERRUPTED, `--abort` clears it, and
`--finish` refuses it. A kill during `--finish` or `--abort` is completed by
running the verb again. `--status` also flags any mismatch between the keys
`config.yaml` accepts and the key files, and names the fix (`--finish` again,
or `cel gateway refresh`). The suite proves each step by killing the verb
after it (`CEL_GATEWAY_ROTATE_CRASH_AFTER`, honoured only under
`cel_under_suite`).

Owner only: `--stage`, `--finish` and `--abort` refuse a process that carries
an agent launch's marks (`CEL_ROLE`, `CEL_INBOX_ME`, `CEL_SESSION_ID`,
`OMP_GATEWAY_TOKEN`, `CLAUDECODE`, `OMPCODE` and similar). They also refuse a
process with such a launch among its ancestors, so shedding the variables does
not help. Separately, `lib/guard.sh` denies those three verbs to every agent
pane. No key value is printed or put in an argv. Keys move through 0600 files
and curl's stdin, and are named by the first 12 hex digits of their sha256.

## Source-control forges

A repo's forge is chosen per repo, never per workspace. `forge_repo`
(`lib/workspace.sh`) reads the repo's declared `url:` (else its clone's
`origin`) through the one remote-url grammar that `github_slug_from_url` also
uses, and returns `{provider, host, owner, repo, ssh_host, web_url, api_url}`.
github.com, or the workspace's `github.ssh_host` alias, is GitHub. Any other
host is Forgejo only when the repo declares `forge: forgejo` or a `host:` of
its own (the web/API host, for a url that dials an ssh alias); an undeclared
host, a lookalike, or a declaration the url contradicts is refused. Web and
API are https unless the repo's own `host:` is written `http://<host>` - a
forge that serves plain HTTP only (an internal box) is declared, never
guessed, and never beside an https clone url. A plain `http://` host sends
the API token unencrypted on every request - only for a trusted LAN. For
example:

```yaml
  - name: gizmo
    url: git@forgejo-ssh.example.net:acme/gizmo.git   # what git dials (ssh)
    forge: forgejo
    host: http://forgejo.example.net                  # web + /api/v1, plain HTTP
```

`lib/forge.sh` holds pull-request and CI operations in Celestial's own
vocabulary (`forge_pr_view`, `forge_pr_list`, `forge_pr_checks`,
`forge_pr_reviews`, `forge_pr_merge`, `forge_pr_create`, `forge_pr_close`,
`forge_pr_ready`, `forge_whoami`, `forge_run_list`, `forge_run_view`,
`forge_run_rerun`, `forge_run_resolve`): each prints one normalised JSON value
or fails, with the same shape from either backend; `forge_run_logs` prints a
job's log as plain text. Run and job ids are the API's (the web UI's run
number is shown beside them as `web #N`, never taken as an id); `run list
--sha <head>` lists a commit's runs with their job ids, and a web page is
mapped to ids only through Forgejo's own `html_url` of the run and job, else
refused. `cel forge` puts them on the command line (`repo`, `whoami`, `pr
view|checks|reviews|list|create|close|ready`, `run list|view|logs|rerun`,
`--json` for the normalised value). The guard leaves its reads - CI runs and
job logs included - to every role; it refuses `pr create` to orchestrators
and core, as it refuses `gh pr create`, and a reviewer never opens a PR; `pr
close`, `pr ready` and `run rerun` belong to the product's own agent (solo or
orchestrator) alone, refused to core, root, members and reviewers.
`cel forge` itself decides who is asking (`_forge_cli_authorise`), and only
positively: `CEL_ROLE` solo or orchestrator AND a product - `CEL_PRODUCT`
and/or its `<product>-orch` mailbox, agreeing when both are set - that owns
the repo, and that identity must be its launch's (`cel_launch_identity`,
lib/identity.sh - the check `cel team` makes), so an agent that exports
another product's `CEL_PRODUCT` is refused; anything missing or
contradictory is refused. There is NO owner
path: the absence of an agent's marks proves nothing (an agent can shed them
with `env -u`, `setsid` or a fresh environment), so a process with no agent
identity is refused every write and told to use the forge's web UI (Forgejo
or GitHub) or `gh` directly - which is what the owner does. Its reads stay
open to everyone. A PR is changed only if the workspace's account authored
it or it is a migrated Forgejo PR (author `Ghost`). Every agent acts as that
one account, so authorship cannot tell one agent's PR from another's on the
same product - that is the limit. Closing never deletes the branch; a rerun
keeps the head, so an approval of it stands.
There is no merge verb: merging goes through `cel solo land`. The same writes
by hand - curl at a forge API with a body or a non-GET method in any
spelling, `tea api` beyond a plain GET, tea's write verbs - are refused to
orchestrators, root, core and solo agents alike; no role may read, copy
or write `~/.config/cel/forge` (by
shell, or by the native read and edit tools where the guard hook runs); no
role may source `lib/forge.sh` or call its `_forge_*`/`forge_*` functions
(also in `bash -c`, `$(...)`, `eval`, or through a variable holding the
name), which carry the token without `cel forge`'s checks; and no role may
run any `cel` command on a line that sets a `CEL_*` or `HERDR_*` variable,
even to empty (`VAR=`, `env VAR=`, `export`, `declare`), or any variable
whose name the guard cannot read - an expansion (`export $X=1`, `eval
"$X=1"`, `printf -v "$X"`) or a nameref (`declare -n`) - dressing up as
another product, lead, member or mailbox (`CEL_GUARD_ALLOW_ONCE`, the human's
approval, does not count; `cel inbox send --from` is a flag), or that hands
`cel`'s own bash shell code (`BASH_ENV=`, `ENV=`, `SHELLOPTS=`, `BASHOPTS=`,
a `BASH_FUNC_` spelling, `export -f`, `declare -fx`). Shedding one
(`unset`, `env -u`, `env -i`, `setsid`) is left to `cel forge` and `cel
team`, which change nothing for a process with no agent identity. Like the rest of
the guard these are tripwires matched as text, not a sandbox: a script file
that sources the library, or a name assembled at run time, still runs -
which is why `cel forge` checks who is asking itself.

A forge review verdict is a person's. No role - reviewers and panes outside
any workspace included - posts an approval or a request for changes: `gh pr
review` with `--approve`/`-a`/`--request-changes`/`-r` (flags after the PR,
`--approve=...`, short groups), a `gh api` write to
`repos/<o>/<r>/pulls/<n>/reviews` or below it (events, dismissals) or a
graphql add/submit/dismiss of a `PullRequestReview`, curl writing there on a
forge API, and tea's `approve|lgtm|reject|review` or `tea api` writing there.
An agent's verdict is recorded with `cel solo review`; comments
(`gh pr review --comment`, `gh pr comment`) stay where they were allowed.
The human's one-off `CEL_GUARD_ALLOW_ONCE=1 <command>` (spelled exactly)
is decided in one place, `guard_override_honoured` in lib/guard.sh, which
every adapter - claude, omp/pi and OpenCode - asks: it never covers a forge
verdict and never a team member.

The binaries that see a token or decide a write are not the caller's to
choose. Every forge operation (`cel forge`, and the library under `cel solo
land`, the reviewer's PR facts and the steward) and every `cel team` verb runs
on `cel_tool_path` (lib/common.sh): the system directories, then this user's
`~/.local/bin` (its home read from `/etc/passwd`, not `$HOME`), never the
caller's `PATH`. The Forgejo token goes only to the system's `curl`, and `jq`
must be the system's; both refuse to run otherwise. Every `gh` call - `ws_gh`
with a workspace's token, and the plain ones in lib/afk.sh, lib/release.sh
and lib/gc.sh - runs `cel_gh_bin` (system, then `~/.local/bin`) through
`cel_gh_run`, which runs it on the tool path with `GH_PAGER=cat`: gh starts
git and a pager through `PATH`, and they inherit `GH_TOKEN`, so a git
planted first on the caller's `PATH` is never handed the token.
`tools/reviewers/retire.mjs` runs the gh, and the tool path, the bash side
resolved and passes as arguments; it reads neither from its environment.
Other caller variables (`GH_CONFIG_DIR`, `GH_EDITOR`, `BROWSER`, ...) still
reach gh - the environment is not scrubbed. The system directories are where
root installs the distribution's packages and are normally root-owned, but
`/usr/local/bin` is user-writable on some boxes (Homebrew, a chown), and a
`gh` or `yq` installed only under the home directory cannot be told from one
planted over it; so this is the least-bad rule - a prepended `PATH` or a
moved `HOME` no longer chooses the binary, a write over the installed file
still would. A `gh` that lives only in a mise, Homebrew or cargo directory is
now refused (gc reads that as unknown: kept). Under the suite tests stub
tools on `PATH` or as functions; `CEL_TOOL_PATH_REAL=1` runs the production
rule.

- **GitHub** is served through `gh` as the workspace's account (`ws_gh`);
  `CEL_FORGE_GH` is its test seam, honoured (as `CEL_WS_GH_BIN`, `GH` and
  `CEL_AFK_GH` are) only under the suite.
- **Forgejo** is served over its REST API with curl, as the account whose
  token is in `${XDG_CONFIG_HOME:-~/.config}/cel/forge/<host>.token` (mode
  600, owned by the user; the host as the descriptor names it, e.g.
  `forgejo.internal.token`). A missing token, or one open to the group or
  others, is refused by name before any request. The token is read only for
  a request to that exact host and reaches curl as a config line on its
  stdin - never in argv, a file or a log - and curl follows no redirect.
  `CEL_FORGE_CURL` is its test seam, honoured only under `CEL_TESTING` inside
  the suite; on
  a plain-http repo every operation says on stderr that the token is sent
  unencrypted. List endpoints are read page by page
  until a page comes back empty (a short page proves nothing: the server
  caps `limit`). Where Forgejo cannot say what GitHub says, the answer is the
  conservative one: a draft is the `WIP:` title prefix (added by
  `forge_pr_create` only where `policy.pr_open` is not `ready`; a WIP title
  under a ready policy is refused, and `forge_pr_ready` removes it);
  `mergeable: false` reads as `unknown`, never `conflicting` - Forgejo also
  answers false for a PR it has not (re)computed, as recorded on a clean
  fast-forward, and its API has no field that proves a conflict; a
  status's site-relative `target_url` is made absolute; Actions runs and jobs
  say their state in `status` with `conclusion` null; review `decision` is `approved` only for a non-stale,
  undismissed approval whose `commit_id` is the current head, and no
  reviewer's latest verdict requesting changes. Checks are the head's
  combined status (latest status per context). The base's required checks
  come from its branch protection: the exact rule, else every glob rule
  matching the branch; `unprotected` only on Forgejo's own 404 for the exact
  rule AND no matching glob, `unknown` on any other error, a glob this cannot
  evaluate, a context that is a pattern, or status checks on with no context
  named. A merge re-reads the head first and refuses a moved one before
  sending anything, then posts `Do: squash`, `head_commit_id` and
  `delete_branch_after_merge`.

`cel solo land` and `cel solo review` (`lib/solo.sh`), the steward's list of
solo PRs ready to land (`solo_ready_prs`) and the reviewer's PR facts (`cel
run reviewer`, `lib/run.sh`) speak to the PR's forge through these
operations, so a Forgejo repo opens, reviews and lands like a GitHub one: the
review verdict is Celestial's own (`.cel/solo-reviews.json`), bound to the
exact head; the reviewer's checkout and the local gate fetch
`refs/pull/<n>/head`, which both forges serve, and the local gate refuses
unless that ref is the head it ran on. Whether CI may stand in for the gate
is `land_ci_gate` (`lib/land.sh`): it takes `{number, head_sha, base_ref}`
and one `forge_pr_checks` read, so the base's required checks (GitHub
classic protection and rulesets, or Forgejo's branch protection rules) and
their latest runs on the head come from the same provider-dispatched answer.
gc and release still call `gh` directly and move onto these operations
separately.

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
`cel fleet --json` and the dashboard all render that
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
