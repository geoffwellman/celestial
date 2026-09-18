### Added
- The console's model offers options and may answer with a chain: a miss is
  asked a second time for up to three candidate commands each with a reason,
  and a sentence that needs a sequence comes back as up to five commands that
  run in order, stopping at the first non-zero exit - and every line of a chain
  passes the console allowlist BEFORE any of them runs, so a refusal on the
  second line cannot arrive after the first has changed the box. Nothing runs
  without the operator's Enter
