### Changed
- Run-area cleanup with no behavior change: removed an unreachable duplicate restart branch from `cel run`, the unused `work_next_action` helper, and incident/ticket history from comments in the launch, solo, liveness, stall, work and recovery code, and corrected the `cel solo land` header comment to describe its local-gate fallback.
