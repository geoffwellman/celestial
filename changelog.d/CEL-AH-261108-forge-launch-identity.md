### Fixed
- `cel forge pr close`, `pr ready` and `run rerun` check the caller's identity against its launch, as `cel team`'s writing verbs do: the nearest process above `cel` whose `/proc/<pid>/environ` carries `CEL_ROLE` must agree on `CEL_ROLE`, `CEL_PRODUCT`, `CEL_INBOX_ME`, `CEL_INBOX_WS` and `CEL_TEAM*`. A product agent that exports another product's `CEL_PRODUCT` (however indirectly) is refused before any write, and so is a role with no launch above it.

### Changed
- The launch-environ check moved from `lib/team.sh` (`_team_launch_identity`) to the shared `lib/identity.sh` (`cel_launch_identity`); `cel team`'s behaviour and messages are unchanged.
