# Changelog

All notable changes to celestial. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow [semver](https://semver.org). Releases are announced on the
[GitHub Releases page](https://github.com/geoffwellman/celestial/releases) -
watch the repo (Watch → Custom → Releases) to be notified.

## [Unreleased]

### Added
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
