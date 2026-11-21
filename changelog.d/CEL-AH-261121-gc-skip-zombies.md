### Fixed
- `cel gc` no longer keeps every worktree "live" because of a zombie (or dead) process: an unreaped defunct child has an unreadable cwd but runs nothing, so it is skipped. Any other live process whose cwd cannot be read still keeps everything.
