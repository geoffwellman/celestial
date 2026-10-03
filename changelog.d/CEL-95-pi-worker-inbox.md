### Fixed
- pi and omp workers and reviewers now launch with the inbox hook and their own mailbox identity (`CEL_INBOX_ME` = pane alias), through both `cel run` and `cel-fanout delegate`, so a reviewer's CHANGES mail wakes an idle worker instead of sitting unread for hours.
