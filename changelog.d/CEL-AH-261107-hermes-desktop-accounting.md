### Fixed
- Exclude owner-managed Hermes desktop SSH servers from preview adoption and orphan accounting/reaping. Match the resolved executable under the owner's `.hermes` directory and the actual SSH token-file option, without opening credentials or hiding unrelated Python processes or descendants.
- Record a new deaf-agent sighting before sampling its confirmation age, avoiding a second-rollover race that could incorrectly defer an immediate, otherwise-safe restart. Confirmation windows and restart safeguards are unchanged.
