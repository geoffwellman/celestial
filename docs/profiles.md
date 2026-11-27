# Profiles: runtime, model and effort per role

`runtime:` picks the CLI for a role; a **profile** picks the CLI *and* the
model *and* the reasoning level. Profiles are declared under
`worker_profiles:` (the key keeps its old name) and bound to roles:

```yaml
thinking: medium              # default level when no profile applies
worker_profiles:
  default: { runtime: omp,   model: openai-codex/gpt-5.5-sol, thinking: low }
  opus:    { runtime: pi,    model: claude-opus-5-5, via: gateway, thinking: medium }
role_profiles:
  solo: opus                  # the product agents and their lanes
  orchestrator: default       # fallback for solo when solo is unbound
  reviewer: default
  qa: default                 # QA agents; unbound, they take the reviewer binding
```

A product or repo entry may narrow a binding for itself
(`products[].role_profiles`). `cel run solo|reviewer ... --profile <name>`
overrides once; a lane remembers it. `cel profiles` prints every profile, the
exact launch flags it resolves to, and the workspace-level bindings for root,
orchestrator, solo, reviewer, qa and direct (not `member` or `team-<role>`).

`agents.yaml` records each runtime's model flag and how it takes a reasoning
level — claude `--effort`, omp/pi `--thinking`, codex
`-c model_reasoning_effort=…`, agy `--effort` (low, medium, high only),
OpenCode through its scoped native config rather than a flag; a level a
runtime doesn't accept is **clamped down its own ladder**. A profile bound to
`reviewer` gives a reviewer a model and level, never a runtime: reviewers run
on pi. `fallback:` names the same model
reached a different way and is checked before the pane spawns: if the
primary's key is missing, the fallback is used and said out loud. Keys live in
the workspace's gitignored `env.local`; nothing but the model id ever reaches
this repo.

## Team workspaces

A team workspace has three layers:

| Layer | File | Committed | Holds |
|---|---|---|---|
| Team contract | `workspace.yaml` | yes | everything, including the default routing |
| Personal routing | `workspace.local.yaml` | no | routing overrides, `me:`, and turning a product's agent off on this box |
| Secrets | `env.local` | no | keys |

The local file may change `role_profiles` (workspace-level and per
`products[]`/`repos[]` entry), add or replace `worker_profiles`, override
`env:` keys, set `me:`, and set `orchestrator: manual` on a `products[]`
entry. It may not change `policy`, `tickets`, `repos`,
`products`, `people`, gates, prefixes, merge or review settings, or
`services` - and the policy block rendered into CLAUDE.md/AGENTS.md always
comes from `workspace.yaml` alone. `cel doctor` fails if `workspace.yaml` is
not committed.

**Turning a product's agent off on one box.** A local
`products[].orchestrator: manual` over a committed `auto` (on the product,
`layout.orchestrators` or the default) means this box's `cel ws up` and
steward never start that product's agent, and the steward raises nothing
about it (it clears an old fault with `... (manual via workspace.local.yaml)`).
`cel ws status`, `cel fleet` and `cel doctor` read the same answer. It works
in that direction only: a local `orchestrator: auto` over a committed
`manual` (or anything but `manual`) is ignored and `cel doctor` warns - a
teammate's committed decision not to auto-start wins. Repos carry no
`orchestrator:`, so there is no repo-level form.

```yaml
# workspace.local.yaml - I stopped bundle's agent on this box; leave it stopped
products:
  - name: bundle
    orchestrator: manual
```

**People.** `people:` in `workspace.yaml` lists who is on the team: an `id`
(`[a-z][a-z0-9-]{0,30}`), their own forge `login`, `roles:` held for every
product and `products: { <product>: [roles] }` held for one. Roles are
`owner`, `product-lead`, `qa`, `design`, `release` and `approver`. Each login
says which person it is with `me: <id>` in its own `workspace.local.yaml`.
That is self-asserted: `cel doctor` checks it against the login's own forge
account (`gh api user` without the workspace's `github.user` token, or the
login's own Forgejo token) and warns on a mismatch. `cel people [--json]`
lists everyone, their roles, and which person this login is.

**One login runs each product.** Each teammate's steward otherwise starts
every `orchestrator: auto` product, and two builders then work the same repos
with separate review state. `products[].home: <id>` (or `repos[].home` for a
repo in no product) names the person whose login runs the product's agents.
On any other login:

- `cel run orchestrator|solo --product <p>`, lanes included, refuses with
  `cel run: atlas runs on sam's login (products[].home: sam); this login is jo - ask sam, or pass --force`;
- `cel ws up` and the steward skip the product silently (`cel ws up
  --dry-run` and `cel ws status` say whose it is);
- a login with no `me:` is treated as nobody's, so it starts no product
  that has a home (fail closed).

**Owner questions go to the people who hold the role.** An agent asks with
`cel decide ask ... --topic product|qa|design|release|merge|owner` (default
`owner`). The topic is a role (`product` is `product-lead`, `merge` is
`approver`), and the route is computed when the question is asked: the asker's
product (its launch's `CEL_PRODUCT`, or its `<product>-orch`/`-<lane>`
mailbox), the people holding that role for it, else the workspace's
`owner`s. The record keeps `topic` and `route: {role, product, people}`; `to`
stays `owner`. Then:

- `cel decide list --mine` (this login's `me:`), `--for <id>` and
  `--topic <t>` narrow the queue; `--mine`/`--for` keep the questions routed
  to that person plus the unrouted ones;
- the desktop notification for a routed decision fires only on a login whose
  `me:` is on the route (a login with no `me:`, and an unrouted decision,
  notify as before);
- `cel decide answer|drop` is a person's: it records `me:` as who answered
  (`--by`, if given, must equal it), and a routed question is answered only
  by its people or by an `owner`, recorded as `by: sam (owner)`. No agent
  answers or drops one - the guard refuses it for solo, orchestrator, root,
  lead and member, and `cel decide` refuses any process launched as an agent;
  core still relays the owner's word, on unrouted questions only. The asker
  still retires its own question with `cel decide withdraw`;
- the dashboard answers as `--by <me>`, shows a **mine** chip (on by default
  when `me:` is set) and a **topic** grouping, and with no `me:` answers only
  unrouted questions;
- the steward's daily line counts the routed questions per person.

With no `people:` there is no route, and `cel decide` and the dashboard work
exactly as before: anyone answers, `--by` is free text.

`cel doctor` reports an error for a malformed `people:` entry, a role that
is not in the list, a `me:` or `home:` that names nobody, or a `me:` committed
to `workspace.yaml`. It warns about a `kind: team` workspace with an
`orchestrator: auto` product that has no `home`. With none of these keys,
nothing changes.

Joining a team workspace: clone it (`cel ws add <url>`), copy
`workspace.local.example.yaml` to `workspace.local.yaml`, set `me:` and choose
your profiles, run `cel doctor`.

## Per-box routing

A team box under one login per person, each on a different provider, has a
problem `env.local` cannot solve: root and the orchestrators only ever get a
model from `role_profiles`, which lives in the workspace's own committed
file - one binding, shared by everyone who clones it. A login without the
credential that binding names has no route for either, short of an
uncommitted edit to a file everyone else also reads.

`workspace.local.yaml`, gitignored, sits beside `workspace.yaml` and overrides
`role_profiles` (workspace-level, and per `products[]`/`repos[]` entry,
matched by name) and adds `worker_profiles` - or replaces one whole, by name,
if it names one the committed file already has, so a local `sonnet` profile
never inherits a base `sonnet` profile's `via:`, `fallback:` or `thinking:`.
It is allowed to do only that, plus `me:` (which person this login is, see
[Team workspaces](#team-workspaces)) and a product's `orchestrator: manual`
(off on this box, never on): it cannot add a repo, change policy, or hide
anything a teammate reading `workspace.yaml` needs to know. Local always wins
over the committed file, except that a local `orchestrator:` can only start
fewer agents. `cel doctor` warns on anything else the file
declares (an unrelated top-level key, a `products[]`/`repos[]` name with
no counterpart in the committed file, or a local `orchestrator:` other than
`manual`) since the merge otherwise drops it with no error.

```yaml
# workspace.local.yaml, gitignored, this box only
worker_profiles:
  sonnet: { runtime: claude, model: claude-sonnet-5, thinking: low }
role_profiles:
  orchestrator: opus   # a base profile - resolves fine, no local entry needed
  solo: sonnet          # a local profile - see worker_profiles above
```

`cel profiles` marks a binding or a profile that came from this file with
`(local)`.

## Subscriptions

Agents do not run on API keys alone. They run on **signed-in subscriptions**
— Claude and Codex (ChatGPT) — and a five-hour window at 100% stops every
agent on that account just as hard as an empty balance does, without an error
message anywhere anyone looks.

`cel quota` reads every signed-in account and prints them above the API
balances, one row per account (provider plus email): first the CLIProxyAPI
vault (each account's usage read with the vault's own access token, never
refreshed), then `omp usage --json`, then the credential files of pi, Claude
Code and the Codex CLI for any provider neither answered for, and OpenCode
Go. Each window shows its percentage, the local time it resets, and whether
extra usage is still a path. A token is never printed anywhere — an account
is named by its provider and a short stable id. The readings are cached for 60 seconds, so `cel fleet --json` and
the dashboard's Subscriptions card read the cache rather than calling a
provider on every draw. A window whose reset time has passed shows as
`reset, no fresh reading` until a fresh read — never its old percentage —
everywhere these numbers appear, including after a read that failed. When a
read fails, a window that has not reset keeps its last percentage, marked
`last known` with the time it was read: a spent window stays spent — still
alerted on and still vetoed — until a reading says otherwise. Once that
reading is more than `CEL_SUB_UNREAD_AFTER_H` hours old (default 2) the
window is `unread`: still drawn, never forecast. The steward's pace item says
instead that the account has `not read since <time>`, why, and what to do —
and an unread window at 100% stays at risk, said as `100% spent (last known,
not read since <time>)`.

A vault account whose access token has expired is not refreshed here —
CLIProxyAPI is the only refresher on the box; Celestial never refreshes a
credential itself. It reads `token stale - refreshed next time this account
serves traffic` unless the gateway reports why its own refresh failed. That
is one read-only `GET /v0/management/auth-files` with the management key,
sent only to a loopback address (`127.0.0.1`, `::1`, `localhost`) because
that key opens the whole vault; the answer, or the failure, is cached for
`CEL_SUB_TTL` seconds (60) in `gateway-states.json` (0600) beside the
subscription cache. A refused refresh (invalid grant, unauthorised, revoked)
and a 401/403 from the provider for a token the vault calls live both read
`needs login: cel gateway login <provider>`, because only a person at a
browser can bring it back. Any other refresh error reads `token stale - the
gateway refresh is failing (…)`.

The steward raises **one rolled-up item per signed-in credential-file
account** (pi, Claude Code, the Codex CLI) — a status over `CEL_SUB_WARN_PCT`
(80), a blocker at 100 — and takes it down when the window drops or once the
reset it quoted has passed; a fresh reading of the new window over the line
raises it again at once. A profile routed at one of those accounts whose 5h
window is spent is vetoed before its pane spawns, the same way a dry balance
is. Vault and omp accounts reach the steward through the pace item: one item
naming every account that, at this week's pace, hits 100% before its reset or
is already at 95%, and every account not read for `CEL_SUB_UNREAD_AFTER_H`
hours. Separately, the orchestrators' own Claude pool (omp's Anthropic
credentials) raises one blocker when every live credential is at or above
`CEL_ORCH_POOL_WARN_PCT` (85) of its 5h or 7d window, and one more, once per
change, naming credentials omp has disabled (`omp login anthropic`).
