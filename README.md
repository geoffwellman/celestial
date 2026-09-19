# Celestial — an AI software factory

**Turn work orders into reviewed software with a visible, steerable team of coding agents.**

One clone per dev box. Celestial organises work into *workspaces*, equips
coding agents (Claude Code, oh-my-pi, codex, opencode, pi), and puts
orchestrators and workers into visible [herdr](https://herdr.dev) panes.
Work moves through delegation, implementation, checks and review under your
workspace policy. You stay at the controls: inspect the work, answer blockers
and make the decisions that need a human.

The dashboard is your factory floor. Isometric workstations show each reported
task as a work order in intake, build, test, review, dispatch or the holding
area. Select a crate to inspect its branch, agent and PR, or focus its worker.
Positions follow real reported signals, not invented progress bars; dispatch
means **ready for a merge decision**, not already shipped.

[![Licence: MIT](https://img.shields.io/badge/licence-MIT-e3b34c)](LICENSE)

![Celestial dashboard with isometric workstations and selectable work orders](docs/images/factory-floor.webp)

*Illustrative work orders in the live dashboard. No agent execution is simulated.*

---

## Why

Running one coding agent is easy. Running twelve — orchestrators delegating
to workers in worktrees, reviewers gating merges, services on ports, tickets
moving — needs a production system. Celestial supplies the coordination,
visibility and housekeeping around the agents:

- **Every agent runs in a visible pane.** No invisible background subagents;
  if it isn't in a pane, it didn't happen.
- **Policy is injected, not hoped for.** Each workspace declares merge rules,
  ticket schemes, runtimes and reviewers once; every agent launched there gets
  them in its system prompt.
- **The fleet cleans up after itself.** A steward tick collects merged
  worktrees, reaps idle agent processes, nudges stalled reviews, and names
  anything waiting on a human.
- **Every work order has a place on the floor.** The isometric dashboard
  distinguishes active work, waiting, blocked work and missing signals.
  Its task list remains available when you need a denser operational view.

## Give this to your agent

You already have a coding agent — Claude Code, oh-my-pi, pi, codex, opencode.
Paste this into it and let it do the install:

```
Install Celestial on this machine and get it running:
1. git clone https://github.com/geoffwellman/celestial.git ~/celestial
2. Add  eval "$(~/celestial/bin/cel shellenv)"  to my shell rc and load it.
3. Run cel setup, then cel doctor. Fix everything red; ask me for anything
   that needs my account (gh auth login, claude setup-token, pi /login).
4. Ask me: a workspace name, my GitHub org, and the repos I want in it.
   Run cel ws new <name> --org <org>, add the repos to workspace.yaml, run
   cel ws sync <name>, then cel doctor again.
5. Start the console with cel console, then run cel fleet and
   cel dash --ensure. Show me both outputs and the dashboard URL, and tell
   me the one command I use from now on.
```

Setup installs third-party code and may invoke `sudo`; read the block before
you paste it, and read [requirements](#requirements) first. If you would
rather type it yourself, the same install is below.

## Quick start

```sh
git clone https://github.com/geoffwellman/celestial.git ~/celestial
eval "$(~/celestial/bin/cel shellenv)"  # add this line to your shell rc
cel setup                               # review the manifests before installing
cel doctor                              # verify prerequisites and account setup

cel ws new acme --org your-gh-user      # scaffold a workspace
cel ws sync acme                        # clone its repos, link skills, check tools
cel console                             # the desk you keep open: routes the box
```

`cel console` is the interface a person keeps open — one per box, across every
workspace. `cd ~/ws/acme && cel run root` is the alternative: it boots that
one workspace's layout with a standing root agent. Pick the console unless you
want a director that lives inside a single workspace and plans for it.

Requires GNU/Linux; automatic prerequisite installation targets apt-based
distributions. Fresh binary installs support x86-64 and arm64. See
[requirements](#requirements) before running setup. Setup installs third-party
code and may invoke `sudo`; it does not supply provider subscriptions or log
you into GitHub, Linear or agent accounts.

## How it works

Three layers on disk, and a factory floor of agents above them.

```
~/celestial                the plane: mechanism only (this repo, public)
├── bin/cel                one CLI for everything
├── core/roles/            role prompts, injected at launch
├── core/skills/           skills linked into every agent
└── agents.yaml            which agents, how to install, how to inject

~/ws/<name>                a workspace: private content + overrides (own repo)
├── workspace.yaml         repos, policy, tickets, runtimes, env, services
├── layouts.yml            herdr layouts (wins over the plane's)
├── externals.yaml         extra tools (additive overlay)
├── skills/                workspace-scoped skills
└── repos/<product>/       the actual product clones (gitignored here)

~/.local/share/cel         box state: registry, published pages (never in git)
```

```
console                one per box - routes; reads cel fleet; never builds
   └── orchestrator        one per product (1..n repos) - plans, delegates, judges, lands
          ├── worker          one ticket, one worktree, one PR
          ├── scout           reads and reports; never writes code
          ├── spike           tries and reports; throwaway code, never shipped
          └── reviewer        one PR, one review per round
```

A **workspace** is not a tier. It is the scope that holds configuration and
grouping: policy, ticket tracker, environment, worker profiles, dashboard. A
**product** is the unit an orchestrator owns — one repo, or several that ship
together. A product that contains all of a workspace's repos is simply "the
workspace orchestrator"; there is no third tier below it, and never was a need
for one. `cel run root` is optional: a standing director for a workspace that
wants one. `root` remains the mailbox name for "the top, whoever is listening",
which is the console otherwise.

`cel run <role>` starts any station with its role injected and permissions
pre-approved; workers are spawned by orchestrators through the `fanout` skill,
which cuts worktrees from origin's real default branch, refuses diverged refs,
and makes every worker land its work as a PR — finished work is never
invisible. `policy.pr_open: draft | ready` decides whether that PR opens as a
draft (default) or ready for review with the workspace reviewer requested.

## Factory vocabulary

The floor has its own words. They are used in the prose below, and none of
them renames a command:

| Word | Means |
|---|---|
| ticket | a work order — the unit a worker is given |
| verdict | the QA gate on a branch: gate result, red-then-green, diff, CI, review |
| land | ship it — squash, merge, clean up |
| steward | the conveyor: the timer that keeps the floor moving without you |
| console | the floor manager's desk: one per box, routes, never builds |

## The console

`cel console` is Celestial's own interface — drawn by the plane, not an agent
pretending to be one. It takes the whole terminal: the alternate screen, like
`htop` or `vim`, so nothing it draws lands in your scrollback and quitting
gives you back the screen you had. Panels, top to bottom:

- **Fleet** — `cel fleet --json` as a table, one block per workspace, coloured
  by state and refreshed every 10 seconds (`--refresh`) and after every command
  you run. ↑/↓ select a row, Ctrl+F focuses that unit's orchestrator pane,
  Ctrl+O opens its dashboard, and **Enter (or a double-click) opens the unit
  view**. Command history is Ctrl+P / Ctrl+N and the Ctrl+R picker, as in a
  shell. Every other keyboard action on this screen is a Ctrl chord: a letter
  you type is always a letter typed.
- **Waiting on you** — every open decision and blocker addressed to `root`,
  across all workspaces, oldest first with their ids. Ctrl+T switches the
  selection here; Enter (or a double-click) opens the item.
- **Detail** — a place, not a popup: the whole message, who sent it and when,
  and the **thread** around it — everything else in that workspace's mailbox
  with the same `ref`, or from the same sender within the hour. `r` resolves,
  `p` starts a reply with the cursor inside the quotes, `g` goes to the sender,
  `Esc` comes back. Bare letters act *here* and only here, because the detail
  view has no command line.
- **Inbox tail** — the newest mail, prefixed with its workspace. Ctrl+T cycles
  the selection fleet → waiting → inbox, and Enter (or a double-click) opens
  the message here too. A decision or a blocker also rings the bell and raises
  a desktop notification.
- **Unit view** — one product, whole: its orchestrator (state, pane, slots,
  workspace and repos) with `[focus]` and `[message]`; every worker it has out
  as a row — ticket, id, state, live agent, quiet time, verdict in colour,
  commits ahead and PR number; that workspace's open decisions; and the last
  ten lines of its mail — and, since CEL-25, the **board** and the **PRs**
  between them. Ctrl+T cycles the focus round the six panels; panels that would
  not fit collapse to their title and a count, because nothing may render below
  the last row of the screen. ↑/↓ pick a row, Enter opens it, `Esc` goes back.
  `n` nudges the selected worker, `R` restarts an orchestrator that is not
  live, `a` answers the waiting item and closes it — each a *proposal* on the
  command line, never a keypress that changes the box.
- **Board** — the product's tickets, from `cel-linear board --json`, grouped by
  state in the team's own workflow order: `ABC-49  In Progress  @worker  2h
  title…`, with the worker column saying what *this box* is doing about a
  ticket the team thinks is in progress. Enter opens the ticket — description
  head, last two comments, the worker on it — and `s` proposes "pick up ABC-49
  next" to the orchestrator, `m` moves it with the team's states offered as
  numbered options, `o` opens it in a browser.
- **PRs** — the open pull requests on the product's repos, one `gh pr list` per
  repo: `#12  ABC-49-slug  review APPROVED  ci ✓  2h  title…`. Enter shows the
  checks by name, the review state and the worker behind the branch. `l` lands
  it — only when the review is APPROVED and the checks are green, and through
  `cel-fanout land` on the *delegation*, because merging by hand leaves a
  worker holding a branch nobody will collect. `v` starts a reviewer.
- **Since you last looked** — one line under the unit view's header, computed
  from the console's own cursor for that workspace: `since 09:41: 3 status from
  bundle-orch (last: "…") · 2 PRs merged · 1 decision waiting`. It is the
  console's mark, not the mailbox's read marker — looking at a panel must not
  mark anyone else's mail as read.
- **Timeline** — `T` (or Ctrl+Y) from the main screen: the box's own history in
  one column, newest *last*, from the mailboxes, the delegation ledger and the
  pull request lists at once — `12:47 alpha  merged  #2008 ABC-105`. Enter
  opens whatever the line is about; `Esc` comes back.
- **Worker view** — the answer to *why*. It runs `cel-fanout why <id>` when it
  opens and shows what it said: the facts line, the pane tail, the mail from
  that worker, the PR and a `next:` sentence. `p` prompts it, `f` focuses its
  pane, `c` collects, `x` releases, `t` tries the preview, `w` asks again.
  Anything that changes state is *proposed* on the command line and runs when
  you press Enter, never on the keypress alone.
- **Output** — the last command's full output, rendered rather than dumped: the
  console knows the shape of what it ran, so `--json` comes back as the same
  tables the panels use and anything else that parses as JSON as `key: value`
  lines. `r` toggles `[raw]` — the bytes exactly as the command printed them. scrolling with PageUp/PageDown
  or the wheel; Ctrl+L collapses it and gives the room back.
- **Command line** — it edits like a shell: a real cursor (←/→, Home/End,
  Ctrl+A / Ctrl+E), Ctrl+W, Ctrl+K, Ctrl+U, Tab completion over the cel
  vocabulary and live workspace and orchestrator names. ↑/↓ walk the history,
  filtered by whatever is already typed, and Ctrl+R opens a history picker you
  can type into. Under it are two lines that never overwrite each other: a
  **status** message that clears itself after 8 seconds (`--status-secs`,
  0 = never) and a permanent **legend** for the focused panel. `?` + Enter lists every
  binding.

The mouse works: click a row to select it, double-click for that panel's
primary action (open the unit, open the message), roll the wheel over a panel
to scroll it, click `[resolve]` `[reply]` `[go to]` in the detail view — or
`[worker]` / `[unit]`, which take you to the page of whoever sent it — and the
buttons in the unit and worker views.
Mouse reporting and the alternate screen are turned off on every exit path
there is — quit, Ctrl+C, SIGTERM, a crash — because a terminal left in mouse
mode is a terminal you cannot select text in.

What you type is either a **command** (it starts with `cel`, `cel-fanout`,
`cel-linear`, `gh` or `herdr`) — which runs as-is, after the same allowlist the
agent console is held to — or a **sentence**, which is sent to a small model.
Anything it returns is *proposed*: it lands on your command line and runs when
you press Enter again, or disappears on `Esc`. The model never executes
anything.

A sentence the console can already answer comes back as an **answer** rather
than as homework. The state the model is given carries every worker, its
verdict, its quiet time and its PR, so "which workers are idle", "why is ABC-49
stalled" and "what is waiting on me on alpha" are answered from it and nothing
runs. Otherwise a sentence can come back as a **chain** of up to five commands when it needs a
sequence — every line is put to the allowlist *before any of them runs*, and
then they run in order, stopping at the first one that exits non-zero. And a miss is not a dead end: the model is asked a
second time for up to three candidates, each with a one-line reason, and they
are listed in the OUTPUT panel:

```
no command for that - did you mean:
1  cel inbox read --for root --workspace alpha     -- what the steward left there
2  cel fleet                                       -- state of every workspace
3  cel-fanout status --workspace alpha             -- what is in flight
```

Type `1`, `2` or `3` and Enter — or click one — to put it on the command line.
It is still only a proposal.

The model is optional, and everything above works without it. It is a router,
not a chat: it knows the vocabulary table and the current fleet, and it can
only pick commands from that table. To wire one in, write
`~/.local/share/cel/config.yaml` (chmod 600 — it may hold a key):

```yaml
console:
  provider: openrouter          # openrouter | anthropic | openai | deepseek
  model: anthropic/claude-haiku-4-5
  key_env: OPENROUTER_API_KEY   # read from the environment, else console.key
  router:                       # optional; without it, the chat model routes
    provider: openrouter        # openrouter | typesafe
    model: typesafe/jev-1.13    # on typesafe: jev-latest
    key_env: OPENROUTER_API_KEY # else console.key_env, else console.key
    min_confidence: 0.6         # below this, the top three become options
```

### The router

Routing a sentence is a classification problem — ten intents, one of them
right — and a **decision model** answers exactly that: it does not generate
text, it picks one option from a set you define and returns the whole
probability distribution with it. Configure `console.router` and the sentence
goes there first: "what is happening with bundle" came back in 0.4 s against
6.5 s for the chat model, because the model picks a *label* and the console
fills in the command itself.

That last part is the safety property. The router never writes a command line.
It answers `product_status 0.98`, and the console — not the model — finds the
product in the fleet it already holds, takes the workspace that owns it and
builds the three commands. A slot it cannot fill (no product named, a ticket
no worker carries) is a **miss**, and a miss falls through to the chat model
rather than guessing: a guessed `--workspace` is somebody else's mailbox.
Below `min_confidence` the top three intents are offered as options, each
already expanded to its command, with the probability as the reason.

The chat model keeps the two jobs that need prose — the answer written from
what the commands printed, and every sentence the router could not place — so
a router that is down, misconfigured or absent costs nothing but latency.
`--no-router` on the command line and `console.router.enabled: false` in the
config bypass it entirely.

Endpoints come from `agents.yaml`'s provider table; the request is one plain
`fetch` with no SDK. With no provider configured, a sentence gets one line
saying so and the command line carries on working.

`cel console --render-once` prints the panels as plain text and exits — no
alternate screen, no mouse — for pipes and for when a full-screen UI is the
last thing you want; `--status "…"` renders a status line with it. `cel
console --ask "<sentence>"` prints the chain one command per line, or the
answer when the state holds one (exit 0), or the numbered options on a miss
(exit 1). `--ask` also prints what the router chose and how long it took on
stderr (`router: product_status 0.98 in 0.4s`). `--render-once --unit <product>` and `--render-once --worker <id>`
print the two depth views the same way. `cel run console --agent` still starts
the original Claude pane for people who would rather talk to a full agent.

## The review loop runs itself

Declare a reviewer in `workspace.yaml`:

```yaml
review: { runtime: omp, model: gpt-5.6-sol }
```

and orchestrators start one reviewer pane per PR. A reviewer delivers one
verdict per round and **records it in the delegation ledger** — `cel-fanout
review <id> approved|changes --by <alias>` — which is where a review exists;
`cel-fanout land` accepts that verdict on repos where the PR author and the
reviewer share one GitHub account, and GitHub approval remains the authority
where they do not. `review.post: github` opts a repo into posting the review
to GitHub as well, for reviewers that have an identity of their own; the
default is `inbox`, because an agent approving its owner's PR under the
owner's account is the owner approving himself in public. Reviewers prompt
workers directly on request-changes; workers fix, push, and prompt back for
re-review; you hear about it only on approval or escalation. A steward tick
(every 5 minutes by default, deterministic, token-free) backstops the whole
thing: verified disposable worktrees are removed, positively identified idle
workers can be reaped, stalled PRs are nudged, and blocked agents or preserved
unlanded work are named until dealt with. Unknown state is a reason to retain
work, not evidence that it is safe to delete.

## Agents talk without hijacking your keyboard

`herdr agent prompt` types into a pane, so a status report landing while you
are mid-sentence merges with your draft. Routine agent-to-agent traffic goes
through `cel inbox` instead - a JSONL mailbox per workspace, with a read
cursor per *reader* so a standing root pane and the console can both drain
root's mail without stealing each other's place - and delivery is out-of-band:
recipients run a `Monitor` background task (`cel inbox watch`, or `cel inbox
watch --all-workspaces` for the console) so new mail arrives as a
notification, and a `UserPromptSubmit` hook drains anything missed on your
next turn. Escalations that truly cannot wait still prompt, deliberately.

## Watch and steer

- **`cel fleet`** — the whole box in one deterministic read: every workspace,
  every product (a repo in no declared product is its own), whether its
  orchestrator is live, workers in flight across the product's repos against
  the cap, stalled and unlanded work, and root's mail. Token-free and free of
  agent judgement; `--json` for scripts. The console answers from this, never
  from memory.
- **Memory is part of that read.** Every process whose working directory is
  under a worker's worktree is that worker's - its shell, its agent, its tools
  and its test runs - so summing their `VmRSS` gives what a worker actually
  costs: ~340 MB for a pi worker, ~370 MB mid-gate. `cel fleet` prints `mem`
  per product and `box 6.9G free of 24G` on each workspace's head line;
  `--json` carries `rss_mb` per worker, per unit and per orchestrator pane plus
  a `box` block. The console shows the same numbers per row, with the box's
  headroom on the status edge (warn under 15% available, bad under 8%) and `s`
  in the unit view to sort workers by memory. The steward raises one blocker
  under 10% naming the largest trees, and tells a product's orchestrator when
  one worker passes `CEL_MEM_WORKER_WARN_MB` (2 GB) - it never kills anything,
  because a sweep that reaped a worker mid-gate would destroy the work it was
  measuring.
- **`cel dash`** — per-workspace dashboard: an attention queue ("needs you"),
  every in-flight branch joined with its agent + PR + CI state, sticky
  filters, and a prompt box that drives any agent in the workspace.
- **`cel publish <file>`** — self-hosted pages server (tailnet-private by
  default, per-document promotion to a public tier). Published pages carry a
  feedback widget that routes straight back to the agent that published them —
  select text to comment on the exact passage.
- **`cel gc`** / **`cel steward`** — the cleanup and liveness machinery, also
  runnable by hand. `cel gc --orphans` reaps what the plane started and nobody
  owns any more: inbox watchers whose console exited, test fixtures whose
  worktree is gone, bare shells on ptys no pane owns, gate runners whose suite
  was killed. The steward does it once a tick and says so in one line.

## What runs in the background

Four kinds of thing run without you: **one timer**, **long-lived servers**, **a
per-turn hook**, and **the agents themselves**. Nothing else is hidden.

### The steward — the only scheduled process

`cel steward` is a single pass over the whole fleet. Its checks do not call a
model, but they can remove verified disposable worktrees, terminate eligible
idle workers, maintain servers and prompt agents. Those agents may then spend
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
dies silently with the herdr session. `Persistent=true`, so a tick missed while
the box slept runs on wake — a ticket moved to the trigger state overnight is
still waiting in the morning. Enable `loginctl enable-linger` or it stops when
you log out.

Each tick, in order:

| Step | What it does |
|---|---|
| **garbage collect** | retains dirty, unlanded, live or unverifiable work; reaps only ownership-verified workers observed idle for 12h (2h under memory pressure), never merely old processes |
| **review sweep** | for each repo, `gh pr list --author @me`: approved PRs, changes-requested with nobody working, and red gates with nobody working each nudge the owning orchestrator |
| **untracked PRs** | a PR older than a day whose branch carries no ticket id — invisible on the board, so it is surfaced |
| **blocked agents** | any agent waiting on input is named every tick, deliberately without dedup; that is your queue |
| **stalled workers** | the one failure no inbox watcher can see: a worker whose provider stream died sends no mail and reads as `idle`. A fatal pane marker (`server_error`, `F5 to Retry`) quiet for 15 minutes, or an agent gone from the roster, escalates to root naming the ticket, pane, stall age, whether the branch is pushed and what is uncommitted — louder when the work is unlanded, because that is when delay costs the work itself |
| **stale mailboxes** | a recipient with unread mail older than 30 minutes has probably lost its inbox monitor, so its pane is told to re-arm and drain |
| **page feedback** | feedback whose publishing pane is gone stays a warning until someone drains it |
| **ready tickets** | tickets in the workspace's `trigger_state` with no branch anywhere are handed to the product's orchestrator, else root — this is what makes "move it to Todo" start work |
| **servers** | `cel dash --ensure` for every workspace declaring a port; expired public shares are deleted, not merely refused |
| **ensure orchestrators** | every product declaring `orchestrator: auto` with no live pane is started with `cel run orchestrator`, at most once every 30 minutes so a crash-looping one is not relaunched every tick |
| **updates** | once a day, whether this plane is behind — the newest release tag on the `release` channel, the commits on `origin/main` on the `main` channel, rolled up into one root item naming how many and which build you are on |

Nudges are **rate-limited per subject** (4 hours; the update check, 24) through
`~/.local/share/cel/steward-state`, so a stuck orchestrator is reminded rather
than spammed.

### Servers — started on demand, kept alive by the steward

Each runs under `setsid`, so it outlives the pane or agent that started it, and
logs to `~/.local/share/cel/logs/`.

| Service | Where | Kept alive by |
|---|---|---|
| `cel dash` | per workspace, port from `dash.port` | the steward, every tick |
| `cel pages` | tailnet tier, `:7780` | `cel pages --ensure` |
| `cel pages --public` | internet-reachable tier, `:7781` | `cel pages --ensure` |
| `cel pages tunnel` | cloudflared/ngrok, for sharing without Tailscale | started by hand |

`--ensure` is idempotent: it starts the service only if it is not already
answering, so it is safe on a loop.

### The hooks — the only things that touch a live session

Four hooks, all registered in the agent's settings by `cel setup`, all failing
open on their own errors so housekeeping can never take an agent down:

| Hook | Event | What it does |
|---|---|---|
| `inbox-drain.sh` | `UserPromptSubmit` | drains the pane's own mailbox at the start of a turn, so mail is never typed over what you were writing |
| `inbox-guard.sh` | `Stop` | if the pane has **unresolved decisions**, blocks the turn's end once with the count and the re-arm instruction — a dead monitor can no longer go unnoticed |
| `orchestrator-guard.sh` | `PreToolUse` | **read-only orchestrators**: from a root or orchestrator pane, refuses commits, pushes, merges, branch switches and edits under `repos/` (by shell or by the native edit tools). Workers are untouched. `CEL_GUARD=0` opts a pane out; `CEL_GUARD_ALLOW_ONCE=1` approves one call |
| `learn-stow.sh` | `SessionEnd` | decays and budgets the workspace's `learnings.md` |

Identity for all of them comes from the pane's working directory — a workspace
root is `root`, `<ws>/repos/<repo>` is that repo's orchestrator, a worktree is
a worker — so nothing needs env plumbing through herdr.

`cel inbox watch` is the other half of the inbox — a `Monitor` an agent arms
inside its own session to notice mail arriving while it is idle. It is not a
daemon; when it dies, the Stop hook and the steward's stale-mailbox check are
what catch it.

### Services

`cel services` is one list of everything this box is running on a port: the
services a workspace declares under `services:` and every `cel-fanout try`
preview, joined.

```yaml
services:
  - name: builder                    # name + url only stays valid, and is
    url: http://localhost:4322       # observe-only: there is nothing to start
    cmd: pnpm --filter builder dev   # with a cmd it can be started and stopped
    cwd: repos/widget
    health: /                        # a path that must answer 200 within 2 s
    env: { MODE: dev }
    restart: auto                    # the steward tries once before it escalates
```

Each row carries `state` (`up` when the port is listening, `healthy` when the
health path answers, else `down`), the port, the pid and the resident memory of
the process tree in its cwd, how long it has been up, and **reach** — the URL
that works from somewhere that is not this box. `cel services start|stop|
restart|logs <name>` runs it in a herdr pane under the workspace's own pane and
remembers the pane in `<ws>/.cel/services.json`; a service without a `cmd` is
observe-only and says so.

Reach exists because every dev server and every preview binds `127.0.0.1`,
which from a laptop is the laptop. The dashboard already listens on the tailnet
IP, so it **proxies** them: `http://<tailnet-ip>:<dash-port>/svc/<port>/…` is
forwarded to loopback, WebSocket upgrades included, for ports that belong to a
known service or preview only, and only with the dashboard's own control token —
a tailnet neighbour cannot browse this box's loopback. `cel-fanout try` prints
that URL as its last line when the dashboard is up.

The steward probes every service that declares `health:` once per tick. Two
consecutive down ticks raise one rolled-up blocker to root naming the service
and the last line of its pane; back up clears it. `restart: auto` restarts it
once first, and says so in the blocker.

Some services belong to the **box** rather than to any workspace — the auth
broker and gateway are used by every workspace and owned by none. They are
declared one JSON file per service in `~/.config/cel/services.d/` (`CEL_SERVICES_D`),
in exactly the shape of a `services:` row plus a bare `port:` shorthand, `0600`
in a `0700` directory because `env` may carry a bearer. They appear in
`cel services` under a `box` block — after the workspace's own rows, or alone
when you run it from outside every workspace — carry `workspace: "box"` in
`--json`, start and stop by name, are probed by the same steward sweep, and
keep their state in `~/.local/share/cel/services/<name>.json` rather than in
any workspace. `env` values whose key looks like a credential are rendered
`***` everywhere. `cel gateway install` writes its two, and `cel doctor` says
how many the box declares and how many are healthy.

In the console, `S` opens the SERVICES view — one row per service and preview,
`o` opens its reachable URL (printed as well as opened, so the link is
clickable through herdr from a laptop), `S` starts or stops, `r` restarts, `L`
reads its log, `x` stops a preview. The dashboard has the same rows as a card.

### The agents

The orchestrators, workers, scouts, spikes and reviewers are herdr panes, not
services. They are started by `cel run` and `cel-fanout delegate`, and they
stop when their pane does. `cel-fanout status` is the ledger of what was
delegated, on which model, and where it got to.

A worktree is a fresh checkout, so the gitignored files an app needs to *run* —
keys, a built wasm directory — are simply absent from it. `repos[].seed` in
`workspace.yaml` names them and `cel-fanout delegate` places them (symlink, or
`copy: true`) before the worker starts, telling it they are not its to commit.
With `repos[].preview` declared, `cel-fanout try <id>` then starts that ticket's
branch from its own worktree on a free block of ten ports and prints the url —
so trying a PR no longer means parking the one shared checkout on it. `--stop`
ends the preview, `release` ends it for you, and `cel-fanout status` shows the
port it is on.

The console runs one background watch of its own: `cel inbox watch --for root
--all-workspaces`, so a decision raised in any workspace raises a desktop
notification rather than waiting for someone to look. Like every watch it is
not a daemon — it lives and dies with the console.

## Any model, any CLI, per worker

`runtime:` picks the CLI for a role; a **worker profile** picks the CLI *and*
the model *and* the reasoning level, and any launch can be pointed at one:

```yaml
thinking: medium              # default level when no profile applies
worker_profiles:
  default:  { runtime: omp,    model: openai-codex/gpt-5.6-sol, thinking: low }
  astra:    { runtime: codex,  model: gpt-6-astra,              thinking: low }
  deepseek: { runtime: omp,    model: deepseek/deepseek-flash,  thinking: medium,
              fallback: openrouter/deepseek/deepseek-v4.1-flash }
```

Bind a profile to a role and it applies with no flag at all:

```yaml
role_profiles:
  root: opus                  # deepest model for planning and delegation
  orchestrator: default       # cheaper for coordination
  worker: default
  scout: opus                 # read-only research; needs web tools, not volume
```

This is the *only* way to configure root and the orchestrators, because neither
is launched by hand — root comes up from the layout when the workspace boots,
and the sub-orchestrators are started by root itself. A flag for those two is
really an instruction to an agent, and agents forget. `scout` is optional and
falls back to `worker`; bind it when investigations want a different CLI or
model from the one that ships tickets.

```bash
cel profiles                                        # resolutions + role bindings
cel run worker --repo r --branch b --profile astra  # override once
cel-fanout delegate r b spec.md --profile deepseek  # profile lands in the ledger
```

Three things make this more than a flag:

- **Every CLI spells it differently, and the plane knows.** `agents.yaml`
  records each runtime's model flag and how it takes a reasoning level — claude
  `--effort`, omp/pi `--thinking`, codex `-c model_reasoning_effort=…`, opencode
  not at all. A level a runtime doesn't accept is **clamped down its own
  ladder**, never passed through to be rejected at launch.
- **`fallback:` is checked before the pane spawns.** It names the same model
  reached a different way — a direct provider API, or an aggregator. If the
  primary's key is missing from the workspace environment, the fallback is used
  and *said out loud*. Without that check an unauthenticated worker starts,
  prints an auth error and idles, which from outside is indistinguishable from
  one thinking hard.
- **The choice is recorded.** `cel-fanout status` shows which model built which
  branch, so running two profiles at the same ticket is evidence rather than
  anecdote.

Keys live in the workspace's gitignored `env.local`; nothing but the model id
ever reaches this repo.

### Subscriptions

The fleet does not run on API keys alone. It runs on two **signed-in
subscriptions** — Claude (through pi's OAuth and through Claude Code) and
Codex (ChatGPT, through omp) — and a five-hour window at 100% stops every
worker on that account just as hard as an empty balance does, without an error
message anywhere anyone looks.

`cel quota` asks both accounts directly and prints them above the API
balances: one row per signed-in account, each window with its percentage and
the local time it resets, and whether extra usage is still a path. A token is
never printed anywhere — an account is named by its provider and a short
stable id. The readings are cached for 60 seconds, so the console's status
edge (`claude 16%/41% · codex 9%/62%`, amber at 80, red at 100), the `q` QUOTA
view, `cel fleet --json` and the dashboard's Subscriptions card all read the
cache rather than calling a provider on every draw.

The steward checks the windows once a tick and raises **one rolled-up item per
account** — a status over `CEL_SUB_WARN_PCT` (80), a blocker at 100 — and
takes it down again when the window drops. A profile routed at a spent 5h
window is vetoed before its pane spawns, the same way a dry balance is.

## Gateway — several subscriptions behind one door

One Codex or Claude subscription maxes out. `cel gateway` puts **all of them**
behind one loopback door and spreads workers across them, and shows what each
one has left.

```bash
cel gateway install          # broker + gateway as box services, loopback only
cel gateway status           # one row per account: provider, id, ok, windows
cel gateway login anthropic  # sign another subscription in
```

Under it are omp's two processes: `auth-broker` is the credential vault (several
OAuth accounts per provider) and `auth-gateway` is an OpenAI/Anthropic surface
on `127.0.0.1` that mints the OAuth itself, drops the accounts that are
unavailable and picks one of the rest **by session key**. A profile reaches it
with one field:

```yaml
worker_profiles:
  gw: { runtime: pi, model: openai-codex/gpt-5.5, via: gateway }
```

`cel run worker --profile gw` then writes an `ompgw` provider into
`~/.pi/agent/models.json` (merged — the owner's other providers are untouched,
and the model list comes from the gateway's own `/v1/models`), launches pi at
`ompgw/openai-codex/gpt-5.5`, and sets two variables in the pane:
`OMP_GATEWAY_TOKEN`, read there by omp so no bearer ever passes through the
plane, and `CEL_SESSION_ID`, which is the **only** thing the balancer can pin an
account by — pi sends no session identity of its own, so without the injected
`x-session-id` header every worker on the box is the same anonymous session.

Three things are worth knowing before you rely on it:

- **Availability filtering comes first, session choice second.** With one
  usable account per provider the spreading is a no-op; the feature is worth
  exactly as many subscriptions as are signed in and not rate-blocked.
- **A disabled credential vanishes**, it does not error. It disappears from
  `/v1/models`, so a worker sent at it dies with "Unknown model" rather than
  "auth expired" — which is why `cel doctor` and the profile preflight both
  say which providers have nothing usable, and veto the launch.
- **The bearer grants every subscription in the vault** to anything that can
  reach the port. The services bind loopback only; nothing writes the token.

Its accounts land in the same places the signed-in subscriptions above do: the
QUOTA view's `via gateway` section, the dashboard's Subscriptions card, and
`cel gateway status --json` - one row per account, carrying `source: gateway`.

## Tickets

Set `tickets: { system: linear }` and the plane wires Linear's **official MCP
server** into Claude sessions at sync, while every other runtime shares
`cel-linear` (a thin GraphQL shim). The lifecycle contract —
In Progress on start, In Review + PR link on open, Done on merge — rides the
policy block into every agent.

## Commands

| Command | What |
|---|---|
| `cel setup` / `cel doctor` | install everything / verify the box |
| `cel fleet [--json]` | the whole box in one deterministic read: orchestrator liveness, workers n/cap, stalled and unlanded work per product, root's mail per workspace |
| `cel update [--check·--rollback·--channel]` | move to the newest release tag (or to `origin/main` on the main channel), re-link and re-render, then verify; `--check` prints what you have not got yet and exits 1 when behind; `--rollback` undoes the last update; `--channel main·release` picks which stream this box follows |
| `cel ws new · add · sync · list · push · env` | workspace lifecycle |
| `cel console` | the desk you keep open: fleet, decisions, inbox and a command line that also takes a sentence |
| `cel run [root·orchestrator·worker·reviewer]` | start an agent, role injected |
| `cel run orchestrator --product <p>` | start the orchestrator for a product (1..n repos) |
| `cel profiles` | worker profiles and the exact launch flags each resolves to |
| `cel steward --install [--interval m]` | run the steward on a timer (the thing that makes any of it proactive) |
| `cel quota [provider] [--json]` | the signed-in Claude and Codex subscriptions — every window, its percentage and when it resets — above the credit left per API provider; a route below its floor, or on a spent 5h window, is vetoed before a pane spawns |
| `cel learn add · list · reinforce · stow` | durable facts the workspace has established — pinned / aging / perishable — budgeted into every agent's policy block |
| `cel inbox open · resolve` | decisions stay open until resolved; reading one does not answer it |
| `cel-fanout scout <repo> <brief>` | an investigation: disposable worktree, a report as the deliverable, no ticket, no PR |
| `cel-fanout spike <repo> <brief>` | a trial: throwaway code in a disposable worktree, a report as the deliverable, never shipped |
| `cel-fanout land <id>` | the one merge path — fleet-authored, approved, green, gate passed, `policy.merge` allows |
| `cel-verify <worktree>` | a structured verdict for a branch: gate result, red-then-green, diff, CI, review |
| `cel dash` | workspace dashboard |
| `cel publish` / `cel pages` | self-hosted documents |
| `cel gc [--reap h] [--orphans]` | reclaim worktrees + idle agents; `--orphans` reaps processes with no owner |
| `cel inbox send · read · count · watch` | agent messages that never type into a pane; `--all-workspaces` for the console |
| `cel steward` | one proactive tick over the whole fleet |
| `cel spike` / `cel promote` | throwaway repo → real repo |

## What lives where

The repo is **mechanism only**. Your setup never lands in it:

| | Where | Committed? |
|---|---|---|
| The tool | `~/celestial` | public repo (this one) |
| Which workspaces exist on this box | `~/.local/share/cel/registry.yaml` | never |
| Published pages | `~/.local/share/cel/pages*` | never |
| Workspace content + overrides | `~/ws/<name>` (own private repo) | yours |
| Secrets | `<ws>/env.local` (gitignored) | never |

Workspace files always win over plane defaults: `layouts.yml` over the plane's
layouts, `externals.yaml` additively, `env:`/`env.local` over your profile,
workspace `skills/` scoped to that workspace's repos only.

### Cleanup safety

GC protects every removal path with delegation and process checks. It requires
a clean attached Git HEAD and proven default-branch ancestry, or a merged PR
whose recorded head is exactly the local HEAD. A missing/broken default,
unknown discovery, running delegation or newer local commit blocks removal.
`cel-fanout release` also refuses uncertain work unless you explicitly choose
`--keep-worktree` or the destructive `--discard`.

The reaper uses herdr foreground-process evidence, a workspace role-file
ownership stamp and a durable observed-idle clock under
`~/.local/state/cel/gc-idle.json`. Its first observation never kills.
Working/blocked/unknown agents, root/orchestrators, manually launched processes
and unsupported ownership stamps are retained regardless of age. Cooperating
fanout operations share lifecycle locks; unrelated manual Git/herdr changes
cannot be made transactional with external tools. Atomic state replacement
prevents partial readers, but is not a promise of power-loss durability.

### Private HTTP services

Private pages and dashboard listeners are local/tailnet control surfaces, not
multi-user authenticated applications. Do not tunnel them onto the public
internet. Published private HTML is trusted active same-origin content.
Only the separate token-addressed public pages tier is intended for sharing.

Private requests require an exact trusted Host. Browser mutations also require
an allowed Origin and a per-process `X-Cel-CSRF` token; built-in controls supply
it automatically. For reverse proxies or extra tailnet names, configure
`CEL_PAGES_TRUSTED_ORIGINS` / `CEL_DASH_TRUSTED_ORIGINS` with comma-separated
exact origins such as `https://control.example` before starting the service.
Forwarded headers never grant trust. Wildcard binding does not grant arbitrary
Host access. Restart after configuration changes.

Local automation reads `{csrfToken}` from `GET /api/session`, then supplies
that value in `X-Cel-CSRF` with `Content-Type: application/json` on mutations.
The session endpoint has no CORS permission and is not available on the public
tier. Generated tokens rotate on restart; stale browser tabs need a reload.
Optional `CEL_PAGES_CSRF_TOKEN` / `CEL_DASH_CSRF_TOKEN` overrides require at least
32 URL-safe characters; treat them as secrets. This is anti-CSRF and
DNS-rebinding protection, **not account authentication**: a directly trusted
local/tailnet caller can obtain the token.

## Requirements

GNU/Linux with Bash, GNU coreutils, `/proc`, Git, Python 3 and
curl **7.55.0 or newer**. Tests and the Node services use Node **24.x**; YAML
processing uses Python `yq` (the jq wrapper), not the Go program of the same
name. [herdr](https://herdr.dev) supplies panes. A systemd user session is
required only for the optional steward timer. macOS and other kernels are
rejected before CLI dispatch.

`cel setup` installs missing prerequisites through apt when available;
otherwise it tells you what to install manually. Fresh application versions
and native checksums live in [`agents.yaml`](agents.yaml), external plugin
commits in [`externals.yaml`](externals.yaml), and Pi extension versions in
[`tools/pi/extensions.txt`](tools/pi/extensions.txt). External overlays must
declare `source` and a full 40-character Git `ref`; legacy version-only
declarations are rejected.

Pins govern **fresh setup**, not a hermetic machine image. Existing executables
are retained (GitHub CLI must be at least 2.90), distribution packages follow
your package sources, and npm transitive dependencies, plugin build
dependencies and later upstream self-updates are not locked by Celestial.
Previously installed plugins from unrelated marketplaces are not silently
removed. Installation/download failures are reported rather than called
success. Review manifests and upstream code before installing.

## Development and security

See [architecture](docs/architecture.md),
[contributing](CONTRIBUTING.md), [security policy](SECURITY.md), and the
[release checklist](docs/release-checklist.md). CI runs the shell/HTTP suite,
source-and-history hygiene checks and a pinned credential scanner. Private
release vocabulary stays outside this repository; the public generic check
alone is not proof that a particular organisation's information is absent.

## Versioning & updates

Celestial follows [semver](https://semver.org); `VERSION` + `v*` tags are the
truth and every release is announced on
[GitHub Releases](https://github.com/geoffwellman/celestial/releases) with
notes from [CHANGELOG.md](CHANGELOG.md) — **Watch → Custom → Releases** to get
notified. On the box, `cel version` tells you what you're running as
`celestial v0.2.0+31 (d43910c, main)`: the nearest tag, **the commits since
it**, the sha and the branch — the `+31` is the part people quote, because a
version alone says v0.2.0 for thirty-odd merges.

Cutting a version is one verb: `cel release <x.y.z>` (or the **Release**
workflow's `Cut` job in the Actions tab) runs the suite and the hygiene scans,
bumps `VERSION`, turns `[Unreleased]` into that version's section and opens a
`release: v<x.y.z>` pull request — main takes no direct pushes, so the bump is
reviewed like any other change. Merging it tags `v<x.y.z>` and publishes the
GitHub Release from the same notes, on its own. `--dry-run` shows what would
ship, `cel release status` shows the open PR and the newest tag, and the
[release checklist](docs/release-checklist.md) has the long form. A change
worth a changelog line adds its own `changelog.d/<branch>.md` — first line the
category heading (`### Added`, `### Changed`, `### Fixed`, `### Removed`), the
rest the entry — and the cut assembles those fragments into the section and
deletes them, so two open pull requests never edit the same `CHANGELOG.md` line.

A box follows one of two **channels**, set in `~/.local/share/cel/config.yaml`
(box-level, created 0600) and switched with `cel update --channel
main|release`:

```yaml
update:
  channel: release      # release (default) | main
```

On `release` — the default, and what you want unless you are working on the
plane itself — `cel doctor`, the steward and `cel update --check` compare you
to the newest release tag and `cel update` lands on it. On `main` they compare
you to `origin/main`: `--check` names how many commits are ahead of your
build, lists their subjects oldest first and the `[Unreleased]` notes you
haven't got, and `cel update` fast-forwards to main's tip. Both channels
refuse to touch a dirty tree or one that is off `main`, record where they came
from, and undo with `cel update --rollback`.

## Licence

[MIT](LICENSE) © Geoff Wellman
