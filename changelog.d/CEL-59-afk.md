### Added
- **`cel afk` — away from keyboard.** Measured over 2026-09-20/22, what stopped
  the factory overnight was never code: an approved, green, gate-verified PR sat
  36 hours on two bot-review threads that needed a human to type a reply, that
  same PR was rebased five times behind other merges, two PRs paused on "shall I
  land this?" when the workspace already said `merge: self`, and documented
  follow-up work went undispatched waiting for a nod. `cel afk on [--until
  <when>] [--reason <text>]`, `cel afk off`, `cel afk status [--json]` and `cel
  afk log [--json]` turn on a mode that removes that pause and nothing else.
  **AFK changes who decides, never what is required**: a PR still needs its
  review, its green gate and its verdict.

  While it is on, exactly four acts are pre-authorised, each gated on its own
  evidence — resolve a bot review thread whose finding is fixed in a pushed
  commit AND confirmed by a reviewer verdict recorded *after* that commit (the
  reply states what was fixed and cites the commit); land a PR that is approved,
  green, gate-verified, mergeable and fleet-authored; rebase and retry a PR that
  was mergeable before another merge pushed it behind, with no new work; and
  dispatch a follow-up a reviewer or scout wrote down, quoted in the spec,
  within the worker cap and above the quota floor. Everything else waits, and
  the refusal is named rather than silent.

  The two mutating call sites go **through** that door before they act, with
  evidence they proved themselves: `cel-fanout land` asks it after its own
  checks and before `gh pr merge`, and `cel-fanout delegate` asks it before a
  worktree, a pane or an agent exists. While AFK is on, a spec is dispatched
  only if it names where its finding came from - a `Finding-from: reviewer
  <alias>` (or `scout`) line and the finding quoted as a `> ` line - and
  `cel afk resolve-thread` and `cel afk rebase-retry` are the entry points for
  the other two, the latter deriving its evidence from git and the PR rather
  than from whoever called it. `cel afk on --scope <workspace>` confines an AFK
  to the workspace it was armed in.

  AFK will not merge anything red, unreviewed, or whose gate produced no
  verdict; will not resolve a finding that is not fixed or not confirmed; posts
  nothing to GitHub beyond that one named thread-resolution case; will not act
  in another orchestrator's workspace; and will not change branch protection,
  repository settings or any policy — including turning its own scope up.

  State lives in the box's own state dir, because sleeping is a property of the
  operator and not of one product, and `--until` expires on its own: a past hour
  reads as off everywhere. Every autonomous act is recorded with what it was,
  which pre-authorisation covered it and when, and the log survives a restart —
  so "what did you do while I was asleep" has one answer to read. The console's
  status edge shows AFK and until when (and `AFK EXPIRED` when the hour has
  passed), its log is on the same screen, and both `cel doctor` and the steward
  report an AFK left on past its `--until`.
