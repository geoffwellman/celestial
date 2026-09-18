### Added
- **One gate at a time: the suite takes a box-wide lock.** Six concurrent
  `tests/run.sh` runs took this box to a load of 190 and every suite past its
  timeout; the worker cap bounds how many workers exist, not how many gates
  run. The runner now queues on an exclusive `flock` (`$CEL_SUITE_LOCK`, else
  `$XDG_RUNTIME_DIR/cel-suite.lock`), naming the holder while it waits and
  printing how long it waited; `--no-lock` and `CEL_SUITE_LOCK=none` opt out,
  a filtered run does not. `cel-verify` queues on the same lock, starts its
  `--gate-timeout` clock only after acquiring it and records
  `gate.waited_secs`; `cel-fanout why` reports a queued worker as queued
  rather than quiet; and the steward raises one rolled-up status when the lock
  is held past `CEL_SUITE_HOLD_WARN_SECS` (30 min), clearing it when the lock
  is free. Nothing is ever killed to take the lock.
