### Fixed
- The per-test watchdog in `tests/run.sh` no longer leaves its `sleep` orphaned on PID 1 when a test finishes first.
- Worker memory is summed by PSS (RSS as fallback), so shared pages are no longer counted once per process; the steward's 2 GB threshold now compares against a real figure.
