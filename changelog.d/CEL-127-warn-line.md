### Fixed
- Memory warning: swap now widens the warning only below 2x the admission floor (not 2x the warning line), so a box with 9.5 GB free and cold swap no longer warns; the steward says "stop delegating" only when admission would actually refuse (CEL-127).
