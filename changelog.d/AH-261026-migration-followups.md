### Added
- `cel-fanout keep <id>... [--workspace w]` marks an already released, landed or abandoned row whose checkout still exists as kept, so `cel gc` never removes it - for rows released with the keep asked for before the keep was recorded. Idempotent; changes nothing else; refuses a live row or a missing checkout.

### Fixed
- A solo lane started with `--profile` (for example Claude Code) kept that profile only for its first launch; a restart through `/cel-restart` or `cel run solo --lane x --restart` came back on the product's default runtime. The lane records its profile beside its role file (`launch-profile`) and reuses it; a later `--profile` replaces it.
- `cel setup`/`cel update` remove a Claude `UserPromptSubmit` hook entry an older install left with an unresolved `__CEL_…__` placeholder, which ran a missing command on every prompt.
