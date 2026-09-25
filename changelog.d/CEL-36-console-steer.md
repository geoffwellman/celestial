### Added

- Console: steering an orchestrator from the TUI. `tell <who> "…"` now
  resolves past `<product>-orch` - a product, a workspace with one product, a
  repo inside one, or a name only the herdr roster carries - and a workspace
  with two products is asked about rather than guessed. When the addressee's
  pane is live the console sends the mail AND prompts the pane to read it
  (`sent to <p>-orch (pane live, prompted)`), then watches that mailbox for up
  to `console.reply_wait` seconds: the reply's first line lands in the status
  and Enter opens it whole. `nudge` reaches orchestrators as well as workers,
  and `talk <p>-orch` (`t` on the orchestrator row) wires the command line to
  one pane - each line a `herdr agent prompt`, the pane's last 40 lines
  refreshed beside it - until Esc.
