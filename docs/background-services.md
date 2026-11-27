# What runs in the background

Four kinds of thing run without you: **one timer**, **long-lived servers**,
**hooks**, and **the agents themselves**. Nothing else is hidden.

## The steward — the only scheduled process

`cel steward` is a single pass over the whole box. Its checks do not call a
model, but they can remove verified disposable worktrees, retire eligible
idle agents, maintain servers and prompt agents. Those agents may then spend
tokens under their existing account permissions.

```bash
cel steward --install                  # systemd user timer, every 5 minutes
cel steward --install --interval 10    # a different cadence
cel steward --install --remove         # stop it
cel steward                            # one tick by hand
systemctl --user list-timers | grep cel-steward
journalctl --user -u cel-steward       # what it did, and when
```

A **systemd user timer** rather than a shell loop in a pane, because the
steward's whole job is to be running when nobody is watching, and a pane loop
dies silently with the herdr session. The timer is monotonic: two minutes
after boot, one minute after the timer itself starts (`OnActiveSec`, so a
user-manager restart or a `systemctl --user start` schedules a tick rather
than leaving `NEXT` at `-`), then every interval. `cel doctor` rewrites an
older installed timer that lacks this, and fails when the last tick is more
than three intervals old or the timer has no next trigger. Ticks never
overlap: a tick that finds another still running says so and exits. Enable
`loginctl enable-linger` or it stops when you log out. `cel steward --no-gc`
runs a tick without the gc and box sweeps.

Each tick, in order:

| Step | What it does |
|---|---|
| **Rex restarts** | a Rex server restart this plane did not drive is noticed first, before any sweep reads the missing agents as gone; [resumable agents are resumed](sessions-herdr-and-rex.md#rex-server-restarts-and-rex-upgrades) and root gets one summary |
| **Rex upgrade** | at most every 30 minutes, the managed `rex` upgrade (`cel sessions rex-upgrade`), only while every Rex agent is idle |
| **garbage collect** | `cel gc --reap 12` (`CEL_STEWARD_REAP_HOURS`; 2 hours when under 2 GiB of memory is available): retains dirty, unlanded, live or unverifiable work; retires only ownership-verified agents observed idle, never merely old processes |
| **box sweep** | every 6 hours (`CEL_STEWARD_BOX_WINDOW`), docker and toolchain caches (`cel gc --box`) |
| **sample** | one line of load, memory, swap and every pane's status to `~/.local/share/cel/samples.jsonl` (newest 2000 kept) for the dashboard |
| **review sweep** | for each repo, our own open PRs (`--author @me`, plus `repos[].pr_authors`), drafts and `hold`/`superseded` labels left alone: approved at the current head, changes requested at the current head, and failing checks each nudge the PR's owner - the product agent, or the lane the repo declares (`repos[].lane`; the product agent, with a note once per head, while that lane is not running). In a Linear workspace, a PR older than a day whose branch carries no ticket id is surfaced too |
| **solo sweep** | a solo product's PR approved at its head with every check green is "land it: `cel solo land`", and a recorded `changes` verdict at the current head is "address it" - each once per head |
| **feature teams** | a member still `reserved` 10 minutes after `cel team add`, or specialist verdicts older than the repo's candidate head, are told to the team's lead once; nothing is retired |
| **root unread** | unread escalations, decisions and blockers to root older than an hour with nobody reading root's mailbox raise one `blocked` item per workspace |
| **AFK** | an AFK window whose `--until` has passed but is still on is said once |
| **blocked agents** | any agent waiting on input is named every tick, deliberately without dedup; that is your queue |
| **stale mailboxes** | an escalation, decision or blocker from someone else unread for 30 minutes gets an inbox reminder to its recipient, at most every 4 hours; the steward never types into a pane. Once a day root hears how many owner decisions are open, and each asker is asked to confirm or withdraw its questions idle for 3 days (`cel decide confirm` keeps one quiet for 7 days) |
| **page feedback** | feedback whose publishing pane is gone stays a warning until someone drains it |
| **updates** | once a day: on the `main` channel, one status item naming how many commits main is ahead of your build; on `release`, the newer tag is logged and written for the console |
| **ready tickets** | Linear workspaces only: tickets in `tickets.trigger_state` (default `Ready`), unassigned or yours, with no branch anywhere, are handed to the product's agent, else root |
| **API balances** | a provider below its floor that a profile routes to raises a blocker (profiles routed there are vetoed); one that recovers takes it down |
| **subscriptions** | the 80% / 100% items per signed-in account, the orchestrators' own Claude pool, and the on-pace forecast ([Subscriptions](profiles.md#subscriptions)) |
| **memory** | under 10% available, one blocker per workspace naming the largest trees and servers (cleared at 15%); under pressure each product agent is told once per condition. Nothing is killed |
| **orphans** | the `cel gc --orphans` sweep; one line to root when the set changes |
| **services** | probes every service with a `health:`; two consecutive misses raise a blocker (`restart: auto` restarts it once first); a box service's (`services.d`) goes to root in the first registered workspace |
| **suite lock** | names the live holder of the box-wide test lock once it has been held 30 minutes ([below](#the-suite-lock)) |
| **servers** | `cel dash --ensure` and both `cel pages --ensure` tiers; expired public shares are deleted, not merely refused |
| **orphan test servers** | a pages/dash server left running in a worktree with no live agent is reported, and stopped once it is an hour old |
| **ensure product agents** | every product resolving `orchestrator: auto`, homed on this login, with no live agent gets one (`cel run orchestrator`), at most every 30 minutes; a failed start is not alerted while an open owner decision names that agent |
| **inbox hooks** | an orchestrator or lane that came back without its inbox hook, or whose inbox watcher died, is restarted with its full launch line, only while it is idle and its composer is provably empty; otherwise root is told once |
| **older launch lines** | after an update, agents still on an older launch line are named to root once per change (silenced while an owner decision names them) |
| **ledgered servers** | `cel serve` servers past their TTL, idle, or whose checkout is gone are stopped and their owner mailed the restart command |
| **previews** | previews of PRs that closed or merged are stopped and their checkouts removed |
| **unledgered servers** | changes to the set of servers nobody registered go to root and to the owning agent |
| **build daemons** | idle Gradle/Kotlin daemons are reported to their owner once |
| **fleet cache** | refilled in the background when stale, so the first console read is recent |

Nudges are **rate-limited per subject** (4 hours, `CEL_STEWARD_WINDOW`; the
update check, 24) through `~/.local/share/cel/steward-state`, so a stuck agent
is reminded rather than spammed; the solo "land it" and "changes" nudges and
lane notes go once per PR head.

**An open owner decision holds every nudge about its PRs.**
`cel decide ask … --pr <repo>#<n>` (repeatable) links a PR to the question.
`<repo>` is a declared repo name (resolved through that workspace's `url`),
`owner/name`, or a remote URL (scp, ssh or https, GitHub or Forgejo); it is
matched case-insensitively on `owner/name`, with the forge host ignored, and a
bare name the workspace declares no URL for matches only inside that
workspace. While the question is open, no per-PR nudge about that PR goes
out - approved, changes requested, failing checks, no ticket, solo "land it"
and recorded `changes` - and nothing is recorded either, so the first tick
after the question is answered or withdrawn nudges as usual. The steward
reads every workspace's open decisions once per tick, so a decision filed in
one workspace holds the PR wherever another workspace's sweep finds it. Only
the explicit `--pr` link counts; free text naming "#7" does not, and
re-asking without `--pr` unlinks the PRs.

### The suite lock

`tests/run.sh` takes one box-wide `flock` so only one suite runs at a time:
`CEL_SUITE_LOCK`, else `$XDG_RUNTIME_DIR/cel-suite.lock`, else
`${TMPDIR:-/tmp}/cel-suite-<uid>.lock` (`none` turns it off). A queued gate
looks exactly like a hung one, so the steward watches the lock. Who holds it
is the kernel's answer, not the lock file's, which names only whoever last
wrote it (and a plain `flock <lockfile> <cmd>` writes nothing): the holder is
the process `/proc/locks` lists with a `FLOCK` on the lock's inode, confirmed
by one of its descriptors that resolves to the lock path and shows that lock
in its `fdinfo`; waiters and POSIX/OFD locks count for nothing. The runner
writes a holder record beside the lock (pid, start time, mailbox, workspace,
checkout, files, when it took the lock), used only when its pid and start
time match the live holder. Once the lock has been held for
`CEL_SUITE_HOLD_WARN_SECS` (default 1800), the steward says who holds it, for
how long, where and what it is running - to root in the box's first
workspace and to the holder's own mailbox (the record's agent, or for a
process cel did not start, the agent whose directory it runs in) - once per
4-hour window, and kills nothing. When the lock is free again, every mailbox
that was told has the item taken down. A runner waiting in the queue names
the same live holder in its own waiting line, and repeats it with the
holder's directory after `CEL_SUITE_WAIT_WARN` seconds (default 120).

## Servers — started on demand, kept alive by the steward

With a systemd user manager the dashboard and both pages tiers are installed
user units (`cel-dash`, `cel-pages`, `cel-pages-public`), each in its own
cgroup and restarted on failure; without one they run under `setsid`. All log
to `~/.local/share/cel/logs/`, and the steward ensures every one of them each
tick.

| Service | Where | Kept alive by |
|---|---|---|
| `cel dash` | one for the box: `dash: port:` in `~/.local/share/cel/config.yaml`, else `:7770`; a workspace's own `dash.port` is ignored (doctor names it) | the steward, every tick |
| `cel pages` | tailnet tier, `:7780` | the steward, every tick (`cel pages --ensure`) |
| `cel pages --public` | internet-reachable tier, `:7781` | the steward, every tick (`cel pages --public --ensure`) |
| `cel pages tunnel` | cloudflared/ngrok, for sharing without Tailscale | started by hand |

`--ensure` is idempotent: it starts the service only if it is not already
answering, so it is safe on a loop.

Agents' own servers go in the `cel serve` ledger. `cel serve start <name>
--owner <alias> --workspace <ws> [--ttl 8h] [--port N] -- <command>` runs one
as a memory-accounted `cel-serve-<name>` user unit; `cel serve adopt` lists
the unledgered preview/dev servers (the steward tells root only when that set
changes - what is new, what is gone, and the whole list - and tells the agent
whose directory a new server runs in about it; a server counts as new only
once it has been up `CEL_UNLEDGERED_MIN_AGE_MIN` minutes, default 15, and is
reported gone only if it was reported new, so short-lived dev and test servers
send nothing) and `cel serve adopt <unit|pid> --owner <alias>
--workspace <ws> [--ttl 8h]` takes one into the ledger. A ledgered server is
stopped by the steward when its TTL runs out, after `serve.idle_hours`
(default 6; `serve.pressure_idle_hours`, default 1, under memory pressure)
without a request, or when its checkout is gone, and its owner is mailed the
restart command.

Whose directory a server runs in is decided in this order: a product's or
lane's own directory is that agent's; a git checkout is the owner of the repo
it is a checkout of (`repos[].lane`, else the product's agent) wherever it
lives - a repo symlinked into `repos/` from `~/code/<repo>`, its worktrees in
`~/code/<repo>-wt/<name>`; a repo can claim more with `owns_paths` in the
committed `workspace.yaml` (globs; `~/` is the home dir, a relative glob is
under the workspace, a dir under a match is matched, the longest glob wins;
`cel doctor` warns about a glob that claims the whole home dir or workspace,
such as `~`, `~/*`, `/**` or a relative `*`):

```yaml
repos:
  - name: example
    owns_paths: ["~/scratch/example-*"]
```

then any other dir under a repo's real root (`repos/<repo>` with symlinks
resolved), or beside it named `<real root>` plus a known suffix, alone or
followed by a dash - `-wt`, `-worktrees`, `-local[-*]`, `-data[-*]`,
`-release[-*]`, the dirs its tooling leaves there, such as
`~/code/<repo>-local-cf-data` - is that repo's, the longest root winning (any
other `<real root>-...`, say `~/code/<repo>-other-project` or
`~/code/<repo>-database`, is another project unless `owns_paths` claims it);
then `repos/<repo>` and
`.cel/solo/<product>` inside a workspace, and anything else in a workspace is
its root's. A server in no workspace is told to root of the box's first
workspace in registry order, and root's summary names that workspace; for a
server routed to another agent the summary says who was told.

Build-tool daemons (Gradle daemons and their workers, the Kotlin compile
daemon, Metals) are never listed as servers. Instead the steward tells the
owner of an **idle** Gradle or Kotlin compile daemon about it, once per
pid and start time: idle means no live child process (another build daemon,
such as a Gradle daemon's Kotlin daemon, does not count), CPU time grown less than
`CEL_BUILD_DAEMON_IDLE_CPU_SECONDS` (default 2) since the previous tick, and
alive more than `CEL_BUILD_DAEMON_IDLE_MIN` minutes (default 30). The owner is
the `CEL_INBOX_ME` of the nearest ancestor process carrying it (else the
daemon's own, inherited from what started the build), else the agent whose
directory it runs in, else root. The note gives pid, RSS, idle minutes and cwd,
and how to stop it (`./gradlew --stop` in the project found from a `gradlew`
ancestor, or `kill <pid>` after checking it is still that daemon); the steward
itself never stops or signals one. A daemon that goes busy and idle again is
not reported again; a reused pid with a new start is a new daemon. When the
owner's mailbox refuses the note, root gets it once instead.

A **permanent** server is an agent's standing box service - a product's live
local app in a persistent user unit that its own follow-main unit recreates,
or a preview its owner said to keep:

```bash
cel serve adopt shop-live --owner shop-orch --workspace plane --permanent \
  --port 8090 --why "shop's live app, recreated by shop-follow-main"
```

It has no TTL and no idle or pressure limit. No sweep stops it - not the
steward's TTL/idle sweep, not the preview sweep or gc's QA-preview release, not
the orphan reaper - and the unledgered report no longer lists it. Because a
registration shields a server from all of that, only a person or the owner
itself registers one: an agent adopts `--permanent` only with `--owner` set to
its own alias (the one its launch fixed), and a server already registered is
never re-registered to another owner. It may run anywhere, inside a workspace
or not; the record keeps the unit's working directory and command. `cel serve
list` (TTL column `permanent`, then a line with that directory and command),
the dashboard's server rows and `cel fleet` (`box.servers`, and a `server`
line under its workspace) show it with owner, port and memory. Only `cel serve
stop <name>` by its owner or a person ends it. A unit is matched by name, so
systemd recreating it is the same server; adopting a pid that runs inside a
user service registers that unit. A unit that stays gone for 15 minutes, or a
pid that exits, is dropped from the registry with one note to its owner and is
never restarted.

## Hooks — session-bound actions

`cel setup` installs Claude's global `UserPromptSubmit` drain and its
`PreToolUse` guard (one entry naming the installed plane's
`orchestrator-guard.sh`; your other `PreToolUse` hooks stay, and an older
celestial guard entry is replaced); `cel run` adds the async
`SessionStart`/`UserPromptSubmit` session hook and the active-turn `Stop`
hook to every Claude launch. `inbox-guard.sh` and `learn-stow.sh` are **not**
installed by cel: register them in `~/.claude/settings.json` yourself (each
file's header gives the entry). Codex has no hook API, so no guard. Pi and
omp load their inbox and guard extensions from `agents.yaml`
on every guarded launch, OpenCode its plugin, and agy's come from the
`celestial` entry cel merges into `~/.gemini/config/hooks.json`. Hook
programs fail open on their own errors, except where a row says otherwise:

| Hook | Event | What it does |
|---|---|---|
| `inbox-drain.sh` | Claude `UserPromptSubmit` | drains the pane's mailbox when a turn is submitted; it does not wake an idle session |
| `inbox-stop.sh` | Claude `Stop` | blocks once for mail arriving during the active turn; it does not wake an idle session |
| `claude-session.sh` / `claude-idle-mail.py` | Claude async session/submit hooks, then native peer socket | reports the exact native session; in a Rex launch, retains one lifetime-bound watcher as Claude's own child that wakes it idle; never writes terminal input |
| `inbox.omp.ts` | Pi/omp extension, every launch | runs `cel inbox watch --parent` for `ui.notify`, drains unread mail into the next turn (starting one when idle), registers the `/cel-*` commands and runs reviewer retirement; never types into the composer |
| `orchestrator-guard.omp.ts` | Pi/omp extension: core, root, product-agent, member and reviewer launches | the same guard as `orchestrator-guard.sh` |
| `guard-classify.sh` | called by every guard adapter | the one classifier: `command`, `path` (write) or `read` → `allow` or `deny <reason>`; exits 2 when it cannot decide |
| `agy-guard.sh` | agy `PreToolUse` | the guard for Antigravity, for every agy session by where it stands; refuses what it cannot judge for an agent cel launched |
| `agy-hook.sh` | agy `SessionStart`, `PreInvocation`, `Stop` | reports the conversation id to Rex, attaches waiting mail to a turn, and keeps a `cel inbox wait` running as agy's wake |
| `inbox-guard.sh` | Claude `Stop` | when configured, blocks once for unresolved decisions/blockers and gives resolution steps; it does not wake an idle session |
| `orchestrator-guard.sh` | Claude `PreToolUse` (registered by `cel setup`) | **read-only coordinators**: from a root, core or orchestrator pane, refuses commits, pushes, merges, branch switches and edits under `repos/` (by shell or by the native edit tools); a solo pane may write and push but not start other agents or `gh pr merge`. In every pane a guard adapter runs in - Claude panes where the hook is registered; omp/pi core, root, product-agent, member and reviewer launches; OpenCode (shell, write, edit, patch - not reads); agy - the forge API token (`~/.config/cel/forge`) is refused to shell commands and the native read/edit tools that adapter checks, and so is sourcing `lib/forge.sh` or calling its `_forge_*`/`forge_*` functions (also via `eval` or a variable; they reach the forge without `cel forge`'s checks) and running any `cel` command on a line that sets, exports or declares a `CEL_*` or `HERDR_*` variable (even to empty; `CEL_GUARD_ALLOW_ONCE` aside). No pane posts a forge review verdict: `gh pr review --approve|-a|--request-changes|-r`, a `gh api`/curl/`tea api` write to a PR's `/reviews` (events and dismissals too, percent-encoded too), a graphql review mutation or a graphql query the guard cannot read (`--input`, `query=@file`), and `tea pr approve|reject|review` (or a prefix, `tea pr r`) are refused, through any wrapper (`env -u X`, `xargs -n1`, `sudo`); so is `gh alias set|import|delete`. An agent's verdict is `cel solo review`, reported by inbox (`review.post: github` is retired; `cel doctor` says so); comments (`gh pr review --comment`, `gh pr comment`) are not refused. `cel forge pr close|ready` and `run rerun` are the product agent's alone, refused to core, root, members and reviewers. These are text tripwires, not a sandbox (a script file still runs), and **no adapter inspects MCP tool calls**; codex has no guard. `cel forge` and `cel team` themselves also check who is asking and change nothing for a process with no agent identity, and `cel team` refuses an identity its launch's `/proc` environ does not carry. `CEL_GUARD=0` opts a pane out; `CEL_GUARD_ALLOW_ONCE=1` approves one call, except a forge verdict, a gh alias write and in a member's pane (every adapter, OpenCode included). An adapter whose classifier cannot run fails open, except for a member, a verdict-shaped command or a classifier that did not finish within `CEL_GUARD_TIMEOUT` seconds (default 10); agy's adapter fails closed for any agent cel launched, and OpenCode's refuses every classifier failure but the classifier's own error exit |
| `learn-stow.sh` | `SessionEnd` | decays and budgets the workspace's `learnings.md` |

Inbox hooks use explicit `CEL_INBOX_ME`/`CEL_INBOX_WS` when the launcher
provides them; otherwise the inbox command derives identity from the working
directory.

### Claude's idle watcher (Rex launches)

`cel inbox watch` streams notices without moving a cursor; it is not itself
an idle-wake API. Claude's idle watcher instead uses the socket published to
its hooks as `CLAUDE_CODE_MESSAGING_SOCKET`. It requires an exact launch
recipient/workspace, a live matching Rex receipt, runtime PID ancestry and
the native conversation UUID; before every send, Linux `SO_PEERCRED` must
match the receipt's PID/UID/start time. Missing support or ambiguous identity
has **no terminal-input fallback**: Rex `send`/`send-key` and screen capture
cannot establish that an owner's composer is empty.

Launches register the watcher as an **asynchronous native command hook** and
keep it in that hook's foreground, which preserves the process ancestry that
lets Claude accept an own-child message, including in `bypassPermissions`
mode, without changing inbound policy. It polls every five seconds; each
unread generation has one stable notification ID. A socket write is
`notified_not_delivered`, never delivery: retries reconcile the hook-provided
transcript first (complete, session-matched top-level rows only, read 1 MiB
at a time), and a matching native receipt suppresses further sends. With an
authoritative absent receipt and an idle target it retries after 30 seconds
and then every 120 seconds; attempts and the next retry live beside the Rex
receipt (`<receipt>.inbox/state.json`). Uncertain evidence produces
`blocked_receipt_unknown` (or `blocked_read_error`) rather than a guess, and
the watcher never consumes mail to clear a block. If the runtime does not
publish the socket, the state is `unavailable`. MCP channels are not
substituted, and attaching to a Claude session cel did not launch is not
supported. An idle launch from before these hooks gains them only through a
canonical resume (`cel run <role> --restart`), which keeps the saved
conversation, model and thinking. See Claude's
[inbound rules](https://code.claude.com/docs/en/cross-session-messaging#control-inbound-messages)
and [async hooks](https://code.claude.com/docs/en/hooks#run-hooks-in-the-background).

The opt-in integration `python3 tests/claude-idle-native.py` (installed
Claude Code, Linux pidfds, `python3-pexpect`) runs a real isolated Claude
against a deterministic loopback provider with a fake key (no paid
inference) and proves own-child idle wake, permission-failure recovery,
exactly-once Stop-hook delivery, refusal of a foreign session and receipt
suppression, with the owner's unsubmitted draft preserved. The normal gate
runs the credential-free regressions without launching Claude.

### Launch drift

Launch diagnostics compare the canonical **effective product plan**: SOLO
role/profile overrides (including `workspace.local.yaml`), the actual runtime,
and the existing terminal backend. Native resume IDs and one-shot kickoff
prompts are not permanent launch requirements. Routing content, argv and PID
start identity invalidate cached verdicts; preserving a running explicit model
choice requires a product-local profile binding, not a global drift exemption.

Pi can rewrite its process title to bare `pi`, including NUL-padding the old
argv storage. That means launch flags are **unknown**, not absent. A matching
owned Rex receipt and exact direct-child inbox watcher can establish observed
inbox evidence; neither proves guard enforcement or a complete current launch.
Without that evidence, doctor warns and the steward requests inspection without
automatically restarting the runtime. Observable genuinely missing hooks remain
actionable. Native OpenCode is not tested for Pi/OMP-only extension flags.
Doctor reports unknown launches by name and never turns an empty inventory or
the absence of known drift into an all-current confirmation.

## Services

`cel services` is one list of everything this box is running on a port: the
services a workspace declares under `services:` and the box's own services.

```yaml
services:
  - name: builder                    # name + url only stays valid, and is
    url: http://localhost:4322       # observe-only: there is nothing to start
    cmd: pnpm --filter builder dev   # with a cmd it can be started and stopped
    cwd: repos/widget
    health: /                        # a path that must answer 200 within 2 s
    # health_auth: "bearer $TOKEN"   # optional: literal, $VAR or $(cmd), sent on stdin
    env: { MODE: dev }
    restart: auto                    # the steward tries once before it escalates
```

Each row carries `state` (`up` when the port is listening, `healthy` when the
health path answers, else `down`), the port, the pid and the resident memory of
the process tree in its cwd, how long it has been up, and **reach** — the URL
that works from somewhere that is not this box. `cel services start|stop|
restart|logs <name>` runs it in a herdr pane under the workspace's own pane and
remembers the pane in `<ws>/.cel/services.json`; `cel services open <name>`
prints its reach URL (and opens it where `xdg-open` exists). A service without
a `cmd` is observe-only and says so.

Reach exists because every dev server and every preview binds `127.0.0.1`,
which from a laptop is the laptop. The dashboard already listens on the tailnet
IP, so it **proxies** them: `http://<tailnet-ip>:<dash-port>/svc/<port>/…` is
forwarded to loopback, WebSocket upgrades included, for ports that belong to a
known service only, and only with the dashboard's own control token —
a tailnet neighbour cannot browse this box's loopback.

**One dashboard for the box.** There used to be one server per workspace,
each polling the same herdr and gh and each drawing the same box-level rows,
so one gateway read as several. Now `cel dash` runs one server covering every
registered workspace; a workspace's services panel lists only its own
services, and anything tagged `box` (and the subscriptions) appears once in
the **Box** panel. The old per-workspace ports answer with a redirect to it
for one release; `cel doctor` names the dashboard and any leftover
per-workspace server (`cel dash --restart` stops them).

The steward probes every service that declares `health:` once per tick. Two
consecutive down ticks raise one rolled-up blocker to the workspace's root
naming the service and the last line of its pane; back up clears it. With
`restart: auto` the steward restarts it once, at the second consecutive miss,
in the same tick, and says so in the blocker.

Some services belong to the **box** rather than to any workspace — the auth
gateway is used by every workspace and owned by none. They are
declared one JSON file per service in `~/.config/cel/services.d/` (`CEL_SERVICES_D`),
in exactly the shape of a `services:` row plus a bare `port:` shorthand, `0600`
in a `0700` directory because `env` may carry a bearer. They appear in
`cel services` under a `box` block — after the workspace's own rows, or alone
when you run it from outside every workspace — carry `workspace: "box"` in
`--json`, start and stop by name, are probed by the same steward sweep (their
blocker is filed under `box`, not under a workspace's root), and
keep their state in `~/.local/share/cel/services/<name>.json` rather than in
any workspace. `env` values whose key looks like a credential are rendered
`***` everywhere. `cel gateway install` writes the gateway's, and `cel doctor` says
how many the box declares and how many are healthy.

## Previews (`cel preview`)

`cel preview <repo>#<pr>` runs any open pull request, from any
agent or shell: it checks out the PR head under
`.cel/previews/`, runs the block's optional `setup:` (install) and `seed:`
(fill `{data}`, the preview's own data directory) and then `cmd:`, and prints
the url - the tailnet address and, when the app listens there, a
`localhost:<port>` forward for clients that come in over ssh (Moshi).

```yaml
preview:
  setup: "bun install --frozen-lockfile"
  seed:  "cp -a ~/widget-data {data}"
  cmd:   "bun run dev -- --mock --host {host} --port {port} --data {data}"
  env:   { MODE: mock }
  url:   "http://{host}:{port}"
```

Every step runs under `env -i` - it sees only `PATH`, `HOME`, `LANG`, `PORT`,
`CEL_PREVIEW=1` and the block's `env`, so provider keys, gateway tokens,
`GH_TOKEN` and the workspace's own env never reach it - and a PR that tracks a
`.env`, `.env.*` or `.dev.vars` file (other than `*.example`, `*.sample` or
`*.template`) is refused. That is environment containment only - not network
isolation. A plain preview's `HOME` is the real one, so files such as
`~/.npmrc` or a CLI's saved login stay readable (a QA agent's preview gets a
private, empty `HOME` of its own); a cmd that would otherwise call a paid API
says `--mock`. `{port+N}` is substituted too; `--port N` fixes the port,
`--no-wait` returns without waiting for the url. Each
preview is a `cel serve` server (8h TTL, `--ttl` to change): `cel preview
--list` shows them, `--stop` ends one, the same head is reused rather than
started twice, a new head replaces the old preview, and the steward stops a
preview - and removes its checkout - once its PR closes or merges.
`--head <sha>` refuses to run any head but that one, and `--qa <focus>` makes
a QA agent's own preview (`preview-<repo>-pr<n>-qa-<focus>`) beside anyone's
plain one, stopped and removed when that agent is retired
([QA agents](review-loop.md#qa-agents-the-change-run-not-read)).
