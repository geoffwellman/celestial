### Fixed
- `cel solo land`, `cel solo approvals`, the steward's land nudge and `cel doctor` no longer refuse a workspace whose `review:` block sets `thinking:` as an unknown key. `thinking` is a known `review:` key; a typo such as `extras:` is still refused.

### Changed
- `review.thinking` sets the PR reviewer's reasoning level over the workspace's `thinking:`, clamped to what pi accepts as for any role; a profile bound to the reviewer, or `cel run reviewer --thinking`, still overrides it.
