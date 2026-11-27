# Runtimes

Celestial launches six coding-agent CLIs. `agents.yaml` describes each one -
install, pin, skills directory, role injection, launch flags, resume - and
`cel run` reads it; the runtime-specific glue lives in `lib/run.sh`,
`lib/opencode.sh` and `lib/agy.sh`. `cel agents` lists them with install
status and injection strategy.

| | Claude Code (`claude`) | oh-my-pi (`omp`) | pi (`pi`) | codex (`codex`) | OpenCode (`opencode`) | Antigravity CLI (`agy`) |
|---|---|---|---|---|---|---|
| **Install and pin** | native binary 2.1.300, SHA-256 per architecture, then `claude install <version>`; updater `claude update` | release binary 18.14.0, SHA-256 per architecture; updater `omp update` | npm global `@earendil-works/pi-coding-agent@1.4.0` (follows the active node, below); extensions pinned in `tools/pi/extensions.txt`; updater `pi update --self` | official `install.sh` for 0.154.0, checked against its SHA-256; updater `codex update` | release tarball 2.2.5 (x64 or arm64), SHA-256, installed where `opencode` already is, else `~/.local/bin`; `cel update` reinstalls the pin | release tarball 1.5.14, SHA-256, installed like OpenCode; `cel update` reinstalls the pin, and every launch sets `AGY_CLI_DISABLE_AUTO_UPDATE=true` |
| **Launch** | `--dangerously-skip-permissions`, `--model`, `--effort` | `--auto-approve`, `--model`, `--thinking`; core, root and product agents also get `--config=core/omp-orchestrator.yml` | `--model`, `--thinking`; agent root pinned (`PI_CODING_AGENT_DIR`) | `--ask-for-approval never --sandbox workspace-write`, `--model`, `-c model_reasoning_effort=` | `tools/opencode/launch.mjs`: a private `opencode serve` that must load the celestial plugin, then the TUI attached to it; model and effort come from the scoped config, never flags; needs a `via: gateway` profile | `--dangerously-skip-permissions`, `--model`, `--effort low\|medium\|high`, `--agent cel-<agent>`; `via: gateway` profiles are refused |
| **Role prompt** | `--append-system-prompt-file` | `--append-system-prompt` | `--append-system-prompt` | the first prompt (does not survive compaction) | `.cel/opencode/<agent>/role-<role>.md`, agent `cel-<role>` in the scoped config | `~/.gemini/config/agents/cel-<agent>.md`, rewritten every launch |
| **Skills** (core / workspace sets) | `~/.claude/skills` / `--add-dir` | `~/.omp/agent/skills` / `--plugin-dir` | `~/.pi/agent/skills` / `--skill` | `~/.codex/skills` / linked there disabled, enabled per launch with `-c skills.config=[…]` | `~/.config/opencode/skills` / `OPENCODE_CONFIG` | `~/.gemini/antigravity-cli/skills` / the agent file's `skills:` list |
| **Restart (`--restart`)** | `--resume <session id>` | `--resume <session file>` | `--session <session file>` | cannot resume: starts fresh and says so | `--session ses_…` (an existing native v2 root with the same directory and agent); another runtime's history moves over only with `--fresh --handoff <file>` | `--conversation <id>`, refused unless that conversation exists |
| **Woken by idle mail** | Rex only: a watcher notifies over Claude's native peer socket. In Herdr, mail is read when a turn is submitted and continues an active turn, but an idle agent is **not** woken | inbox extension (`inbox.omp.ts`): when idle with an empty composer it starts a turn with the mail | same extension | **no**: mail waits until the agent runs `cel inbox read` | the celestial plugin hands mail to the idle session as native input | its hooks keep a `cel inbox wait` running as an agy background task; its exit on new mail is the wake |
| **Guard** | `tools/hooks/orchestrator-guard.sh` as a `PreToolUse` hook (Bash, Edit, Write, MultiEdit, NotebookEdit; reads are not checked), registered in `~/.claude/settings.json` by `cel setup`/`cel update` against the installed plane | `orchestrator-guard.omp.ts` on core, root, product-agent, member and reviewer launches (not a Direct pane): bash, edit, write, read | same, via `--extension` | **none** (codex has no hook API; its own workspace-write sandbox only) | plugin hooks: shell, write, edit and patch; reads are not checked | `agy-guard.sh` (`PreToolUse` in `~/.gemini/config/hooks.json`, every agy session); fails closed for an agent cel launched |
| **Roles** | any but reviewer; the default `runtime:` for root and product agents | any but reviewer; core's default (`defaults.core`) | every role; the only reviewer runtime | any but reviewer | product agent (solo or lane) only | root, product agent, lane, member |

**MCP tool calls are guarded in no runtime.** Each adapter checks only the
tools listed above: Claude's `mcp__*` tools fall outside its match, omp and pi
pass every tool they do not list, OpenCode classifies only shell, write, edit
and patch, agy passes `call_mcp_tool` explicitly, and codex has no guard. An
MCP server that runs commands or writes files (REA, for example) is outside
every guard.

- **Roles.** Root and product agents take `runtime:` from `workspace.yaml`
  (default `claude`) unless a bound profile says otherwise; team members
  default to the orchestrator runtime. Reviewers and QA agents always run on
  pi, whatever `review.runtime` or a profile says - pi's inbox extension is
  what wakes an idle reviewer. Core comes from `defaults.core`.
- **Effort.** A level a runtime does not accept is clamped down its own
  ladder (agy: `xhigh` and `max` become `high`). A runtime with no model flag
  refuses a profile that names a model rather than ignoring it.
- **Setup and update.** `cel setup` installs every runtime (`--agents a,b`:
  only those). `cel update` updates what is installed with each updater above
  and never installs a missing optional runtime. Pins govern fresh installs;
  see [Requirements](requirements.md#requirements).
- **agy's hooks.** Every agy launch merges one `celestial` entry into
  `~/.gemini/config/hooks.json` (guard, session, inbox), keeping the entries
  already there; if it cannot, nothing is launched.
- **Missing workspace skills.** A launch that cannot carry its workspace's
  [skill sets](skills.md#vendored-skills) is refused.

## OpenCode: the scoped gateway launch

OpenCode is pinned to the verified **2.2.5 CLI release** (`agents.yaml`), not
the legacy npm package or GitHub's stale latest-release pointer. `cel setup`
and `cel update` install the digest-checked official asset next to the
existing executable (fresh installs use `~/.local/bin`); they never restart an
agent or change accounts. OpenCode runs only as a product agent (solo or
lane), on a `via: gateway` profile.

The gateway path starts with a prepared per-agent native-v2 configuration:
`ompgw-codex/gpt-6.1-sol`, medium effort, evidenced 500K context/128K output
limits, and the existing credential reference. Nothing imports credentials or
edits global OpenCode settings. Roles live under
`.cel/opencode/<agent>/role-<role>.md`. The plugin is a directory package with
an explicit server export, not a standalone v1 hook file.

`cel gateway opencode-models` prints the read-only gateway chat inventory as
JSON. Advertised supported Codex/GPT and Anthropic chat IDs remain available
when exact cached capabilities are absent; those entries use native defaults,
not invented limits or sibling metadata. Exact capabilities enrich entries
where available. OMP-only aliases and unsupported image APIs stay excluded.
It uses only the existing private key and model-list/cache reads: no mint,
refresh, account inspection, inference, or native account integration.

```sh
cel gateway opencode-models --sync --workspace <registered-name> --agent <existing-alias> --dry-run
cel gateway opencode-models --sync --workspace <registered-name> --agent <existing-alias>
```

Sync accepts only the existing private, UID-owned, non-symlinked
`.cel/opencode/<alias>/role-orchestrator.opencode.json` and role file under the
registered workspace; arbitrary global paths are not accepted. Namespace
directories must be UID-owned and not group/world-writable; mode 0755 is
allowed while role/config files remain private. It refuses noncanonical/custom
configuration rather than discarding it. Dry-run writes
nothing and prints only inventory/eligibility and activation status. Publication
holds the sibling config lock, retains a private backup, and atomically replaces
the config with mode 0600. Root/agent Sol-medium defaults, role/plugin, gateway
route, URL and environment-key reference remain unchanged; unrelated scopes and
native sessions/PIDs/settings are not modified. **File publication is not live
availability:** an existing process captured inline configuration at launch.
The result reports `activationRequired`; coordinated activation at the same
native SID boundary belongs to its owner. This command never reloads/restarts.

```sh
cel run solo --product <product> --profile <scoped-profile> --session-backend rex --fresh --handoff /absolute/checkpoint.md
```

The native `--prompt` kickoff instructs a fresh session to read the handoff;
an archived OMP log is consultation material, never a native resume. Subsequent
continuation accepts only an existing migrated OpenCode `ses_...` root with
the exact directory and scoped agent. Without a catalog the exact Sol-medium
selection remains required; a canonical catalog additionally admits an
owner-selected eligible provider/model and its native variant, without an
automatic fallback or changing the launch default. Storage errors, pending
migrations and missing IDs refuse before stopping/relaunching a runtime:
v2's bare `--session` can otherwise create a missing session.

The launcher owns a private, authenticated `serve --stdio` server. Before
attaching the TUI it verifies the server, the native plugin, migration
readiness, the saved session and the selected model, and holds inbox mail
until those checks pass; a missing or failed plugin never admits an unguarded
TUI. The server's copy of the config sets
`experimental.location_idle_timeout: false`: OpenCode otherwise unloads a
location's services, the plugin's idle inbox observer among them, after 60
minutes without session activity, and an agent idle that long stopped waking
for mail. The plugin delivers idle mail as native synthetic input, never
terminal typing, and binds a fresh root created before its first observer
tick, so a `--handoff` kickoff always runs. Medium is persisted in the native
model selection and sent as Responses reasoning effort. The shared guard
covers shell, write, edit and patch (not reads, not MCP tools); `--auto`
never waives an explicit denial.

A completed v1 migration marker does not prove a later v1 session reached
v2: back up the database first and investigate on a disposable copy; never
reset a live marker or replace shared native storage. Installation is not
authorisation to quit or reload a held runtime.
