#!/usr/bin/env python3
"""Restore buildability of debian:-based terminal-bench task images.

Debian moves released suites to archive.debian.org. deb.debian.org stops
rotating the suite's Release file (apt: "Release file ... is expired",
exit 100 inside `docker compose build`) and mid-migration prunes pool
files while the index is stale. Measured 2026-09-13, bullseye:
archive.debian.org/debian serves the final suite (200s);
archive.debian.org/debian-security has NO bullseye-security (404) —
Seen in run 34576017658 (issue #142): qemu-alpine-ssh / qemu-startup
(debian:bullseye-slim) failed their trials as unknown_agent_error before
any agent ran.

This patch inserts one RUN line after each FROM of debian:-based task
Dockerfiles that (a) disables apt's Valid-Until check for every apt
invocation in the build (both the archive's and the snapshot's Release
files are expired forever) and (b) repoints the MAIN suite
(deb.debian.org/debian) at archive.debian.org, the frozen,
self-consistent end state. The security
suite (bullseye-security) is not on the archive yet (probed 404) while
deb.debian.org's security pool 404s a stable subset of files mid-archival
(apt Err 404 on systemd_247.3-7+deb11u8_arm64.deb etc., while the same
URL via curl returns 200) — so the security suite is repointed at
snapshot.debian.org at a fixed timestamp that probed complete (Release +
pool 200s). Acquire::Retries=8 rides the same conf against snapshot's
throttling.

Usage:
    patch_dataset.py <dataset-dir>     # e.g. ~/.cache/terminal-bench/terminal-bench-core/0.1.1

Idempotent: Dockerfiles already carrying the marker conf are skipped.
Ceiling: snapshot.debian.org keeps everything forever; revisit only when
a task bumps its base image.

gh-1208: fix-git's setup.sh clones github.com/TheMikeMerrill/personal-site,
which was DELETED (404 → `could not read Username for 'https://github.com'`,
exit 128 inside `docker compose build`; no trial ever starts). The repair
replaces that setup.sh with a network-free rebuild of the identical task
state — master one commit past a detached-HEAD "Move to Stanford" commit
holding the resources/patch_files payloads, HEAD reflog keeping that commit
on line 4 (the upstream solution.sh reads it there). Marker for idempotency:
the dead repo URL's presence.
"""
import re
import sys
from pathlib import Path

_FROM = re.compile(r"^FROM\s+(?:--platform=\S+\s+)?(\S+)", re.M)
_APT = re.compile(r"\bapt(?:-get)?\s+\S")
_MARKER = "99tb-no-valid-until"
_SNAPSHOT = "20260901T000000Z"  # post-final-u8 upload, pre-archival; probed 200s 2026-09-13
_FIX_RUN = (
    "RUN printf 'Acquire::Check-Valid-Until \"false\";\\nAcquire::Retries \"8\";\\n' "
    f"> /etc/apt/apt.conf.d/{_MARKER} "
    "&& sed -i "
    "'s@\\(deb\\.debian\\.org\\|security\\.debian\\.org\\)/debian-security@"
    f"snapshot.debian.org/archive/debian-security/{_SNAPSHOT}@g; "
    "s@deb\\.debian\\.org/debian@archive.debian.org/debian@g' "
    "/etc/apt/sources.list 2>/dev/null || true"
)

# --- gh-1208: fix-git clones a deleted GitHub repo during image build ------
_FIX_GIT_DIR = "fix-git"
_FIX_GIT_DEAD_REPO = "TheMikeMerrill/personal-site"
# Rebuilds the exact task state the original (dead) clone produced: a
# personal-site repo on master whose tip is one commit PAST the recovery
# point, plus a detached-HEAD "Move to Stanford" commit carrying the
# resources/patch_files payloads. The HEAD reflog must keep that commit on
# LINE 4 — the upstream solution.sh extracts it with
# `awk '{print $2}' | sed -n '4p'`; agents copy that approach.
#   1 commit (initial)   — the pre-Stanford site
#   2 commit             — master moves past the recovery point (was: reset)
#   3 checkout HEAD~1    — detached at the recovery point
#   4 commit             — "Move to Stanford"  ← solution.sh reads this hash
#   5 checkout master    — the dangling commit is left to the reflog
_FIX_GIT_SETUP = """\
#!/bin/bash
# gh-1208: the original setup cloned the author's GitHub repo, which was
# deleted (404) and broke `docker compose build`. This rebuilds the same
# task state locally, without the network.
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

git config --global user.email "test@example.com"
git config --global user.name "Test User"

rm -rf personal-site
mkdir personal-site
cd personal-site
git init -q -b master

# The pre-Stanford site (master tip).
mkdir -p _includes _layouts css
cat > index.md <<'EOF'
---
title: Mike Merrill
---

My personal site.
EOF
cat > _includes/about.md <<'EOF'
I am a Student Researcher at [Google Research](https://research.google/).

Before that I studied CS at UC Berkeley.
EOF
cat > _includes/contact.md <<'EOF'
- [Email](mailto:mike@example.com)
EOF
cat > _includes/interests.md <<'EOF'
- Human-AI interaction
- Machine learning
EOF
cat > _layouts/default.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Mike Merrill</title>
</head>
<body>
    <div class="container">
        <h1>Student Researcher @ Google</h1>
        {{ content }}
    </div>
</body>
</html>
EOF
echo "body { font-family: sans-serif; margin: 2rem; }" > css/style.css
git add -A
git commit -q -m "Initial site"

# Master moves one commit past the recovery point (the original history
# reset the cloned master back before making the recovery commit).
cat > README.md <<'EOF'
# personal-site

Source for my personal site.
EOF
git add -A
git commit -q -m "Add README"

git checkout -q HEAD~1 # Move to the commit before the reset (detached)

cp "$ROOT/resources/patch_files/about.md" ./_includes/about.md
cp "$ROOT/resources/patch_files/default.html" ./_layouts/default.html
git add -A
git commit -q -m "Move to Stanford" # Commit the changes without a branch
git checkout -q master
"""


def patch_fix_git_setup(task_dir):
    """Replace fix-git's dead-clone setup.sh. Returns True when replaced."""
    if task_dir.name != _FIX_GIT_DIR:
        return False
    setup = task_dir / "setup.sh"
    if not setup.is_file():
        return False
    text = setup.read_text(errors="replace")
    if _FIX_GIT_DEAD_REPO not in text:
        return False  # already repaired, or upstream fixed the task
    setup.write_text(_FIX_GIT_SETUP)
    return True


def patch_dockerfile(text):
    """Return (patched_text, changed). Non-debian or apt-less files pass through."""
    bases = _FROM.findall(text)
    if not any(b == "debian" or "debian:" in b for b in bases):
        return text, False
    if _MARKER in text or not _APT.search(text):
        return text, False
    out = []
    for line in text.splitlines(keepends=True):
        out.append(line)
        if line.startswith("FROM"):
            out.append(_FIX_RUN + "\n")
    return "".join(out), True


def main(dataset_dir=None):
    root = Path(dataset_dir if dataset_dir is not None else sys.argv[1])
    dockerfiles = sorted(root.glob("*/Dockerfile"))
    if not dockerfiles:
        raise SystemExit(f"no task Dockerfiles under {root}")
    changed = 0
    for df in dockerfiles:
        text = df.read_text(errors="replace")
        new, did = patch_dockerfile(text)
        if did:
            df.write_text(new)
            changed += 1
            print(f"patched {df.relative_to(root)} (archive.debian.org + no-valid-until)")
    print(f"{changed} of {len(dockerfiles)} Dockerfile(s) patched")

    repaired = 0
    for setup in sorted(root.glob("*/setup.sh")):
        if patch_fix_git_setup(setup.parent):
            repaired += 1
            print(
                f"repaired {setup.relative_to(root)} "
                f"(dead repo clone replaced with vendored rebuild)"
            )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <dataset-dir>")
    main(sys.argv[1])
