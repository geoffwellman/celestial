### Changed

- `cel-fanout delegate` confirms the agent ACCEPTED the dispatch, not merely
  that a pane exists. A prompt that `herdr agent prompt` reported as sent but
  the agent never took is re-submitted once; if the pane is still at zero
  context with the text below its divider, the row is recorded `unconfirmed`
  and the worktree is KEPT - re-prompting that alias is the whole recovery.
- The liveness classifier learns three silences, read from the pane text
  alone with no router and no key: `unstarted` (a prompt sitting in the
  composer, never submitted - the shape is the same for a worker pane and a
  reviewer pane), `erroring` (a repeated terminal error with no turn between
  prompts - the CLASS, not any particular message) and `throttled` (a
  provider refusal that no turn followed, carrying the 5h window's reset time
  where `cel quota` knows it). A pane whose own output merely mentions a rate
  limit - the quota suite, a diff, a grep - is not throttled. They report;
  nothing here kills anything.
- The steward names the BLOCK instead of a missing worker: a red gate or
  changes-requested branch whose worker is throttled, erroring or unstarted
  says so and explicitly does not ask for another worker, and a throttled
  worker never becomes a nudge loop against the window it is waiting on.
- `cel-fanout status` shows the silence in the live column (`idle!unstarted`),
  so `running` at `+0` commits with a dead pane no longer reads like progress;
  `cel fleet --json` carries `silence` and `silence_reset` per worker.
- `fleet_alias_undeliverable` reports mail addressed to an alias with no live
  pane, instead of accepting a message that goes nowhere.
- Not yet covered: `cel run reviewer` still launches without the acceptance
  check, and reviewer panes are not in the delegation ledger, so an unstarted
  reviewer is recognisable by the classifier but nothing is reading its pane.
  That wiring is in `lib/run.sh` and the reviewer store, neither of which this
  ticket owns.
