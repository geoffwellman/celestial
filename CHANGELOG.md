# Changelog

All notable changes to celestial. Format follows [Keep a Changelog](https://keepachangelog.com);
versions follow [semver](https://semver.org). Releases are announced on the
[GitHub Releases page](https://github.com/geoffwellman/celestial/releases) -
watch the repo (Watch → Custom → Releases) to be notified.

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
