### Fixed
- The rendered policy's `pr review` line now names the owning lane on a repo that declares `repos[].lane`; before, it said reviewer findings always go to `<product>-orch`.
- A reviewer started for a lane-owned repo while that lane is not running still sends its findings to the lane (its mailbox keeps them), and is now also told to copy its verdict line to `<product>-orch` with a note that the lane is down. An unreadable agent roster asks for no copy.
- The steward's once-per-head "lane is not running" note is recorded only after the mail carrying it was sent; a failed send leaves it for the next nudge on that head.
