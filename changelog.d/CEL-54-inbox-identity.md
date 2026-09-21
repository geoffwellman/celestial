### Fixed
- `cel inbox read` and `cel inbox count` no longer report "nothing" when they
  could not ask the question. A cwd outside every registered workspace is now
  a **refusal** naming `--workspace` / `--all-workspaces` instead of a silent
  empty read, an empty mailbox says which reader and which workspace it
  answered for, a `--for` name no mailbox has ever used reads differently from
  one that exists and is empty, and a reader with mail in another workspace is
  told where and how many (without moving that mailbox's cursor). `--json`
  carries the three states as `state: empty|no_mailbox|no_workspace` plus an
  `elsewhere` array.
