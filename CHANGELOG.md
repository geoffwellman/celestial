# Changelog

All notable changes to celestial. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow [semver](https://semver.org). Releases are announced on the
[GitHub Releases page](https://github.com/geoffwellman/celestial/releases) -
watch the repo (Watch → Custom → Releases) to be notified.

## [Unreleased]

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
