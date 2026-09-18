### Changed
- An orchestrator owns the STATE of its own checkout, never its authorship:
  `git checkout <ref>` / `git switch <ref>` between existing refs, `gh pr
  checkout <n>`, `git branch -d`, and `gh pr edit --add-label/--remove-label`
  are now allowed, while creating branches, discarding paths and reaching into
  another checkout stay denied
