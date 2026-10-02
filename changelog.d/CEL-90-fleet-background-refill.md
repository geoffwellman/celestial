### Fixed
- `cel fleet` now returns a valid cached document straight away, whatever its age. If the document is older than `fleet.cache_secs`, one detached, single-flight refill rebuilds it in its own session, so a caller's timeout can no longer kill the rebuild. Before this, a console under load sat on "stale" for good.
- The fleet lock is no longer inherited by the rebuild's child processes, so a killed holder cannot leave orphans that keep the lock.
- `orphans_list` reads `/proc` with bash builtins and one batched `find`, with no subprocess per process; it took 12.6 s on the box and now takes 1.7 s.
- The document carries `generated_at`. The console's "stale as of" label uses it, and a cold console's error now names the timeout.
- The steward tick warms the fleet cache.
