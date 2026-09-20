- `cel quota` and every surface that draws it now read `omp usage --json` when
  omp is on PATH: it holds refreshed OAuth per account, so all three Anthropic
  logins, both ChatGPT ones and opencode are listed, each window comes from the
  authoritative `.limits[]` (scoped windows keep their model's label instead of
  being dropped), and a null window is skipped rather than drawn at 0%. A box
  without omp falls back to the per-provider endpoint reads exactly as before.
- `extra_usage.disabled_reason` with spending disabled now reads "top-up is
  off" rather than "out of credits" on a healthy account.
- `opencode` is a declared provider: plan windows, no credit balance.
- Credit stays workspace-scoped, and says which kind of unknown it is - "no key
  in this workspace" (where you are standing) or "asked and could not tell" (a
  fault) - in `cel quota`, in its `--json` as `balances[].state`, and on screen.
- The console QUOTA page, the console status edge and the dashboard's
  subscriptions card draw each window as a bar sized from the `used_pct` that
  already existed, degrading to plain text on a terminal too narrow for one.
- omp on PATH that answers nothing usable now says so once on stderr and falls
  back; a box with no omp still falls back in silence, as before.
