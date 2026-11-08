### Fixed
- YAML-to-JSON cache (`lib/yaml.sh`): concurrent first reads of one file (background subshells, process substitutions) no longer collide on a shared `$$` temp and fail an `mv`. Each publish uses its own `mktemp` beside the entry (same filesystem, atomic rename), removes it on failure, and a lost rename counts as success when the entry now there is valid JSON. Covers the `workspace.local.yaml` merge too.
- Manifest cache (`lib/manifest.sh`): its conversion temps use a `mktemp` stem instead of `$$.$RANDOM`, which subshells could repeat.
