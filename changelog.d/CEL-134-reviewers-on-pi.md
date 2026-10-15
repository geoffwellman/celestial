### Changed

`cel run reviewer` maps `sonnet` and `opus` to gateway Claude models, validates the live catalog before launch, and installs the inbox extension so mail wakes idle reviewers. Updated the pinned pi, omp and Claude CLI releases. Gateway credentials are now typed into the agent's shell launch line, fail closed when unavailable, and remain masked in dry-run output.

- `cel-fanout delegate|scout` now shares gateway setup with `cel run`: Pi provider config is generated before launch, token/session variables reach the actual pane shell, and failed required-prefix staging prevents agent start. Each delegated process uses its own alias as the gateway session identity rather than inheriting the parent orchestrator's.
