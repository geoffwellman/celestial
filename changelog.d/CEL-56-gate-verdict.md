### Changed

- `cel-verify` now has four outcomes, not three: pass, fail, timed out, and
  **produced no verdict**. A gate whose process was killed before it reported
  an exit status never said the code was wrong, and is no longer recorded as a
  failure. `verdict.json` carries `gate.outcome`, `gate.code` and, when the
  code is absent, `gate.no_verdict_reason`; the summary line renders
  `gate:NO-VERDICT` and the exit status is 3.
- The gate writes its own exit status down at the moment it has one, so a suite
  that already printed "N passed, M failed" keeps its verdict even when the
  process group it shares with its own cleanup is torn down afterwards.
- A gate that printed nothing at all is recorded as such (`gate.output_empty`)
  instead of storing an empty tail and moving on - that silence was the only
  visible signature of the bug.
- `cel-fanout land` refuses a no-verdict gate by name rather than as a red one,
  and `--gate-from-ci` is available for it on exactly the terms it is available
  for a timeout: every check the base branch is protected by, green on that
  head. `collect` warns without calling it a failure, and `status` shows `NV`.
