### Fixed
- `cel-fanout land --gate-from-ci` checks CI first: when every protected required check is green on the PR head it lands on that evidence without running the local gate, and says so in the merge body. Otherwise the local gate runs as before, and land's `--gate-timeout` now includes the wait for the box's suite lock (`cel-verify --lock-in-timeout`).
- `tests/run.sh` gives each test a wall limit (`CEL_TEST_TIMEOUT`, default 120 s); a test past it is reported as a timeout and its whole process group, servers included, is killed.
- `tests/run.sh` runs independent test files in parallel (`CEL_TEST_JOBS`, default min(nproc, 6); files sharing box-wide state run alone); `--no-lock` now also keeps nested gates out of the lock queue.
- A quota test no longer waits 60 s on its stub server's dead man's switch; `test_no_lock_runs_while_the_lock_is_held` no longer races a loaded box.
