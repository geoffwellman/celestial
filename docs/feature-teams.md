# Feature teams

Small work stays with the product's agent. A feature with two or more parts
that can be built at the same time, or one that needs a specialist (device
QA, design, data, a release check), gets a **team** that the product's agent
leads. The lead stays the only integrator: one integration branch and PR per
repo, reviewed by `cel run reviewer` and landed with `cel solo land` as in
[Solo mode](solo-mode.md).
Members are short-lived scoped agents, admitted against the box-wide helper
budget that every product's reviewers and team members share - by default 8
helpers and 4 team members in all (`budget.max_live_agents`,
`budget.max_team_members`; `cel run reviewer` can be refused too). Product
agents (`<product>-orch`, solo lanes) and core are shown by `cel budget` but
never counted: a box running ten products still has all 8 helpers for their
reviewers. Only the product's orchestrator (`<product>-orch`, `CEL_ROLE` solo
or orchestrator and its product proven by `CEL_PRODUCT` or its mailbox)
starts and leads a team. A process with no agent identity is refused; the
owner asks the product's agent by `cel inbox` or answers its `cel decide`.

```
cel team start login --product shop --brief-file brief.md      # lead only
cel team event login candidate.updated --data '{"repo":"web","head":"<sha>","branch":"CEL-login"}'
cel team add login builder --repo web --owns 'src/auth/**' --focus backend --task-file t1.md
cel team add login qa --repo web --focus browser --task-file t2.md
cel team status login            # roster, liveness, candidate heads, verdict freshness, who owes next
cel team close login             # retires everyone; refuses over unpushed builder work
```

Everything a team is lives in `<ws>/.cel/teams/<feature>/` (feature ids are
`[a-z0-9][a-z0-9-]{1,40}`): `team.json` (the roster), `brief.md`,
`acceptance.yaml`, `contracts/`, `events.jsonl` (append-only),
`verdicts.json`, and a scope packet per member, `members/<alias>.md`. Every
write holds the folder's lock and JSON is replaced whole.

- **Roles** — `product`, `design`, `builder`, `qa`, `platform`, `release`,
  `analyst` (`core/roles/team-<role>.md`), each narrowed by an optional focus
  pack (`core/roles/focus/<role>/<focus>.md`, a short checklist). Only a
  builder writes code, on `team/<feature>/<member>` in its own worktree,
  inside the paths it `--owns`; it pushes that branch and never opens a PR.
  Two builders' `--owns` globs may not overlap in one repo; where overlap
  cannot be decided exactly it counts as overlapping and the refusal says why.
- **Adding a member** admits it against the box-wide agent budget first (a
  refusal is printed and nothing is written), then reserves its row, writes
  its scope packet and a one-time launch token, and launches it with `cel run
  member`. It is `reserved` until the launcher confirmed the exact agent AND
  the member ran `cel team ack`; a launch that never confirms stays reserved
  and is not relaunched.
- **Models** — a member launches on `role_profiles.team-<role>`, else
  `role_profiles.member`, else the workspace's `runtime.orchestrator` with
  that CLI's default model; a `products[]` entry may narrow either binding
  for its own product, and `cel team add ... --model m` sets the model for
  one member. Example: [Configure your teams](configure-teams.md#1-declare-products-models-and-review).
- **Reporting** — members append `task.ready` (head + gate result) and
  `preview.ready` (platform or qa) events with `cel team event ... --to
  <alias>` (which also mails), and judge the lead's candidate head with `cel
  team verdict <f> --repo r --head <sha> pass|changes|blocked|advisory
  --evidence <file>`. A newer `candidate.updated` makes older verdicts show
  as stale.
- **Owner decisions** go through the lead's `cel decide ask`; only the lead
  records a `decision` event. Members spend nothing unless the
  lead sets the team's spend cap from one (`cel team cap <f> "<cap>"`, kept in
  `team.json`); nothing in `brief.md`, which members can write, widens a
  member's authority or spend.
- **Closing** — `cel team retire <f> <alias>` closes one member's pane; `cel
  team close <f>` retires everyone and refuses while a builder's work is not
  on origin, unless `--force-keep` (which keeps those worktrees).
