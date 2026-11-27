# Watch and steer

- **`cel fleet`** — the whole box in one deterministic read: every workspace,
  every product (a repo in no declared product is its own), its mode, whether
  its agent and lanes are live, PRs, and root's mail. Token-free and free of
  agent judgement; `--json` for scripts. `cel core` answers from this, never
  from memory.
- **Liveness: what the pane is doing, not how long it has been quiet.** A
  runtime's own status can be wrong — a suite hung while herdr said
  `working`, an agent burned cores while it said `idle`. Code filters first,
  and each candidate costs one decision request carrying the last lines of its
  pane. The answer (`working`, `waiting_on_input`, `looping`, `crashed`,
  `finished`, `unclear`) is only ever REPORTED — no path from an answer to a
  kill or a prompt — and the timers decide alone whenever there is no model
  or the answer is below `liveness.min_confidence`. Configure under
  `liveness:` in `~/.local/share/cel/config.yaml`; `cel doctor` says whether
  it is on and which model answers.
- **Memory is part of that read.** `cel fleet` prints `mem` per product and
  `box 6.9G free of 24G` on each workspace's head line; `--json` carries the
  numbers and a `box` block. The steward raises one blocker under 10% naming
  the largest trees (cleared at 15%) — it never kills anything.
- **`cel dash`** — one dashboard for the whole box: an attention queue ("needs
  you"), every in-flight branch joined with its agent + PR + CI state across
  every workspace, sticky filters, and a composer that mails a product agent.
  The old `/classic` page is retired and redirects to `/`.
- **`cel publish <file>`** — self-hosted pages server (tailnet-private by
  default, per-document promotion to a public tier). Published pages carry a
  feedback widget that routes straight back to the agent that published them —
  select text to comment on the exact passage. A public share carries the
  page's own screenshots, stylesheets and linked non-page files (same
  directory only, copied at share time, never symlinks); another page it
  links goes too only when named (`cel publish --public --include m.html`, or
  `"include"` in the promote call). The token serves exactly that list.
  `cel pages bundle <doc> [--include m.html]` adds them to a live share
  without changing its link or expiry.
- **`cel gc`** / **`cel steward`** — the cleanup and liveness machinery, also
  runnable by hand. `cel gc --orphans` reaps what the plane started and nobody
  owns any more: inbox watchers whose agent exited, test fixtures whose
  worktree is gone, bare shells on ptys no pane owns, gate runners whose suite
  was killed. Only this user's processes reparented to init are candidates;
  box services, permanent servers and protected launch lines are never taken.
  The steward does it once a tick and says so in one line. The worktree pass
  covers herdr worktrees, every solo agent's worktrees and every repo a
  registered workspace declares, by the real path of its clone (`repos/<name>`
  may be a symlink to a clone outside `~/ws`), and every worktree git records
  for it, wherever it lives. It never touches `~/orca/workspaces` or a
  follow-main `local-*` tree. What it keeps, and why, is in
  [What `cel gc` keeps](what-lives-where.md#what-cel-gc-keeps). `cel gc` prints, and
  `cel doctor` repeats from the last sweep, one line per repo: worktrees,
  removed, stale records pruned, kept by reason.
- **`cel box space`** / **`cel gc --box`** — the box is a resource the factory
  spends. `cel box space` measures what is large, what of it is reclaimable,
  and which of three classes it is in: **ours** (`~/.cache/cel` entries older
  than 7 days, `~/.local/state/cel/scratch` older than 3), **regenerable**
  (docker images and build cache; bun, npm, uv and pip caches older than 14
  days; Playwright, Puppeteer and Selenium downloads older than 30 — deleting
  costs a re-download, never data) and **someone's** (`~/restore`,
  `~/backups` — reported with an age and a suggestion, and never swept by
  anything). It also shows the reviewer panes and the memory they hold.
  Worktrees are not a box class: only `cel gc`'s worktree pass removes them.
  `cel gc --box` sweeps the first two after the worktree pass; only direct
  children of a cache root go, never the root. Docker removes only
  unreferenced, unprotected full image IDs (without force), plus build cache;
  there is no image age filter. `--dry-run` reports the same policy without
  deleting. The steward sweeps on a six-hour cadence
  (`CEL_STEWARD_BOX_WINDOW`) and `cel doctor` warns below a free-space floor
  (`CEL_BOX_FREE_FLOOR_GB`, default 20), naming the largest reclaimable class
  and the command that clears it. `cel box diag` is the
  same question asked by an alert: at most two bounded lines - docker's own
  images / build cache / volumes summary (left out when docker is absent,
  slow past `CEL_BOX_DIAG_TIMEOUT` seconds, default 30, or not this user's to
  query) and every running `docker build` / `buildx` with the agent whose pane
  or working directory it runs in - secret values in the build's argv
  (`--build-arg`, `--secret`, `-e`/`--env`, any `KEY=VALUE`) printed as `***`,
  and the herdr lookup held to the same time limit.
