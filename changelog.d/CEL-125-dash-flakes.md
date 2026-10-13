### Fixed
- Dashboard tests no longer pick a port by bind-and-close and probe whatever answers on it: a boot waits for its own server and re-picks on EADDRINUSE, ending the "flaky" unreadable-repo and classic typing tests that talked to a parallel test's server.
