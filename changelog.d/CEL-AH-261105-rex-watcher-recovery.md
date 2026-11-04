### Fixed

- Keep OMP inbox watcher, wake/retry debt, shutdown and retirement state inside each extension instance. OMP rebinds the same prepared factory for in-process tasks; a task starting or disposing must not replace the main session's watcher/API, drain its mailbox, or permanently disable idle recovery.
- Ignore OMP task-session lifecycle events (`ctx.agent.kind === "sub"`) for the terminal's mailbox and Rex status. Start the main instance's idle timer and process-exit cleanup only when its watcher starts; stop that timer with its watcher. Pi contexts without OMP agent metadata keep their existing behavior.
- Add a real-hook/real-inbox regression covering task startup/disposal, untouched owner drafts, exactly-once main delivery, recovery while idle after task disposal, and final watcher cleanup. Existing primary shutdown, failed-retirement recovery, refused-spawn and lost-exit checks remain applicable.
