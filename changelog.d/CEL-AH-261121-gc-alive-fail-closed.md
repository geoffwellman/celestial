### Fixed
- `cel gc` no longer treats a zombie thread-group leader whose other threads still run (leader called `pthread_exit`) as dead: a Z pid with any live task keeps its worktree. A pid that still exists but whose state cannot be read now counts as alive (fail closed), so its unreadable cwd keeps everything; the idle-reap wait on such a pid stays bounded by `CEL_GC_GRACE` and reports it kept.
