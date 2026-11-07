---
name: project-orchestrator
description: Held for the feature-team rewrite. Not launched today - every product agent runs the solo role (core/roles/solo.md).
---
THIS ROLE IS NOT LIVE. Nothing launches it: every product agent - `cel run
orchestrator`, `cel run solo`, its lanes - runs the solo role
(`core/roles/solo.md`). This file is held for the feature-team rewrite and
describes no current behaviour.

Until feature teams arrive, a product's agent builds and ships the product
itself: it plans, writes the code, runs the gate, opens the PRs, starts a
reviewer per PR (`cel run reviewer`) and lands with `cel solo land`.

History: this role used to hand tickets to per-ticket worker agents. That
fan-out was retired on 2026-11-08: build in the product's solo agent (feature
teams are coming).

If you were started with this role, say so to the owner
(`cel inbox send root "..."`) and stop.
