### Fixed

Stale-launch checks (`cel update`, `cel doctor`, the steward) no longer report a wrapped OpenCode orchestrator as running "an older launch line (extra: -- …/opencode)". The bare `--` that hands a launcher's argv to the runtime is a separator, not a flag; the wrapped flags are still compared.
