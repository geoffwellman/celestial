---
name: verify
description: Produce a structured verdict for a worker's branch - gate result, red-then-green evidence, diff size, CI and review state - instead of a prose opinion. Used by cel-fanout collect and land; use directly when judging whether a branch is ready.
---
# Verify

`cel-verify <worktree> [--gate '<cmd>'] [--slug owner/repo]` writes
`<worktree>/.agent/verdict.json` and prints one line:

```
verdict gate:PASS  red-green:yes  diff:4 files +120/-8  checks:SUCCESS  review:APPROVED
```

Each field is a fact, not an opinion:

- **gate** - the repo's configured test command, actually run in the worktree.
  `none` means the repo declares no gate, and verification there is prose;
  `cel doctor` warns about it.
- **red-green** - whether a test-only commit precedes the first source commit
  on the branch. Evidence, not enforcement: tests written after the fact pass
  regardless of correctness, and this makes the order visible per branch.
- **diff** - size against the base, so a "one-line fix" touching forty files
  is seen for what it is.
- **checks / review** - CI and review decision on the PR, when one exists.

`cel-fanout collect` runs it and records the verdict in the ledger;
`cel-fanout land` refuses a branch whose configured gate did not pass. Read
the verdict before the result.md, not after: the result is what the worker
says happened, the verdict is what did.
