### Fixed
- The dashboard runs as an installed systemd user service (`cel-dash.service`, own cgroup, `Restart=on-failure`, explicit PATH and working directory, logging to `dash.log`). `cel dash --ensure/--restart`, `cel update` and the steward drive the unit instead of forking, so it no longer dies when the steward tick that started it ends. `cel doctor` reports the unit's state.
- The pages servers, forked the same way from the same tick, now run as transient user units (`cel-pages`, `cel-pages-public`) for the same reason.
