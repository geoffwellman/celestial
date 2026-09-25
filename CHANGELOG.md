# Changelog

All notable changes to celestial. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow [semver](https://semver.org). Releases are announced on the
[GitHub Releases page](https://github.com/geoffwellman/celestial/releases) -
watch the repo (Watch → Custom → Releases) to be notified.

## [Unreleased]

## [0.3.0] - 2026-09-25

### Added
- A worker may no longer **land, release, delegate, scout, spike, collect or
  reconcile**: the guard denies those verbs for the worker role and
  `cel-fanout` refuses them on its own before any `gh` call or ledger lock, so
  the bottom tier ships a PR and reports rather than driving the factory.
- **The two signed-in subscriptions are visible at last.** The fleet runs on a
  Claude subscription (pi's OAuth and Claude Code) and a Codex one (ChatGPT,
  through omp), and nothing on the plane could see either: `cel quota` knew API
  balances only, so a five-hour window at 100% stopped every worker on that
  account with no message anywhere anyone looks. `cel quota` now prints one row
  per signed-in account above the balances — each window, its percentage and
  the local time it resets — and `cel quota --json` carries them under
  `subscriptions`. A token is never printed: an account is named by its
  provider plus a short stable id. Readings cache for 60 s, so the console's
  status edge (`claude 16%/41% · codex 9%/62%`, amber at 80, red at 100), its
  new `q` QUOTA view, `cel fleet --json` and the dashboard's Subscriptions card
  all read the cache instead of calling a provider on every draw. The steward
  raises one rolled-up item per account (status over `CEL_SUB_WARN_PCT`, 80;
  blocked at 100) and clears it when the window drops, and a profile routed at
  a spent 5h window is vetoed before its pane spawns, with the reset time in
  the refusal
- **The ledger closes what the world already closed**: `cel-fanout reconcile`
  lands the rows whose PR GitHub merged, abandons the ones closed unmerged past
  `CEL_RECONCILE_GRACE_HOURS`, raises one rolled-up item per unread scout
  report and releases ship rows with no PR and no worktree - one `gh pr list`
  per repo, run every steward tick, with `release --all --merged` and a console
  `X` option for the same clean-up by hand
- **Releasing is one verb**: `cel release <x.y.z>` dispatches a GitHub workflow
  that checks hygiene and the suite, bumps `VERSION`, closes `[Unreleased]` and
  opens the `release: v<x.y.z>` PR; merging it tags and publishes the GitHub
  Release from the same notes. `--dry-run` shows what would ship and
  `cel release status` the open PR and newest tag
- The console is a **control panel**: the unit view now lays out ORCHESTRATOR ·
  WORKERS · **BOARD** · **PRS** · WAITING · RECENT MAIL, with Ctrl+T cycling
  the focus and panels that would not fit collapsing to a title and a count
- **BOARD**: the product's tickets from `cel-linear board --json`, grouped by
  state in the team's workflow order, with the worker on each; Enter opens the
  ticket detail
- **PRS**: the open pull requests on the product's repos from one `gh pr list`
  per repo - review decision, checks, age - with `l` landing an approved, green
  one through `cel-fanout land`
- **"Since you last looked"**: a one-line digest under the unit view's header,
  computed from the console's own cursor per workspace, and a **TIMELINE** view
  (`T`, or Ctrl+Y) merging the mailboxes, the delegation ledger and the merged
  pull requests into one column, newest last
- **Seven verbs as keys and as intents**: start, answer, land, nudge, restart,
  move and review, each a proposal on the command line and each a router intent
  with its slots filled from state the console already holds
- `cel-linear board [--team K] [--state a,b] [--json]`: a team's open issues and
  what it finished today, grouped by state in workflow order, with the raw query
  cached 60 s under `$CEL_CACHE` so the console's refresh cannot hammer Linear
- **`cel gateway`** - several Codex/Claude subscriptions behind one loopback
  door. `install` registers omp's `auth-broker` and `auth-gateway` as box
  services on 127.0.0.1 (47311/47411 by default) and mints the bearer;
  `status [--json]` prints one row per account with each window's used/limit
  and state, short ids only and never the token; `login <provider>` /
  `logout <provider> <id>` are the one-line verbs for adding and dropping a
  subscription. A worker profile that says `via: gateway` launches pi at
  `ompgw/<provider>/<model>` with an `ompgw` provider merged into
  `~/.pi/agent/models.json` and `OMP_GATEWAY_TOKEN` + `CEL_SESSION_ID` set in
  the pane - the session id is what the gateway balances accounts on, because
  pi sends no session identity of its own. A gateway that is down, or a
  provider with no usable credential, vetoes the profile before a pane spawns;
  `cel doctor` carries one line about it and the QUOTA view and the dashboard
  list the accounts
- **Services are declared, watched and reachable**: `cel services` lists the
  services a workspace declares and every `cel-fanout try` preview as one
  model - state (`up`/`healthy`/`down`), port, pid, resident memory, uptime and
  the URL that reaches each one from a laptop - and
  `start|stop|restart|logs|open <name>` drives them through a herdr pane
  (a `services:` entry with only a name and a url stays valid, and is
  observe-only). The steward probes every service declaring `health:` and
  raises ONE rolled-up blocker after two consecutive down ticks, clearing it
  when the service answers again; `restart: auto` restarts it once first and
  says so. The dashboard gains a reverse proxy -
  `http://<tailnet-ip>:<dash-port>/svc/<port>/…`, WebSocket upgrades included,
  known ports only, control token required - so a loopback dev server or
  preview is reachable from the laptop at all; `cel-fanout try` prints that URL
  as its last line. The console gains a SERVICES view (`S`) and the router
  three intents (`open_service`, `service_ctl`, `service_logs`)
- The console can be routed by a **decision model**: `console.router` in
  `~/.local/share/cel/config.yaml` sends the sentence to a classifier that
  picks one of ten intents (`fleet`, `product_status`, `why_worker`,
  `message`, ...) and returns a confidence with it - the console fills the
  slots from the fleet it already holds, so the model never writes a command
  line. 0.4 s against 6.5 s for the chat model on "what is happening with
  bundle"; below `min_confidence` the top three intents become options with
  their probabilities; anything it cannot place falls through to the chat
  model, as does a router that is down. `--no-router` and
  `console.router.enabled: false` bypass it
- `agents.yaml` knows the `typesafe` provider (`TYPESAFE_API_KEY`), and
  OpenRouter's decisions endpoint is derived from its chat one
- Update awareness by **commit**, not only by tag: an `update.channel` of
  `main` or `release` in `~/.local/share/cel/config.yaml` (`cel update
  --channel`), a build string of `v0.2.0+31 (d43910c, main)` everywhere, and a
  `cel update --check`, steward item, dashboard chip and `cel doctor` line
  that say how many commits are new and what they were
- **Memory, everywhere state is read**: `cel fleet` carries `rss_mb` per
  worker, unit and orchestrator pane plus a `box` block, prints `mem` per
  product and the box's headroom on its head line; the console shows it per
  row with the free figure on the status edge and `s` to sort a unit's workers
  by memory; the steward raises one blocker under 10% available naming the
  largest trees and tells an orchestrator about a worker over
  `CEL_MEM_WORKER_WARN_MB` - reporting only, never killing
- The console has a **unit view**: Enter or a double-click on a fleet row opens
  one product whole - its orchestrator with `[focus]` and `[message]`, every
  worker with ticket, state, quiet time, verdict, ahead count and PR, the open
  decisions and the recent mail
- The console has a **worker view**, the answer to "why": it runs `cel-fanout
  why <id>` on open and offers `[prompt]` `[focus]` `[collect]` `[release]`
  `[try]` `[why again]` - the ones that change state as proposals on the
  command line
- Every list in the console is a place you can enter: the inbox tail is
  selectable (Ctrl+T cycles fleet → waiting → inbox), and a message from a
  worker or an orchestrator carries `[worker]` / `[unit]` to its page
- The console never shows raw JSON: `cel fleet --json`, `cel-fanout status
  --json`, `cel inbox open --json`, `herdr agent focus` and `herdr agent get`
  are rendered as the tables and lines the panels use, anything else that
  parses as JSON as `key: value`, and `r` toggles `[raw]`
- The console's model can answer from state: `ANSWER: <text>` for questions the
  fleet document (which now carries `workers_list`) already holds, with nothing
  run; `cel console --render-once --unit <product>` and `--worker <id>` print
  the two new views
- `cel fleet --json` carries `units[].workers_list`: every worker still worth
  acting on (`running`, `finished`, `collected`) - id, ticket, repo, branch,
  shape, state, live agent status, `quiet_secs`, stall `verdict` and
  `severity`, `ahead`, PR, alias, pane and
  worktree - so the `stalled` count can be read back to its rows, and
  `cel-fanout status --json` prints the same objects for one workspace
- `cel-fanout why <id>` says why one worker is stuck in words: verdict, quiet
  time and work at risk, the pane's last 25 lines, the last five messages it
  sent, its PR, and the one next act
- The steward says a thing once: every item it raises carries a condition key
  (`cel inbox send --fp`), so a repeat becomes an update on the item already
  open - `cel inbox open` shows `(×12, last 17:35)` - and the steward resolves
  its own item, with a `cleared:` line, when the condition stops being true
- `cel inbox resolve --all [--from x] [--matching s] [--kind k] [--older-than h]`
  cleans a mailbox in one line, and `cel inbox open --all-workspaces` shows
  everything waiting on one reader across every registered workspace
- `repos[].seed` in `workspace.yaml` - the gitignored local files every
  worktree needs to run (symlinked, or copied with `copy: true`), placed by
  `cel-fanout delegate`/`scout`/`spike` before the worker starts and named in
  its first prompt
- `cel-fanout try <id> [--stop]` - runs a ticket's branch from its own worktree
  on a free block of ten ports (`repos[].preview`, `CEL_TRY_PORT_BASE`) in a
  pane of its own, prints the url, and is stopped by `--stop` or by `release`;
  `cel-fanout status` gains a `TRY` column
- The console's fleet panel counts PRODUCTS, not repos, and a declared product
  names the repos it bundles - `widget (widget-core, widget-web)` - as
  `cel fleet` already did
- `cel console` edits like a shell: a real cursor (←/→, Home/End, Ctrl+A /
  Ctrl+E), Ctrl+W / Ctrl+K / Ctrl+U, a history walk filtered by the prefix
  already typed, and Ctrl+R for a history picker you can type into
- The console's status message and its key legend are two lines: the status
  clears itself after 8 seconds (`--status-secs`, 0 = never) and can no longer
  overwrite the bindings; the OUTPUT panel keeps the last command's full
  output, scrolls, and folds away on Ctrl+L
- The console takes the mouse: click to select, double-click for the panel's
  primary action, the wheel scrolls the panel under it, and the detail view's
  `[resolve]` `[reply]` `[go to]` are buttons. Mouse mode is turned off on
  every exit path, including SIGTERM and a crash
- A decision opens into a detail view that is a place rather than a popup: the
  whole message, its sender and workspace, and the thread around it - same
  `ref`, or the same sender within the hour - with `r` resolve, `p` reply and
  `g` go to
- The console's model offers options and may answer with a chain: a miss is
  asked a second time for up to three candidate commands each with a reason,
  and a sentence that needs a sequence comes back as up to five commands that
  run in order, stopping at the first non-zero exit - and every line of a chain
  passes the console allowlist BEFORE any of them runs, so a refusal on the
  second line cannot arrive after the first has changed the box. Nothing runs
  without the operator's Enter
- F1 (and `help`) lists every binding by panel; the layout survives a resize
  with the command line and its two lines always visible
- The console runs on the terminal's alternate screen, like `htop` or `vim`:
  it fills the terminal, draws nothing into the scrollback and restores the
  screen you had on the way out
- `cel console` - Celestial's own terminal interface, built with ink: the
  fleet table, every open decision addressed to root across all workspaces,
  the inbox tail and a command line, in one full-screen pane that is not an
  agent. `--render-once` prints the panels as plain text and exits
- A translator wired into that command line: type a sentence and a small model
  (`console.provider` in `~/.local/share/cel/config.yaml`, endpoints from
  `agents.yaml`) proposes exactly ONE command, which runs only when you press
  Enter again. No key configured means no translation and a console that is
  otherwise fully useful; the model never executes anything
- `cel console` runs commands through the same `lib/guard.sh` allowlist the
  agent console is held to - one policy, two surfaces
- `cel setup` installs the console's pinned UI dependencies with
  `npm ci --ignore-scripts`; `cel doctor` reports them missing
- `cel update` is a real upgrade path: it lands on the newest **release tag**
  (never main's tip), records the previous build, re-applies everything the
  installation touched (links, claude settings, `ws sync`, dashboards, pages),
  then runs `cel doctor` and offers a way back when it is red
- `cel update --check` - installed/available versions plus only the changelog
  sections you have not got yet; exit 1 when behind, so scripts can test it
- `cel update --rollback` - reset to the recorded previous build and re-apply
- `cel dash --restart` / `cel pages [--public] --restart` - stop this
  workspace's (or this tier's) server and ensure it again, so an update does
  not leave the old code serving
- The steward records an available release in
  `~/.local/share/cel/update/available`; the dashboard build chip reads that
  file per request and shows `update available vX → cel update`
- Listing after an update of long-lived agents still carrying the previous
  build's role prompt and guard hook
- README "Give this to your agent": one pasteable prompt block that installs
  and starts the factory through the reader's own coding agent.
- README factory vocabulary table: ticket, verdict, land, steward, console.
- README rows for `cel fleet`, `cel run console`, `cel run orchestrator
  --product`, `cel-fanout spike` and `cel update --check/--rollback`, and the
  console's `cel inbox watch --all-workspaces` background watch.
- **One gate at a time: the suite takes a box-wide lock.** Six concurrent
  `tests/run.sh` runs took this box to a load of 190 and every suite past its
  timeout; the worker cap bounds how many workers exist, not how many gates
  run. The runner now queues on an exclusive `flock` (`$CEL_SUITE_LOCK`, else
  `$XDG_RUNTIME_DIR/cel-suite.lock`), naming the holder while it waits and
  printing how long it waited; `--no-lock` and `CEL_SUITE_LOCK=none` opt out,
  a filtered run does not. `cel-verify` queues on the same lock, starts its
  `--gate-timeout` clock only after acquiring it and records
  `gate.waited_secs`; `cel-fanout why` reports a queued worker as queued
  rather than quiet; and the steward raises one rolled-up status when the lock
  is held past `CEL_SUITE_HOLD_WARN_SECS` (30 min), clearing it when the lock
  is free. Nothing is ever killed to take the lock.
- **A service can belong to the box.** `~/.config/cel/services.d/` (one `0600`
  JSON file per service, the same shape as a `services:` row) declares services
  no workspace owns, and every consumer — `cel services` and its
  `start|stop|restart|logs|open`, the steward health sweep with `restart: auto`,
  the dash proxy, the console and the fleet JSON — sees them as rows with
  `workspace: "box"`; `cel services` run from outside every workspace now
  answers with them instead of refusing. `cel gateway install` writes the auth
  broker and gateway there and starts them through the normal path, so the pair
  that ran unsupervised for a day is watched; `cel gateway status` and
  `cel doctor` say whether anything is watching. `env` values whose key looks
  like a credential render as `***` wherever a row is drawn.
- Console: steering an orchestrator from the TUI. `tell <who> "…"` now
  resolves past `<product>-orch` - a product, a workspace with one product, a
  repo inside one, or a name only the herdr roster carries - and a workspace
  with two products is asked about rather than guessed. When the addressee's
  pane is live the console sends the mail AND prompts the pane to read it
  (`sent to <p>-orch (pane live, prompted)`), then watches that mailbox for up
  to `console.reply_wait` seconds: the reply's first line lands in the status
  and Enter opens it whole. `nudge` reaches orchestrators as well as workers,
  and `talk <p>-orch` (`t` on the orchestrator row) wires the command line to
  one pane - each line a `herdr agent prompt`, the pane's last 40 lines
  refreshed beside it - until Esc.
Orphans: what the plane started and nobody owns any more gets reaped.

A walk of this box found around a gigabyte of processes with no owner at all,
all reparented to init: thirteen `cel inbox watch` trees from consoles that
had exited, fifty-six test fixtures whose worktree had been deleted nine days
earlier, 173 bare pane shells on ptys whose pane was gone, and gate runners
whose suite had been killed. None of it was visible anywhere, because the
memory sweep groups by pane and these have no pane.

- The console now kills its watcher's whole process group on every exit path,
  and the watcher takes `--parent <pid>` and leaves on its own if that pid is
  gone.
- The test runner kills anything still sitting in the run's own `TMPDIR` at
  exit, which catches a fixture that escaped its test's process group.
- `cel gc --orphans [--dry-run]` finds and reaps the four classes; the steward
  does it once a tick and reports one rolled-up line (`reaped 6 orphans
  (2 watchers, 3 fixtures, 1 shell), 410 MB`) only when it took something.
- `cel doctor` names them in one line, `cel fleet --json` carries
  `box.orphans`, and the console's box line shows the count when it is not
  zero.

Nothing under a live herdr pane, no box service, no auth broker or gateway,
no Claude daemon and nothing belonging to another user is ever a candidate; a
pane list that cannot be read keeps every shell.

A box service is identified by IDENTITY, not by its name appearing in an
argv where it never appears: each `services.d` declaration is resolved to the
pid listening on its port or the pid its state file records, and that tree is
excluded. The cmdline test is only a second line of defence, and it matches
the line the gateway actually launches (`omp auth-broker serve --bind ...`).
- Liveness: the steward asks what a pane is DOING, not only how long it has
  been quiet. A candidate - a worker herdr calls `working` whose pane text has
  not moved in five minutes, one it calls `idle`/`done` while the ledger says
  running, or one the marker rule already caught - gets one decision request
  carrying the last 40 pane lines and three facts, and comes back as
  `working` / `waiting_on_input` / `looping` / `crashed` / `finished` with a
  confidence. `looping` and `crashed` are reported at any age instead of
  waiting out the three-hour quiet timer, `waiting_on_input` after 15 minutes,
  `finished` while the ledger still says running.
- It REPORTS. Nothing it answers can kill, release or re-prompt a worker, and
  the marker and quiet timers still stand on their own: no router, no key, a
  failing endpoint or an answer below `liveness.min_confidence` (0.6) all leave
  the box behaving exactly as it did before.
- `cel-fanout why <id>` says it in words, with how much longer the timer alone
  would have taken. `cel fleet --json` carries `activity` and
  `activity_confidence` per worker, and the console's `live` column shows both
  words when the runtime and the pane disagree (`working!loop`).
- New config block `liveness:` (`enabled`, `model`, `min_confidence`,
  `still_secs`, `wait_secs`, `lines`), defaulting on when `console.router` has
  a key. `cel doctor` says whether it is on and which model answers.
- `cel fleet --json` carries `mail: {to_root_unread, oldest_secs, reader}` per
  workspace, `cel doctor` names a root mailbox nobody is reading, and the
  steward raises one rolled-up, self-clearing `blocked` item per workspace
  when an unread escalation is older than `CEL_ROOT_UNREAD_SECS` (3600) with
  no live reader.
- `cel inbox open --for root --ranked`, the console digest and the dashboard
  card order the unread by a decision model's level and show the top
  `inbox.top_n` (3), then `and N more`. The model supplies only the level;
  counts, ages, ordering, the cut and the per-id cache are the code's, and
  below `triage.min_confidence` (0.6) a message keeps its kind's default rank.
- `cel ws up|down|reset|status`: a workspace declares its shape in
  `workspace.yaml` (`layout.orchestrators`, `layout.panes`) and the plane can
  put it back. `up` reconciles - herdr workspace, declared panes in order, an
  orchestrator for every product that wants one - and is idempotent; `down`
  stops the agents it owns and closes its PANES, refusing over work that is
  neither pushed nor landed; `reset` is down-then-up; `status` is `up
  --dry-run` in table form. Nothing here removes a worktree or writes the
  delegation ledger.
- A nameless agent is a fault, not an absence: `cel ws up` renames a live
  agent in a product's own directory to its canonical alias, `cel fleet`
  reports `orch unnamed` instead of `-`, `cel doctor` names the directory, and
  `cel run orchestrator` refuses to start a second orchestrator over a live
  one (named or not) without `--force`.
- The console gains `workspace_up`, `workspace_down` and `workspace_reset`
  intents - the last two always proposed, never auto-run - and `u` / `U` on
  the unit view.
- **The work item** — the thing being made, not the machines making it.
  `cel work` is the board: every item grouped by stage (`building`, `review`,
  `landing`, `merged`, `released`, `ready`, `backlog`) with who holds it, its
  age and the next action a person would take; `cel work <key>` renders one
  item and its whole event list; `cel history` is the vertical timeline —
  ticket, worktree, PR, mail, reviewer and AFK events grouped per item and
  drawn with a spine. `--json` of each is the frozen shape the console and the
  dashboard render.
- **The box is a resource the factory spends: measure it, then sweep it.** The
  plane measured its machines and never its floor space, so the first symptom
  of a full disk was a build failing rather than a dashboard going amber, and
  the only remedy anyone had was a human remembering to run `docker system
  prune` by hand — the word "docker" appeared nowhere in the tree, while
  Docker alone held ~74G of a box at 144G of 193G. **`cel box space`** now
  prints one measured table of what is large, what of it is reclaimable and
  which of three classes it is in — **ours** (`~/.cache/cel`, scratch),
  **regenerable** (docker images, build cache, bun/npm/uv/pip caches and
  browser drivers) and **someone's** (restore dumps, dated backups) — sorted
  by reclaimable bytes rather than total, because a 15G dump nobody may touch
  is less interesting than 8.7G of build cache. Every number is measured, not
  remembered: there is no cache file. `--json` emits a frozen
  `{paths:[{path,class,bytes,reclaimable,age_days}],docker:{…}}`. **`cel gc
  --box`** runs the sweepers after the existing worktree pass (a freed
  worktree may be the last reference to a cache entry), on fourteen days for
  docker images and build cache — the working set is three to six days old and
  superseded build tags are two weeks and older — with exited containers taken
  with no age filter and base images exempt regardless of age. The rule the
  whole feature encodes: **a sweeper may delete only what the box can make
  again.** Class-three paths are never swept by any flag; they are a number on
  a report with an age and a suggestion. No sweeper takes a path from argv —
  each reads a declared policy table — and `--dry-run` covers the new work
  exactly as it covers the old, with no "prune and report" path. `cel gc` is
  unchanged by default, its summary line gains freed bytes per class, and a
  class that found nothing says so rather than vanishing. The steward sweeps
  on a six-hour cadence and records the bytes it has freed; `cel doctor` warns
  below a free-space floor, naming the largest reclaimable class and the
  command that clears it.
- `cel run reviewer` now records the reviewer it starts (repo, PR, pane,
  agent) in box state, and a second call for the same PR reuses that pane
  instead of splitting another one.
- `cel gc` gained a reviewer pass: a reviewer whose pull request is merged or
  closed has its pane closed and its row dropped. An open PR's reviewer is
  left alone however old it is, a working reviewer is never closed, and a PR
  whose state cannot be read keeps its reviewer and says which one. The
  summary counts reviewers closed beside worktrees removed.
- `cel box space` reports the reviewer panes and the RSS they hold, and `cel
  doctor` names them when they are the largest reclaimable thing on the box.
- The gc pass and the report both DISCOVER reviewer panes by the name
  `cel run reviewer` gives them, so reviewers that predate the registry are
  swept and measured too; a surviving unrecorded reviewer is adopted into the
  registry. The registry is an index, not the definition of existence.
- Every read-modify-write of the reviewer registry is held under a lock on
  the file, and `cel gc` writes back a MERGE of what it established (panes
  closed or gone, live panes it adopted) rather than a stale snapshot - a
  `cel run reviewer` landing mid-sweep is no longer erased.
- **`cel afk` — away from keyboard.** Measured over 2026-09-20/22, what stopped
  the factory overnight was never code: an approved, green, gate-verified PR sat
  36 hours on two bot-review threads that needed a human to type a reply, that
  same PR was rebased five times behind other merges, two PRs paused on "shall I
  land this?" when the workspace already said `merge: self`, and documented
  follow-up work went undispatched waiting for a nod. `cel afk on [--until
  <when>] [--reason <text>]`, `cel afk off`, `cel afk status [--json]` and `cel
  afk log [--json]` turn on a mode that removes that pause and nothing else.
  **AFK changes who decides, never what is required**: a PR still needs its
  review, its green gate and its verdict.

  While it is on, exactly four acts are pre-authorised, each gated on its own
  evidence — resolve a bot review thread whose finding is fixed in a pushed
  commit AND confirmed by a reviewer verdict recorded *after* that commit (the
  reply states what was fixed and cites the commit); land a PR that is approved,
  green, gate-verified, mergeable and fleet-authored; rebase and retry a PR that
  was mergeable before another merge pushed it behind, with no new work; and
  dispatch a follow-up a reviewer or scout wrote down, quoted in the spec,
  within the worker cap and above the quota floor. Everything else waits, and
  the refusal is named rather than silent.

  The two mutating call sites go **through** that door before they act, with
  evidence they proved themselves: `cel-fanout land` asks it after its own
  checks and before `gh pr merge`, and `cel-fanout delegate` asks it before a
  worktree, a pane or an agent exists. While AFK is on, a spec is dispatched
  only if it names where its finding came from - a `Finding-from: reviewer
  <alias>` (or `scout`) line and the finding quoted as a `> ` line - and
  `cel afk resolve-thread` and `cel afk rebase-retry` are the entry points for
  the other two, the latter deriving its evidence from git and the PR rather
  than from whoever called it. `cel afk on --scope <workspace>` confines an AFK
  to the workspace it was armed in.

  AFK will not merge anything red, unreviewed, or whose gate produced no
  verdict; will not resolve a finding that is not fixed or not confirmed; posts
  nothing to GitHub beyond that one named thread-resolution case; will not act
  in another orchestrator's workspace; and will not change branch protection,
  repository settings or any policy — including turning its own scope up.

  State lives in the box's own state dir, because sleeping is a property of the
  operator and not of one product, and `--until` expires on its own: a past hour
  reads as off everywhere. Every autonomous act is recorded with what it was,
  which pre-authorisation covered it and when, and the log survives a restart —
  so "what did you do while I was asleep" has one answer to read. The console's
  status edge shows AFK and until when (and `AFK EXPIRED` when the hour has
  passed), its log is on the same screen, and both `cel doctor` and the steward
  report an AFK left on past its `--until`.
- A workspace can act as its own GitHub account: `github: {user, ssh_host}` in workspace.yaml gives its panes and every workspace-scoped plane `gh` call that account via a per-process `GH_TOKEN` (never `gh auth switch`), refuses when the account is not logged in, clones over the SSH alias, and is checked by `cel doctor` (CEL-70).

### Changed
- An orchestrator owns the STATE of its own checkout, never its authorship:
  `git checkout <ref>` / `git switch <ref>` between existing refs, `gh pr
  checkout <n>`, `git branch -d`, and `gh pr edit --add-label/--remove-label`
  are now allowed, while creating branches, discarding paths and reaching into
  another checkout stay denied
- `cel run console` now requires `--agent`: the console is `cel console`, and
  the Claude pane survives behind the flag. A bare `cel run console` exits 2
  and names the new command
- The console's vocabulary table lives in `tools/console/vocabulary.md` and is
  included by both consoles, so the TUI's translator and the agent role file
  cannot drift apart
- `cel fleet` counts by **product**, not by repo: one row per product with
  its repos named, `<product>-orch` liveness, and the worker cap
  `cel-fanout delegate` actually enforces (`products[].workers`, else
  `policy.workers`); `--json` units gain `repos` and `declared`
- `cel update` refuses a dirty tree or a checkout that is not on `main`: the
  plane's developer moves with git, everyone else moves with `cel update`
- The documented shape of the factory is console -> orchestrator per product
  -> stations (worker, scout, spike, reviewer); the old root -> project
  orchestrator -> worker tier diagram is gone.
- A workspace is documented as configuration and grouping scope, not a tier;
  a product holding all its repos is "the workspace orchestrator".
- `cel run root` is documented and prompted as optional; `root` remains the
  mailbox name for "the top, whoever is listening".
- Quick start boots `cel run console` and explains when to prefer `cel run root`.
- The review loop section documents the ledger verdict (`cel-fanout review`)
  and `review.post: inbox | github`, not GitHub approval alone.
- The inbox section documents the per-reader cursor and `--all-workspaces`.
- `core/roles/console.md` no longer says the `--all-workspaces` flag is
  pending, and drains every workspace in one command.
- A changelog entry is a **file, not a shared line**: a pull request adds
  `changelog.d/<branch>.md` (first line the category heading, the rest the
  entry) and `cel release` assembles the fragments into the version's section
  in Added / Changed / Fixed / Removed order, file-name order within, deleting
  them in the same commit and leaving `[Unreleased]` empty. Seven open PRs each
  editing the same three lines under `[Unreleased]` meant a rebase and a suite
  run per PR per merge; nothing collides now. A hand-written `[Unreleased]`
  entry still ships, and CI fails a PR that leaves that section non-empty
- `cel-fanout release --all` now takes only `landed` and `abandoned` rows;
  `--merged` adds GitHub's merged rows to the same pass. Every `--all` run
  prints its plan first, naming each skipped row with its state, and
  `--dry-run` stops there. A "left as-is" line no longer precedes a removal:
  that path returns before anything is touched.
- Releasing the last worker under a `<repo>/workers` container keeps the
  container (recreating it if herdr closed it), `cel-fanout status` reports a
  worker whose container is gone as `detached`, and `cel doctor` warns when a
  workspace has worker worktrees on the roster and no container.
- `cel-fanout collect` and `land` apply the workspace `env:` block before
  running `cel-verify`, so a declared `CEL_VERIFY_GATE_TIMEOUT` reaches the
  gate; `--gate-timeout <secs>` on either command overrides it.
- `collect` and `land` no longer hold the delegation-ledger lock while the gate
  runs: the lock is released before `cel-verify` and retaken to write the
  verdict, so other `cel-fanout` commands are not stuck behind a gate queueing
  on the box-wide suite lock. If the row changed state while the gate ran,
  collect refuses and says to re-run rather than writing a stale verdict.
- A wait for the suite lock past `CEL_SUITE_WAIT_WARN` (120 s) says so once
  more, naming the holder's pid, start time and directory - or saying the
  recorded holder is dead and the lock has leaked. The lock file's first line
  carries the holder's cwd for it.
- `cel doctor` prints one line when the suite lock is held by a pid that is
  gone, or by a process that is not running from a checkout.
- `cel release <product> <version|bump>` cuts a release of anything the factory makes: a repo declares its `release:` workflow, input and accepted values in `workspace.yaml`, and the plane dispatches it, follows it and reports the tag and Release. A caller without write access is refused locally, by name, instead of taking a 403 from GitHub at the last step; `cel release status [--all-workspaces] [--json]` reports every releasable repo. The old `cel release <x.y.z>` still works where the workspace has exactly one releasable repo.
- The console answers instead of transcribing. Ask about a stalled worker and
  you get three lines and a counted summary rather than forty rows: the
  decision model picks which rows matter and how urgent each is, the console
  computes every number from the fleet JSON, and the chat model writes the
  English. `a` (or `r`) still shows the whole transcript.
- One request now carries every question the router asks - the intent, the
  workspace, the product, whether it is destructive and whether the state can
  answer at all - because the decisions endpoint evaluates them in parallel.
- Confidence routes instead of gating: `console.router.run_confidence` (0.75)
  proposes as before, `propose_confidence` (0.5) proposes with the intent
  named, and below that the console asks one question back built from the top
  two intents. A destructive sentence is proposed however sure the model was.
  `min_confidence` still works and is read as `run_confidence`.
- New console config keys, all defaulted in code: `console.rows_inline` (6)
  and `console.summary_timeout` (4 s).
- Mail to `root` is reserved for `escalation`, `decision` and `blocked`.
  Ticket status is the ledger's job (`cel-fanout status`), and the
  orchestrator role files say so: one instruction accounted for 466 of the 553
  messages one root mailbox took in nine days. `cel inbox send root --kind
  status` warns and still sends.
- An `escalation` raises a desktop notification, as a `decision` and a
  `blocked` already did. It is by definition the kind that cannot wait.
- The dashboard partitions box-level material out of a workspace's own: the
  services panel lists this workspace's services, and anything tagged `box` -
  plus the subscriptions, which are box-level in their entirety - moves to a
  `Box` panel drawn on exactly one dashboard (`dash.box: true`, defaulting to
  the registry's first workspace). Every other dashboard shows one line
  naming that URL. One broker and one gateway rendered on four dashboards
  read as several; there is still no box-wide dashboard.
- The delegation ledger records **every** state transition as
  `history: [{state, at, by}]` — a row carried one timestamp, so nothing said
  when work was collected, landed or released and no timeline could draw it.
  Rows written before this read back a synthesised history and are never
  rewritten on disk.
`cel fleet` is a batch, not a fan-out. The whole-box read computed every
worker row with five `jq` and up to twelve `git` processes of its own, 278
`jq` and 112 `git` on a single console render, with 62% of the wall clock in
system time - fork and exec for crumbs of work that no network was ever
involved in. The ledger is now read in one `jq` per repo, joined against the
herdr roster in the same program; every git question about a worktree is one
`for-each-ref`, one `status` and at most two `rev-list`, asked once and shared
between the row and the unit's counts. The console's two serial loops over
`cel inbox open` and `cel services` now run their calls together, and a
workspace whose call fails still leaves the others rendered.

The document is unchanged, field for field and in order, and the suite holds
a ceiling on EVERY process the read starts - not just the two tools this work
set out to reduce - with PATH replaced by a counting shim so nothing can run
uncounted. An unreadable roster, or one whose shape says nothing about
agents, is now an ABSENT roster - `-` against the observer - and never
`gone` against every worker on the box. On the fixture: 185 processes for
three rows and 239 for twelve, down to 158 and 176; five processes per extra
row become one.
- `cel quota` and every surface that draws it now read `omp usage --json` when
  omp is on PATH: it holds refreshed OAuth per account, so all three Anthropic
  logins, both ChatGPT ones and opencode are listed, each window comes from the
  authoritative `.limits[]` (scoped windows keep their model's label instead of
  being dropped), and a null window is skipped rather than drawn at 0%. A box
  without omp falls back to the per-provider endpoint reads exactly as before.
- `extra_usage.disabled_reason` with spending disabled now reads "top-up is
  off" rather than "out of credits" on a healthy account.
- `opencode` is a declared provider: plan windows, no credit balance.
- Credit stays workspace-scoped, and says which kind of unknown it is - "no key
  in this workspace" (where you are standing) or "asked and could not tell" (a
  fault) - in `cel quota`, in its `--json` as `balances[].state`, and on screen.
- The console QUOTA page, the console status edge and the dashboard's
  subscriptions card draw each window as a bar sized from the `used_pct` that
  already existed, degrading to plain text on a terminal too narrow for one.
- omp on PATH that answers nothing usable now says so once on stderr and falls
  back; a box with no omp still falls back in silence, as before.
- `cel-fanout delegate` confirms the agent ACCEPTED the dispatch, not merely
  that a pane exists. A prompt that `herdr agent prompt` reported as sent but
  the agent never took is re-submitted once; if the pane is still at zero
  context with the text below its divider, the row is recorded `unconfirmed`
  and the worktree is KEPT - re-prompting that alias is the whole recovery.
- The liveness classifier learns three silences, read from the pane text
  alone with no router and no key: `unstarted` (a prompt sitting in the
  composer, never submitted - the shape is the same for a worker pane and a
  reviewer pane), `erroring` (a repeated terminal error with no turn between
  prompts - the CLASS, not any particular message) and `throttled` (a
  provider refusal that no turn followed, carrying the 5h window's reset time
  where `cel quota` knows it). A pane whose own output merely mentions a rate
  limit - the quota suite, a diff, a grep - is not throttled. They report;
  nothing here kills anything.
- The steward names the BLOCK instead of a missing worker: a red gate or
  changes-requested branch whose worker is throttled, erroring or unstarted
  says so and explicitly does not ask for another worker, and a throttled
  worker never becomes a nudge loop against the window it is waiting on.
- `cel-fanout status` shows the silence in the live column (`idle!unstarted`),
  so `running` at `+0` commits with a dead pane no longer reads like progress;
  `cel fleet --json` carries `silence` and `silence_reset` per worker.
- `fleet_alias_undeliverable` reports mail addressed to an alias with no live
  pane, instead of accepting a message that goes nowhere.
- Not yet covered: `cel run reviewer` still launches without the acceptance
  check, and reviewer panes are not in the delegation ledger, so an unstarted
  reviewer is recognisable by the classifier but nothing is reading its pane.
  That wiring is in `lib/run.sh` and the reviewer store, neither of which this
  ticket owns.
- **One place a secret lives: the workspace's gitignored `env.local`.** The
  setup skill, `cel help`, `cel setup`'s closing hints and the doctor checker
  now all name and read exactly that one location; `~/.zshenv` is documented
  only for a box-wide credential no workspace owns, and says why.
- **`cel doctor` now evaluates each registered workspace's `env.local`** - it
  is sourced, i.e. executed, in a subshell, to judge that workspace's `setup:`
  checks. Previously only `cel ws env` / `cel shellenv` did that, so a
  diagnostic command now runs user-authored shell from every workspace on the
  box. The subshell contains it and nothing leaks back into doctor or into the
  next workspace.
- `cel run reviewer` now opens the pane in a checkout of its own, a detached
  git worktree at the pull request's head, instead of the orchestrator's
  working copy. The reviewer's role body names the head SHA it is reading, the
  base ref it compares against, and the command that tells it the head has
  moved since the pane started.
- A reviewer's checkout is released when the reviewer is: `cel gc` removes the
  worktree as it closes the pane, and also when a recorded pane has gone by
  other means.
- `cel doctor` reports any workspace repo checkout that is behind its remote
  default branch, with the count and the command that fixes it. A checkout
  with no remote, or one that cannot be fetched, is reported as UNKNOWN rather
  than passing silently.
- `cel-verify` now has four outcomes, not three: pass, fail, timed out, and
  **produced no verdict**. A gate whose process was killed before it reported
  an exit status never said the code was wrong, and is no longer recorded as a
  failure. `verdict.json` carries `gate.outcome`, `gate.code` and, when the
  code is absent, `gate.no_verdict_reason`; the summary line renders
  `gate:NO-VERDICT` and the exit status is 3.
- The gate writes its own exit status down at the moment it has one, so a suite
  that already printed "N passed, M failed" keeps its verdict even when the
  process group it shares with its own cleanup is torn down afterwards.
- A gate that printed nothing at all is recorded as such (`gate.output_empty`)
  instead of storing an empty tail and moving on - that silence was the only
  visible signature of the bug.
- `cel-fanout land` refuses a no-verdict gate by name rather than as a red one,
  and `--gate-from-ci` is available for it on exactly the terms it is available
  for a timeout: every check the base branch is protected by, green on that
  head. `collect` warns without calling it a failure, and `status` shows `NV`.
- `cel ws`: the orchestrator mode for a product is resolved in one place
  (`ws_orchestrator_mode`), and `up`, `up --dry-run`, `status` and the steward
  all read it. A workspace declaring `layout: <string>` (a herdr layout id) no
  longer implies `orchestrators: manual` by accident - a string layout, an
  object layout without the key, and no layout at all all mean the same thing.
- `products[].orchestrator` now takes precedence in EITHER direction: `auto`
  can turn an orchestrator on under a workspace that is not auto, as well as
  `manual`/`none` turning one off.
- `cel ws status` and `cel ws up --dry-run` say WHERE the effective mode came
  from - product, layout or default - and `status --json` carries it as
  `source`.
- The steward no longer reports that an orchestrator "will not start" when the
  resolved mode is manual; it says the product is set to manual and takes any
  stale fault down.
- `cel gateway` now runs on CLIProxyAPI instead of omp's broker and gateway:
  one supervised box service that is both the credential vault and the
  loopback OpenAI/Anthropic surface, with session affinity switched on (it
  defaults to off, and off means a worker switches account mid-conversation),
  an unauthenticated `/healthz` probe, plain model ids, and a `0700` auth-dir
  in the box state directory. `cel gateway status` lists accounts by reading
  those files, so it costs no quota; `cel gateway login <provider>` drives the
  proxy's own OAuth and prints the instruction rather than hanging off a TTY.
  omp stays installed as an agent runtime.
- **`cel quota` asks each account for its own usage, from the one vault.**
  CLIProxyAPI is now the single credential store on the box, and it cannot
  report usage — it removed usage statistics in v6.10.0 and keeps only a
  snapshot of the last response's rate-limit headers, which is empty for an
  idle account. What it does keep is each account's OAuth token, one file per
  account, so celestial now enumerates the vault and asks Anthropic and
  ChatGPT for the windows itself. One list of accounts instead of two: an
  account logged into the gateway can no longer be missing from `cel quota`.
  The rows are the shape the console's QUOTA view and the dashboard card
  already render — every account, every window, scope labels read off the
  response rather than named in code, so a scoped weekly window appears
  without a release. **celestial never refreshes a token and never calls a
  provider's token endpoint**: CLIProxyAPI owns these credentials, refreshes
  them on its own loop, and both providers rotate the refresh token on use —
  spending it to draw a usage bar would retire the one the gateway has stored
  and send the owner back to a browser. An account whose stored token has aged
  out reads `token stale - refreshed next time this account serves traffic`; a
  token the provider actually rejects reads `needs login: cel gateway login
  <provider>`; neither reads `unreadable`, which is the word CEL-49's Codex row
  wore for sixteen days. opencode keeps reporting from its own auth file, which
  the vault has never held.
- omp's `usage --json` path stays as the fallback until the new reader has
  proved itself: with no accounts in the vault, the output is exactly what it
  was. `tools/quota-compare.sh` prints both readers side by side, per account
  and per window, which is what says when omp's path can go.
- Every OMP launch Celestial makes (root, orchestrator, worker, scout, reviewer, direct, and `cel-fanout delegate`/`scout`) passes `--no-prewalk`, so a pane stays on the model its profile named instead of switching to `smol` after its first edit (CEL-68).

### Fixed
- **GC could not see a pi worker, so it reclaimed nothing.** pi rewrites its
  own argv, so `/proc/<pid>/cmdline` of a live worker is the two bytes `pi` and
  padding - and `cel gc` proved ownership by finding the role file path there.
  Every pi worker read as unidentified, which kept its whole worktree, and the
  steward journal printed `0 worktrees removed, 0 agents reaped, 36 kept` every
  tick for weeks without that looking like a fault. `cel run` and `cel-fanout`
  now mark each launch with `CEL_ROLE`, `CEL_ROLE_FILE` and `CEL_WORKSPACE` in
  the process environment, which no runtime rewrites, and GC reads those first
  and falls back to the old argv scan for panes started by an earlier build. A
  null herdr session no longer disqualifies a process that carries the mark.
  Idle agents of a runtime declaring `signal: int` (pi ignores SIGTERM) get
  SIGINT, then SIGTERM after `CEL_GC_GRACE`, then are reported `stubborn` and
  kept - GC never sends SIGKILL. The summary line now splits `kept` by reason
  (`gc: 2 worktrees removed, 1 agent reaped, 33 kept (12 live, 9 unlanded, 12
  unidentified)`), names the directories it could not identify, and `cel
  doctor` repeats the count, so a blind GC can no longer look like an idle one.
- **A subscription is where it is signed in, and every surface shows the same
  rows.** This box listed five Claude subscriptions for two logins: an account
  was named by the first six hex of its token's sha256, and pi refreshes that
  token, so every refresh minted a new "account" and a new cache file that
  `cel fleet --json` then listed. An account is now identified by the
  credential's home — `claude/pi`, `claude/claude-code`, `codex/<account id>`,
  `gateway/<provider>/<id>` — so a refresh overwrites one file, the display
  label is whatever stable field the credential carries, and pi and Claude
  Code showing the same windows are one row (`pi + claude-code`). Cache files
  that match no current identity are swept on the next read. An account whose
  usage cannot be read is a row saying `unreadable: <reason>` rather than a
  silence, so Codex stops disappearing from the console while the dashboard
  shows it. `cel fleet --json .subscriptions` is now literally what `cel quota
  --json .subscriptions` returns, gateway accounts included, and the console's
  QUOTA view and the dashboard's Subscriptions card build their rows from one
  function over that one list — the console no longer runs `cel gateway
  status` of its own
- **The suite lock no longer outlives the suite.** flock lives on the open file
  description, so every child that inherited the runner's lock descriptor held
  the lock too: one backgrounded `sleep` kept every gate on the box queued for
  eighteen minutes after the run that started it had finished. `tests/run.sh`
  and `cel-verify` now spawn every child - the source-check and
  function-listing shells, the gate, and the gate's timeout watchdog - with the
  descriptor closed, the way `lock_spawn` has done for the ledger lock since
  the same bug was found there.
- The console's INBOX tail dropped the id of the record it had just parsed,
  so a detail view opened from that pane read `id undefined` and its
  `[resolve]` did nothing, while the same item opened from WAITING resolved
  fine. The tail carries `id` (and `ref`, `fp` and what resolved it).
- A detail view computes its actions from the item's live state: an item that
  is not open shows `[reply]` and `[go to]` only, with one line saying
  `resolved <when> by <who>` or `not an open item - this is the log`. A
  resolve now reports its outcome - `resolved <id>`, or the command's error -
  instead of failing silently.
- console: the subscription edge is on all five status rows, not one. Four
  renderers called `statusRow` without the fleet document, so the usage the
  owner asked for was absent from the services, unit, worker and timeline
  views; the width now reaches `subsEdge` too, so the bar is actually drawn.
  `statusRow` refuses a missing document instead of rendering an empty edge.
- **`cel ws` no longer refuses in silence.** `cel ws sync <name>` for a
  workspace that was never registered exited 1 with nothing printed at all -
  the refusal died inside a command substitution. Every name-taking verb
  (`sync`, `push`, `env`, `up`, `down`, `reset`, `status`) now checks the name
  in the caller's own process and says, on stderr, that the workspace is not
  registered and that `cel ws add <git-url>` is what registers it. A path that
  is registered but gone reads differently again.
- **`cel doctor` reads a workspace before judging it.** Each workspace's
  `setup:` checks now run with that workspace's own env loaded
  (`ws_env_exports` in a subshell, so nothing leaks between workspaces), so a
  check for a key that is correctly sitting in `env.local` passes instead of
  printing red at a box that is set up properly. A value that is missing and
  an env that could not be read are two distinct findings.
- `cel inbox read` and `cel inbox count` no longer report "nothing" when they
  could not ask the question. A cwd outside every registered workspace is now
  a **refusal** naming `--workspace` / `--all-workspaces` instead of a silent
  empty read, an empty mailbox says which reader and which workspace it
  answered for, a `--for` name no mailbox has ever used reads differently from
  one that exists and is empty, and a reader with mail in another workspace is
  told where and how many (without moving that mailbox's cursor). `--json`
  carries the three states as `state: empty|no_mailbox|no_workspace` plus an
  `elsewhere` array.
- Naming a workspace that does not exist is non-zero however it was named: a
  cwd that derives none and an unregistered `--workspace` are one class of
  answer (`state: no_workspace`, exit 2), including for the `root`, `console`
  and `all` addresses, which previously read as an empty mailbox anywhere.
  `cel inbox count` still prints its number on stdout first.
- The console suite no longer goes red because a day passed. Its tail,
  digest and timeline are windows on *now*, and the fixtures pinned absolute
  timestamps - so the same unchanged commit passed at merge time and failed
  every run after the window closed. Fixture timestamps are now anchored to
  the moment the test sets up, and a lint fails any `ts` or `mergedAt` fixture
  that carries a frozen date.
- Box-level services start again: `herdr pane split` now requires a direction
  and a target pane, and the box-level branch passed neither, so every service
  in `services.d` - the auth gateway included - was unstartable. Box services
  now live in a dedicated `cel services` herdr workspace, found by label or
  created unfocused - never a tab in whatever workspace is focused - which
  is a target the steward's timer can use too. A refused split reports herdr's
  own message instead of "returned no pane id".
- **Inbox mail no longer lands in an omp orchestrator's composer**: console
  `tell` to a live orchestrator is `cel inbox send` alone (no `herdr agent
  prompt` tap), and `cel run` loads `tools/hooks/inbox.omp.ts` on omp root and
  orchestrator panes - it raises `ui.notify` for new mail, injects unread mail
  into the next turn exactly once, and kills its watcher on session shutdown
- **The steward no longer types into root or orchestrator panes**: PR,
  stale-inbox and open-decision nudges are inbox mail (same rate-limit keys),
  the reminder names `cel inbox read --for <who> --workspace <ws>`, and `cel
  run` exports `CEL_INBOX_ME`/`CEL_INBOX_WS` so an orchestrator reads its own
  mailbox wherever it stands
- `cel run reviewer` resolves the PR via the repo's GitHub slug (declared url, else origin remote) instead of the workspace-local name (CEL-67).
- Liveness tests no longer race the wall clock: `lib/liveness.sh` reads time through one seam (`CEL_LIVENESS_NOW` pins it for tests), and the output-age and cache-expiry tests advance a pinned clock instead of real seconds.
- steward: a PR's worker is found at the worktree the delegation ledger records (herdr lowercases worktree names), so a live worker on an uppercase ticket branch is no longer reported as "nobody on <branch>".
- Hygiene scan no longer reads `FOLLOWUPS-<yymmdd>` as a ticket; `cel-fanout land` refuses a review note carrying a ticket-shaped token the scan would reject, naming it.
- Every `changelog.d/` fragment now starts with a category heading, so `cel release` can cut again, and the release suite fails in CI naming any tracked fragment whose first line is not `### Added`, `### Changed`, `### Fixed` or `### Removed` (unknown `### ` headings are now refused too).

### Removed
- The omp gateway's `/v1/usage` read and its subscription rows: CEL-60 removes
  that gateway, so they had nothing left to read.

## [0.2.0] - 2026-09-15

First public release, published from a reviewed clean source snapshot.

### Changed
- GNU/Linux is the supported runtime; unsupported platforms refuse before
  dispatch. Fresh x86-64/arm64 installs consume explicit application releases,
  verified native checksums and exact plugin Git commits.
- External dependency overlays now require `source` and a full Git `ref`.
  Version-only declarations are rejected. Setup retains existing tools and
  unrelated plugin installations; it is not a hermetic machine-image lock.
- Installation and generation failures propagate instead of reporting success.
- Garbage collection retains dirty, unlanded, live or unverifiable work on
  every removal path. Squash-merge cleanup requires an exact merged head match.
- Idle reaping requires plane ownership, foreground-process identity and
  durable observed-idle evidence; process age alone never authorises a kill.
- Fanout lifecycle and registry writers are locked; state files are replaced
  atomically on the destination filesystem. Unknown release comparisons
  require an explicit keep/discard decision.

### Fixed
- CI's publication-hygiene scan now requires the private vocabulary (repository
  secret `CEL_PRIVATE_PATTERNS`, one regex per line) instead of running generic
  checks only, which had let two workspace names into the tree
- `cel console` under a terminal host that reports the mouse in X10 form
  (herdr) no longer types `[M !!` into the command line: X10 reports are
  decoded, and any input carrying an escape or control byte is dropped
  rather than inserted
- `cel console`: ↑/↓ move the selection; command history is Ctrl+P / Ctrl+N
  and the Ctrl+R picker (Shift+arrows never reached the console through herdr)
- `cel console` no longer says "translate": a sentence is *asked* of the
  model (`--ask` on the CLI; `--translate` still accepted), a miss shows what
  the model actually said so you can rephrase, and the prompt carries worked
  examples so "what's blocked" is plain `cel fleet`, "what is waiting on me"
  spans all workspaces, and "take me to <product>" focuses `<product>-orch`
- `cel console` no longer steals the first letter of what you type: the
  navigation keys (`j`/`k`/`f`/`o`/`r`/`w`/`q`/`i`) were bound on an empty
  command line, so "what's blocked" flipped the panel and "quit" exited. Every
  action is now a Ctrl chord (Shift+↑/↓ or Ctrl+N/P select, Ctrl+T panel,
  Ctrl+F focus, Ctrl+O dashboard, Ctrl+E detail, Ctrl+R resolve, Ctrl+U clear);
  `quit`/`exit`/`q` + Enter leaves
- `cel-fanout delegate` nests workers under the repo's own herdr workspace
  even when a product orchestrator exists (herdr only cuts a worktree of the
  repo a workspace owns, and has no parent option - nesting under the product
  pane cut a worktree of the workspace-config repo), and creates a
  `<repo>/workers` container workspace when no workspace holds the repo
- Cross-workspace credential leakage during steward ticket sweeps; HTTP
  credential headers no longer appear in curl argument lists.
- Stored feedback HTML execution and empty-inbox dashboard crashes.
- Private HTTP control surfaces now check exact Host/Origin and per-process
  anti-CSRF tokens. Built-in controls and local automation use the same gate.

### Added
- AI software factory framing and an interactive isometric dashboard floor,
  grounded in reported task, agent, PR and CI state. Blocked and unknown work
  remain explicit; approved green PRs are ready for merge, not shown as shipped.
- Behavioral regression coverage, CI source/history and credential scans,
  and an external private-vocabulary release check with no committed denylist.
- Public architecture, contribution, security and clean-history release guidance.

## [0.1.0] - 2026-09-09

First versioned release: the working control plane.

### Added
- `cel setup` / `cel doctor` / `cel update` - box bootstrap, verification, upgrade
- Workspaces: `cel ws new/add/sync/list/push/env`, workspace.yaml policy
  injection into every agent, machine-local registry (`~/.local/share/cel`)
- `cel run root/orchestrator/worker/reviewer` - role-injected agents in herdr
  panes; workspace-first layout resolution (`<ws>/layouts.yml`)
- Fanout delegation: worktrees cut from origin's real default, diverged-ref
  refusal, workers land PRs so finished work is never invisible
- Self-running review loop: per-PR reviewer panes, direct reviewer<->worker
  handoff, escalation caps
- `cel steward` + `cel gc` - proactive tick: worktree collection, idle-agent
  reaping (pressure-aware), stalled-PR nudges, unlanded-work naming
- `cel dash` - per-workspace dashboard with attention queue and agent prompt box
- `cel publish` / `cel pages` - self-hosted documents, tailnet-private with a
  per-document public tier, on-page feedback routed to the publishing agent
- Linear tickets: official Linear MCP for claude at sync + `cel-linear`
  GraphQL shim for every other runtime, lifecycle contract in the policy block
- Workspace env layering (`env:` map + gitignored `env.local`), externals
  overlay, workspace-scoped skills
- Public-hygiene test suite, MIT licence
