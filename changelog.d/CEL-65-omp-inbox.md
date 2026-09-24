### Fixed
- **Inbox mail no longer lands in an omp orchestrator's composer**: console
  `tell` to a live orchestrator is `cel inbox send` alone (no `herdr agent
  prompt` tap), and `cel run` loads `tools/hooks/inbox.omp.ts` on omp root and
  orchestrator panes - it raises `ui.notify` for new mail, injects unread mail
  into the next turn exactly once, and kills its watcher on session shutdown
- **The steward no longer types into root or orchestrator panes**: PR,
  stale-inbox and open-decision nudges are inbox mail (same rate-limit keys),
  the reminder names `cel inbox read --for <who> --workspace <ws>`, and `cel
  run` exports `CEL_INBOX_ME`/`CEL_INBOX_WS` so an orchestrator reads its own
  mailbox wherever it stands
