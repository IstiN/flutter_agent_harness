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


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <dataset-dir>")
    main(sys.argv[1])
