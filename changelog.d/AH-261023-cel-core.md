### Added
- `cel core` starts the box's coordinator: one agent pane over every workspace (pane `core`, label `celestial/core`, directory `~/.local/share/cel/core`), which reads `root`'s mailbox in every workspace. It holds cross-product priorities and blockers, reads state and code read-only, directs product agents by inbox, starts and restarts them (`cel run orchestrator`) and switches a product's mode (`cel mode`); it does not build, delegate workers, record verdicts or land PRs (role `core/roles/core.md`). It launches from agents.yaml `defaults.core` - omp on gateway Opus (`via: gateway`, the same omp route and vetoes as an orchestrator profile) - with the guard and inbox hooks and the orchestrators' retry overlay, refuses a second core while one is live, and resumes its last session: `--restart [--pane p] [--force]` relaunches it in its own pane, `--fresh` starts a new conversation.
- Guard role `core` (`CEL_ROLE=core`, or standing in the core directory): orchestrator-class (no repository or GitHub writes), and additionally refuses fan-out, landing and review verbs, starting workers, reviewers or root, `herdr worktree`, and `cel learn|release|promote|update|setup`. Its file writes are confined to its own directory. Workers and solo agents may not start core.
- Mail addressed to `core` lands in `root`, and `cel fleet`/the steward count a live `core` pane as root's reader.

### Changed
- `cel run console` is now an alias of `cel run core` (and `cel core`): it starts the coordinator, without `--agent`. The `--agent` flag is gone. `cel console` is still the TUI.
- agents.yaml `defaults.console` (claude/haiku) is replaced by `defaults.core`.
- `cel run root|orchestrator` share one resume/restart path with core (`_run_resume_resolve`, `_run_restart_in_place`); behaviour is unchanged.

### Removed
- `core/roles/console.md`, the agent console's routing-only role; `core/roles/core.md` replaces it.
