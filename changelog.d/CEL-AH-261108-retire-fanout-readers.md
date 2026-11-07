### Removed
- Fan-out is retired (2026-11-08): nothing at runtime reads `.cel/delegations.json` or delegation bindings any more. The ledger files stay on disk untouched (archived separately). Gone with it: the steward's ledger reconcile, stalled-worker sweep, worker-branch PR nudges and per-worker memory warnings; gc's delegated-pane, done-pane, waiter/handback and ledger-veto passes; doctor's ledger-state, worker-container and stale-delegation checks and the `worker` runtime check; the AFK `dispatch` and `ordered_work` acts (release is now pre-authorisation 4); `cel services` ledger `try` previews; `cel here land`'s fan-out path (it always runs `cel solo land`); the dashboard's ledger-derived feeds; fleet verdict rounds in reviewer retirement; `lib/ledger_states.sh`.

### Changed
- The steward's PR sweep nudges a product's own agent the same way for every product: changes requested -> fix, push, ask the reviewer; red checks -> fix on the branch.
- `cel ws down` names unpushed/unlanded work in the workspace's solo worktrees instead of reading the ledger, and no longer refuses when no ledger exists.
- `cel solo land` records its AFK evidence as `author: "solo"` (the AFK land door now requires it).

### Fixed
- A Forgejo repo on plain http warns that its token travels unencrypted only when a request actually sends the token, not before an operation that is refused first.
