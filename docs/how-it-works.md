# How it works

Three layers on disk, and a factory floor of agents above them.

```
~/celestial                the plane: mechanism only (this repo, public)
├── bin/cel                one CLI for everything
├── core/roles/            role prompts, injected at launch
├── core/skills/           skills linked into every agent
├── core/workspace-skills/ vendored skills linked only for the workspaces they name
├── vendored-skills.yaml   pins for the third-party skills in both
└── agents.yaml            which agents, how to install, how to inject

~/ws/<name>                a workspace: private content + overrides (own repo)
├── workspace.yaml         repos, policy, tickets, runtimes, env, services
├── layouts.yml            herdr layouts (wins over the plane's)
├── externals.yaml         extra tools (additive overlay)
├── skills/                workspace-scoped skills
└── repos/<repo>/          the actual product clones (gitignored here)

~/.local/share/cel         box state: registry, published pages (never in git)
```

The agents above them, and how they reach each other, are drawn in
[Setups at a glance](setups.md#setups-at-a-glance).

A **workspace** is not a tier. It is the scope that holds configuration and
grouping: policy, ticket tracker, environment, profiles, dashboard. A
**product** is the unit one agent owns — one repo, or several that ship
together. Its agent's pane and mailbox are `<product>-orch`. `root` is the
mailbox name for "the top, whoever is listening", which is `cel core`.
`cel run root` still starts a standing director inside one workspace, but it
is not the path these docs assume: it refuses while core is live (unless
`--force`), and `cel core` refuses while any workspace's `*-root` agent is
live. The product orchestrator and the solo agent are one role
(`core/roles/solo.md`; `project-orchestrator.md` points at it): it builds
small work itself and leads a [feature team](feature-teams.md#feature-teams) when a feature
needs one.

`cel core` (also `cel console`, `cel run core` and `cel run console`) starts
the box's coordinator: one agent, standing in no workspace, that reads
`root`'s mail in every workspace, holds cross-product priorities and
blockers, reads state and code read-only, directs product agents by inbox,
starts and restarts them, and shows or sets a product's mode with `cel mode`.
It runs the role in `core/roles/core.md` with no workspace policy block, in
`~/.local/share/cel/core` (`CEL_CORE_DIR`), as `CEL_ROLE=core`; its alias is
`core` and mail sent to `core` lands in `root`. Its runtime, model and effort
come from `agents.yaml` `defaults.core` - out of the box omp,
`anthropic/claude-opus-5-5`, `medium`, through the gateway (`via: gateway`
is supported for core on omp only). `--model` and `--thinking` override
them; `--profile` is refused, since profiles are bound per workspace. It
resumes its last session and refuses a second copy; `cel core --restart`
relaunches it, `--fresh` starts a new conversation.

Core does not build or land PRs. The guard treats it as a read-only
coordinator (no repository or forge writes) and also refuses
`cel solo land|review`, `cel spike`, `cel forge pr close|ready`,
`cel forge run rerun`, `cel run reviewer|root`, `herdr agent start`,
`herdr worktree create|open|remove` and `cel learn|release|promote|update|setup`,
naming the product agent's route instead. Its one configuration write is
`cel mode`.

## A workspace with its own GitHub account

`gh` keeps several accounts per host but only one is *active*, box-wide, so
`gh auth switch` for one workspace would re-identify every other workspace.
A workspace whose repos belong to a second account says so in
`workspace.yaml`:

```yaml
github:
  user: acct-b              # the gh account this workspace acts as
  ssh_host: github-acct-b   # optional: an ~/.ssh/config Host alias with acct-b's key
```

Every pane `cel run` starts for that workspace
gets `GH_TOKEN="$(gh auth token --user acct-b)"`, evaluated in the pane (the
value never passes through cel), and every `gh` call the plane makes for the
workspace (steward sweeps, `cel solo land`, reviewer PR lookup, `cel ws push`,
`cel gc`, `cel release`) runs with that account's token for that call only.
Nothing ever runs `gh auth switch`. If the account is not logged in, launches
and calls for that workspace refuse rather than fall back to the active
account. With `ssh_host`, `cel ws sync` clones over `git@github-acct-b:owner/repo.git`;
the `url:` in `workspace.yaml` keeps the canonical `git@github.com:` form.
Without a `github:` block nothing changes.

Two human steps, once per box:

1. `gh auth login` as acct-b (it is added beside the existing account; check with `gh auth status`).
2. An SSH key for acct-b, added to acct-b on GitHub, and an alias in `~/.ssh/config`:

   ```
   Host github-acct-b
     HostName github.com
     User git
     IdentityFile ~/.ssh/id_ed25519_acct_b
     IdentitiesOnly yes
   ```

`cel doctor` checks both for every workspace that declares `github.user`.


## Solo lanes: several big goals, one agent each

A product's agent holds one picture of the work. When a product has two or
three large feature sets that each want one agent holding the whole picture,
run them as lanes:

```
cel run solo --product celestial --lane ui      # pane and mailbox celestial-ui
cel run solo --product celestial --lane api     # pane and mailbox celestial-api
```

Each lane is a full solo agent - its own pane, mailbox, directory
(`.cel/solo/<product>/lane-<name>`) and resumable session - working in the
product's repos through its own branches and worktrees, opening and landing
its own PRs (`cel solo land`, same review and CI checks). Reviewers it starts
report back to it. The product's main agent (`<product>-orch`) keeps running
beside them. Lanes are told about each other and coordinate overlapping files
by inbox; nothing stops two lanes editing the same file, so give them goals
that touch different parts of the code. `cel fleet` lists a product's live
lanes; `/cel-restart` in a lane restarts that lane only.

**A repo one lane owns.** When a lane is the only agent that works in one of
the product's repos, say so in the committed `workspace.yaml`, with the name
`--lane` takes:

```yaml
repos:
  - name: atlas-checkout-ui # one of atlas's repos
    lane: checkout          # its PRs are atlas-checkout's, not atlas-orch's
```

Then everything about that repo's PRs goes to the lane's mailbox
(`<product>-<lane>`), not the product's main agent: every steward nudge
(approved and green - land it; a recorded `changes` verdict; changes requested
on the forge; failing checks; no ticket in the branch name) and the findings
of every reviewer of its PRs, whoever started that reviewer. One function
answers "who owns this repo's PRs" for all of them (`ws_repo_pr_owner`), and
the rendered policy names the lane on the repo's line and in its review line.
While the lane is not running (its name in its own
`.cel/solo/<product>/lane-<lane>`), the steward sends its nudges to
`<product>-orch` instead, and the first one for each PR head says so: which
lane, that it is not running, and how to start it. A reviewer started while
the lane is down still sends its findings to the lane, whose mailbox keeps
them, and copies its verdict line to `<product>-orch` saying the lane is down.
`workspace.local.yaml` cannot set or move it - it is the team's contract.
`cel doctor` warns about a value no lane can have, and about a lane this box
has never started (no `.cel/solo/<product>/lane-<lane>`).

A lane remembers explicitly named `--profile` and `--model` choices only after
a successful launch; a bare `--restart` keeps those saved choices. An
explicit new profile clears the old model override unless you also name a new
model. Workspace/profile defaults remain dynamic; dry runs, invalid choices
and failed launches do not replace saved choices. These overrides belong to
that lane, never the shared workspace profile.

To persist a model already used by a **managed Rex lane** without restarting
or changing its native session, name its exact current runtime PID and launch
model (not a requested in-session model change):

```sh
cel run solo --product <product> --lane <lane> --model <exact-model> --remember-current-model <pid> --dry-run
cel run solo --product <product> --lane <lane> --model <exact-model> --remember-current-model <pid>
```

This bounded command verifies the lane's live Rex receipt, PID start time,
runtime and actual `/proc` model argument before writing only its `launch-model`
override. It does not start/stop an agent, edit global profiles or alter native
session identity. It cannot be combined with restart, fresh, profile, thinking
or backend changes. Model syntax validation is offline; it is not a provider
availability check.

## Commands inside an agent

Core and solo agents all take the same small set of commands,
typed in the agent's own pane instead of remembering CLI flags. Each runs
`cel here <verb>` - a thin wrapper over one `cel` command - scoped to the
pane's own product unless one is named (core names one: `<product>` or
`<workspace>/<product>`). The output is posted into the conversation without
starting a turn, so the agent sees what its owner ran.

| In the agent | Runs | Does |
| --- | --- | --- |
| `/cel-mode [product] [solo]` | `cel mode` | show the product's mode, or set it to solo (restart at end of turn) |
| `/cel-status [product]` | `cel fleet --workspace <w>` (core: `cel fleet`) | agent, lanes, mail |
| `/cel-inbox` | `cel inbox read --for <me> --all-workspaces` | unread mail now (core: root's) |
| `/cel-decide` | `cel decide list` (others: `--workspace <w> --asker <me>`) | open owner questions |
| `/cel-review [repo#]<pr>` | `cel run reviewer` | start a reviewer pane (not core) |
| `/cel-land [repo#]<pr>` | `cel solo land` | merge through the checked path (not core) |
| `/cel-restart` | the `cel mode` restart waiter | restart this agent on its own session once its turn ends |
| `/cel-focus <product>` | `herdr agent focus <product>-orch` | core only |

omp and pi register them through the inbox extension
(`tools/hooks/inbox.omp.ts`, for core, root and product agents); Claude Code
gets `~/.claude/commands/cel-*.md` links from `cel setup`/`cel update`. The
`cel-` prefix is deliberate: omp has built-in `/review` and `/restart`, Claude
Code built-in `/status` and `/review`. codex, OpenCode and agy panes have no
`/cel-*` commands; run `cel here <verb>` in a shell instead. Core cannot
`review` or `land`; a lane's `restart` restarts that lane, never the main
agent; root's is refused (use `cel run root --restart`).

`cel run <role>` starts any station with its role injected and permissions
pre-approved; with no role it is Direct mode (`<repo>-direct` in the repo).
`policy.pr_open: draft | ready` decides whether a PR opens as a draft (the
default; on Forgejo a `WIP:` title) or ready for review; its reviewer is
started separately with `cel run reviewer`. `cel solo land` refuses a draft,
so a workspace whose agents land their own PRs sets `pr_open: ready` beside
`merge: self`. `cel ws new` writes neither: it asks for the merge policy
(default `humans-only`) and writes `policy: { merge: <answer>, pr: required }`.
`pr: none` on a repo entry (or as the workspace-level `policy.pr`) skips the
PR for that repo: the agent rebases onto origin's default branch and pushes,
fast-forward only.
