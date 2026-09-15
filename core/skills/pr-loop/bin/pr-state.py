"""Decide what one PR needs next, from `gh pr view` + timeline JSON files.

Reads two FILES named by $PR_FILE and $TL_FILE rather than one composed JSON document.
Composing them (`jq -n --argjson pr "$pr" --argjson t "$timeline"`) put both payloads on the
command line, and a long-lived PR's timeline is easily megabytes: a real PR open 18
days died with `jq: Argument list too long` while every short-lived PR worked. Files have no
such ceiling, and it drops the jq dependency from this path entirely.

Separate from pr-format.py (the standing dashboard) because this answers a different
question: not "what is open?" but "what should I DO about this one, right now?". The whole
state machine lives here rather than in the skill prose so the loop and the documentation
cannot drift apart — the skill says what each action means, this decides which one applies.

Env:
  REVIEWER   the review bot to shepherd (from the workspace policy; no default)
  NUDGE_MIN  minutes to wait on a requested review before nudging (default 15)
  MAX_NUDGE  nudges since the last commit before escalating to the human (default 3)
  STALE_H    hours after which an unanswered request is retried once more anyway (default 6)
"""
import datetime
import json
import os
import sys

REVIEWER = os.environ.get("REVIEWER", "")
NUDGE_MIN = int(os.environ.get("NUDGE_MIN", "15"))
# Default 1, not 3: a re-request has never been OBSERVED to make the reviewer review
# anything (2026-08-31 — observed reviewing a colleague's PRs that morning with no request
# event at all, while ignoring seven on ours). One attempt, then hand it to a human.
MAX_NUDGE = int(os.environ.get("MAX_NUDGE", "1"))
STALE_H = float(os.environ.get("STALE_H", "6"))
# The GitHub login this loop acts for. Empty disables the ownership guard — set it deliberately.
VIEWER = os.environ.get("VIEWER", "")

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
RED, GREEN, YELLOW, BLUE = "\033[31m", "\033[32m", "\033[33m", "\033[34m"


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def mins_since(t):
    return (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 60


def checks(rollup):
    """SUCCESS / FAILURE / PENDING / NONE — an empty rollup is NOT a pass.

    Same rule as the dashboard: no workflow reporting at all is its own state. Asking for
    a review on a PR nothing has built is how a red branch gets approved.
    """
    if not rollup:
        return "NONE", 0, 0
    bad = pending = 0
    for c in rollup:
        state = c.get("conclusion") or c.get("state") or ""
        if state in ("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR"):
            bad += 1
        elif state not in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            pending += 1
    return ("FAILURE" if bad else "PENDING" if pending else "SUCCESS"), bad, pending


def decide(pr, timeline):
    # OWNERSHIP FIRST, before any other consideration. This tool exists to shepherd the
    # viewer's OWN PRs, and every action it names writes to a PR — a re-request, a push, a
    # comment. Doing any of that on a colleague's PR is not a smaller version of the job, it is
    # a different and unwelcome one. The sweep already filters `--author @me`, but a directly
    # addressed PR number bypasses that entirely, so the refusal lives HERE where every path
    # goes through it.
    if VIEWER and (pr.get("author") or {}).get("login") != VIEWER:
        return "not-mine", f"authored by {(pr.get('author') or {}).get('login') or 'someone else'} — not mine to act on"

    """One action, and the reason for it. Order matters: the first true branch wins, and it
    runs cheapest-and-most-blocking first — there is no point asking for a review of a branch
    that will not merge or does not build."""
    if pr.get("isDraft"):
        return "skip", "draft — mark it ready when you want it reviewed"
    if pr.get("mergeable") == "CONFLICTING":
        return "rebase", "conflicts with the base branch"

    state, bad, pending = checks(pr.get("statusCheckRollup"))
    if state == "FAILURE":
        return "fix-checks", f"{bad} check(s) failing"

    commits = [ts(c["committedDate"]) for c in pr.get("commits", []) if c.get("committedDate")]
    last_push = max(commits) if commits else None

    reviews = [r for r in pr.get("reviews", []) if (r.get("author") or {}).get("login") == REVIEWER]
    reviews.sort(key=lambda r: r["submittedAt"])
    last = reviews[-1] if reviews else None
    last_at = ts(last["submittedAt"]) if last else None
    # A review of code that has since been pushed over says nothing about what is there now.
    stale = bool(last_at and last_push and last_at < last_push)

    if last and not stale:
        if last["state"] == "APPROVED":
            # Approved is not the finish line — merged is. Everything that could still make the
            # merge wrong is re-checked HERE rather than trusted from the approval: an approval
            # given before a check went red, or before the base moved under it, is an approval of
            # something other than what would land.
            if state == "SUCCESS" and pr.get("mergeable") == "MERGEABLE":
                return "merge", "approved, green and mergeable — squash it"
            if state == "SUCCESS":
                return "wait", f"approved, but mergeable={pr.get('mergeable')} — not safe to merge yet"
            # PENDING/NONE fall through to the check rules below, which say the same thing
            # more precisely.
        if last["state"] == "CHANGES_REQUESTED":
            return "fix-review", "changes requested — read the review, fix, push, re-request"
        # COMMENTED / DISMISSED: a comment is not a verdict, so this is still waiting on one.

    if state == "PENDING":
        return "wait", f"{pending} check(s) still running"
    if state == "NONE":
        return "no-checks", "nothing reported a check — do not ask for a review of an unbuilt branch"

    requested = REVIEWER in [(u or {}).get("login") for u in pr.get("reviewRequests", [])]
    if not requested:
        return "request", f"{REVIEWER} is not on the review — request it"

    # Requested and waiting. How long, and how many times have we already asked since the
    # last push? Both come from the timeline; `gh pr view` carries neither.
    asks = [ts(e["created_at"]) for e in timeline
            if e.get("event") == "review_requested"
            and (e.get("requested_reviewer") or {}).get("login") == REVIEWER]
    since_push = [a for a in asks if not last_push or a >= last_push]
    waited = mins_since(max(asks)) if asks else None

    if len(since_push) > MAX_NUDGE:
        # A long silence is a DIFFERENT fact from a burst of ignored nudges. Five unanswered
        # asks in one afternoon means stop pestering; the same five with the newest four days
        # old means the bot was down or dropped it, and conditions have since changed — that
        # earns exactly one fresh attempt, reported as the retry it is, not another escalation
        # to a human who was already told.
        if waited is not None and waited > STALE_H * 60:
            return "nudge", f"{len(since_push)} unanswered requests, newest {int(waited // 60)}h ago — retry once, then escalate"
        return "escalate", (f"{len(since_push)} request(s) since the last push, no review — a re-request is not a "
                            f"proven trigger for {REVIEWER}; ask a human how it gets invoked")
    if waited is None:
        return "nudge", "requested, but no request event found — re-request"
    if waited < NUDGE_MIN:
        return "wait", f"requested {int(waited)}m ago — {REVIEWER} usually answers within 5m, give it {NUDGE_MIN}m"
    return "nudge", f"requested {int(waited)}m ago with no review — remove and re-request"


ACTION_COLOR = {
    "done": GREEN, "wait": DIM, "skip": DIM,
    "nudge": YELLOW, "request": YELLOW, "no-checks": YELLOW,
    "fix-review": RED, "fix-checks": RED, "rebase": RED, "escalate": RED,
    "not-mine": DIM,
    "merge": GREEN,
}


def main():
    with open(os.environ["PR_FILE"]) as f:
        pr = json.load(f)
    try:
        with open(os.environ["TL_FILE"]) as f:
            timeline = json.load(f)
    except (OSError, json.JSONDecodeError):
        # A timeline we could not read only costs the nudge AGE, never a wrong action — the
        # decision falls through to "requested, but no request event found -> nudge".
        timeline = []
    action, why = decide(pr, timeline)
    state, _, _ = checks(pr.get("statusCheckRollup"))
    print(f"{BOLD}#{pr['number']}{RESET} {pr['title']}")
    print(f"    {BLUE}{pr['headRefName']}{RESET}  {DIM}·{RESET} checks {state}"
          f"  {DIM}·{RESET} {pr.get('reviewDecision') or 'no decision'}  {DIM}·{RESET} {pr['url']}")
    print(f"    {ACTION_COLOR.get(action, '')}{BOLD}{action}{RESET} — {why}")
    # The action word on its own last line, for a caller that wants to branch on it.
    print(f"ACTION={action}")


if __name__ == "__main__":
    main()
