#!/usr/bin/env bash
# duration_budget_selftest.sh — fixture self-test for the gh-1300 shard
# duration-budget gate (check_shard_durations.py).
#
# Proves, on fabricated dart-json reports (no CI, no real shards):
#   AC1 a breaching shard FAILS the gate (exit 1) and the issue body
#       carries measured-vs-budget numbers + the slowest-tests table;
#   AC2 a fitting shard passes (exit 0) and writes no issue body;
#   AC3 the warn band (>= warn_fraction of budget) passes but warns
#       loudly in the summary;
#   AC4 an unbudgeted shard is a loud failure (a new shard cannot sneak
#       past the ratchet);
#   AC5 --update-budgets is down-only: it lowers and adds, refuses to
#       raise.
# Same discipline as check_lockfiles_selftest.sh (#1100 pattern): the
# gate's own red exits are fixture-tested so the check cannot rot
# silently.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/check_shard_durations.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # check <desc> <condition-exit-code: 0 = pass>
  if [ "$2" = "0" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    fails=$((fails + 1))
  fi
}
check_fail() { # check_fail <desc> <exit-code: non-zero = pass>
  if [ "$2" != "0" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    fails=$((fails + 1))
  fi
}

# ── fixture: one dart-json shard report with two sequential tests ────────
# 90 s wall (100 ms → 90_100 ms): "slow case" 60 s + "quick case" 30 s.
make_report() { # make_report <path>
  cat >"$1" <<'EOF'
{"type":"suite","suite":{"id":1,"path":"test/integration/slow_suite_test.dart","platform":"vm"}}
{"type":"suite","suite":{"id":2,"path":"test/integration/quick_suite_test.dart","platform":"vm"}}
{"type":"testStart","test":{"id":10,"name":"slow case","suiteID":1},"time":100}
{"type":"testDone","testID":10,"result":"success","hidden":false,"time":60100}
{"type":"testStart","test":{"id":11,"name":"quick case","suiteID":2},"time":60100}
{"type":"testDone","testID":11,"result":"success","hidden":false,"time":90100}
EOF
}

python3 - "$GATE" <<'EOF' || { echo "FAIL: $GATE missing"; exit 1; }
import os, sys
sys.exit(0 if os.path.isfile(sys.argv[1]) else 1)
EOF
[ $? = 0 ] || { echo "gate script missing — self-test cannot run"; exit 1; }

budgets0="$TMP/budgets0.json"
echo '{"_meta": {"law": "down-only"}, "warn_fraction": 0.9, "shards": {"0": 60.0}}' >"$budgets0"

# ── AC1: breach (wall 90 s vs budget 60 s) fails and files the body ──────
make_report "$TMP/integration-shard-0.json"
out="$TMP/summary-a.txt"
body="$TMP/issue-a.md"
python3 "$GATE" --budgets "$budgets0" --issue-body "$body" --run-url \
  "https://ci.example/run/1" "$TMP/integration-shard-0.json" >"$out" 2>&1
check_fail "AC1 breach exits 1" "$?"
grep -q "FAIL" "$out"
check "AC1 summary carries a FAIL line" "$?"
grep -q "| 0 | 90.0 |" "$out"
check "AC1 summary carries the measured wall" "$?"
test -f "$body"
check "AC1 issue body written on breach" "$?"
grep -q "90.0" "$body" && grep -q "60.0" "$body"
check "AC1 body carries measured-vs-budget numbers" "$?"
grep -q "slowest" "$body"
check "AC1 body carries the slowest-tests table" "$?"
grep -q "\[ENH\]" "$body"
check "AC1 body names the [ENH] optimization issue" "$?"
grep -q "https://ci.example/run/1" "$body"
check "AC1 body carries the run link" "$?"
grep -qE "slow case|quick case" "$body"
check "AC1 body lists the actual slow tests" "$?"

# ── AC2: fit (same report vs budget 300 s) passes, no body ───────────────
make_report "$TMP/integration-shard-1.json"
budgets1="$TMP/budgets1.json"
echo '{"_meta": {}, "warn_fraction": 0.9, "shards": {"1": 300.0}}' >"$budgets1"
out="$TMP/summary-b.txt"
body="$TMP/issue-b.md"
python3 "$GATE" --budgets "$budgets1" --issue-body "$body" \
  "$TMP/integration-shard-1.json" >"$out" 2>&1
check "AC2 fit exits 0" "$?"
grep -q "RESULT: OK" "$out"
check "AC2 summary says OK" "$?"
test ! -f "$body"
check "AC2 no issue body on a green run" "$?"

# ── AC3: warn band (wall 90 s vs budget 100 s) passes but warns ──────────
make_report "$TMP/integration-shard-2.json"
budgets2="$TMP/budgets2w.json"
echo '{"_meta": {}, "warn_fraction": 0.9, "shards": {"2": 100.0}}' >"$budgets2"
out="$TMP/summary-c.txt"
python3 "$GATE" --budgets "$budgets2" "$TMP/integration-shard-2.json" \
  >"$out" 2>&1
check "AC3 warn-band run exits 0" "$?"
grep -q "WARN" "$out"
check "AC3 warn-band summary carries a WARN line" "$?"

# ── AC4: an unbudgeted shard fails loudly ────────────────────────────────
make_report "$TMP/integration-shard-9.json"
budgets9="$TMP/budgets9.json"
echo '{"_meta": {}, "warn_fraction": 0.9, "shards": {}}' >"$budgets9"
out="$TMP/summary-d.txt"
python3 "$GATE" --budgets "$budgets9" "$TMP/integration-shard-9.json" \
  >"$out" 2>&1
check_fail "AC4 unbudgeted shard exits 1" "$?"
grep -q "has no budget" "$out"
check "AC4 summary names the missing budget" "$?"

# ── AC5: --update-budgets is down-only ───────────────────────────────────
# AC5a: an unbudgeted shard is ADDED at measured x 1.2.
echo '{"_meta": {}, "warn_fraction": 0.9, "shards": {}}' >"$TMP/b3.json"
python3 "$GATE" --budgets "$TMP/b3.json" --update-budgets \
  "$TMP/integration-shard-0.json" >"$TMP/update-a.txt" 2>&1
check "AC5a update with no prior entry succeeds" "$?"
python3 - "$TMP/b3.json" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))
sys.exit(0 if abs(b["shards"]["0"] - 108.0) < 0.01 else 1)
EOF
check "AC5a new shard budgeted at measured x 1.2 (108.0)" "$?"

# AC5b: a measured value BELOW the budget LOWERS it (the ratchet law).
echo '{"_meta": {}, "warn_fraction": 0.9, "shards": {"0": 120.0}}' >"$TMP/b4.json"
python3 "$GATE" --budgets "$TMP/b4.json" --update-budgets \
  "$TMP/integration-shard-0.json" >"$TMP/update-b.txt" 2>&1
check "AC5b lowering update succeeds" "$?"
python3 - "$TMP/b4.json" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))
sys.exit(0 if abs(b["shards"]["0"] - 90.0) < 0.01 else 1)
EOF
check "AC5b budget lowered to the measured wall (90.0)" "$?"

# AC5c: a measured value ABOVE the budget is REFUSED — raising requires a
# hand-edited reviewed PR.
echo '{"_meta": {}, "warn_fraction": 0.9, "shards": {"0": 60.0}}' >"$TMP/b5.json"
python3 "$GATE" --budgets "$TMP/b5.json" --update-budgets \
  "$TMP/integration-shard-0.json" >"$TMP/update-c.txt" 2>&1
check "AC5c update that would RAISE is refused (exit 1)" "$?"
grep -q "REFUSED" "$TMP/update-c.txt"
check "AC5c refusal is named" "$?"
python3 - "$TMP/b5.json" <<'EOF'
import json, sys
b = json.load(open(sys.argv[1]))
sys.exit(0 if abs(b["shards"]["0"] - 60.0) < 0.01 else 1)
EOF
check "AC5c raised entry left untouched" "$?"

echo
if [ "$fails" = "0" ]; then
  echo "PASS: duration budget gate self-test"
  exit 0
fi
echo "FAIL: $fails assertion(s) failed"
exit 1
