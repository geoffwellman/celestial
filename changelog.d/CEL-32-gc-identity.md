### Fixed
- **GC could not see a pi worker, so it reclaimed nothing.** pi rewrites its
  own argv, so `/proc/<pid>/cmdline` of a live worker is the two bytes `pi` and
  padding - and `cel gc` proved ownership by finding the role file path there.
  Every pi worker read as unidentified, which kept its whole worktree, and the
  steward journal printed `0 worktrees removed, 0 agents reaped, 36 kept` every
  tick for weeks without that looking like a fault. `cel run` and `cel-fanout`
  now mark each launch with `CEL_ROLE`, `CEL_ROLE_FILE` and `CEL_WORKSPACE` in
  the process environment, which no runtime rewrites, and GC reads those first
  and falls back to the old argv scan for panes started by an earlier build. A
  null herdr session no longer disqualifies a process that carries the mark.
  Idle agents of a runtime declaring `signal: int` (pi ignores SIGTERM) get
  SIGINT, then SIGTERM after `CEL_GC_GRACE`, then are reported `stubborn` and
  kept - GC never sends SIGKILL. The summary line now splits `kept` by reason
  (`gc: 2 worktrees removed, 1 agent reaped, 33 kept (12 live, 9 unlanded, 12
  unidentified)`), names the directories it could not identify, and `cel
  doctor` repeats the count, so a blind GC can no longer look like an idle one.
