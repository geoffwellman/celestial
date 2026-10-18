### Fixed
- A gateway launch (worker or reviewer) no longer rewrites existing model entries in the shared pi `models.json`: it adds missing ids only, deletes nothing, and skips the write when nothing changes. `GATEWAY_PI_WRITE=refresh` (used by an explicit refresh) lets the catalog's fields win.
