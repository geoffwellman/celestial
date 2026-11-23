### Added
- `externals.yaml` gains `npm_tools`: global npm tools that register themselves with the runtimes. The first is REA (`rea-agents` 6.10.1, MIT, morluto/rea), installed by `cel setup`.
  - The exact registry tarball is downloaded and checked against its recorded sha512 integrity before npm installs it. The package's own `npm-shrinkwrap.json` pins its dependencies. A release at or above the pin is kept, never downgraded.
  - Registration is REA's own CLI. `rea doctor --client ... --skill` runs first, and `rea setup --yes --client claude_code codex opencode antigravity omp --tool-catalog-profile hot-cold` runs only when doctor is not healthy. pi is aligned separately against `~/.pi/agent`.
  - REA reads `PI_CODING_AGENT_DIR` for omp's root and pi's root, and `OPENCODE_CONFIG` for OpenCode's file. Each call therefore pins the agent root cel launches that runtime with, and drops an inherited OpenCode overlay or omp profile. Run from inside an omp session, `rea setup --client pi` writes omp's `mcp.json` and leaves pi unregistered.
  - Doctor does not check the catalog profile, so a box already registered with another profile keeps it.
  - REA's `reverse-engineer-anything` skill belongs to `rea setup`. It is not vendored into `core/skills`.
- A regression suite shows that every Celestial writer of a runtime's user config keeps another installer's MCP entry and skill directory. This covers the link pass (`cel setup`, `cel update`), the codex marked block, the claude settings merge and trust write, agy's `hooks.json`, the OpenCode skills overlay, the OpenCode scoped launch config and the opt-in OpenCode plugin writer.

### Changed
- `agents.yaml` base tool `node` now records mise's `lts` alias instead of 24.21.0. Before this change, `cel setup` on a box without node ran `mise use -g node@24.21.0`, which overwrote a `node = "lts"` selection with an older pin. REA also needs node ^24.22.1. An installed node and its mise config are still retained, and `cel update` has no base-tool step.
