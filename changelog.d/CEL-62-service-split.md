### Fixed

- Box-level services start again: `herdr pane split` now requires a direction
  and a target pane, and the box-level branch passed neither, so every service
  in `services.d` - the auth gateway included - was unstartable. Box services
  now live in a dedicated `cel services` herdr workspace, found by label or
  created unfocused - never a tab in whatever workspace is focused - which
  is a target the steward's timer can use too. A refused split reports herdr's
  own message instead of "returned no pane id".
