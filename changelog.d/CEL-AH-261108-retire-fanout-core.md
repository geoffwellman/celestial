### Removed
- Fan-out is retired (2026-11-08). Deleted: `cel-fanout` and its skill, `lib/fanout_recover.sh`, the worker, scout and spike roles, the `pr-loop` skill, `cel work` / `cel history` (the delegation-ledger work-item view), worker launches in `cel run`, worker rows in `cel fleet`, and the worker/scout policy lines in every agent's policy block. The delegation ledgers stay on disk untouched; nothing reads them any more.

### Changed
- Every product is built by its solo agent. A product that declares no `mode:` is now `solo` (it was `fleet`); `mode: solo` stays valid. `cel run orchestrator` and `cel run solo` both start the solo agent; a product still set to `mode: fleet` is refused at launch with `cel mode <p> solo` as the fix.
- One-release refusals, each exiting non-zero with "fan-out was retired on 2026-11-08: build in the product's solo agent (feature teams are coming)": `cel-fanout ...`, `cel run worker|scout|spike`, `cel mode <p> fleet` (writes nothing), `cel work`, `cel history`.
- `core/roles/project-orchestrator.md` is kept for the planned feature-team rewrite and says it is not launched today. The guard has no worker role any more; its refusals name `cel solo land` and the product's solo agent. `cel setup`/`cel update` remove skill links left pointing at the retired skills.
- README rewritten solo-first: one agent per product that builds, tests, opens PRs, gets a reviewer and lands; lanes for parallel goals; `cel core` as the box coordinator. The fan-out, worker, scout, spike and console chapters are gone.
