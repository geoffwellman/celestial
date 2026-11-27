# Agents talk without hijacking your keyboard

`herdr agent prompt` types into a pane, so a status report landing while you
are mid-sentence merges with your draft. Routine agent-to-agent traffic goes
through `cel inbox` instead - a JSONL mailbox per workspace, with a read
cursor per *reader* so a standing root pane and `cel core` can both drain
root's mail without stealing each other's place. Delivery is inbox-only, but
idle wake depends on runtime (the [Runtimes](runtimes.md#runtimes) table):

- **pi and omp**: the inbox extension watches mail, raises `ui.notify`, and
  injects unread items into a turn, starting one when the agent is idle.
- **Claude Code**: the global `UserPromptSubmit` hook drains mail on
  submission and the launch-time `Stop` hook continues for mail arriving
  during a turn. Only a **Rex** launch also gets a receipt-bound idle watcher
  (`claude-session.sh`), which sends a native Unix peer event, not terminal
  text, into the same conversation without submitting the owner's draft; an
  idle Claude in a Herdr pane is not woken.
- **OpenCode**: its plugin hands mail to the idle session as native input.
- **agy**: it wakes only when one of its own background tasks finishes, so its
  hooks keep `cel inbox wait` running as that task; it exits on new mail
  without reading it, and that exit is the wake. Mail waiting when a turn
  starts is attached to it.
- **codex**: no inbox hook; mail waits until the agent runs `cel inbox read`.

Mail stays unread until the agent's own hook or `cel inbox read` reads it.
Direct `herdr agent prompt` is limited to one-time launch kickoffs and the
owner's deliberate interrupts. Escalations remain inbox items, not pane
prompts.

**One name per mailbox.** A mailbox is named by the same string as the herdr
agent that reads it: `cel_alias_norm` (lowercase, `[a-z0-9_-]` only, starts
with a letter, at most 32 characters) is the single rule behind `cel run`,
the steward, every `cel inbox` sender, reader, counter and watcher, and an
explicit `CEL_INBOX_ME`. It is idempotent - normalising a name twice is
normalising it once - so mail to an agent's full name and mail
to its 32-character alias reach the same mailbox, even when the cut falls
right after a dash (that dash is kept: it is the alias herdr already holds).
Before this, such a name came out one character shorter the second time and
the mail sat in a phantom mailbox nobody opened. `cel inbox migrate
--workspace <w>` repairs mail already split that way. It is a dry run by
default and it does not guess: the canonical name must be a live agent or own
a worktree (a sender name or a cursor is typed by whoever runs a command, so
it can disprove a phantom but never prove a target); a legacy name with any
trace of its own is `unsafe` (two real recipients) and left alone; one with no
trace is `unverified`, because a genuine dead recipient looks exactly the same,
and is migrated only when the operator attests it with `--apply --only
<legacy-name>`. Applying keeps every message and id and each reader's unread
position, exactly once. It is journalled: the mailbox and cursors are saved
under `<inbox>/migrate-backup/` first, and if the run is killed the next send,
read or `migrate --apply` finishes it before touching the mailbox.

**Mail to `root` is for a person: `escalation`, `decision`, `blocked`.**
Status belongs in `cel fleet` and the dashboard, so nothing reports it to root
as mail; `cel inbox send root --kind status` warns and still sends.

A mailbox nobody reads is a **fault**, not silence. `cel fleet --json` carries
`mail: {to_root_unread, oldest_secs, reader}` per workspace — `reader` is the
live pane whose alias matches the mailbox, or a running `cel core`, or empty —
`cel doctor` says `alpha: root has 13 unread, oldest 7h, nobody reading it`,
and the steward raises one rolled-up `blocked` item per workspace (which takes
the desktop-notification path, as an `escalation` now does too) when an
unread escalation, decision or blocker (the steward's own mail aside) is
older than `CEL_ROOT_UNREAD_SECS` (default 3600, an hour) and nobody -
matching pane, `cel core` or the console - is reading root's mailbox.

What is left gets **ranked**. `cel inbox open --for root --ranked` and the
dashboard card show the top `inbox.top_n` (3) of the
unread, then `and N more`. A decision model scores each message once against
four concrete levels (`0 informational` … `3 blocking work right now`) and
supplies *only* that level; counts, ages, ordering, the cut and the caching
are the code's. Below `triage.min_confidence` (0.6) a message keeps its kind's
default rank, so an unreachable model degrades to the old ordering rather than
losing messages.
