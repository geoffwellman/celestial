---
name: setup
description: Walk the user through a workspace's human setup steps - auth tokens, logins, env vars - declared in workspace.yaml's setup section. Use when the user runs /celestial:setup, asks to set up a workspace, or a tool fails because a setup step (token, login) is missing.
---

# Workspace setup walkthrough

Walk the user through the human setup steps a workspace declares, checking as
you go so finished steps are skipped and completed steps are verified before
moving on.

## Find the workspace

Walk up from the current directory to the nearest `workspace.yaml`. If there is
none, list registered workspaces (`cel ws list`, with `cel` at
`$CEL_ROOT/bin/cel`; `CEL_ROOT` defaults to `~/celestial-plane`) and ask which
one to set up, then work from its directory.

## Read the declared steps

Two sections of `workspace.yaml` matter:

- `tools:` - executables that must be on PATH (check with `command -v`).
- `setup:` - human steps, each `{name, check, docs?, hint?}`:
  - `check` - a shell command; exit 0 means the step is done. Run it with
    `bash -lc` so login-shell env (`~/.zshenv` exports) is visible.
  - `docs` - workspace-relative doc with the full instructions.
  - `hint` - one-line pointer when there is no doc.

Plane-level health is `cel doctor`'s job, not yours - suggest it at the end if
anything box-wide looked off, but do not duplicate its checks.

## Walk through them

1. Run every check first and show one table: step, done/missing, source of
   truth (docs or hint). If everything passes, say so and stop.
2. For each missing step, one at a time:
   - Read the step's `docs` file if it has one and give the user the exact
     commands for their situation, not a paraphrase of the doc.
   - Anything an agent can safely do (mkdir, writing non-secret config), do.
   - Anything needing their identity - browser logins, token creation, secrets
     into `~/.zshenv` - hand over as copy-paste commands. Interactive logins
     (`bt login --oauth`, `wrangler login`, `gcloud auth login`) should be run
     as `! <command>` in the Claude Code prompt so the output lands in the
     session.
   - Never echo a secret value back, never write secrets into the workspace
     repo, and never send tokens anywhere except the tool that owns them.
   - Re-run the step's `check` to confirm before moving to the next step.
3. Finish with what changed and what (if anything) is still pending. If a
   check cannot pass in this environment (e.g. needs another machine), say so
   explicitly instead of looping.

## No setup section?

If the workspace has no `setup:` block, say so, and offer to scaffold one from
what its docs describe as one-time setup - the schema above, one entry per
human step, committed to the workspace repo so the whole team gets the same
walkthrough.
