---
name: linear
description: Work with Linear tickets - read, create, comment, move states - in workspaces whose policy block says tickets are linear. Use whenever a task references a ticket ID, when starting/finishing delegated work that must update its ticket, or when filing follow-up issues.
---

# Linear tickets

Applies only where your injected policy block says `tickets: linear`. Where it
says `none`, never invent ticket references.

## Two surfaces, one rule: prefer MCP, fall back to the shim

1. **Linear MCP tools** (official server, registered for claude sessions by
   `cel ws sync`): if tools like `linear` / `mcp__linear__*` are available in
   your session, use them directly.
2. **`cel-linear`** (on PATH via cel shellenv) for every other runtime:

```bash
cel-linear my-issues
cel-linear issue WG-12
cel-linear create --team WG --title "..." --description "..."
cel-linear comment WG-12 "PR: <url>"
cel-linear state WG-12 "In Progress"
```

Auth is `LINEAR_API_KEY` from the workspace env (`env.local`); if it is unset,
say so and continue without ticket updates - never block the work on it.

## Filing work: one ticket per work package, SEARCH FIRST

The point of tickets is that nobody steps on anyone's toes - so creation is
gated on a search, every time:

1. `cel-linear search <key terms> --team <KEY>` (or the MCP search tool).
2. A live match (not Done/Canceled/Duplicate) exists:
   - **assigned to someone else and In Progress → the work is CLAIMED.**
     Do not create, do not delegate; comment your context on their ticket and
     report to root.
   - unassigned or stale → comment your intent on the existing ticket and use
     it instead of creating a twin.
3. A finished match exists → create yours and link it ("supersedes"/"related").
4. No match → create in the policy block's team. Title imperative, description
   carries the acceptance criteria. Agent-created tickets are labelled
   `celestial` automatically so humans can filter them.
5. Discover a duplicate late → move YOURS to Duplicate and comment the
   survivor's id; never the other way around.

## Lifecycle convention (the handoff contract)

- Orchestrator delegates a ticketed task → worker spec names the issue ID, and
  the orchestrator moves it to **In Progress**.
- PR opened for the work → move to **In Review** and `comment` the PR URL on
  the issue.
- PR merged → **Done**. Rejected/abandoned → comment why; the orchestrator
  decides the state.
- The team key for each repo is in your policy block; file new issues there.
  One issue per ticket, titles imperative, descriptions carry the acceptance
  criteria from the spec.

## Starting work from the board

A human moves a ticket into the workspace's TRIGGER STATE
(`tickets.trigger_state` in workspace.yaml, default `Ready`) to say "build
this". The steward notices tickets in that state with no branch anywhere and
puts them in root's inbox; root plans them and delegates as normal. Nothing
auto-delegates straight from a ticket - a title is not a spec, and a worker
started without acceptance criteria wastes a worktree.

The trigger state belongs to the OWNER. Never move a ticket out of it
yourself: an agent reversing it erases the request. If it cannot be started,
comment on the ticket saying exactly what is missing and leave the state
alone. Once a branch names the ticket, the steward leaves it alone.

## Assignment follows PR ownership

`cel-linear create` assigns the new ticket to the key owner by default, because
an unassigned ticket appears on nobody's list — including the "assigned to me"
view the dashboard is built on — so it lands on the board and is still
invisible.

That default is only correct while the fleet owns the work. **Never leave a
ticket assigned to the key owner when it tracks someone else's pull request.**
The API key is the fleet's identity, not a claim on other people's work, and a
colleague's PR appearing on the owner's list reads as "yours to deliver".

```
cel-linear create --team K --title T            # assigned to the key owner
cel-linear create --team K --title T --assignee none   # tracking someone else's work
cel-linear assign <ID> none                     # correct one after the fact
```

Ownership is decided by the PR author, not by who filed the ticket:
`gh pr view <n> --json author --jq .author.login` against the login `cel` runs
as. The steward only ever sweeps `--author @me`, so tickets it prompts for are
ours by construction; anything you create for a PR you did not open is not.

## Record what you learn

When you establish a durable fact - a runtime quirk, a provider behaviour, a
team convention, a decision and the reason for it - record it with
`cel learn add "<fact>"` (`--pin` for a standing rule, `--perishable` for one
with a known expiry). It reaches every agent's policy block from then on. Do
NOT record task status there; that is the ledger and the inbox.

## Cross-repo tickets

One Linear team can serve several repos, so a ticket may need work in more
than one. The rules:

- The ROOT orchestrator owns the ticket's state; project orchestrators own
  only their repo's branch and PR.
- One branch per repo, all named for the same ticket (`ABC-123-<slug>` in
  each repo) - branch namespaces are per-repo, so identical ids never clash.
- Comment EVERY PR link on the ticket as it opens. The ticket moves to
  In Review when the FIRST PR opens, and to Done only when the LAST PR
  merges - a half-landed cross-repo ticket is In Review, never Done.
- If one side lands and the other stalls, that is an escalation to root,
  not a reason to close the ticket.
