# The review loop

Declare a reviewer in `workspace.yaml` with a gateway-backed Claude or Codex model:

```yaml
review: { runtime: pi, model: sonnet }
```

`sonnet` resolves to the highest versioned Claude Sonnet ID in the live gateway
catalog; `opus` maps to `claude-opus-5-5`. Explicit advertised Claude IDs and
`ompgw-claude/<model>` IDs are preserved. `cel run reviewer` checks that the
gateway is installed, ready, has a Claude account, and advertises the selected
model before opening a pane. Missing gateway/model data refuses launch; pi's
ambient provider and Anthropic login are never used. Configure a reachable
Claude account with `cel gateway` before starting reviewers.

A Codex-family id (`gpt-6.1-sol`, or spelled `ompgw-codex/gpt-6-astra`) runs
the reviewer on the gateway's codex provider instead - `review: { runtime: pi,
model: gpt-6.1-sol }` or `cel run reviewer ... --model gpt-6.1-sol`. The launch
refuses when the gateway does not publish that id or holds no usable codex
account; an id is never substituted.


A product agent starts one reviewer pane per PR (`cel run reviewer --repo r
--pr n`, or `/cel-review`). Its inbox extension wakes the idle reviewer when
new mail arrives, so request-changes and re-review round trips do not wait for
someone to type. `review.runtime` stays in the workspace schema for
compatibility but no longer selects the reviewer runtime: a value other than
`pi` is ignored, and `cel run reviewer` warns naming the field. `review.model`
selects the requested model, and `review.thinking` (optional) the reviewer's
reasoning level over the workspace's `thinking:` - clamped to what pi accepts,
as for any role; a profile bound to the reviewer, or `--thinking`, still wins. A reviewer delivers one verdict per round with
`cel solo review <repo>#<n> approved|changes --head <sha> --by <alias>`, bound
to the exact commit it read, and mails its findings to the product agent,
which fixes, pushes and asks for re-review; you hear about it only on approval
or escalation. A steward tick (every 5 minutes by default, deterministic,
token-free) backstops the loop: verified disposable worktrees are removed,
stalled PRs are nudged, and blocked agents or preserved unlanded work are
named until dealt with. Unknown state is a reason to retain work, not
evidence that it is safe to delete.

## Extra reviewers: a focus, by hand or by policy

A specialist reviews a PR beside its plain reviewer, through one focus pack
(`core/roles/focus/reviewer/`: `security`, `performance`, `db-migration`):

```sh
cel run reviewer --repo atlas-web --pr 41 --focus security
```

It is a reviewer of its own: the pack is appended to the reviewer role, it is
named `<repo>-pr-<n>-review-<focus>` (`atlas-web-pr-41-review-security`; a
name cut to 32 characters into another reviewer's is refused), has its own
pane, checkout and mailbox, and counts against the box's helper budget like
any reviewer. It records with `cel solo review atlas-web#41 approved|changes
--head <sha> --by <its alias> --focus security`. A caller launched as a
reviewer signs only as itself, on the plain slot as on a focus one: `--by`
must equal the mailbox its launch line gave it (`CEL_INBOX_ME`, with
`CEL_ROLE=reviewer`), and a focus verdict needs exactly that. In a Herdr
pane this identity is the launch environment - the same trust as the guard
that stops the solo agent recording its own verdict, which another process
on the box could imitate; a Rex reviewer is bound to its alias, repo and PR
by its receipt (`cel_assert_reviewer_identity`). A focus with no pack is
refused, naming the packs there are.

The workspace can require them instead, by the files a PR touches -
`review.extra` workspace-wide and under a `repos[]` entry, read from
`workspace.yaml` only:

```yaml
review:
  model: sonnet
  extra:
    - focus: security
      paths: ['lib/auth/**', '**/*token*']
    - focus: db-migration
      paths: ['migrations/**']
```

An entry has `focus`, `paths` and an optional `kind`: `review`, the default,
or `qa` (a QA agent - [below](#qa-agents-the-change-run-not-read)). Globs match repo-relative paths, both sides of a rename,
and the whole path: `*` and `?` stay inside one directory level, `**` as a
whole segment spans any number of directories (`**/*token*` matches
`token.sh` and `a/b/api_token.ts`; `lib/auth/**` everything under
`lib/auth/`, not `lib/auth` itself), everything else is literal. Nothing
malformed is skipped: a bad entry, a `review:` that is not a map, a key in
it Celestial does not know (workspace-wide `runtime`, `model`, `thinking`, the retired `post`,
`extra`; on a repo only `extra` - so `extras:` is an error), and two
`repos:` entries of one name each refuse `cel run reviewer` and `cel solo
land` for the repos they reach, and `cel doctor` names them. With a policy, `cel run reviewer --repo r
--pr n` starts (or reuses) the plain reviewer and then every extra reviewer
whose paths match a file the PR touches now, saying which and why.

`cel solo land` then requires an approval of the exact current head from
every reviewer the policy requires for that PR - the plain one and each
matching extra one, computed from the PR's files at land time - and counts an
extra one only by a verdict its own alias recorded. A missing or stale one is
refused by name, with the command that starts it; one that can never start
(its name cut to 32 characters is another reviewer's) is named with what to
change instead. A focus reviewer started
by hand that the policy does not require is **advisory**: its approval adds
nothing and a verdict for an older head holds nothing up, but its `changes`
at the head being merged blocks the land, as a red check does - a finding at
that head is a finding whoever asked for it. The steward's "approved and
green, land it" nudge and the dashboard's PR approval use the same rule;
`cel solo approvals <repo>#<n> [--json]` shows each reviewer the PR needs and
its word on the current head.

## QA agents: the change run, not read

For UI paths a workspace can require a QA agent beside the code reviewer: it
does not read the diff, it USES the change at the PR's exact head.

```yaml
review:
  extra:
    - kind: qa
      focus: browser          # core/roles/focus/qa/: browser, exploratory, mobile-device
      paths: ['web/**', '**/*.tsx', '**/*.css']
```

`cel run reviewer --repo r --pr n` then starts it with the plain reviewer when
the PR touches those paths (same box budget admission); start one by hand with
`cel run reviewer --repo r --pr n --qa browser`. Its role is
`core/roles/pr-qa.md` plus the qa focus pack - the same packs a feature
team's `qa` member uses. It is named `<repo>-pr-<n>-qa-<focus>`
(`atlas-web-pr-41-qa-browser`; the `qa-` slot never collides with a
`review-` one), has its own pane, detached checkout, mailbox and registry row,
and runs as a reviewer (`CEL_ROLE=reviewer`).

It builds and runs the head with `cel preview <repo>#<n> --qa <focus> --head
<sha>`: the repo's own `preview:` block, a preview of its own (its own server,
ports from 4600 and checkout under `<workspace>/.cel/previews/`, never
anyone's plain preview of the PR), refused for any head but the one it was
started for. It drives that in a real browser (or a device or simulator for
`mobile-device`), walks what the PR claims and its edges, and records

```sh
cel solo review atlas-web#41 approved|changes|blocked --head <sha> \
  --by atlas-web-pr-41-qa-browser --qa browser --evidence login-<head12>.png --note "..."
```

under `<repo>#<n>/qa-<focus>` in `.cel/solo-reviews.json`. `approved` and
`changes` stand on a run: that slot's own preview of that head must be on
record when the verdict is, and at least one evidence file - a regular file,
not a symlink, not empty, the image its name says, named with the first 12
characters of the head it shows - is copied (bytes, sha256, size) to
`.cel/qa-evidence/<repo>-pr-<n>/qa-<focus>/` beside the verdict. `blocked`
means it could not run the change (no `preview:` block, a build that will not
start, no browser or simulator) and says why in `--note`: land treats it as
not approved and names the agent, why it was blocked and how to start it.
Land, the steward's nudge, `cel solo approvals` and the dashboard read QA
agents through the same rule as extra reviewers - one rule, no second one; a
hand-started QA agent the policy does not require is advisory, and its
`changes` at the head blocks the land.

Retiring it takes its preview with it: `cel gc` closing it (its approval of
the current head, quiet for the window, or its PR closed, Herdr or Rex) and
`cel solo land` retiring it stop its `cel preview --qa` server and remove that
preview's checkout and its own checkout (a checkout a retained Rex retirement
packet still cites is kept, as for any reviewer). A server that will not stop
keeps its record, the retirement says so, and the steward's preview sweep
stops it once no live agent bears its owner's name; the sweep also stops any
preview of a closed PR. The preview runs with a private, empty `HOME` under its
own state directory, so the app cannot read `~/.config` tokens. Its model is
`role_profiles.qa`, else `role_profiles.reviewer`, else `review.model`.

## What a reviewer may run

Every reviewer - plain, `--focus` and `--qa` - judges and changes nothing it
judges, and the guard knows it by its launch role (`CEL_ROLE=reviewer`)
wherever it stands. git, cel and gh are allowlists for it: git read verbs
only (`diff`, `log`, `show`, `status`, `rev-parse`, `ls-files`, `cat-file`,
`blame`, `grep`, `merge-base`, `describe`, `range-diff`, `for-each-ref`,
`show-ref`, and `fetch` into remote-tracking refs - no refspec colon, `+`,
`--force` or `--recurse-submodules`), whatever global options lead (`-c`,
which can run a command, `-p`/`--paginate`, which runs the pager, and
`--git-dir`, `--work-tree`, `--namespace` and `-C` to anywhere but its own
checkout, which point git at another repository's config, are refused). A
read verb's flags that write a file, run a program or pager or change config
are refused too, in every spelling (separate or attached argument, quoted,
abbreviated, clustered): `--output`, `--ext-diff`, `--textconv`, `cat-file
--filters`, `grep -O`/`--open-files-in-pager`, `--show-signature`, `--help`
and `git help <topic>`, `fetch --upload-pack` and `--set-upstream`; `git
diff`, `log -p`, `show`, `range-diff` and `grep` themselves stay. A
reviewer's git command is taken literally: no `$`, backquote, brace
expansion or unquoted glob before `--`, and no `VAR=` or `env`, `command`,
`exec` or `sudo` in front of git; it sets, exports and unsets no `GIT_*` or
`PAGER` variable. Its launch pins git's environment (pager `cat`,
`safe.bareRepository=explicit`, no `GIT_EXTERNAL_DIFF` or `GIT_SSH_COMMAND`;
[docs/architecture.md](architecture.md#launch-environment-by-role)), so
a bare-repository-shaped directory a PR commits runs nothing when the
reviewer stands in it. Then cel `solo review|approvals`, `inbox`, `preview`,
`serve list|start|stop`, forge reads, `fleet`, `status`, `profiles`,
`budget`, `people`, `decide|learn list` and `help`; gh reads, `gh pr comment`
and `gh pr review --comment`. Everything else - pushes, merges by any tool,
`cel solo land`, `cel afk|release|update|learn add|mode|decide
ask|ws|team|run|gc`, starting or stopping agents or panes - is refused, and
no `CEL_GUARD_ALLOW_ONCE=1` override is honoured for a reviewer: nobody
stands over its pane to approve one.

The guard's job for a reviewer is no git or forge writes and no merges; it is
not a filesystem sandbox. A reviewer may write files - notes, QA evidence -
so a shell redirect (`git diff > notes.txt`, `| tee`) is allowed: it writes
no more than `echo` does, and nothing in a repository's state.
