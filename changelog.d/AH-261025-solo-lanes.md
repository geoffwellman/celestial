### Added
- Solo lanes: `cel run solo --product <p> --lane <name>` starts a further solo agent on a solo product for a separate goal, beside the product's main agent. A lane has its own pane and mailbox (`<p>-<name>`), directory (`.cel/solo/<p>/lane-<name>`), role file and resumable session (`--restart`, `--fresh`), is told in its role that it is a lane among peers in the same repos, and launches with `CEL_PRODUCT`/`CEL_LANE` so `/cel-*` commands scope to its product and `/cel-restart` restarts that lane only. One agent per lane is enforced as one per product is; lanes are refused on fleet products, for the name `orch`, and for any role but the product agent. A reviewer started by a lane sends its findings to that lane. `cel fleet` shows a solo product's live lanes (`lanes` in `--json`). `cel decide list --asker` from a lane lists the lane's own questions.

### Changed
- `cel mode <p> fleet` is refused while any of the product's lanes is live.
