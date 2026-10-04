### Fixed
- The steward no longer nudges a PR labelled `superseded` or `hold`, an approval of an old head, or a change request already answered by a push or a later approval.
- Ready-ticket nags skip tickets assigned to someone else, done/cancelled tickets, and blocked tickets.
- An inbox fingerprint rolls up repeats of any kind, so "AFK expired" is one item per workspace, resolved when AFK is no longer expired-and-on.
- The PR-reviewer role now arms `cel inbox watch` as a background Monitor.
