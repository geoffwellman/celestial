"""Render one repo's open PRs as a compact block. Reads `gh pr list --json` on stdin.

Lives in its own file rather than inline in pr-watch.sh: the f-strings here need
double quotes inside double-quoted braces, which is unescapable inside a shell
heredoc without turning every line into backslash soup.
"""
import datetime
import json
import os
import sys

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
RED, GREEN, YELLOW, BLUE = "\033[31m", "\033[32m", "\033[33m", "\033[34m"

# omp variant arms are long-lived experiment branches that say "do not merge" in their
# own titles — 15 of the 21 open games PRs. They are never the thing you need to act on,
# so they're out by default. ARM=1 puts them back.
SHOW_ARM = bool(os.environ.get("ARM"))


def is_arm(pr):
    return pr["headRefName"].startswith("omp-variant/") or pr["title"].startswith("[ARM")


def ago(ts):
    then = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    secs = (datetime.datetime.now(datetime.timezone.utc) - then).total_seconds()
    for size, unit in ((86400, "d"), (3600, "h"), (60, "m")):
        if secs >= size:
            return f"{int(secs // size)}{unit}"
    return "now"


def checks(rollup):
    """One phrase for the whole check rollup.

    An empty rollup is NOT a pass — it means no workflow reported at all, which is
    exactly how the stale builder-catalog reached games main unnoticed. It gets its
    own marker rather than being blended into a green tick.
    """
    if not rollup:
        return f"{YELLOW}no checks{RESET}"
    bad = pending = ok = 0
    for c in rollup:
        state = c.get("conclusion") or c.get("state") or ""
        if state in ("SUCCESS", "NEUTRAL", "SKIPPED"):
            ok += 1
        elif state in ("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR"):
            bad += 1
        else:
            pending += 1
    if bad:
        return f"{RED}{bad} failing{RESET}"
    if pending:
        return f"{YELLOW}{pending} running{RESET}"
    return f"{GREEN}{ok} green{RESET}"


def review(pr):
    d = pr.get("reviewDecision") or ""
    return {
        "APPROVED": f"{GREEN}approved{RESET}",
        "CHANGES_REQUESTED": f"{RED}changes req{RESET}",
        "REVIEW_REQUIRED": f"{YELLOW}needs review{RESET}",
    }.get(d, f"{DIM}unreviewed{RESET}")


def main():
    prs = json.load(sys.stdin)
    hidden = 0
    if not SHOW_ARM:
        kept = [p for p in prs if not is_arm(p)]
        hidden = len(prs) - len(kept)
        prs = kept
    if not prs:
        # Say *why* the list is empty. "none open" when 15 were filtered out is a lie
        # that reads as good news.
        note = f" {DIM}({hidden} ARM hidden){RESET}" if hidden else ""
        print(f"  {DIM}none open{RESET}{note}")
        return
    for pr in sorted(prs, key=lambda p: p["number"]):
        num = pr["number"]
        title = pr["title"]
        if len(title) > 54:
            title = title[:53] + "…"
        draft = f" {DIM}[draft]{RESET}" if pr["isDraft"] else ""
        # MERGEABLE/CONFLICTING/UNKNOWN — only shout about a real conflict; UNKNOWN
        # just means GitHub hasn't finished computing the merge yet.
        conflict = f" {RED}CONFLICTS{RESET}" if pr.get("mergeable") == "CONFLICTING" else ""
        print(f"  {BOLD}#{num}{RESET} {title}{draft}{conflict}")
        print(
            f"      {BLUE}{pr['headRefName']}{RESET}"
            f"  {DIM}·{RESET} {checks(pr.get('statusCheckRollup'))}"
            f"  {DIM}·{RESET} {review(pr)}"
            f"  {DIM}·{RESET} {pr['author']['login']}"
            f"  {DIM}·{RESET} {ago(pr['updatedAt'])} ago"
        )
    # Always account for what was filtered, so a suppressed PR is a visible decision
    # rather than an invisible one.
    if hidden:
        print(f"  {DIM}+ {hidden} ARM variant PR(s) hidden — ARM=1 to show{RESET}")


if __name__ == "__main__":
    main()
