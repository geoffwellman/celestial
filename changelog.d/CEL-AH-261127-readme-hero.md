### Changed
- The README hero is a fresh screenshot of the current dashboard on fictional fixture data (`docs/images/dashboard.webp`); the retired v1 factory-floor image is gone. The One box and gateway diagrams move to the README front page (setups.md links to them) and now show the steward, Herdr/Rex sessions, reviewer verdicts by inbox, and which runtimes go through the gateway (pi, omp, OpenCode and every reviewer; Claude Code and codex normally use their own sign-in; agy refuses it).

### Fixed
- Dashboard: the Needs you URGENT badge no longer wraps to one letter per line beside a long title (the card's `overflow-wrap:anywhere` let the flex row squeeze it).
