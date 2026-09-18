### Added
- `cel update` is a real upgrade path: it lands on the newest **release tag**
  (never main's tip), records the previous build, re-applies everything the
  installation touched (links, claude settings, `ws sync`, dashboards, pages),
  then runs `cel doctor` and offers a way back when it is red
