### Fixed

- omp inbox hook: an idle orchestrator with an empty composer now wakes itself for new mail (`pi.sendMessage` with `triggerTurn`), coalesced per burst; drafts and streaming stay notify-only (CEL-76).
