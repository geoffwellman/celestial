### Added
- Solo products are visible everywhere the fleet is. `cel fleet --json` units carry `mode` and `solo_worktrees`, and the text view draws a solo product as `solo <agent state>  worktrees N` instead of worker counts. The dashboard tags a solo product's agent row "solo".
- The steward tells a solo product's agent, once per head, when one of its PRs is approved at its current head with every check green and still unmerged: `cel solo land <repo>#<pr>`. It never lands anything itself.
- `cel gc` removes a solo agent's own worktrees (`<ws>/.cel/solo/<product>/<branch>`) through the same checks as orphaned worker worktrees - no live process, nothing unsaved or unpushed, the branch's PR merged or closed, no `--force` - and keeps one whose branch has no PR yet (`no-pr`).
