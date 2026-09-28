### Fixed
- An orchestrator herdr brings back as a bare `omp --resume` (no inbox hook) is now caught: the steward restarts it with the full launch line when it is idle with a provably empty composer, and otherwise tells root once with the exact command; `cel doctor` fails on it. The omp inbox hook also wakes an idle session for mail that was already waiting when it started (CEL-85).
