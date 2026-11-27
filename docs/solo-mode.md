# Solo mode

Every product is built by **one agent** that plans, writes, tests and ships it
itself, using everything its own runtime offers — its own git worktrees, its
harness's subagents in parallel, several branches and PRs at once:

```yaml
products:
  - name: atlas
    repos: [atlas-app]
    mode: solo          # the default when absent
```

`cel mode [<product>]` shows the mode; `cel mode <product> solo` sets it,
editing that one line of `workspace.yaml` in place (comments and layout
untouched) and restarting the product's live agent **on the same session**
once its current turn ends — so an agent can set its own mode.
`--no-restart` leaves the live agent alone until its next launch. Fan-out was
retired: a legacy `mode: fleet` is refused at launch (`cel run orchestrator`
names `cel mode <p> solo`), and `cel mode <p> fleet` is refused and writes
nothing. `cel run solo` starts the solo agent directly.

The solo agent is still *the product's agent*: same directory, pane name and
mailbox (`<product>-orch`) as an orchestrator, so mail, decisions, the
steward and the dashboard reach it unchanged. `cel run solo` and `cel run
orchestrator` start the same agent: role file `core/roles/solo.md`, launched
with `CEL_ROLE=solo`, `CEL_PRODUCT=<product>` and, for a lane,
`CEL_LANE=<lane>`. The guard lets it write code, commit, push, open PRs and
start a reviewer for its own PR, and refuses starting any other Celestial
agent or pane (`cel run reviewer` excepted), recording a verdict on its own
PR, `cel decide answer|drop`, merging by any route but `cel solo land`, and
changing its forge except through `cel forge`. Its model is
`role_profiles.solo` (narrowed per product or repo), else
`role_profiles.orchestrator`, else `runtime.orchestrator` (default `claude`).

Its PRs follow the workspace's PR and review policy, keyed by the PR itself:

- the reviewer records `cel solo review <repo>#<n> approved|changes --head
  <full 40-character sha> --by <alias>` (an approval must equal the PR's current head; verdicts
  live in `<ws>/.cel/solo-reviews.json`, an extra reviewer's under
  `<repo>#<n>/review-<focus>`) and sends findings to
  `<product>-orch` (the lane that started it, or the lane the repo declares
  with [`repos[].lane`](how-it-works.md#solo-lanes-several-big-goals-one-agent-each)). The solo agent itself can never record a verdict on its
  own PR, and only it (or a person) lands one - not a reviewer;
- `cel solo land <repo>#<n>` (`lib/solo.sh`; the CI rule in `lib/land.sh`)
  merges once it finds: `merge: self`; an open non-draft PR the workspace's
  account opened (or an author the repo lists in `pr_authors`, below); for the
  plain reviewer, the forge's review decision `approved` or a recorded
  `approved` verdict at the current head, plus each
  [extra reviewer's](review-loop.md#extra-reviewers-a-focus-by-hand-or-by-policy) or QA
  agent's own approval of that head; no red check and none still running; no
  conflict; and every check the base branch requires - through classic branch
  protection or a repository/organisation ruleset - green on that head. It
  merges only that head (`--match-head-commit`), and CI on the head is the
  evidence the squash body cites. Only when neither protection nor any ruleset
  requires a check does the repo gate run locally instead, in the solo
  agent's own clean worktree at exactly that head (none is a refusal), after
  proving the forge's `refs/pull/<n>/head` is that commit; requirements that
  cannot be read refuse the land. With [AFK](../README.md#commands) on, AFK must admit
  the land first. After the merge it retires the PR's reviewers and QA agents.
- the land says who landed it. The forge shows every land as merged by the
  workspace's account (on Forgejo, and on GitHub when that account is the
  owner's), so `cel solo land` names the agent itself: the squash message ends
  in git trailers -

  ```
  Reviewed-by: widget-pr-7-review (approved)
  Landed-by: widget-orch (cel solo land)
  Gate: CI (suite) on <head>
  ```

  (`Reviewed-by:` for the recorded verdict's reviewer, each approving forge
  account and each required extra reviewer; the review note, if any, in a
  paragraph above them), and just before the merge it comments on the PR:
  `Landing as widget-orch via cel solo land (attempting): approved by
  widget-pr-7-review at <head>, checks green.` If the forge refuses the merge,
  a second comment says `Not landed: ...` with the forge's reason, paths and
  token-shaped text taken out (and left off entirely if the comment would fail
  the squash body's hygiene scan). The lander
  is the alias the agent's launch gave it, named only for a role that lands
  (solo, orchestrator); a shell with no role is the account, `by hand`, and any
  other role is `an unnamed agent`. Every name is one token: one carrying a
  control character refuses the land before anything is posted, so a newline
  cannot forge a trailer. A refused comment is reported and does not stop the
  merge - the trailers carry the record. The body is checked against the
  history scan's ticket rule before anything is posted. Separate forge
  accounts per agent would put the name in "merged by" itself; that is the
  owner's call, not something `cel solo land` changes.
- a PR a bot (or any other forge account) opened for the product lands too
  when the repo lists that login in the committed `workspace.yaml`:

  ```yaml
  repos:
    - name: example
      pr_authors: [example-bot]
  ```

  Its reviewer can then record verdicts on it, the steward nudges about it
  like the account's own, and `cel solo land` lands it with every check above
  unchanged, adding `PR-author: example-bot (allowed by repos[].pr_authors)`
  above `Landed-by:`. An author nobody listed is refused as before, and the
  refusal names the line to add. The list is the team's contract:
  `workspace.local.yaml` cannot add to it (`cel doctor` names a local
  `pr_authors` as ignored), and `cel doctor` fails an entry that is not a
  login-shaped string.

  List the author exactly as the forge reports it; nothing is normalised, so
  a person whose login happens to be a bot's name never passes as the bot:

  | forge | PR opened by | it reports (`cel forge pr view <repo>#<n> --json`, `.author`) | put in `pr_authors` |
  |---|---|---|---|
  | GitHub | a GitHub App (Dependabot, Renovate, your own App) | `app/<name>`, e.g. `app/renovate` | `app/renovate` |
  | GitHub | a machine user (an ordinary account a bot logs in as) | its plain login | `example-bot` |
  | Forgejo | any account, bot or not | its plain login | `example-bot` |

  GitHub's REST API spells an App `<name>[bot]`; cel reads authors through
  `gh`, which never does, so that spelling is not accepted.

The rest of the box sees a solo product for what it is: `cel fleet` draws it as
`solo <agent state>  worktrees N` (JSON: `mode`, `solo_worktrees`), the
dashboard tags its agent row, the steward tells the agent - once per head - when
a PR of its is approved and green but unmerged, and `cel gc` removes its
worktrees under `<ws>/.cel/solo/<product>/` once their PR has merged or closed
and nothing in them is unsaved (a worktree with no PR yet is kept).
