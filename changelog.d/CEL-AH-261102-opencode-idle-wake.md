### Fixed

An OpenCode orchestrator now keeps delivering inbox mail after its agent or model is switched while idle. The plugin treated the native `session.agent.selected` and `session.model.selected` events as proof the session was busy, and an idle session sends no later event to clear that, so mail waited until someone typed a turn. A selection now only discards in-flight observations; the native busy and idle timestamps decide when mail is delivered.
