### Fixed

- Every `changelog.d/` fragment now starts with a category heading, so `cel release` can cut again, and the release suite fails in CI naming any tracked fragment whose first line is not `### Added`, `### Changed`, `### Fixed` or `### Removed` (unknown `### ` headings are now refused too).
