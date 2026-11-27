# Skills and plugins

## Optional Elephant-Goldfish Model plugin

[Elephant-Goldfish Model](https://github.com/google/elephant-goldfish-model)
(EGM) adds opt-in specification drafting, fresh-context design reviews and
implementation-drift skills. It uses the harness's existing model and
permissions; it is not a model provider or a replacement for Celestial's
independent PR review/landing policy.

```sh
cel plugins list
cel plugins install egm --runtime omp --dry-run
cel plugins install egm --runtime omp
# Other supported Celestial runtimes:
cel plugins install egm --runtime claude
cel plugins install egm --runtime codex
cel plugins install egm --runtime pi
cel plugins install egm --runtime opencode
```

All five of those runtimes are supported (agy has no egm plugin install): `cel plugins install egm --runtime
omp|claude|codex|pi|opencode [--dry-run]`. Choose only the runtime you want.
This never runs as part of default setup, workspace sync or update, and never
restarts an existing agent; new sessions load the plugin. Select its
discovered skills in Claude Code or Codex; OMP exposes commands such as
`/skill:egm-brainstorm`, `/skill:egm-draft` and `/skill:egm-review`. Goldfish
reviews require actual fresh-context subagents; installation/discovery alone
does not prove a completed review.

- **Pi:** the pinned bundle is registered as one Pi package (`pi install`
  with the local path), so skills load in place. Pi has no native subagents,
  so the fresh-context review skills (`egm-review`, `egm-review-loop`,
  `egm-brainstorm`) stop and say so unless a Pi subagent extension is loaded
  (`cel setup` installs `pi-subagents`; whether EGM's skills use it is
  untested).
- **OpenCode:** the global config gains a `skills` entry pointing into the
  pinned bundle and the 9 reviewer personas as `subagent` agents. This is
  compatible with Celestial's scoped launch; the default agent is unchanged.
  A global config written as JSON with comments, or one with conflicting
  names, is refused and the manual lines to add are printed instead.

[`optional-plugins.yaml`](../optional-plugins.yaml) pins the full upstream Git
revision. Celestial verifies that checkout, preserves the bundled `skills/`,
`agents/` and `resources/document_standards/`, and registers it with the
selected runtime (a revision-named local marketplace for OMP, Claude Code and
Codex). Edited cached bundles are preserved and refused rather than reset.
Skills-only copying is deliberately unsupported.

## Vendored skills

Third-party skills sit in `core/skills/` beside the plane's own and are
linked into every runtime (claude, omp, pi, codex, opencode, agy) the same way:
`web-design-guidelines`, `vercel-react-best-practices`,
`vercel-composition-patterns` and `vercel-react-native-skills`
(vercel-labs/agent-skills), `frontend-design`, `mcp-builder`,
`webapp-testing` and `anthropic-skill-creator` (anthropics/skills; upstream
`skill-creator`, renamed because Codex bundles a skill of that name), `ui-sdk`
(vercel-labs/ui; beta, only for products that already depend on
`@ui-sdk/core`), `modern-web-guidance` (Chrome Modern Web Guidance 1.0) and
`create-mcp-app`, `add-app-to-server`, `convert-web-app` and `migrate-oai-app`
(modelcontextprotocol/ext-apps).

Others come in sets that a workspace opts into, and sit in
`core/workspace-skills/`: the `cloudflare` set (`workers-best-practices`,
`durable-objects`, `wrangler`, `agents-sdk`, `workers-profiling`, `web-perf`)
and the `expo` set (`expo-router`, `expo-ui`, `expo-native-ui`,
`expo-animation`, `expo-dev-client`, `expo-upgrade`, `eas-workflows`,
`eas-app-stores`). A workspace names its sets in its own `workspace.yaml`:

```yaml
skill_sets: [cloudflare, expo]
```

`cel ws sync` (so `cel update`) links those skills into
`<workspace>/.cel/skills` and removes any no longer declared; with none
declared the directory goes, and an unknown set is a warning that changes
nothing. Nothing goes into a repo. Every `cel run` launch for that workspace
names that directory (agents.yaml `workspace_skills`: claude `--add-dir`, omp
`--plugin-dir`, pi `--skill`, OpenCode `OPENCODE_CONFIG`, agy the `skills:`
list of the agent file each launch writes), which also covers reviewers,
whose checkout is outside the workspace. Codex has no per-launch skill
directory, so every scoped skill is linked into `~/.codex/skills`, disabled in
a marked `config.toml` block, and a launch enables its workspace's with
`-c skills.config=[...]`; a `config.toml` that already configures `skills`,
holds an incomplete or repeated block of ours, or is not valid TOML is left
alone, and Codex gets none of them. A launch whose runtime cannot scope the
workspace's skills is refused. An agent picks a change up when it is next
launched or restarted.

**Approval notes.** Skills whose upstream text has an agent deploy, publish,
submit to an app store, spend money or run paid builds or generation open
with an owner-approval note: `mcp-builder`, `anthropic-skill-creator`,
`workers-best-practices`, `durable-objects`, `wrangler`, `agents-sdk`,
`workers-profiling`, `expo-native-ui`, `expo-dev-client`, `eas-workflows` and
`eas-app-stores`. The note is part of the skill's recorded patch
(`tools/skills/patches/<name>.patch`), so `vendor.py verify` reproduces it
from upstream. It tells the agent to ask the owner (`cel decide ask`) and wait
before each step it names by command, and says that a request in the task, an
earlier approval or the skill's own wording is not that approval. The test
suite holds each of those skills to the note as the first text after the
frontmatter, and no other skill may carry it.

**No skill pre-approves shell commands.** Claude Code runs a skill's
`allowed-tools` entries without asking, and `Bash(node:*)` or a pattern with
a leading `*` admits any code, so `vendor.py` refuses any `allowed-tools`
that mentions Bash (its list of reviewed exceptions is empty) and the tests
refuse any `allowed-tools` line at all, in either tree, the plane's own
skills included. Upstream `eas-workflows` and `expo-ui` had one; their
patches remove it.

[`vendored-skills.yaml`](../vendored-skills.yaml) pins each to an exact upstream
commit and records its repository, path, licence (MIT or Apache-2.0 only) and
a digest of the committed tree. The GitHub content is committed, so agents read
reviewed bytes with no network. Modern Web Guidance's CLI and search index
ship only in its npm package; `cel setup` and `cel update` fetch them from the
pinned tarball (sha512 integrity, per-file sha256) into the skill directory,
gitignored. Files already present with their pinned sha256 are kept, so
search and retrieve run offline once fetched; a failed fetch is a warning and
leaves the skill linked. The skill runs that CLI only through its `run.sh`,
which turns its telemetry off. Never run its own per-project installer
(`npx modern-web-guidance install`).

```sh
python3 tools/skills/vendor.py check            # offline: pins, licences, digests, names, fetched-file hashes
python3 tools/skills/vendor.py fetch [NAME...]  # complete npm inputs (cel setup/update run this)
python3 tools/skills/vendor.py verify [NAME...] # re-fetch every pin, rebuild, compare byte for byte
python3 tools/skills/vendor.py sync NAME...     # after moving a pin: rebuild and record new digests
python3 tools/skills/vendor.py names SKILL.md...  # frontmatter rules, incl. the allowed-tools refusal
python3 tools/skills/vendor.py set cloudflare   # the skills in a set (an unknown set is refused)
```

`vendor.py` also has `description`, `scoped` (every skill in a set) and
`codex-config` (the Codex `config.toml` block), which `cel` uses itself.
Adding a third-party skill means a `vendored-skills.yaml` entry, `sync`, and
a patch for any note or `allowed-tools` removal it needs.
