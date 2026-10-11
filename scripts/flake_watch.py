#!/usr/bin/env python3
"""Flake watcher (gh-1199 AC6): catch the NEXT #1171 before it parks PRs.

Scans the failed ci.yml Quality-gate runs of the last N hours; a test that
is RED in >=2 runs with DISTINCT head SHAs within the window is a proven
flake candidate (the #1171 signature: same SHA can flip green/red, so a
single SHA never proves anything — and one red run is just a regression).
For each candidate the watcher:

    1. creates a `flake`-labelled GitHub issue (or updates the existing
       one) carrying the failing run links, the distinct SHAs, and a
       ready-to-paste entry for scripts/test_quarantine.json;
    2. with --push-quarantine, opens (or updates) a PR adding that entry
       so the gate skips the file pending the fix — the list is checked
       in and reviewed in the fix PR (gh-1199 AC6).

Tests already in scripts/test_quarantine.json are reported but not
re-filed. The gate legs apply the skip via scripts/apply_quarantine.py.

Requires the `gh` CLI and a token with issues+contents+pull-requests
write (GITHUB_TOKEN from the flake-watch.yml schedule is enough).

Pure stdlib + gh. Exit 0 even when nothing to do; 2 on usage/gh errors.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
QUARANTINE_PATH = os.path.join(HERE, "test_quarantine.json")
FLAKE_LABEL = "flake"


def gh(*args: str, check: bool = True) -> str:
    proc = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def failed_runs(repo: str, window_hours: int) -> list:
    since = datetime.now(timezone.utc) - timedelta(hours=window_hours)
    out = gh("run", "list", "--repo", repo, "--workflow", "ci.yml",
             "--json", "databaseId,headSha,createdAt,conclusion,event",
             "--limit", "100")
    runs = []
    for r in json.loads(out):
        if r.get("conclusion") != "failure":
            continue
        created = datetime.fromisoformat(
            r["createdAt"].replace("Z", "+00:00"))
        if created < since:
            continue
        runs.append(r)
    return runs


def failing_tests(repo: str, run_id) -> list:
    """[(file, test_name)] that failed in this run's integration shards."""
    with tempfile.TemporaryDirectory() as tmp:
        proc = subprocess.run(
            ["gh", "run", "download", str(run_id), "--repo", repo,
             "--pattern", "junit-integration-shard-*", "--dir", tmp],
            capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"::warning::run {run_id}: no junit artifacts "
                  f"({proc.stderr.strip()[:200]})", file=sys.stderr)
            return []
        failed = []
        for dirpath, _dirs, files in os.walk(tmp):
            for name in files:
                if not name.endswith(".xml"):
                    continue
                try:
                    tree = ET.parse(os.path.join(dirpath, name))
                except ET.ParseError:
                    continue
                for tc in tree.getroot().iter("testcase"):
                    if tc.find("failure") is None and \
                       tc.find("error") is None:
                        continue
                    failed.append((tc.get("classname", "?"),
                                   tc.get("name", "?")))
        return failed


def load_quarantined() -> set:
    try:
        with open(QUARANTINE_PATH, encoding="utf-8") as f:
            return {e["file"] for e in json.load(f).get("quarantined", [])}
    except (OSError, json.JSONDecodeError, ValueError):
        return set()


def quarantine_entry(file: str, test: str, issue_url: str,
                     shas: list, runs: list) -> str:
    today = datetime.now(timezone.utc).date().isoformat()
    return json.dumps({
        "file": file,
        "test": test,
        "issue": issue_url,
        "since": today,
        "runs": runs,
    }, indent=2)


def list_flake_issues(repo: str, state: str = "open") -> list:
    """Open/closed `flake` issues, listed outright — no `--search`.

    gh-1364: GitHub issue search silently returns [] for an unquoted
    `(#<digits>` title fragment (seven duplicate trackers got minted that
    way, one per hourly run), and a freshly created issue only surfaces
    in search after an indexing lag. The label+state listing has neither
    failure mode; matching happens in Python.
    """
    out = gh("issue", "list", "--repo", repo, "--label", FLAKE_LABEL,
             "--state", state, "--limit", "500",
             "--json", "number,title,url,body")
    return json.loads(out)


def issue_tracks_file(issue: dict, file: str) -> bool:
    """True when the issue body's `**File**:` line names `file`.

    The quarantined path is the dedup key — unique per flake — never the
    truncated test title (two tests may share their first 77 chars, and
    the `(#<digits>` suffix in those titles is what GitHub search cannot
    see, gh-1364).
    """
    return f"**File**: `{file}`" in (issue.get("body") or "")


def find_issue(repo: str, file: str):
    """The open flake tracker for `file`, or None."""
    for i in list_flake_issues(repo):
        if issue_tracks_file(i, file):
            return i
    return None


def issue_body(file: str, test: str, repo: str, runs: list,
               shas: list) -> str:
    links = "\n".join(f"- https://github.com/{repo}/actions/runs/{r}"
                      for r in runs)
    entry = quarantine_entry(file, test, "<issue url>", shas, runs)
    return (
        f"## Flake: `{test}`\n\n"
        f"**File**: `{file}`\n\n"
        f"Red in **{len(shas)} distinct-SHA** Quality-gate runs within "
        f"24h (gh-1199 AC6 signature) — a model's mood or a schedule "
        f"shift, not the PRs' code, is the only thing those SHAs share.\n\n"
        f"### Failing runs\n{links}\n\n"
        f"### Distinct SHAs\n" +
        "\n".join(f"- `{s}`" for s in shas) +
        "\n\n### Quarantine\n\nAdd this entry to "
        "`scripts/test_quarantine.json` (reviewed in the fix PR) so the "
        "gate skips the file pending the fix; nightly keeps running it "
        "supervised to produce the un-quarantine repeat-run proof "
        "(gh-1199 AC4):\n\n```json\n" + entry + "\n```\n")


def tracker_runs(repo: str, number: int) -> str:
    """The issue's body plus every comment body, concatenated.

    Run mentions must count across BOTH (gh-1364): ensure_issue appends
    missing runs as comments, so a run counted against the body only is
    re-commented on every pass while the body stays stale. Callers match
    mentions by their `/runs/<id>` link tail — a bare id substring would
    false-positive on digit-bearing title fragments (`(#573 review`)."""
    out = gh("issue", "view", str(number), "--repo", repo,
             "--json", "body,comments")
    doc = json.loads(out)
    return "\n".join([doc.get("body") or ""] +
                     [c.get("body") or "" for c in doc.get("comments", [])])


def _assert_sole_tracker(repo: str, file: str, created_url: str) -> None:
    """gh-1364 guard rail: a tracker we just minted must own the file's
    ONLY open issue. Any other open flake issue carrying the same
    `**File**:` line means the dedup above missed — close the fresh
    duplicate and fail loudly (the watcher run goes red, a human looks)
    instead of silently minting one duplicate per hourly run."""
    number = created_url.rstrip("/").rsplit("/", 1)[-1]
    others = [i["number"] for i in list_flake_issues(repo)
              if issue_tracks_file(i, file) and str(i["number"]) != number]
    if others:
        gh("issue", "close", str(number), "--repo", repo)
        raise RuntimeError(
            f"flake dedup missed: created {created_url} for {file} but "
            f"open tracker(s) {others} already carry the same file — "
            f"closed the fresh duplicate, check find_issue")


def ensure_issue(repo: str, file: str, test: str, runs: list,
                 shas: list) -> str:
    """Create or update the flake issue; returns its URL.

    Dedup keys on `file` (see find_issue). A CLOSED tracker for the same
    file is re-opened and refreshed instead of re-filed next to: the
    watcher's window keeps holding the pre-fix red runs after a flake is
    fixed and its tracker proof-closed, and minting a fresh tracker there
    unlinks the closure proof — exactly how #1365 landed next to
    proof-closed #1362 (gh-1364 round 3).
    """
    title_key = test if len(test) <= 80 else test[:77] + "..."
    existing = find_issue(repo, file)
    if existing is None:
        closed = [i for i in list_flake_issues(repo, "closed")
                  if issue_tracks_file(i, file)]
        if closed:
            existing = max(closed, key=lambda i: i["number"])
            gh("issue", "reopen", str(existing["number"]), "--repo", repo)
    if existing is None:
        out = gh("issue", "create", "--repo", repo,
                 "--title", f"Flake: {title_key}",
                 "--label", FLAKE_LABEL,
                 "--body", issue_body(file, test, repo, runs, shas))
        # `gh issue create` prints the URL on success.
        url = out.strip().splitlines()[-1]
        _assert_sole_tracker(repo, file, url)
        return url
    # Update: append any run not already mentioned in body or comments.
    known = tracker_runs(repo, existing["number"])
    missing = [r for r in runs if f"/runs/{r}" not in known]
    if missing:
        gh("issue", "comment", str(existing["number"]), "--repo", repo,
           "--body", "Additional red runs: " +
           ", ".join(f"https://github.com/{repo}/actions/runs/{r}"
                     for r in missing))
    return existing["url"]


def push_quarantine_pr(repo: str, file: str, test: str, issue_url: str,
                       shas: list, runs: list, cwd: str) -> None:
    """Best-effort PR adding the quarantine entry (checked in + reviewed).

    Runs inside the workflow's git checkout with gh-authenticated git
    (flake-watch.yml does `gh auth setup-git`). Idempotent: an existing
    branch/PR for the same file is reused, the entry is only appended
    once.
    """
    branch = "flake-quarantine/" + os.path.basename(file).replace(
        "_test.dart", "")[:40]
    entry = json.loads(quarantine_entry(file, test, issue_url, shas, runs))

    def git(*args: str) -> None:
        subprocess.run(["git", *args], cwd=cwd, check=True,
                       capture_output=True, text=True)

    git("fetch", "origin", "main")
    git("checkout", "-B", branch, "origin/main")
    with open(os.path.join(cwd, "scripts/test_quarantine.json"),
              encoding="utf-8") as f:
        doc = json.load(f)
    if any(e["file"] == file for e in doc.get("quarantined", [])):
        print(f"::notice::{file} already quarantined on {branch}")
        return
    doc.setdefault("quarantined", []).append(entry)
    with open(os.path.join(cwd, "scripts/test_quarantine.json"), "w",
              encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    git("add", "scripts/test_quarantine.json")
    git("-c", "user.name=ai.teammate",
        "-c", "user.email=agent.ai.native@gmail.com",
        "commit", "-m",
        f"ci(quarantine): skip {os.path.basename(file)} in the gate "
        f"(flake, {issue_url})")
    git("push", "-f", "origin", branch)
    existing = subprocess.run(
        ["gh", "pr", "list", "--repo", repo, "--head", branch,
         "--json", "url", "--jq", ".[0].url"],
        capture_output=True, text=True)
    if existing.stdout.strip():
        print(f"::notice::quarantine PR already open: {existing.stdout.strip()}")
        return
    body = (f"gh-1199 AC6 flake quarantine: `{test}` "
            f"(`{file}`) red in {len(shas)} distinct-SHA gate runs.\n\n"
            f"Tracked in {issue_url}. The gate skips this file until the "
            f"fix lands; nightly keeps running it supervised "
            f"(un-quarantine needs the AC4 repeat-run proof).")
    out = subprocess.run(["gh", "pr", "create", "--repo", repo,
                          "--title", f"ci(quarantine): {file} (flake)",
                          "--body", body, "--base", "main",
                          "--head", branch],
                         capture_output=True, text=True)
    if out.returncode == 0:
        print(f"::notice::quarantine PR opened: {out.stdout.strip()}")
    else:
        print(f"::warning::pr create failed: {out.stderr.strip()[:300]}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    ap.add_argument("--window-hours", type=int, default=24)
    ap.add_argument("--min-runs", type=int, default=2)
    ap.add_argument("--push-quarantine", action="store_true",
                    help="best-effort: open a PR adding the quarantine "
                         "entry (needs a git checkout with gh auth)")
    ap.add_argument("--checkout", default=".",
                    help="git checkout used by --push-quarantine")
    args = ap.parse_args()
    if not args.repo:
        print("ERROR: --repo or GITHUB_REPOSITORY required", file=sys.stderr)
        return 2

    runs = failed_runs(args.repo, args.window_hours)
    if not runs:
        print(f"No failed ci.yml runs in the last {args.window_hours}h — "
              f"nothing to watch")
        return 0

    by_test: dict = {}
    for r in runs:
        for file, name in failing_tests(args.repo, r["databaseId"]):
            slot = by_test.setdefault((file, name), {"runs": [], "shas": []})
            slot["runs"].append(r["databaseId"])
            if r["headSha"] not in slot["shas"]:
                slot["shas"].append(r["headSha"])

    quarantined = load_quarantined()
    filed = 0
    for (file, name), info in sorted(by_test.items()):
        if len(info["shas"]) < args.min_runs:
            continue  # one red run is a regression, not a flake
        if file in quarantined:
            print(f"already quarantined: {file} ({name})")
            continue
        issue_url = ensure_issue(args.repo, file, name, info["runs"],
                                 info["shas"])
        filed += 1
        print(f"flake proven across {len(info['shas'])} SHAs: {name} "
              f"({file}) — {issue_url}")
        if args.push_quarantine:
            push_quarantine_pr(args.repo, file, name, issue_url,
                               info["shas"], info["runs"], args.checkout)
    if not filed:
        print("No >=2-distinct-SHA flake candidates in window.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
