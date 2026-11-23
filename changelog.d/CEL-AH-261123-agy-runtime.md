### Added
- Google Antigravity CLI (`agy`) is a runtime a workspace or profile can choose. It installs from the pinned, hash-checked 1.5.14 release tarball (never the piped `install.sh`), and every launch sets `AGY_CLI_DISABLE_AUTO_UPDATE=true` so agy cannot update itself off the pin. Solo agents, orchestrators, lanes and team members can run on it, under Herdr or Rex. `--model` and the thinking level map to `--model` and `--effort`; `xhigh` and `max` clamp to `high`. A restart resumes the agent's own conversation with `--conversation <id>`. The id is taken from agy's SessionStart hook (Rex) or from Herdr's antigravity-cli integration, and cel refuses to resume an id that is missing from agy's store, because agy would otherwise start a new conversation without saying so.
- The role is a per-agent custom agent file (`~/.gemini/config/agents/cel-<agent>.md`, selected with `--agent`), never a `GEMINI.md` in a repository. That file also lists the workspace's scoped skills, so they reach this launch only. Core skills link into `~/.gemini/antigravity-cli/skills`.
- A `celestial` entry is merged into agy's global `~/.gemini/config/hooks.json` by `cel link` and on every agy launch; a launch is refused if the entry cannot be installed. It carries:
  - the celestial guard as a PreToolUse adapter (`tools/hooks/agy-guard.sh`), which uses the same classifier as the other runtimes and refuses commands even under `--dangerously-skip-permissions`;
  - the conversation id and working/idle state for Rex;
  - inbox mail, attached to the first model call of each turn;
  - a Stop hook that continues the turn when mail arrives and arms the inbox waiter.
- `cel inbox wait`: blocks until the reader has unread mail, prints a notice and exits without consuming anything. An idle agy conversation wakes only when one of its own background tasks finishes, so each agy agent keeps this command running as one. `--check` reports whether a waiter is running.
- The Hindsight MCP server (registered by the Hindsight installer's antigravity-cli target) is declared as agy's owned child for `cel gc`.

### Changed
- A workspace whose scoped skills a launch cannot carry now refuses that launch. Before this change, the launch started silently without those skills.
- A `via: gateway` profile on agy is refused. agy can reach an OpenAI- or Gemini-shaped gateway through `AGY_LLM_GATEWAY_*`, but cel does not set those variables yet.
