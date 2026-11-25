#!/usr/bin/env bash
# Copyright (c) 2026, the Flutter Agent Harness authors.
# Use of this source code is governed by a MIT license that can be found
# in the LICENSE file.
#
# nightly_red_tracker_selftest.sh — fixture self-test for the nightly-red
# tracker's close self-heal (scripts/nightly_red_tracker.sh, issue #2362).
#
# 2026-11-20 + 2026-11-21 (2/2 consecutive nights): the nightly auto-issue
# close leg closed the open nightly-red tracker (#1953) with a "Green
# again" comment while the run's PTY/CLI integration and Build ios legs
# had failed ~3h earlier (runs 44667132620 / 44860623417 — close logged at
# 06:40:02Z, run concluded failure at 06:40:05Z), and the reopen that
# normally lands in 2-3.5 min (a fleet-side monitor sweep) never did —
# manual reopens both nights. Proves, against a stubbed `gh` (no network,
# no token; the jq filtering runs the REAL jq against real API shapes):
#   AC1 a premature close on a red night (the observed Nov-20 job shape:
#       PTY/CLI + ios failed, needs-green legs + in-flight filer green)
#       is re-opened back-to-back and the OPEN state is verified;
#   AC2 reopen retry exhaustion stamps a `reopen-failed` label + comment
#       and exits nonzero — loud, no SLA polling timer;
#   AC3 the close stands untouched on a genuinely green run — zero
#       mutating calls, tracker stays closed;
#   AC4 the bounded retry: a state read that still says CLOSED (GH
#       propagation lag) re-opens a second time instead of giving up or
#       looping forever;
#   AC5 an empty close-number (dispatch drill, or the close leg closed
#       nothing) is a silent why-not — no gh calls at all;
#   AC6 a timed_out leg (budget breach) is a red night — close must not
#       stand, reopen names the leg (#2362 review finding);
#   AC7 a cancelled leg (infrastructure cut, the watchdog_trip_check.sh
#       kill shape) is a red night — same contract as AC6.
# Same discipline as flake_watch_selftest.sh (gh-1364, #1100 pattern).
# Wired into ci.yml Static gates.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Stub `gh`: serves jobs-API and issue fixtures, records every invocation,
# applies state mutations (reopen/comment/label), and delegates the script's
# --jq filtering to the REAL jq so the queries themselves stay under test.
# `lag` = how many issue-view reads still report CLOSED after a reopen
# (emulates GH state propagation; drives the retry paths).
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys

args = sys.argv[1:]
state_path = os.environ["FAKE_GH_STATE"]
log_path = os.environ["FAKE_GH_LOG"]

with open(log_path, "a", encoding="utf-8") as f:
    f.write(json.dumps(args) + "\n")


def load():
    with open(state_path, encoding="utf-8") as f:
        return json.load(f)


def save(st):
    with open(state_path, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=2)


def flag(name):
    return args[args.index(name) + 1] if name in args else None


def jq(expr, doc):
    # gh's --jq renders string results raw (jq -r semantics).
    proc = subprocess.run(["jq", "-r", expr], input=doc,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"stub gh: jq failed: {proc.stderr}")
    return proc.stdout


def find(st, num):
    for i in st["issues"]:
        if i["number"] == num:
            return i
    raise SystemExit(f"stub gh: no issue #{num}")


if args[0] == "api":
    st = load()
    out = json.dumps({"jobs": st["jobs"]})
    sys.stdout.write(jq(flag("--jq") or ".", out))
elif "issue" in args and "view" in args:
    st = load()
    i = find(st, int(flag("view")))
    if st["lag"] > 0:
        st["lag"] -= 1
        save(st)
        reported = "CLOSED"
    else:
        reported = i["state"]
    sys.stdout.write(jq(".state", json.dumps({"state": reported})))
elif "issue" in args and "reopen" in args:
    st = load()
    find(st, int(flag("reopen")))["state"] = "OPEN"
    save(st)
elif "issue" in args and "comment" in args:
    st = load()
    i = find(st, int(flag("comment")))
    i.setdefault("comments", []).append(flag("--body"))
    save(st)
elif "issue" in args and "edit" in args:
    st = load()
    i = find(st, int(flag("edit")))
    i.setdefault("labels", []).append(flag("--add-label"))
    save(st)
elif "label" in args and "create" in args:
    pass
else:
    raise SystemExit(f"stub gh: unexpected call: {args}")
PYEOF
chmod +x "$TMP/bin/gh"

export FAKE_GH_STATE="$TMP/state.json"
export FAKE_GH_LOG="$TMP/calls.log"
export GITHUB_REPOSITORY="o/r"
export GITHUB_RUN_ID="44667132620"
export GITHUB_SERVER_URL="https://github.com"
export REOPEN_VERIFY_WAIT="0"  # real GH propagation wait — not in tests
export GITHUB_STEP_SUMMARY="$TMP/summary.txt"

# The observed 2026-11-20 job shape (run 44667132620): PTY/CLI + ios legs
# failed at 03:25/03:33, the needs-green legs succeeded, the filer itself
# was still in flight when the self-heal queries the run.
RED_RUN='[
 {"name": "PTY/CLI integration (nightly-only suites)", "conclusion": "failure"},
 {"name": "Build ios (release)", "conclusion": "failure"},
 {"name": "Build macos (release)", "conclusion": "success"},
 {"name": "Build linux (release)", "conclusion": "success"},
 {"name": "Memory churn report (issue", "conclusion": "success"},
 {"name": "File nightly-red issue", "conclusion": null}
]'
GREEN_RUN='[
 {"name": "PTY/CLI integration (nightly-only suites)", "conclusion": "success"},
 {"name": "Build ios (release)", "conclusion": "success"},
 {"name": "Memory churn report (issue", "conclusion": "success"},
 {"name": "File nightly-red issue", "conclusion": "success"}
]'
# Red subclasses beyond plain failure: a timed-out leg (budget breach) and
# a cancelled leg (infrastructure cut — the watchdog_trip_check.sh kill
# shapes). Both are red nights; the close must never stand on them.
RED_TIMEOUT_RUN='[
 {"name": "PTY/CLI integration (nightly-only suites)", "conclusion": "timed_out"},
 {"name": "Build macos (release)", "conclusion": "success"},
 {"name": "Memory churn report (issue", "conclusion": "success"},
 {"name": "File nightly-red issue", "conclusion": null}
]'
RED_CANCELLED_RUN='[
 {"name": "Build ios (release)", "conclusion": "cancelled"},
 {"name": "Build macos (release)", "conclusion": "success"},
 {"name": "Memory churn report (issue", "conclusion": "success"},
 {"name": "File nightly-red issue", "conclusion": null}
]'

fails=0

check() { # <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (got: $2, want: $3)"
    fails=$((fails + 1))
  fi
}

reset() { # <jobs-json> <lag>
  cat > "$FAKE_GH_STATE" <<EOF
{"jobs": $1, "lag": $2, "issues": [
  {"number": 1953, "state": "CLOSED", "comments": [], "labels": ["nightly-red"]}
]}
EOF
  : > "$FAKE_GH_LOG"
  : > "$GITHUB_STEP_SUMMARY"
}

call_count() { # <argv-token> — gh invocations carrying it as an exact token
  python3 - "$FAKE_GH_LOG" "$1" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    rows = [json.loads(l) for l in f if l.strip()]
print(sum(1 for r in rows if sys.argv[2] in r))
PYEOF
}

all_calls() {
  python3 -c 'import json,sys
rows = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
print(len(rows))' "$FAKE_GH_LOG"
}

issue_field() { # <field: state|labels|comments>
  python3 - "$FAKE_GH_STATE" "$1" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    st = json.load(f)
i = next(i for i in st["issues"] if i["number"] == 1953)
v = i.get(sys.argv[2], [])
print("\n".join(v) if isinstance(v, list) else v)
PYEOF
}

heal() { PATH="$TMP/bin:$PATH" bash "$HERE/nightly_red_tracker.sh" self-heal "$@"; }

# AC1 — the headline bug: a close that lands on a red night (the observed
# Nov-20 shape) is self-healed back-to-back and verified OPEN.
reset "$RED_RUN" 0
heal 1953
check "AC1 red-night premature close exits 0" "$?" "0"
check "AC1 tracker is OPEN after the self-heal" "$(issue_field state)" "OPEN"
check "AC1 exactly one reopen lands" "$(call_count reopen)" "1"
check "AC1 reopen comment names the failing legs" \
  "$(issue_field comments | grep -c 'PTY/CLI integration')" "1"
check "AC1 decision + step summary say reopened" \
  "$(grep -c 'reopened #1953' "$GITHUB_STEP_SUMMARY")" "1"

# AC2 — retry exhaustion stamps the loud marker and exits nonzero.
reset "$RED_RUN" 999  # every state read stays CLOSED
heal 1953
rc=$?
check "AC2 exhaustion exits nonzero" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
check "AC2 exactly 2 reopen attempts (retry once)" "$(call_count reopen)" "2"
check "AC2 reopen-failed label lands" \
  "$(issue_field labels | grep -c 'reopen-failed')" "1"
check "AC2 exhaustion comment lands" \
  "$(issue_field comments | grep -c 'reopen-failed')" "1"

# AC3 — a genuinely green run leaves the close standing: no mutations.
reset "$GREEN_RUN" 0
heal 1953
check "AC3 green run exits 0" "$?" "0"
check "AC3 tracker stays CLOSED" "$(issue_field state)" "CLOSED"
check "AC3 zero reopens" "$(call_count reopen)" "0"

# AC4 — bounded retry: a state read still saying CLOSED (propagation lag)
# re-opens a second time instead of giving up.
reset "$RED_RUN" 1
heal 1953
check "AC4 lagged verify exits 0" "$?" "0"
check "AC4 retry lands exactly 2 reopens" "$(call_count reopen)" "2"
check "AC4 tracker is OPEN" "$(issue_field state)" "OPEN"

# AC5 — empty close-number (dispatch drill / nothing closed): silent why-not.
reset "$RED_RUN" 0
heal ""
check "AC5 empty number exits 0" "$?" "0"
check "AC5 no gh calls at all" "$(all_calls)" "0"

# AC6 — a timed_out leg is a red night (budget breach): the close must not
# stand and the reopen must name the leg.
reset "$RED_TIMEOUT_RUN" 0
heal 1953
check "AC6 timed_out night exits 0" "$?" "0"
check "AC6 timed_out night reopens the tracker" "$(issue_field state)" "OPEN"
check "AC6 timed_out night fires exactly one reopen" "$(call_count reopen)" "1"
check "AC6 reopen comment names the timed-out leg" \
  "$(issue_field comments | grep -c 'PTY/CLI integration')" "1"

# AC7 — a cancelled leg is a red night (infrastructure cut, the
# watchdog_trip_check.sh kill shape): same contract as AC6.
reset "$RED_CANCELLED_RUN" 0
heal 1953
check "AC7 cancelled night exits 0" "$?" "0"
check "AC7 cancelled night reopens the tracker" "$(issue_field state)" "OPEN"
check "AC7 cancelled night fires exactly one reopen" "$(call_count reopen)" "1"
check "AC7 reopen comment names the cancelled leg" \
  "$(issue_field comments | grep -c 'Build ios')" "1"

if [ "$fails" -gt 0 ]; then
  echo "nightly_red_tracker_selftest: FAILED"
  exit 1
fi
echo "nightly_red_tracker_selftest: all green"
