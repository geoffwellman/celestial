### Added
- Dashboard v2 data feeds on the dash server: `GET /api/v2/{since,activity,stuck,lanes,load,merges,cycle,heat,forecast}` (each with `?ws=<name>|all`), a per-browser "last looked" mark (`POST /api/v2/seen`), and `POST /api/v2/act`, which maps named actions (message, orch.restart, afk.on/off, seen, stuck fixes) to existing commands and never types into a pane.
- The steward tick appends load, memory, swap and pane status to a small sample ring (`~/.local/share/cel/samples.jsonl`) that the load and lanes feeds read.
