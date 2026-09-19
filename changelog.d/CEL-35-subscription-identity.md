### Fixed
- **A subscription is where it is signed in, and every surface shows the same
  rows.** This box listed five Claude subscriptions for two logins: an account
  was named by the first six hex of its token's sha256, and pi refreshes that
  token, so every refresh minted a new "account" and a new cache file that
  `cel fleet --json` then listed. An account is now identified by the
  credential's home — `claude/pi`, `claude/claude-code`, `codex/<account id>`,
  `gateway/<provider>/<id>` — so a refresh overwrites one file, the display
  label is whatever stable field the credential carries, and pi and Claude
  Code showing the same windows are one row (`pi + claude-code`). Cache files
  that match no current identity are swept on the next read. An account whose
  usage cannot be read is a row saying `unreadable: <reason>` rather than a
  silence, so Codex stops disappearing from the console while the dashboard
  shows it. `cel fleet --json .subscriptions` is now literally what `cel quota
  --json .subscriptions` returns, gateway accounts included, and the console's
  QUOTA view and the dashboard's Subscriptions card build their rows from one
  function over that one list — the console no longer runs `cel gateway
  status` of its own
