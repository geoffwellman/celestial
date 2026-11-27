# What lives where

The repo is **mechanism only**. Your setup never lands in it:

| | Where | Committed? |
|---|---|---|
| The tool | `~/celestial` | public repo (this one) |
| Which workspaces exist on this box | `~/.local/share/cel/registry.yaml` | never |
| Published pages | `~/.local/share/cel/pages*` | never |
| Workspace content + overrides | `~/ws/<name>` (own private repo) | yours |
| Secrets | `<ws>/env.local` (gitignored) | never |

Workspace files always win over plane defaults: `layouts.yml` over the plane's
layouts, `externals.yaml` additively, `env:`/`env.local` over your profile,
workspace `skills/` scoped to that workspace's repos only.

## Cleanup safety

GC protects every removal path with process checks. It requires a clean
attached Git HEAD and proven default-branch ancestry, or a merged PR whose
recorded head is exactly the local HEAD. A missing/broken default, unknown
discovery or newer local commit blocks removal.

The reaper uses herdr foreground-process evidence, a workspace role-file
ownership stamp and a durable observed-idle clock under
`~/.local/state/cel/gc-idle.json`. Its first observation never kills.
Working/blocked/unknown agents, root/core, manually launched processes
and unsupported ownership stamps are retained regardless of age. Cooperating
Celestial operations share lifecycle locks; unrelated manual Git/herdr changes
cannot be made transactional with external tools. Atomic state replacement
prevents partial readers, but is not a promise of power-loss durability.

## What `cel gc` keeps

`cel gc` removes a worktree only when it can show the tree is finished and
nobody is in it. Anything it cannot read counts as in use.

**Which trees.** Herdr worktrees; each solo agent's own worktrees
(`<ws>/.cel/solo/<product>/`); and every other linked worktree
`git worktree list` records for any repo a registered workspace declares. A
repo is taken by the real path of its clone, so `repos/<name>` may be a
symlink to a clone outside `~/ws`, and its worktrees may sit beside it, in
`/tmp`, or anywhere; a clone several workspaces name is swept once. Those
trees go by the solo rules: a merged or closed PR whose head is exactly the
tree's HEAD, a clean attached HEAD that has landed, no live process and no
agent. A clone is asked about as the GitHub account its workspace declares;
one registered by workspaces declaring different accounts is not asked
about, so its trees are kept. Trees under the review-checkout directory are
left to that pass.

**Kept before any other rule, in every pass:**

- `owner`: anything under `~/orca/workspaces`, compared as given and resolved.
- `follow-main owned`: a tree whose directory name starts `local-`. A
  product's follow-main loop makes one per main commit and retires them
  itself.
- `claimed`: a tree that contains the owner root, another worktree, a clone,
  a workspace or its `repos/<name>`, or the review checkouts; is a registered
  checkout; is locked in git; or (repo trees only) has a pane or agent in it -
  an unreadable pane list claims every repo tree.

After those come `symlink`, `live`, `detached` (no branch, so no PR can speak
for it), `open-pr`, `no-pr`, `unlanded`, `busy`, `unidentified` and `refused`
(git or herdr refused the plain, non-forced remove). A tree with a Rex agent
in it is never removed.

**Which process keeps a tree live.** Only this user's processes are visible.
One whose cwd is in the tree keeps it. One whose cwd cannot be read keeps
every tree, with three exceptions:

- **A zombie or dead process** (`Z`/`X`) runs nothing and keeps nothing - unless
  it is a thread-group leader whose other threads still run: a `Z` leader with
  any thread that is not `Z`/`X` is alive. A pid whose state cannot be read
  counts as alive.
- **Fixed system processes:** the user's own `systemd`, `(sd-pam)`,
  `ssh-agent`, `sshd-session` and `sftp-server`, matched by exact name.
- **An own-uid `smbd`** (Samba forks one per client, running as the connecting
  user) occupies exactly the directories Samba exports: a tree inside, equal to
  or containing a share is kept, and nothing else is. The shares come from
  `testparm -s`, else `/etc/samba/smb.conf` with its includes, plus
  `net usershare` files when usershares are enabled; `[homes]` is the passwd
  home and symlinks are resolved. If they cannot all be named (a `%`-macro or
  relative path, an unparsable line, an unreadable usershare), that `smbd`
  keeps everything.

The sweep reads `/proc` once to choose, then walks it again (and reads the
shares afresh) immediately before each removal. The reviewer-checkout pass
applies the same rules to open files as well as cwds.

**Stale records.** A record whose directory is gone is pruned with
`git worktree prune --expire 7.days.ago` (git measures the age of the
record's admin files, not how long the directory has been missing). An
owner's record, and one whose parent directory is missing too
(`parent-missing`: an unmounted disk or share, a dangling symlink), are kept;
prune clears every due record of a clone at once, so one such record keeps
all of that clone's stale records (`stale`), as does a record younger than the
grace. `--dry-run` names what would be pruned.

**Reviewer checkouts** under `~/.local/state/cel/reviews` go once all of these
are facts: the PR is merged or closed - asked of the repo's own forge, the
answer naming exactly that PR; unreadable is kept - and closed more than
`CEL_REVIEW_CHECKOUT_KEEP_DAYS` (default 3) days ago; no reviewer of the PR is
recorded and no pane, process cwd or open file is in it (by the rules above);
no retained Rex retirement packet cites it; and it holds nothing of its own -
an untracked or modified file (ignored build output does not count) or a
commit only it has keeps it, and the sweep names it. A private clone must
also be the PR's (HEAD at or behind the PR's head, or cloned from the repo).
All of it is asked again right before the remove, under the lock `cel run`
holds while it starts a reviewer. At most `CEL_GC_REVIEW_CHECKOUT_CAP`
(default 30) are asked of the forge per pass, oldest first.

Each sweep prints one line per registered repo with worktrees: total,
removed, stale records pruned, left to the review-checkout pass, and kept by
reason. `cel doctor` repeats them from the last sweep (`last gc sweep Nm
ago`), read from `~/.local/state/cel/gc-kept.json`.

## Private HTTP services

Private pages and dashboard listeners are local/tailnet control surfaces, not
multi-user authenticated applications. Do not tunnel them onto the public
internet. Published private HTML is trusted active same-origin content.
Only the separate token-addressed public pages tier is intended for sharing.

Private requests require an exact trusted Host. Browser mutations also require
an allowed Origin and a per-process `X-Cel-CSRF` token; built-in controls supply
it automatically. For reverse proxies or extra tailnet names, configure
`CEL_PAGES_TRUSTED_ORIGINS` / `CEL_DASH_TRUSTED_ORIGINS` with comma-separated
exact origins such as `https://control.example` before starting the service.
Forwarded headers never grant trust. Wildcard binding does not grant arbitrary
Host access. Restart after configuration changes.

Local automation reads `{csrfToken}` from `GET /api/session`, then supplies
that value in `X-Cel-CSRF` with `Content-Type: application/json` on mutations.
The session endpoint has no CORS permission and is not available on the public
tier. Generated tokens rotate on restart; stale browser tabs need a reload.
Optional `CEL_PAGES_CSRF_TOKEN` / `CEL_DASH_CSRF_TOKEN` overrides require at least
32 URL-safe characters; treat them as secrets. This is anti-CSRF and
DNS-rebinding protection, **not account authentication**: a directly trusted
local/tailnet caller can obtain the token.
