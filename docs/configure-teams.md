# Configure your teams

| | Feature team | Team workspace |
|---|---|---|
| What it is | members one product's agent leads for one feature | one workspace shared by several people |
| Configured in | `workspace.yaml` (`role_profiles`, `worker_profiles`) and the box config (`budget:`) | `workspace.yaml` (committed), plus `workspace.local.yaml` and `env.local` per person |
| Started by | the product's agent: `cel team start` | you: `cel ws new`, then `cel ws add` on each box |

## 1. Declare products, models and review

A complete `workspace.yaml` for one workspace with two products:

```yaml
# ~/ws/acme/workspace.yaml - committed: everyone who clones the workspace reads it
name: acme
kind: team                     # a label; cel ws new asks, and defaults to personal
org: acme                      # GitHub owner; cel ws push creates acme/ws-acme
tickets: { system: none, adhoc: "AH-<yymmdd>" }
policy:
  merge: self                  # product agents land their own approved, green PRs
  pr: required
  pr_open: ready               # open PRs ready for review, not as drafts
runtime: { root: claude, orchestrator: claude }   # the CLI when no profile applies
env: {}                        # plain settings only; keys go in env.local
repos:
  - name: atlas-web
    url: git@github.com:acme/atlas-web.git
    prefix: ATL                # branch prefix
    gate: npm test             # the check an agent runs before it pushes
  - name: atlas-api
    url: git@github.com:acme/atlas-api.git
    prefix: API
    gate: go test ./...
    review:
      extra:                   # this repo's own specialist reviewers, beside the ones below
        - focus: db-migration
          paths: ['migrations/**']
  - name: billing              # in no product, so it is its own product
    url: git@github.com:acme/billing.git
    prefix: BIL
    gate: npm test
    home: jo                   # a repo in no product names its home here
products:
  - name: atlas                # one agent, atlas-orch, owns both repos
    repos: [atlas-web, atlas-api]
    mode: solo                 # the default
    home: sam                  # only sam's login starts atlas's agents (team workspaces)
people:                        # who is on the team; ids are what home: names
  - id: sam
    login: sam-example         # their own forge login (GitHub or Forgejo)
    roles: [owner, approver]   # workspace-wide
  - id: jo
    login: jo-example
    products: { atlas: [product-lead], billing: [qa] }   # per product
layout:
  orchestrators: auto          # cel ws up acme starts one agent per product
review:                        # one reviewer per PR, through the gateway
  runtime: pi
  model: sonnet
  extra:                       # specialist reviewers by the files a PR touches (policy)
    - focus: security          # a pack in core/roles/focus/reviewer/
      paths: ['lib/auth/**', '**/*token*']
    - kind: qa                 # a QA agent: runs the head in a preview and uses it
      focus: browser           # a pack in core/roles/focus/qa/
      paths: ['web/**', '**/*.tsx', '**/*.css']

thinking: medium               # reasoning level when a profile names none
worker_profiles:               # a name for each CLI + model + effort you use
  opus: { runtime: pi, model: claude-opus-5-5, via: gateway, thinking: medium }
  sol:  { runtime: pi, model: gpt-6.1-sol, via: gateway, thinking: low }
role_profiles:                 # which profile each role launches on
  solo: opus                   # the product agents and their lanes
  qa: sol                      # QA agents (else the reviewer binding, else review.model)
  member: sol                  # any team member without its own line below
  team-builder: opus           # team-<role>: product, design, builder, qa,
  team-qa: sol                 #   platform, release or analyst
```

A team member's model comes from `role_profiles.team-<role>`, else
`role_profiles.member`, else `runtime.orchestrator` with that CLI's default
model. A product entry may narrow any binding for itself
(`products[].role_profiles: { team-builder: sol }`). The lookup tries
`team-<role>` on the product (or repo) and then the workspace before it tries
`member` anywhere, so a product-level `member` loses to a workspace-level
`team-<role>`: narrow a role for one product with `team-<role>` there. The model ids above are
examples: use what `cel gateway status` and your providers offer. More on
profiles: [Profiles](profiles.md#profiles-runtime-model-and-effort-per-role).

`people:` and `home:` matter once several people share the workspace (step
3). Each person's `login` is their own forge account. Roles come from a fixed
list: `owner`, `product-lead`, `qa`, `design`, `release` and `approver`,
held workspace-wide (`roles:`) or per product (`products:`). `home:` names the
person whose login runs a product's agents: on any other login, `cel ws up`
and the steward skip that product, and `cel run solo` refuses it unless you
pass `--force`. A personal workspace leaves `people:` and `home:` out, and
nothing changes.

`review.extra` is review policy: every PR gets its plain reviewer, and a PR
that touches a file one of the `paths` globs matches also needs that entry's
agent - a focus reviewer (`kind: review`, the default) or a QA agent
(`kind: qa`), which builds the PR's head in a preview of its own and drives it
in a browser. A repo's own list adds to the workspace-wide one, so an
`atlas-api` PR answers to both. `cel run reviewer` starts them and
`cel solo land` waits for each one's approval of the head; see
[The review loop](review-loop.md#the-review-loop). It is read from `workspace.yaml` only -
`workspace.local.yaml` cannot add or drop one. A QA agent's model is
`role_profiles.qa`, else `role_profiles.reviewer`, else `review.model`; like
every reviewer it runs on pi.

How many helpers may run at once is a box setting, not a workspace one. It
lives in `~/.local/share/cel/config.yaml` and covers every workspace on the
box:

```yaml
budget:
  max_live_agents: 8           # helpers: reviewers, team members and other launched agents
  max_team_members: 4          # of those, team members
```

Both values above are the defaults. Product agents and core are never
counted. `cel budget` shows what is live against both limits.

Then, from the workspace:

```sh
cel ws sync acme               # clone the repos, render the policy into each one
cel doctor                     # check the box and the workspace
cel profiles                   # each profile's exact launch line
cel ws up acme                 # sam's login starts atlas-orch, jo's billing-orch
```

## 2. Run a feature team, start to close

You don't run these yourself: `cel team` refuses a shell with no agent role,
except `cel team status`. Ask the product's agent, for example
`cel inbox send atlas-orch "build login as a team"`, and it runs:

```sh
cel team start login --product atlas --repo atlas-web --brief-file brief.md
# push the integration branch, then post its head as the candidate
cel team event login candidate.updated --data '{"repo":"atlas-web","head":"<40-char sha>","branch":"ATL-login"}'
cel team add login builder --repo atlas-web --owns 'src/auth/**' --focus backend --task-file auth.md
cel team add login builder --repo atlas-web --owns 'src/ui/login/**' --focus frontend --task-file ui.md
cel team add login qa --repo atlas-web --focus browser --task-file qa.md
cel team add login design --focus ux --task-file design.md
cel team status login          # roster, candidate heads, verdict freshness, who owes next
# builders push team/login/<member> and report task.ready; the lead merges them,
# runs the gate, pushes and posts candidate.updated again; qa and design judge
# that head with: cel team verdict login --repo atlas-web --head <sha> pass --evidence report.md
cel team cap login "<cap> (decision <id>)"   # only if members may spend; zero otherwise
cel run reviewer --repo atlas-web --pr <n>   # one PR per repo, its own reviewer
cel solo land atlas-web#<n>
cel team close login           # retires every member; refuses over unpushed builder work
```

Members are admitted against the box budget, and `cel team add` is refused
rather than queued when it is full. Roles, focus packs, events and verdicts:
[Feature teams](feature-teams.md#feature-teams).

## 3. Share a workspace with your team

One person creates the workspace and publishes it:

```sh
cel ws new acme --kind team --org acme --merge self
# edit ~/ws/acme/workspace.yaml as in step 1 - add everyone to people: and give
# each product a home: - then commit it
cel ws push acme               # creates the private repo acme/ws-acme and pushes
```

Each teammate, on their own box:

```sh
cel ws add git@github.com:acme/ws-acme.git   # clones to ~/ws/acme, registers and syncs it
cd ~/ws/acme
cp workspace.local.example.yaml workspace.local.yaml   # then edit it, below
# put your own keys in env.local
cel doctor                     # checks me: against your own forge login
cel people                     # who is who, and which person this login is
cel profiles                   # bindings and profiles from your file are marked (local)
```

```yaml
# ~/ws/acme/workspace.local.yaml - gitignored, this box only
me: jo                         # your id in people: - which products start here
worker_profiles:
  mine: { runtime: claude, model: claude-sonnet-5, thinking: medium }  # adds, or replaces one by name
role_profiles:
  solo: mine
  team-builder: mine
products:
  - name: atlas                # by name; role_profiles and orchestrator: manual are read here
    role_profiles: { team-qa: mine }
env:
  TMPDIR: /tmp/you             # per-box settings; keys still go in env.local
```

The local file may change only `role_profiles`, `worker_profiles`, `env:` and
the `role_profiles` of a `products[]` or `repos[]` entry, set `me:`, and turn
a product's agent off on this box (`products[].orchestrator: manual`).
Policy, repos, people, homes, review, gates and the box budget stay in the
shared files. To change the contract, edit `workspace.yaml`, commit and push;
teammates `git pull` and run `cel ws sync acme`.

`cel people` on jo's login, for the workspace in step 1:

```text
acme: 2 people; this login is jo

    sam              sam-example              owner, approver
  * jo               jo-example               atlas: product-lead; billing: qa

who runs each product's agents (products[].home):
  atlas            runs on sam's login - not started here
  billing          this login (jo)
```

On jo's login, `cel ws up acme` and the steward start billing-orch and leave
atlas alone, without a warning. `cel run solo --product atlas` refuses:

```text
cel run: atlas runs on sam's login (products[].home: sam); this login is jo - ask sam, or pass --force
```

A login with no `me:` starts no product that has a `home:`. Details:
[Team workspaces](profiles.md#team-workspaces) and [Per-box routing](profiles.md#per-box-routing).

## The shape a workspace declares

`workspace.yaml` may say what should be running in a workspace, and `cel ws up`
puts it back:

```yaml
layout:
  orchestrators: auto        # auto: one agent per product that wants one | manual | none
  panes:                     # optional extra panes, opened at `up`, in order
    - label: dash
      cwd: .
      cmd: cel dash --ensure # optional; an empty pane when absent
    - label: notes
      cwd: .
```

`products[].orchestrator` (`auto`/`manual`) decides per product underneath the
workspace-wide switch. The agent started is the product's solo agent. A
workspace with **no** `layout:` block behaves as `orchestrators: manual` with
no extra panes.

`up` is a reconcile, not a launcher: when herdr loses a live agent's name (it
clears it on restart), every surface that resolves a product agent by its
alias would report the product as dead — and the answer to a dead agent is to
start another one on top of the running one. So a live agent in a product's
own directory is that product's agent whatever herdr calls it: `cel fleet`
shows `orch unnamed` rather than `-`, `cel doctor` says which directory it is
in, `cel ws up` renames it, and `cel run orchestrator` refuses to start a
second one over it without `--force`.
