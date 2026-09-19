Orphans: what the plane started and nobody owns any more gets reaped.

A walk of this box found around a gigabyte of processes with no owner at all,
all reparented to init: thirteen `cel inbox watch` trees from consoles that
had exited, fifty-six test fixtures whose worktree had been deleted nine days
earlier, 173 bare pane shells on ptys whose pane was gone, and gate runners
whose suite had been killed. None of it was visible anywhere, because the
memory sweep groups by pane and these have no pane.

- The console now kills its watcher's whole process group on every exit path,
  and the watcher takes `--parent <pid>` and leaves on its own if that pid is
  gone.
- The test runner kills anything still sitting in the run's own `TMPDIR` at
  exit, which catches a fixture that escaped its test's process group.
- `cel gc --orphans [--dry-run]` finds and reaps the four classes; the steward
  does it once a tick and reports one rolled-up line (`reaped 6 orphans
  (2 watchers, 3 fixtures, 1 shell), 410 MB`) only when it took something.
- `cel doctor` names them in one line, `cel fleet --json` carries
  `box.orphans`, and the console's box line shows the count when it is not
  zero.

Nothing under a live herdr pane, no box service, no auth broker or gateway,
no Claude daemon and nothing belonging to another user is ever a candidate; a
pane list that cannot be read keeps every shell.
