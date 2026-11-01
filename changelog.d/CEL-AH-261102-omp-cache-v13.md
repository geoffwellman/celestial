### Fixed

OpenCode gateway catalogs read OMP model-cache versions 13 and 14. A cache rewritten as version 13 previously stripped every model to bare client defaults, which removed effort variants such as Opus 5.5 medium; the catalog command now also warns when no capability metadata applies.
