# Setups at a glance

"Team" means two different things in Celestial. A **feature team** is a group
of short-lived agents that one product's agent leads for one feature
(`cel team`). A **team workspace** is one workspace shared by several people,
each on their own box. [Configure your teams](configure-teams.md#configure-your-teams) sets up
both.

## One box: core, product agents, reviewers

```mermaid
flowchart TB
  owner(["you"])
  core["cel core<br/>one per box, never builds"]
  subgraph acme["workspace acme"]
    atlas["atlas-orch<br/>atlas's agent"]
    billing["billing-orch<br/>billing's agent"]
    ra["reviewer<br/>one per PR"]
    rb["reviewer<br/>one per PR"]
  end
  subgraph lab["workspace lab"]
    gizmo["gizmo-orch"]
  end
  owner <--> core
  core -- "cel inbox" --> atlas
  core -- "cel inbox" --> billing
  core -- "cel inbox" --> gizmo
  atlas -- "cel run reviewer" --> ra
  billing -- "cel run reviewer" --> rb
```

Every setup is built on this one. You talk to `cel core`, one per box, which
reads `root`'s mail in every workspace and directs each product's agent; each
product's agent builds and lands its own PRs and starts one reviewer per PR.
Selected by: `cel core` once per box; one `products:` entry per product (a repo
that is in no product is its own product); `layout: { orchestrators: auto }`
so `cel ws up <workspace>` starts every product's agent; and a `review:` block
so there are reviewers at all.

## One product, solo (the default)

```mermaid
flowchart LR
  agent["atlas-orch"] -- "branch, gate, push, open PR" --> pr["PR on atlas-web"]
  agent -- "cel run reviewer" --> rev["reviewer for that PR"]
  agent -- "cel run reviewer<br/>(UI paths: review.extra kind: qa)" --> qa["QA agent for that PR"]
  rev -- "reads the head" --> pr
  qa -- "runs the head in cel preview,<br/>drives it in a browser" --> pr
  rev -- "cel solo review" --> agent
  qa -- "cel solo review --qa + evidence" --> agent
  agent -- "cel solo land" --> main[("main")]
```

Choose this for almost everything: one agent holds the whole product, uses its
own worktrees and subagents, and lands each PR once its reviewer approved that
exact head and the checks are green - and, for a PR touching the paths
`review.extra` names, once each QA agent (or focus reviewer) has too. Selected
by `mode: solo` on the product, which is also the default when absent, and
`policy: { merge: self }` (with `merge: humans-only` the agent opens the PR
and stops). Details: [Solo mode](solo-mode.md#solo-mode).

## Solo lanes: several goals on one product

```mermaid
flowchart LR
  subgraph atlas["product atlas, same repos"]
    direction TB
    orch["atlas-orch<br/>main agent"]
    checkout["atlas-checkout<br/>lane checkout"]
    search["atlas-search<br/>lane search"]
    checkout -. "inbox mail about shared files" .- search
  end
  prs["each agent: its own branches,<br/>PRs and reviewers"]
  main[("main")]
  orch & checkout & search --> prs
  prs -- "cel solo land" --> main
```

Choose lanes when one product has two or three large goals that each want one
agent holding the whole picture, in different parts of the code. Nothing in
`workspace.yaml` starts a lane: start one with
`cel run solo --product atlas --lane checkout`. A repo one lane owns outright
can say so (`repos[].lane`), so its PR mail goes to that lane. Details:
[Solo lanes](how-it-works.md#solo-lanes-several-big-goals-one-agent-each).

## A feature team, led by the product's agent

```mermaid
flowchart LR
  subgraph team["members, added with cel team add"]
    b1["builder<br/>owns src/auth"]
    b2["builder<br/>owns src/ui/login"]
    qa["qa"]
    des["design"]
  end
  lead["atlas-orch, the lead<br/>integrates the branches"]
  pr["one PR per repo"]
  rev["PR reviewer"]
  main[("main")]
  b1 & b2 -- "push team branches" --> lead
  qa & des -- "verdicts on the candidate head" --> lead
  lead -- "opens" --> pr
  rev -- "approves" --> pr
  lead -- "cel solo land" --> main
```

Choose a team when a feature has two or more parts that can be built at the
same time, or needs a specialist (device QA, design, data, a release check).
The product's agent stays the only integrator: builders push
`team/<feature>/<member>` branches and never open PRs, qa and design judge the
lead's candidate head, and the lead opens one PR per repo, gets it reviewed
and lands it with `cel solo land`. Selected by: `role_profiles` lines
`team-<role>` and `member` for the members' models, and the box's `budget:`
for how many may run. The product's agent runs the `cel team` commands.
Details: [Feature teams](feature-teams.md#feature-teams).

## A team workspace, shared by several people

```mermaid
flowchart TB
  remote[("acme/ws-acme<br/>workspace.yaml, the team contract")]
  subgraph boxa["your box"]
    ya["workspace.yaml"]
    la["workspace.local.yaml<br/>your routing"]
    ea["env.local<br/>your keys"]
  end
  subgraph boxb["a teammate's box"]
    yb["workspace.yaml"]
    lb["workspace.local.yaml<br/>their routing"]
    eb["env.local<br/>their keys"]
  end
  remote -- "cel ws add, git pull" --> ya
  remote -- "cel ws add, git pull" --> yb
  la -. "overrides routing" .-> ya
  lb -. "overrides routing" .-> yb
```

Choose this when several people, or one person on several boxes, work on the
same products. Everyone shares `workspace.yaml` through git: repos, products,
policy, review, the default routing, and `people:` - who is on the team.
Each person keeps a gitignored `workspace.local.yaml` that changes only
routing (which profile each role runs on), per-box `env:` and `me:` (which
person this login is), and an `env.local` with their own keys. A product's
`home:` names the one login that runs its agents, so two teammates' boxes
never both build it. Details: [Team workspaces](profiles.md#team-workspaces) and
[Per-box routing](profiles.md#per-box-routing).

## How agents reach models: the gateway

```mermaid
flowchart LR
  agents["agents on a via: gateway profile<br/>and every PR reviewer"] --> gw["cel gateway<br/>one door on 127.0.0.1"]
  gw --> c1["Claude subscription 1"]
  gw --> c2["Claude subscription 2"]
  gw --> cx["Codex subscription"]
```

A profile with `via: gateway` reaches its model through `cel gateway`, which
holds several subscriptions and keeps each agent on one account. Reviewers
always go through it. Details:
[Gateway](gateway.md#gateway--several-subscriptions-behind-one-door).
