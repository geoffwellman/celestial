### Fixed
- **The suite lock no longer outlives the suite.** flock lives on the open file
  description, so every child that inherited the runner's lock descriptor held
  the lock too: one backgrounded `sleep` kept every gate on the box queued for
  eighteen minutes after the run that started it had finished. `tests/run.sh`
  and `cel-verify` now spawn every child - the source-check and
  function-listing shells, the gate, and the gate's timeout watchdog - with the
  descriptor closed, the way `lock_spawn` has done for the ledger lock since
  the same bug was found there.

### Changed
- A wait for the suite lock past `CEL_SUITE_WAIT_WARN` (120 s) says so once
  more, naming the holder's pid, start time and directory - or saying the
  recorded holder is dead and the lock has leaked. The lock file's first line
  carries the holder's cwd for it.
- `cel doctor` prints one line when the suite lock is held by a pid that is
  gone, or by a process that is not running from a checkout.
