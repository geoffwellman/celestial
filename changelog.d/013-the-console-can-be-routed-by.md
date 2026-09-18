### Added
- The console can be routed by a **decision model**: `console.router` in
  `~/.local/share/cel/config.yaml` sends the sentence to a classifier that
  picks one of ten intents (`fleet`, `product_status`, `why_worker`,
  `message`, ...) and returns a confidence with it - the console fills the
  slots from the fleet it already holds, so the model never writes a command
  line. 0.4 s against 6.5 s for the chat model on "what is happening with
  bundle"; below `min_confidence` the top three intents become options with
  their probabilities; anything it cannot place falls through to the chat
  model, as does a router that is down. `--no-router` and
  `console.router.enabled: false` bypass it
