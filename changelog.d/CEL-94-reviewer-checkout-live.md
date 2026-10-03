### Fixed
- A review checkout is no longer deleted while a live herdr pane stands in it. `cel gc` and `cel run reviewer` now ask the herdr roster at the moment of deletion (an unreadable roster counts as occupied), and `cel run reviewer` reuses a live reviewer found by its checkout directory even when its registry row is missing, writing the row back.
