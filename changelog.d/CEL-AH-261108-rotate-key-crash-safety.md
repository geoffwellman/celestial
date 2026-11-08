### Fixed
- `cel gateway rotate-key` survives a kill at any step.
  - A `--stage` killed after keeping `api-key.previous` but before moving the new key over `api-key` now reads as INTERRUPTED, not staged. `--status` says so and names the fix, `--abort` clears it, and `--finish` refuses with a clear message instead of failing every time.
  - `--finish` and `--abort` now rewrite `config.yaml` and prove the gateway's answers first, and delete `api-key.previous` / `api-key.next` last. A kill at any point leaves the files saying what is left, and running the verb again completes it. `--finish` also removes a leftover `api-key.next` (and `--status` shows one).
  - `--status` reports any mismatch between the keys `config.yaml` accepts and the key files, naming the fix: `cel gateway rotate-key --finish` again after a cut-short finish, otherwise `cel gateway refresh`.
  - A failed wait reports the HTTP codes both keys get now, not an earlier answer.
