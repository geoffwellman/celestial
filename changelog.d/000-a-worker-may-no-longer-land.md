### Added
- A worker may no longer **land, release, delegate, scout, spike, collect or
  reconcile**: the guard denies those verbs for the worker role and
  `cel-fanout` refuses them on its own before any `gh` call or ledger lock, so
  the bottom tier ships a PR and reports rather than driving the factory.
