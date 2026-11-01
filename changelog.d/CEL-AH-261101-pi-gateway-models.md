### Fixed

Fix Pi gateway catalog discovery for ESM-only Pi packages and expose every advertised Claude/Codex chat model without making capability metadata an availability gate. Add `cel gateway pi-models --list|--json|--refresh` for existing-key-only discovery and model-metadata-only refresh, preserving provider resolvers, defaults, unrelated providers and running sessions. Enrich exact supported models from installed Pi data and authoritative local metadata instead of family-name guesses.
