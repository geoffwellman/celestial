# builder focus: refactor

This focus narrows the role; it never widens its authority.

- [ ] Behaviour does not change: tests pass before and after, unchanged.
- [ ] Move in small commits a reviewer can follow; each one passes the gate.
- [ ] Migrate every caller and delete the old path in the same branch - no shims.
- [ ] Grep for string references (docs, configs, scripts), not only imports.
- [ ] Report what got smaller: files, lines, duplicated paths removed.
