#!/usr/bin/env python3
"""gh-2463 — changelog entries guard.

The changelog merge surface is PER-ENTRY FILES now
(`changelog/entries/<issue-or-pr>-<slug>.md`, YAML frontmatter + 1–3
user-facing bullets; conventions: docs/agents/commits-releases.md). The
shared-file habit this card retired must not creep back, and every PR must
document its user-facing change:

  1. HARD (every event): archive history is immutable — MODIFYING or
     DELETING CHANGELOG_ARCHIVE.md or changelog/archive/** fails
     (ADDITIONS are the migration/housekeeping path). CHANGELOG.md is
     generated-only: any edit to it must be byte-identical to what
     scripts/gen_changelog.dart --write-changelog produces from the same
     entries+archive inputs (verified in a temp dir; the checkout is never
     mutated) — a hand wording fails, the gh-2463 migration and future
     regenerations pass.
  2. ENTRY REQUIREMENT: the diff must ADD at least one
     changelog/entries/*.md file. On pull_request events the `no-changelog`
     label waives this (meta/CI/test-only changes). WITHOUT PR label
     context (push/validation-dispatch arms) the requirement degrades to a
     ::warning:: — the pull_request run is the hard gate; a dispatch must
     never false-red for a label it cannot see (same fail-safe direction as
     the #1267 classifier: over-notify, never silently pass a PR arm).
  3. An EMPTY diff passes (main pushes diff to nothing via merge-base).

Usage:
  python3 scripts/check_changelog_entry.py [--base REF] [--head REF]
      [--labels CSV] [--pr-context true|false] [--self-test]
  BASE_REF/HEAD_REF env vars are honored (ci.yml wiring); the base falls
  back to merge-base(origin/main, HEAD) so push/dispatch arms diff the
  actually-landed changes.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ENTRY_RE = re.compile(r"^changelog/entries/\d+-[a-z0-9-]+\.md$")
FORBIDDEN = ("CHANGELOG.md", "CHANGELOG_ARCHIVE.md")
FORBIDDEN_PREFIX = "changelog/archive/"
NO_CHANGELOG_LABEL = "no-changelog"


def _diff_files(repo: str, base: str, head: str) -> list:
    out = subprocess.run(
        ["git", "diff", "--name-status", base, head],
        cwd=repo, capture_output=True, text=True, check=True,
    ).stdout
    files = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status = parts[0][0]  # A / M / D / R / C...
        if status in ("R", "C"):
            # A rename copies+deletes: model it as a deletion of the source
            # (immutability checks) and an addition of the destination.
            if len(parts) >= 3:
                files.append(("D", parts[1]))
                files.append(("A", parts[2]))
            continue
        files.append((status, parts[1]))
    return files


def _regenerated_equals(repo: str, labels: str) -> bool | None:
    """True when the worktree CHANGELOG.md is byte-identical to what
    scripts/gen_changelog.dart --write-changelog produces from the same
    entries+archive inputs (run in a TEMP dir — the checkout is never
    mutated). None when dart is unavailable (skip with a warning)."""
    dart = shutil.which("dart")
    if dart is None:
        print("::warning::dart not on PATH — skipping the changelog "
              "regeneration equality check (the ci.yml static job runs it)")
        return None
    tmp = tempfile.mkdtemp(prefix="cl-regen-")
    try:
        for sub in ("changelog/entries", "changelog/archive"):
            src = os.path.join(repo, sub)
            if os.path.isdir(src):
                shutil.copytree(src, os.path.join(tmp, sub))
        gen = subprocess.run(
            [dart, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "gen_changelog.dart"), "--write-changelog"],
            cwd=tmp, capture_output=True, text=True,
        )
        if gen.returncode != 0:
            print(f"::error::changelog regeneration failed — the committed "
                  f"CHANGELOG.md cannot be generator-made\n{gen.stdout}"
                  f"{gen.stderr}")
            return False
        made = open(os.path.join(tmp, "CHANGELOG.md"), "rb").read()
        have = open(os.path.join(repo, "CHANGELOG.md"), "rb").read()
        return made == have
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check(repo: str, base: str | None, head: str | None, labels: str,
          pr_context: bool) -> int:
    if not base:
        base = os.environ.get("BASE_REF", "")
    if not head:
        head = os.environ.get("HEAD_REF", "")
    if not head:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo,
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    if not base:
        merged = subprocess.run(
            ["git", "merge-base", "origin/main", head], cwd=repo,
            capture_output=True, text=True,
        )
        base = merged.stdout.strip() if merged.returncode == 0 else head

    files = _diff_files(repo, base, head)
    if not files:
        print("changelog entries guard: empty diff — nothing to check")
        return 0

    failures = []
    changelog_touched = False
    for status, path in files:
        if path == "CHANGELOG.md":
            changelog_touched = True
            continue  # legitimacy decided by the regeneration check below
        if path == "CHANGELOG_ARCHIVE.md" or path.startswith(FORBIDDEN_PREFIX):
            if status != "A":
                failures.append(
                    f"forbidden changelog history rewrite ({status} {path}): "
                    "archive files are immutable — history is corrected by "
                    "ADDING a new file, never editing the existing one "
                    "(gh-2463)"
                )
    if failures:
        print("changelog entries guard: FAILED\n")
        for f in failures:
            print(f"::error::{f}")
        return 1

    if changelog_touched:
        # CHANGELOG.md is generated-only: the edit is legitimate iff the
        # committed bytes equal what the generator produces from the same
        # entries+archive (the gh-2463 migration + future regenerations
        # take this path; any hand wording fails).
        same = _regenerated_equals(repo, labels)
        if same is False:
            print("::error::CHANGELOG.md was hand-edited — it must be the "
                  "exact output of `dart scripts/gen_changelog.dart "
                  "--write-changelog` (gh-2463); regenerate instead")
            return 1
        if same:
            print("CHANGELOG.md matches the regenerated output "
                  "(generator-made edit)")

    added_entries = [
        p for s, p in files if s == "A" and ENTRY_RE.match(p)
    ]
    if added_entries:
        for p in sorted(added_entries):
            print(f"changelog entry added: {p}")
        print("changelog entries guard: ok")
        return 0

    label_set = {x.strip() for x in labels.split(",") if x.strip()}
    if pr_context and NO_CHANGELOG_LABEL in label_set:
        print(f"changelog entries guard: ok ('{NO_CHANGELOG_LABEL}' label)")
        return 0
    msg = (
        "no changelog/entries/<issue-or-pr>-<slug>.md file ADDED — every PR "
        "documents its user-facing change in its OWN entry file "
        "(frontmatter type/scope/issue + 1-3 bullet lines); pure meta/CI/"
        "test changes take the 'no-changelog' label"
    )
    if pr_context:
        print(f"::error::{msg}")
        return 1
    print(f"::warning::{msg} (no PR label context on this event — the "
          "pull_request run is the hard gate)")
    return 0


def self_test() -> int:
    """Fixture repo per case: green paths + every red path."""
    def git(repo, *args):
        return subprocess.run(
            ["git", "-c", "user.email=t@t", "-c", "user.name=t", *args],
            cwd=repo, capture_output=True, text=True,
        )

    def fixture(name):
        repo = os.path.join(tempfile.mkdtemp(prefix="cl-guard-"), name)
        os.makedirs(repo)
        git(repo, "init", "-q", "-b", "main")
        with open(os.path.join(repo, "CHANGELOG.md"), "w") as fh:
            fh.write("# Changelog\n")
        with open(os.path.join(repo, "README.md"), "w") as fh:
            fh.write("# t\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "init")
        return repo

    def entry(repo, name):
        d = os.path.join(repo, "changelog", "entries")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name), "w") as fh:
            fh.write("---\ntype: fix\nissue: %s\n---\n\n- bullet\n"
                     % name.split("-")[0])

    def run(repo, pr_context="true", labels=""):
        return subprocess.run(
            [sys.executable, os.path.abspath(__file__),
             "--base", "HEAD~1", "--head", "HEAD",
             "--pr-context", pr_context, "--labels", labels],
            cwd=repo, capture_output=True, text=True,
        )

    cases = []

    r = run((lambda repo: (
        entry(repo, "100-fix.md"), git(repo, "add", "-A"),
        git(repo, "commit", "-qm", "x"), repo)[3])(
        fixture("entry-added")))
    cases.append(("entry added passes", r, 0))

    def edit_changelog(repo):
        entry(repo, "101-fix.md")
        with open(os.path.join(repo, "CHANGELOG.md"), "w") as fh:
            fh.write("# hand\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "x")
        return repo
    r = run(edit_changelog(fixture("changelog-edit")))
    cases.append(("CHANGELOG.md hand edit fails", r, 1))

    def generator_rewrite(repo):
        entry(repo, "102-fix.md")
        subprocess.run(
            ["dart", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  "gen_changelog.dart"), "--write-changelog"],
            cwd=repo, capture_output=True, text=True, check=True,
        )
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "x")
        return repo
    r = run(generator_rewrite(fixture("generator-rewrite")))
    cases.append(("generator-made CHANGELOG.md edit passes", r, 0))

    def add_archive(repo):
        entry(repo, "103-fix.md")
        d = os.path.join(repo, "changelog", "archive")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "1.0.551.md"), "w") as fh:
            fh.write("## 1.0.551\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "x")
        return repo
    r = run(add_archive(fixture("archive-add")))
    cases.append(("archive addition (migration) passes", r, 0))

    def edit_archive(repo):
        d = os.path.join(repo, "changelog", "archive")
        os.makedirs(d)
        with open(os.path.join(d, "1.0.551.md"), "w") as fh:
            fh.write("## 1.0.551\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "seed")
        with open(os.path.join(d, "1.0.551.md"), "w") as fh:
            fh.write("## 1.0.551\n\n- tampered\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "x")
        return repo
    r = run(edit_archive(fixture("archive-edit")))
    cases.append(("archive history rewrite fails", r, 1))

    def code_only(repo):
        with open(os.path.join(repo, "lib.dart"), "w") as fh:
            fh.write("void f() {}\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "x")
        return repo
    r = run(code_only(fixture("no-entry")))
    cases.append(("no entry fails on PR", r, 1))

    r = run(code_only(fixture("labeled")), labels=NO_CHANGELOG_LABEL)
    cases.append(("no-changelog label passes", r, 0))

    r = run(code_only(fixture("wrong-label")), labels="some-other")
    cases.append(("unrelated label fails", r, 1))

    r = run(code_only(fixture("dispatch")), pr_context="false")
    cases.append(("dispatch arm warns, passes", r, 0))

    repo = fixture("empty-diff")
    git(repo, "commit", "--allow-empty", "-qm", "second")
    r = run(repo, pr_context="false")
    cases.append(("empty diff passes", r, 0))

    for name, r, want in cases:
        if r.returncode != want:
            print(f"self-test: {name} FAILED (rc={r.returncode}, "
                  f"want {want})\n{r.stdout}{r.stderr}")
            return 1
    print("self-test: PASS (entry ok, forbidden edits red, label waiver, "
          "dispatch warn-only, empty diff)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", help="base ref (default BASE_REF / merge-base)")
    ap.add_argument("--head", help="head ref (default HEAD_REF / HEAD)")
    ap.add_argument("--labels", default=os.environ.get("CHANGELOG_LABELS", ""),
                    help="comma-separated PR labels")
    ap.add_argument("--pr-context",
                    default=os.environ.get("CHANGELOG_PR_CONTEXT", "false"),
                    help="true on pull_request events (label waiver active)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    return check(os.getcwd(), args.base, args.head, args.labels,
                 args.pr_context.strip().lower() == "true")


if __name__ == "__main__":
    sys.exit(main())
