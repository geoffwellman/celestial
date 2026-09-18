### Added
- **A service can belong to the box.** `~/.config/cel/services.d/` (one `0600`
  JSON file per service, the same shape as a `services:` row) declares services
  no workspace owns, and every consumer — `cel services` and its
  `start|stop|restart|logs|open`, the steward health sweep with `restart: auto`,
  the dash proxy, the console and the fleet JSON — sees them as rows with
  `workspace: "box"`; `cel services` run from outside every workspace now
  answers with them instead of refusing. `cel gateway install` writes the auth
  broker and gateway there and starts them through the normal path, so the pair
  that ran unsupervised for a day is watched; `cel gateway status` and
  `cel doctor` say whether anything is watching. `env` values whose key looks
  like a credential render as `***` wherever a row is drawn.
