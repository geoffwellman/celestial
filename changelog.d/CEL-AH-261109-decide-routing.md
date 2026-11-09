### Added
- `cel decide ask --topic product|qa|design|release|merge|owner` (default `owner`). In a workspace with `people:`, the question is routed at ask time to whoever holds that role for the asker's product, else to the `owner`s; the record keeps `topic` and `route: {role, product, people}`, and `to` stays `owner`.
- `cel decide list --mine | --for <id> | --topic <t>`; `list --json` says per decision who this login is (`me`), whether it is this person's (`mine`) and whether this login may answer it (`answerable`).
- The dashboard's decisions board has a **mine** chip (on by default when `me:` is set) and a **topic** grouping; a card this login may not answer says who may and sends nothing.
- The steward's daily owner-decision line counts routed questions per person.

### Changed
- `cel decide answer|drop` is a person's: no agent may run it (the guard denies it to solo, orchestrator, root, lead and member; `cel decide` refuses any process launched as an agent, core excepted on unrouted questions). With `me:` set the answer is recorded as `me` (`--by` must equal it); a routed question is answered only by its people or an `owner`, recorded as `<id> (owner)`. The dashboard answers with `--by <me>`, and with no `me:` only unrouted questions.
- A routed decision raises a desktop notification only on a login whose `me:` is on its route.
- With no `people:`, nothing changes: no route, anyone answers, `--by` is free text.
