### Fixed

`cel doctor` and the restart guard no longer report "two live processes resume" for one OpenCode session: the launcher and the OpenCode TUI it starts both carry `--session`, and a process whose ancestor already holds the same session now counts as that holder, not a second writer.
