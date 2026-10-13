### Fixed
- `cel watchdog print` emitted a script whose service heredoc never closed (missing newline before `EOF`); it now runs as-is. New `cel watchdog install`/`uninstall` write the units via non-interactive sudo and verify the timer is active; `cel doctor` names `cel watchdog install`.
