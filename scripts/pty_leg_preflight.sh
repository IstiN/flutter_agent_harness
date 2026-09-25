#!/usr/bin/env bash
# gh-936 — PTY/CLI leg-start preflight.
#
# A CANCELLED run's orphans poisoned the successor: the chain of doom was
# cancel → orphans ("Cleaning up orphan processes" in the runner log) →
# the still-alive dart tests keep holding /tmp dirs and ports → the next
# dispatch contaminates → fails → cancel. This script runs at the START
# of every PTY leg and clears the predecessor's residue:
#
#   1. kill orphaned PTY-harness CLI children (the harness spawns
#      `dart ... bin/fah.dart`; they hold the fa_pty_ tmp dirs as CWD and
#      the hub/test ports as listeners);
#   2. kill orphaned `dart test --tags integration` runners from a
#      previous cancelled dispatch (their in-process FakeHubs hold ports
#      the unique-slice allocator would otherwise have to avoid);
#   3. sweep the harness's tmp roots — the current per-RUN unique
#      `fa_pty_*` roots (created lazily AFTER this step, so the sweep
#      never touches this leg's own dirs) plus the legacy fixed names
#      the suites used before gh-936.
#
# SAFE TO RUN PER LEG: a self-hosted runner in this repo's pools serves
# ONE job at a time (runner-pick counts the pool before dispatch), so
# everything matched here belongs to a FINISHED or cancelled dispatch.
# If a host ever serves concurrent legs, drop step 2 first — it is the
# only pattern a live sibling leg could legitimately match.
set -u

# 1. Orphaned PTY-harness CLI children (the harness marker is the script
#    path every spawn carries on its command line).
pkill -f 'bin/fah.dart' 2>/dev/null || true

# 2. Orphaned integration test runners from a cancelled predecessor.
pkill -f 'test --tags integration' 2>/dev/null || true

# 3. Harness tmp roots: per-run unique prefix + the pre-gh-936 fixed
#    names (the old suites never cleaned them on cancel).
rm -rf /tmp/fa_pty_* 2>/dev/null || true
rm -rf /tmp/fa_539_home /tmp/fa_539_proj /tmp/fa_573_home /tmp/fa_573_proj \
      /tmp/fa_599_home /tmp/fa_599_proj /tmp/fa_446_home /tmp/fa_446_proj \
      /tmp/fa_pty_cwd /tmp/fa496ws /tmp/fa467ws /tmp/fa467ws2 /tmp/fa503ws \
      /tmp/fa479ws /tmp/fatinyws /tmp/fa_badge_ws /tmp/fa_probe_ws \
      2>/dev/null || true

echo "pty leg preflight: orphans killed, tmp roots swept"
