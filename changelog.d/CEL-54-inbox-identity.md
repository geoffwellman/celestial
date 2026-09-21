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
- Naming a workspace that does not exist is non-zero however it was named: a
  cwd that derives none and an unregistered `--workspace` are one class of
  answer (`state: no_workspace`, exit 2), including for the `root`, `console`
  and `all` addresses, which previously read as an empty mailbox anywhere.
  `cel inbox count` still prints its number on stdout first.
