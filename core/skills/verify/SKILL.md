---
name: verify
description: Produce a structured verdict for a branch - gate result, red-then-green evidence, diff size, CI and review state - instead of a prose opinion. Use directly when judging whether a branch is ready.
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

Read the verdict before any prose report, not after: a report is what the
author says happened, the verdict is what did.

A gate that ran out of time is not a gate that failed. The gate runs under
`timeout` (`--gate-timeout <secs>`, else `CEL_VERIFY_GATE_TIMEOUT`, else 600);
when the timeout kills it the verdict records `gate.passed = null`,
`gate.timed_out = true` and `gate.timeout_secs`, the tail ends in
`killed after <n>s - no verdict`, the summary reads `gate:TIMEOUT(600s)` and
the exit code is `2` - never `1`, which stays reserved for a gate that
genuinely failed. "Ran out of time" and "the code is wrong" lead to opposite
actions: treat a timeout as unknown, and either rerun with a longer timeout or
rely on CI evidence (`--gate-from-ci`, which accepts only when every check the
base branch's protection requires concluded `success` on the PR head).
