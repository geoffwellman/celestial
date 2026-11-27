# Tickets

Set `tickets: { system: linear }` and the plane wires Linear's **official MCP
server** into Claude Code at sync (`claude mcp add` at user scope, OAuth on
first use; skipped when `claude` is not installed), while every runtime can
use `cel-linear` (a thin GraphQL shim in `core/skills/linear/bin`, on PATH
through `cel shellenv` and every agent launch; it reads `LINEAR_API_KEY` from
the workspace's `env.local`). The lifecycle contract — In Progress on start,
In Review when the PR opens (Linear links the PR from the ticket ID in the
branch name), Done on merge, each set by the agent with `cel-linear state` —
rides the policy block into every agent; nothing moves tickets for it. A repo
names its Linear team with `repos[].linear_team`. With the default
`tickets: { system: none }` there are no tickets, and the steward's ticket
steps do nothing.
