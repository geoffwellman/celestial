### Fixed
- The steward timer now carries `OnActiveSec=1min`, so it always has a next trigger after the user systemd manager restarts (it previously showed NEXT `-` and the steward and gc stopped silently). `cel doctor` (and so `cel update`) rewrites an installed timer that lacks it, and fails when the steward's last tick is older than three intervals, naming the repair command.
