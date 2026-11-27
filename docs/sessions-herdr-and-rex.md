# Sessions: Herdr and Rex

An agent is a terminal session, not a service: it stops when its terminal
does. The terminal host is independent of the agent runtime and model. Herdr
stays the default; select Rex for a new session with:

```sh
cel run solo --product celestial --lane ui --session-backend rex
cel run reviewer --repo celestial --pr 123 --session-backend rex
cel core --session-backend rex
cel sessions --json
```

Or set `session_backend: rex` in a workspace's `workspace.yaml` for its new
`cel run` sessions. The order is `--session-backend`, then
`CEL_SESSION_BACKEND`, then the workspace's `session_backend`, then Herdr.
Existing live agents are never moved: a restart retains their current
terminal host. After a process
has exited, normal new-launch defaults apply; keep `--session-backend rex` in
recovery commands unless the workspace default is Rex. Rex must already be
installed; Celestial does not adopt unrelated Rex sessions. A product agent,
lane, root or core gets its own named Rex session. A reviewer - and a team
member whose lead runs in Rex - opens as a window labelled with its alias in
its product agent's session instead, so a product's whole team is one session
group; when that session cannot be proven live it gets a session of its own,
and says so. The command prints its session (and window) and terminal IDs.
Use `rex ls`, `rex window ls -s <session>`, `rex capture -s <session> -b
<block>` and Rex's native controls, not Herdr commands, for those terminals.
Retiring a reviewer or member closes only its own window, never the session.

Role prompts, model and profile, environment, inbox identity and review gates
are the same on both hosts. Pi/OMP (inbox extension), Claude
(session/submit/Stop hooks), OpenCode (its plugin) and agy (its hooks) report
their real turn state and native conversation; a report counts only when it
comes from the receipt's live runtime process tree, and a runtime without
native observation stays conservatively busy. These hooks never type into
the terminal or a pending owner draft. A restart refuses to discard an
unreported native conversation unless `--fresh` is given. Rex sessions appear
alongside Herdr agents in Celestial's inventory (`cel sessions`, `cel fleet`,
the dashboard), and Herdr's pane cleanup never closes a Rex terminal.

## Rex server restarts and rex upgrades

A Rex server restart ends every program in its sessions. Each core, root,
orchestrator and solo-lane receipt records the `cel run` line that brings it
back (its role, product, lane, workspace and the profile/model/thinking you
named; a lane keeps its remembered choices). Every steward tick records the
running server instance and the live managed agents; when the instance changes,
each agent that was live under the old server and was not stopped, retired or
relaunched since is resumed ONCE through that line, into its saved session, and
root gets one summary. Each resumed agent is also told that its background
shells, subagents and servers ended with the old server. Reviewers and team
members never resume. Nor does an agent launched before relaunch lines were
recorded, one whose runtime never reported a native session, or one whose
saved session no longer matches its receipt. Each is listed in the summary
with the command to run.

A resume that only ran out of time - an OpenCode launcher refusing on one of
its own timeouts (`server_not_ready`, `guard_not_loaded`, `admission_timeout`,
`models_not_admitted`, a `*_request_timeout`), as a cold box after an upgrade
can make it - is run once more after `CEL_REX_RESUME_RETRY_SECS` (60), unless
the agent is live again by then or its retirement has begun. If the retry
also fails, the summary reports it once and says it was retried. A refusal
for any other reason (guard, auth, scope, session, a veto or a duplicate) is
reported without a retry. Nor is it retried when the first attempt's dead
terminal could not be closed, when the agent was relaunched or stopped during
the wait, or when its saved session no longer matches. A pass retries at most
`CEL_REX_RESUME_RETRY_MAX` (3) agents within `CEL_REX_RESUME_RETRY_BUDGET_SECS`
(300); the rest are reported with "retry skipped: restore time cap". Retries
add about 3 minutes to that steward tick, at most about 7.

Before resuming, the restore repairs what a restart leaves behind. The new
server restores the old sessions as empty shells under the same labels: for
each agent being resumed, the sessions with its label are closed only when at
least one block was seen and every block's process report names child and
foreground as null - an omitted key, an error, an empty or unreadable session
counts as alive and is never touched. A
client-autostarted server runs with `--exit-empty`, so closing the last shell
can end it: if no server answers, a persistent one (`rex server start`, in its
own systemd scope with `OOMPolicy=continue`, with `--tailscale` when the old one served the tailnet) is
started before any resume. If the old server served the tailnet and the new
one does not, `rex server tailscale on` is run and verified. The summary names
the server's version and API revision before and after.

The steward also keeps rex current, at most every 30 minutes:

```sh
cel sessions rex-upgrade --check   # newer rex? busy, not resumable, or unmanaged sessions?
cel sessions rex-upgrade           # one round now
```

A round runs only when apt's candidate for rex is newer than the installed
version and comes from `https://pkgs.superlogical.com` exactly (that host, not
one containing the name; `apt-cache policy rex`, without `apt-get update`). It
waits up to `CEL_REX_UPGRADE_IDLE_SECS` (120) for every live Rex agent to be
idle, and skips the round otherwise. Root is told once, and nothing changes,
while the round is blocked by any live agent it could not resume (a reviewer,
an older receipt, a missing saved session) or by ANY Rex session
that is not a live managed launch - a session you opened yourself, or an old
empty shell: stopping the server ends every session, and only managed agents
come back. Close those sessions (`rex ls`, `rex kill`) to let it proceed. That
alert is said once per rex version, whoever is in the way, and the steward
reminds root once more if that version has stayed blocked for over 24 hours. Then
it records the agents, installs exactly the version it vetted
(`sudo -n apt-get install --only-upgrade -y rex=<version>`), restarts the
per-user Rex server in its own systemd scope if the package did not, resumes
each recorded agent, checks it is still alive after a short settle, and sends
root one summary. New Celestial launches wait while it runs. If apt does not
install the vetted version, nothing is stopped, and root is told once that
the upgrade failed and why.

Rex is the only thing Celestial upgrades on its own. Coding-agent runtimes
and Celestial itself move when you run `cel update` (see
[Versioning & updates](versioning.md#versioning--updates)).

## Rex agents' memory: one runaway, one kill

Every program a Rex terminal runs is a child of the Rex server. Each managed
Rex launch therefore starts its terminal's command through
`systemd-run --user --scope` (which execs it in place: same PID, same receipt)
into a scope of its own, `cel-agent-<name>-<epoch>-<pid>.scope`, under
`cel-agents.slice` (systemd nests it as `cel.slice/cel-agents.slice`). The
agent's runtime and everything it starts - builds, test binaries, browsers -
live there, not in the server's cgroup. Past the agent's `MemoryMax` the kernel
kills that agent's largest process; in a box-wide out-of-memory the kernel's
choice is the runaway, in its own scope. Either way the server's scope is not
the one that loses a process, and the server's scope runs with
`OOMPolicy=continue` besides (a scope's default, `stop`, ends the server and
every session when any process in it is killed - what happened on
2026-11-21). `systemd-cgls --user-unit cel-agents.slice` shows who is where.

The limits live in the box config, `~/.local/share/cel/config.yaml`, in MB:

```yaml
agent_memory:
  max_mb: 9583          # one agent's scope MemoryMax          (default: 40% of RAM)
  swap_max_mb: 2047     # one agent's scope MemorySwapMax      (default: 25% of swap)
  slice_max_mb: 20364   # cel-agents.slice MemoryMax, all agents (default: 85% of RAM)
  slice_high_mb: 17968  # cel-agents.slice MemoryHigh, throttle  (default: 75% of RAM)
  oom_policy: continue  # continue | kill | stop                 (default: continue)
```

The numbers shown are the defaults on a 23.4 GiB box with 8 GiB of swap; every
default is computed from `/proc/meminfo` at launch. A value that is not a whole
number of MB (or an unknown policy) is the default. `oom_policy` is the agent
scope's: `continue` kills only the process the kernel chose, so an agent sees
its test binary killed and carries on; `kill` ends the agent's whole scope,
runtime included; `stop` stops it. The per-agent limits apply to new launches
(and resumes); the slice limits are set on the live slice at every launch
(`systemctl --user set-property --runtime`), so a change reaches agents already
running at the next launch. `systemd-oomd` is not used.

Without a systemd user manager (no `systemd-run`, or `systemctl --user` not
answering within `CEL_AGENT_MANAGER_TIMEOUT` seconds, default 5) a launch
warns that the agent runs inside the Rex server's own cgroup and proceeds as
before. If the manager refuses the slice limits, the launch warns and the
agent still gets its own scope; a `slice_high_mb` above `slice_max_mb` is
ignored and both take their defaults. Herdr sessions are unchanged.

Nothing here moves what is already running: a running server keeps its
cgroup and `OOMPolicy` (including one a Rex client auto-started inside some
other unit's cgroup), and an agent launched earlier shares the server's cgroup
until it is relaunched. To move a live server without ending any session,
adopt its PID (`pgrep -f '^/usr/bin/rex server run '`) into a scope of its
own:

```sh
busctl --user call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' \
  "cel-rex-server-$(date +%s).scope" fail 2 PIDs au 1 <pid> OOMPolicy s continue 0
```

Otherwise restart it in one line, which ends every session
([above](#rex-server-restarts-and-rex-upgrades)):
`rex server stop && systemd-run --user --scope --unit cel-rex-server-$(date +%s) -p OOMPolicy=continue -- rex server start --tailscale`.

## Retire a completed Rex reviewer, keep its evidence

```sh
cel sessions retire-reviewer widget#12 --workspace demo --dry-run
cel sessions retire-reviewer widget#12 --workspace demo
```

`--focus F` or `--qa F` names an extra reviewer or QA agent of the PR instead
of its main reviewer. The targeted command handles Rex reviewers only; Herdr
reviewers are retired by `cel gc`. The PR's state is asked of the repo's own
forge (GitHub or Forgejo). Before a real attempt, a reviewer's own
group-writable evidence is made private; a dry run changes nothing.

The targeted command, reviewer GC and `cel solo land` share the same native
proof. Idle alone is never eligibility: the PR must be merged or closed (an
open PR can still take a push or a re-review request, so its reviewer stays),
the PR's final head must have a completed canonical solo review round,
the actual Pi leaf must be settled, and no tool, background job, queued input,
inbox retry debt, unread mail or draft may remain. A completed `changes`
round is not an approval and retirement never changes its verdict.

After a successful merge, `cel solo land` retires that PR's Rex reviewer the
same way. A reviewer it has to keep (still mid-turn, mail owed, proof
unavailable) is named and left for the next `cel gc` sweep; retirement never
fails a land.

New Rex/Pi reviewers expose a private native handshake. It samples the live
leaf and in-memory debt, checks them again before graceful shutdown, and only
after the runtime has exited is the exact empty Rex session removed and its
registry row reconciled. Extra terminals, replacement processes and unknown
evidence are protected; older reviewers without the handshake are kept. A
reviewer that has gone by other means (off the roster, its PID gone, no
retirement in flight) loses only its registry row to `cel gc`, so the PR can
be reviewed again; its receipt, checkout and native log stay.

A kept checkout does not stay forever: `cel gc` removes reviewer checkouts
(under `~/.local/state/cel/reviews`) whose PR closed more than
`CEL_REVIEW_CHECKOUT_KEEP_DAYS` (default 3) days ago and that hold nothing of
their own - the full rule is in [What `cel gc` keeps](what-lives-where.md#what-cel-gc-keeps).
The verdicts and evidence under the workspace's `.cel` stay.

A reviewer's inbox watcher is owned infrastructure only while its every child
is recognised. Its jq child counts if it runs the launch checkout's current
`_INBOX_WATCH_JQ` (lib/inbox.sh) or a program an earlier release started
watchers with, listed by sha256 in `tools/reviewers/inbox-watch-programs.mjs`;
so a reviewer whose watcher predates a `cel update` can still be retired. Any
other program keeps the reviewer `protected`. A change to `_INBOX_WATCH_JQ`
adds its hash there, beside the old ones (retire.test.mjs fails until it does).

The command returns JSON with a status of `eligible` (dry run), `retired`,
`protected` (outstanding work or an unsupported context) or `unknown` (missing
proof or incomplete teardown). A partial failure keeps private evidence in
`<receipt>.retirement/` for an identity-checked retry; never purge it to force
cleanup. Native history, verdicts, the checkout and review artefacts are
always kept, and a fresh round uses a separate checkout. For a new head or a
re-review, run `cel run reviewer --repo widget --pr 12 --workspace demo`
first, then send its inbox request: it reuses a live reviewer or starts the
next round. Saved retirement history is evidence, not permission to approve
or close a new round.
