### Fixed

- Claude's managed Rex terminal now closes on normal native completion instead of retaining an orphan shell-flavored block; other runtimes keep their existing terminal policy. Restart preserves extra user windows and never deletes a session based on a dead process receipt. Added isolated real-server and credential-free native Claude UUID/model resume coverage. Server-restored replacement shells and zero-window session deletion remain separate upstream API limitations.
