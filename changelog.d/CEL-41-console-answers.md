- The console answers instead of transcribing. Ask about a stalled worker and
  you get three lines and a counted summary rather than forty rows: the
  decision model picks which rows matter and how urgent each is, the console
  computes every number from the fleet JSON, and the chat model writes the
  English. `a` (or `r`) still shows the whole transcript.
- One request now carries every question the router asks - the intent, the
  workspace, the product, whether it is destructive and whether the state can
  answer at all - because the decisions endpoint evaluates them in parallel.
- Confidence routes instead of gating: `console.router.run_confidence` (0.75)
  proposes as before, `propose_confidence` (0.5) proposes with the intent
  named, and below that the console asks one question back built from the top
  two intents. A destructive sentence is proposed however sure the model was.
  `min_confidence` still works and is read as `run_confidence`.
- New console config keys, all defaulted in code: `console.rows_inline` (6)
  and `console.summary_timeout` (4 s).
