# Requirements

GNU/Linux with Bash, GNU coreutils, `/proc`, Git, jq, Python 3 and
curl **7.55.0 or newer**. CI runs the tests and Node services on Node
**24.x**; YAML processing uses Python `yq` (the jq wrapper), not the Go
program of the same name. [herdr](https://herdr.dev) supplies panes (Rex is
optional, installed from its own apt source). A systemd user session is
required only for the optional steward timer and per-agent Rex memory
scopes. macOS and other kernels are rejected before CLI dispatch.

`cel setup` installs missing prerequisites (git, jq, curl, tar, gzip and a C
compiler) through apt when available, and Python yq through pipx;
otherwise it tells you what to install manually. Fresh application versions
and native checksums live in [`agents.yaml`](../agents.yaml), external plugin
commits in [`externals.yaml`](../externals.yaml), and Pi extension versions in
[`tools/pi/extensions.txt`](../tools/pi/extensions.txt). External overlays must
declare `source` and a full 40-character Git `ref`; legacy version-only
declarations are rejected. Node is the one base tool recorded as an alias: mise's
`lts`, which is what `cel setup` writes when node is missing. An installed
node and its mise selection are kept, and `cel update` does not touch them.

`npm_tools` in [`externals.yaml`](../externals.yaml) lists global npm tools that
register themselves with the runtimes. Only the base file is read; an
`npm_tools` block in a workspace overlay is ignored. The first is
[REA](https://github.com/morluto/rea) (`rea-agents`, MIT), a
reverse-engineering MCP server. `cel setup` downloads the exact registry
tarball and checks its sha512 integrity before npm installs it (npm runs the
package's own install scripts; REA's native binding needs one), and keeps any
release at or above the pin. A node outside the package's own `engines`
range is refused before npm runs. It then runs `rea doctor` and runs
`rea setup` only for agent roots that doctor does not report as healthy:
Claude Code, Codex, OpenCode, Antigravity and omp against omp's root, and pi
against its own - the roots cel launches them with (`CEL_OMP_AGENT_DIR`,
`CEL_PI_AGENT_DIR`). REA's `reverse-engineer-anything` skill comes from
`rea setup` and is not vendored. REA's tools can run commands, debuggers and
browsers, and write files, and **no runtime's celestial guard inspects MCP
tool calls** ([Runtimes](runtimes.md#runtimes)). `cel update` runs the
same step, so a tool missing from the active node's global root (after mise's
`lts` alias moved to a new node release) is installed there again.

**npm-global agents follow the active node.** Pi is an npm global
(`npm_package` in [`agents.yaml`](../agents.yaml)), installed under the node that
was active when it was installed. A new node release moving mise's `lts` alias
leaves its mise shim on PATH with nothing behind it: `command -v pi` succeeds
and `pi` prints `No version is set for shim: pi`. A dead shim is not a working
agent, so `cel setup` and `cel update` reinstall it under the active node, at
the newer of the pin and the release the previous node still holds, before
`cel update` runs its updater. A working agent is retained whatever its
release. `cel doctor` names every dead shim: an agent's or a plane npm tool's
is a failure with `cel setup` as the fix; any other tool's (graphite's `gt`,
for example) is a warning with the exact `npm install -g <package>@<version>`.
`cel run` (and `--restart`) refuses a runtime whose bin is a dead shim before
it stops the agent, claims its session or opens a terminal. `cel setup`,
`cel update` and `cel doctor` check in the global mise context (`$HOME`);
`cel run` checks from the launch's own directory, where a workspace's mise
config applies; when only that directory's node lacks the agent, its refusal
names the directory and node and gives the install that works there (`cel
setup` repairs only the global node). Each check is bounded (5s,
`CEL_SHIM_CHECK_SECS`): a mise that does not answer is a warning, never a
refused launch or a reinstall, and an agent `cel update` therefore skipped
makes it exit non-zero. Pinning node per
tool (mise's `npm:` backend, or a fixed node path) was not chosen: it would
write the mise config that `cel update` leaves alone, bypass the integrity
check `npm_tools` installs through, and split Pi from `pi update --self`, which
installs into the active node's global prefix.

The current pins are Claude Code 2.1.300, omp 18.14.0, pi 1.4.0, codex
0.154.0, OpenCode 2.2.5 and agy 1.5.14 ([Runtimes](runtimes.md#runtimes)). Updating Pi
on an already-configured box is explicit because `cel setup` keeps installed
runtime versions. Apply the pin in [`agents.yaml`](../agents.yaml) with its
scoped npm installer (currently
`npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@1.4.0"`),
then restart existing Pi panes and verify `pi --version`. Do not install the
unrelated bare `pi` npm package.
Gateway-backed Pi upgrades are a matched rollout: `gateway_pi_models_write`
must emit the provider key, protocol, URL, and model list consumed by the same
revision's `cel run`, whose shell launch line exports that key. Update them
together and keep the generated-config/launch regression green.

`cel gateway pi-models --list` shows every gateway-advertised Claude/Codex chat
model; `--json` includes capability-default and unsupported-transport details.
Missing capability metadata never removes an advertised chat model. Exact
reasoning, vision, context/output limits and compatibility come from the installed
Pi catalog and matching authoritative local metadata, not sibling model names.
`cel gateway pi-models --refresh` updates only Pi model metadata. It preserves
provider URLs, authentication/header resolvers, unrelated providers, existing
legacy entries and defaults; it never restarts sessions, changes their selected
models, mints credentials or makes inference calls. Discovery reads the existing
private gateway key and fails if it is missing rather than repairing credentials.

Pins govern **fresh setup**, not a hermetic machine image. Existing executables
are retained (GitHub CLI must be at least 2.90), distribution packages follow
your package sources, and npm transitive dependencies, plugin build
dependencies and later upstream self-updates are not locked by Celestial.
Previously installed plugins from unrelated marketplaces are not silently
removed. Installation/download failures are reported rather than called
success. Review manifests and upstream code before installing.
