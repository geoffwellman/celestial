### Fixed
- The land checks (`cel-fanout land`, `cel solo land`, the solo ready-PR finder and `cel-fanout why`) judge each check by its latest run (per workflow and check name, or status context). A check that failed and then passed on a re-run of the same commit no longer blocks landing; one that passed and then failed still does.
