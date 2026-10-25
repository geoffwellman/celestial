### Fixed
- `cel solo land`'s local gate runs in the checkout the caller stands in when it is clean at the PR head, and never in a reviewer's checkout (`.../cel/reviews/...`), which has no dependencies installed; it had taken the first clean match.
