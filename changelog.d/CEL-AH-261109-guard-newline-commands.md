### Changed
- The guard reads a command line as bash does, for every rule and every adapter (claude, omp/pi, OpenCode): a newline ends a command, like `;`. A heredoc body (`<<EOF`, `<<-EOF`, `<<'EOF'`), a newline inside a quoted string and a comment are data. The exceptions are a heredoc fed to a shell (`bash <<EOF`, `cat <<EOF | sh`), a string that is code for one (`bash -c`, `sh -c`, `$'...\n...'`, eval, ssh), and the `$(...)` an unquoted heredoc expands. A line left open (an unclosed quote or heredoc) is read the cautious way: every newline separates commands.
- Orchestrator, root and core lines are judged one command at a time, and the line takes the strictest verdict. A `cel ...` or `gh pr comment|review ...` command allows only itself.
- `CEL_GUARD_ALLOW_ONCE=1` on a line of its own leads no command and covers nothing after the newline.
- The guard strips the shell keywords in front of a command (`if`, `then`, `do`, `else`, `!`, `{`, ...) before matching it.

### Fixed
- A command after a newline got past every rule anchored at a command's start: `true` then `gh pr merge 3` on the next line was allowed for a solo agent; the same held for a builder's push to main, a read-only member's git write or `rm` of team records, core's `cel solo land`, `cel run member` and raw forge writes. So did `bash -c $'true\ngh pr merge 3'`. An orchestrator's `git checkout main` followed by a newline and any git write was allowed as a checkout move.
- `cel ...` or `gh pr comment|review|checks ...` anywhere in an orchestrator, root or core line allowed the whole line: `git push origin main && cel fleet`, `cel fleet; gh pr merge 3` and `gh pr comment 3 -b x; gh pr merge 3` were allowed.
- An orchestrator, root or core pane was refused a heredoc or multi-line quoted body that only spelled a refused command, for example `cat > .cel/notes.md <<'EOF'` with `gh pr merge` on a body line.
