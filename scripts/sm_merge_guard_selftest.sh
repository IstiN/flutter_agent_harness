#!/usr/bin/env bash
# sm_merge_guard_selftest.sh — fixture self-test for the gh-1537 AC5 SM
# merge guard (sm_merge_guard.py), gh-1568.
#
# Proves, on a PATH-stubbed gh (no network, no real runs):
#   AC1 (the gh-1568 regression) a merge-commit landing whose tree equals
#       a successful dispatch's commit tree VALIDATES — with the commits
#       API served in its REAL shape (tree nested under `commit`, no
#       top-level `tree` key). The shipped `.tree.sha` jq path resolved
#       empty for every run, so every merge-commit landing false-alarmed
#       (issue #1568: merges 392fe540ae of #1484 and afed64bfd0 of #1468
#       both carried trees byte-identical to their green validations).
#   AC2 an UNCOVERED tree still alarms (exit 3) — the fix must not mute
#       the invariant.
#   AC3 a fast-forward landing (pushed sha == validated head sha)
#       validates with no tree lookup at all.
#   AC4 the race: a validation still in_progress at push time can never
#       certify — alarm (the SM merges strictly after green, so
#       in_progress-at-push means the merge beat the validation).
#   AC5 a failed tree lookup (commit API 404) degrades to a warning and
#       alarms — never a false validate, never a traceback.
#   AC6 the alarm body renders each considered run's resolved tree, so
#       future alarms are self-diagnosing, and files with the
#       bug+sm-guard labels (dedup convention untouched).
# Same discipline as check_lockfiles_selftest.sh (#1100 pattern).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/sm_merge_guard.py"
TMP="$(mktemp -d)"
trap '[ "${KEEP:-0}" = 1 ] || rm -rf "$TMP"' EXIT

fails=0
check() { # check <desc> <condition-exit-code: 0 = pass>
  if [ "$2" = "0" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    fails=$((fails + 1))
  fi
}
check_absent() { # check_absent <desc> <grep-exit-code: 1 = pass>
  if [ "$2" != "0" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1"
    fails=$((fails + 1))
  fi
}
# Via the interpreter, not the shebang: checkouts may drop the exec bit
# (same as test/scripts/sm_merge_guard_test.dart's Process.run('python3')).
run_guard() { python3 "$GUARD" "$@"; }

# The real shas from the #1568 false alarm (merge of #1484):
PUSHED_SHA=392fe540ae739931bdc348b607f3a02533b9dd9b
PUSHED_TREE=0fd92616c897199580c030675dd7854758ea9879
HEAD_SHA=06898ec2b58c5a22696b7b2e2f147d6fab976c5a
SUBJECT="ci(quarantine): un-quarantine wire_serve_cli_test.dart (#1484)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Canned gh: case-dispatch on argv. The commits fixture uses the REAL
# response shape — `commit.tree.sha`, deliberately WITHOUT a top-level
# `tree` key (that absence is exactly what broke `.tree.sha`).
mkdir -p "$TMP/bin" "$TMP/stub"
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
set -u
case "\$*" in
  *"run list"*) cat "$TMP/stub/runs.json" ;;
  *"issue list"*) echo "" ;; # post-jq: .[0].number // empty on no match
  *"issue create"*)
    printf '%s\n' "\$*" > "$TMP/stub/create_args.log"
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "--body" ] && printf '%s' "\$a" > "$TMP/stub/created_body.md"
      prev="\$a"
    done
    echo "https://github.com/acme/widget/issues/99" ;;
  *"repos/"*"/commits/"*)
    sha="\$(printf '%s' "\$2" | sed 's|.*/||')"
    if [ -f "$TMP/stub/commit-\$sha.json" ]; then
      # Real gh applies --jq before printing; emulate the one filter
      # the guard uses (the whole point of the gh-1568 regression is
      # that the filter runs against the REAL response shape).
      cat "$TMP/stub/commit-\$sha.json" | python3 -c '
import json, sys
print(json.load(sys.stdin)["commit"]["tree"]["sha"])'
    else
      echo "gh: HTTP 404: no commit \$sha" >&2
      exit 1
    fi ;;
  *) echo "stub gh: unexpected call: \$*" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# One successful dispatch on HEAD_SHA, recently inside the 24h window.
cat > "$TMP/stub/runs.json" <<JSON
[{"databaseId": 38260860862, "headSha": "$HEAD_SHA",
  "conclusion": "success", "createdAt": "$NOW"}]
JSON
# Real commits-API shape: tree ONLY under `commit`.
cat > "$TMP/stub/commit-$HEAD_SHA.json" <<JSON
{"sha": "$HEAD_SHA",
 "commit": {"tree": {"sha": "$PUSHED_TREE"}},
 "parents": [{"sha": "4b7a740d990636c6db769eb3ec83b58bee1a4c06"},
             {"sha": "6d7e0d268b02aee7e4961f14d09359fd5b1427d3"}]}
JSON

# AC1 — gh-1568 regression: merge-commit landing, identical tree → ok.
out="$(run_guard --repo acme/widget --sha "$PUSHED_SHA" \
  --subject "$SUBJECT" --tree "$PUSHED_TREE" 2>&1)"
check "AC1 merge-commit landing with identical tree validates (exit 0)" $?
printf '%s\n' "$out" > "$TMP/ac1.log"
grep -q "tree match: run 38260860862" "$TMP/ac1.log"
check "AC1 verdict cites the covering run by tree match" $?
grep -q "Traceback" "$TMP/ac1.log"
check_absent "AC1 no traceback" $?

# AC2 — genuinely uncovered tree → alarm.
run_guard --repo acme/widget --sha "$PUSHED_SHA" \
  --subject "$SUBJECT" --tree 1111111111111111111111111111111111111111 \
  >"$TMP/ac2.log" 2>&1
[ "$?" -eq 3 ]
check "AC2 uncovered tree alarms (exit 3)" $?
grep -q "no successful ci.yml workflow_dispatch run covers" "$TMP/ac2.log"
check "AC2 alarm reason names the uncovered tree" $?

# AC3 — fast-forward: pushed sha == validated head sha, no commit
# fixture (tree lookup 404s and must not matter).
rm "$TMP/stub/commit-$HEAD_SHA.json"
out="$(run_guard --repo acme/widget --sha "$HEAD_SHA" \
  --subject "$SUBJECT" --tree "$PUSHED_TREE" 2>&1)"
check "AC3 fast-forward landing validates (exit 0)" $?
printf '%s\n' "$out" > "$TMP/ac3.log"
grep -q "exact head-SHA match" "$TMP/ac3.log"
check "AC3 verdict cites the head-SHA match" $?

# AC4 — race: in_progress validation can never certify (decide seam;
# fetch_validated_runs filters the same way on conclusion).
cat > "$TMP/stub/inflight.json" <<JSON
[{"databaseId": 1, "headSha": "$HEAD_SHA", "conclusion": null,
  "tree_sha": "$PUSHED_TREE", "created_at": "$NOW"}]
JSON
run_guard --sha "$PUSHED_SHA" --subject "$SUBJECT" --tree "$PUSHED_TREE" \
  --runs-json "$TMP/stub/inflight.json" >"$TMP/ac4.log" 2>&1
[ "$?" -eq 3 ]
check "AC4 in_progress validation does not certify (exit 3)" $?

# AC5 — tree lookup failure: warning + alarm, never a false validate.
cat > "$TMP/stub/runs.json" <<JSON
[{"databaseId": 42, "headSha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
  "conclusion": "success", "createdAt": "$NOW"}]
JSON
run_guard --repo acme/widget --sha "$PUSHED_SHA" \
  --subject "$SUBJECT" --tree "$PUSHED_TREE" >"$TMP/ac5.log" 2>&1
[ "$?" -eq 3 ]
check "AC5 failed tree lookup still alarms (exit 3)" $?
grep -q "::warning::" "$TMP/ac5.log"
check "AC5 lookup failure surfaces as a warning" $?
grep -q "tree match" "$TMP/ac5.log"
check_absent "AC5 no tree match claimed despite lookup failure" $?

# AC6 — alarm body: considered runs carry resolved trees; bug+sm-guard
# labels; dedup issue conventions untouched.
cat > "$TMP/stub/runs.json" <<JSON
[{"databaseId": 38260860862, "headSha": "$HEAD_SHA",
  "conclusion": "success", "createdAt": "$NOW"}]
JSON
cat > "$TMP/stub/commit-$HEAD_SHA.json" <<JSON
{"sha": "$HEAD_SHA",
 "commit": {"tree": {"sha": "$PUSHED_TREE"}},
 "parents": []}
JSON
run_guard --repo acme/widget --sha "$PUSHED_SHA" --subject "$SUBJECT" \
  --tree 1111111111111111111111111111111111111111 \
  --alarm-issue >"$TMP/ac6.log" 2>&1
grep -q "tree \`$PUSHED_TREE\`" "$TMP/stub/created_body.md"
check "AC6 alarm body renders considered run's resolved tree" $?
grep -q "392fe540ae73" "$TMP/stub/created_body.md"
check "AC6 alarm body names the pushed sha" $?
grep -q "Guard verdict" "$TMP/stub/created_body.md"
check "AC6 alarm body keeps the verdict section" $?
grep -q -- "--label sm-guard" "$TMP/stub/create_args.log"
check "AC6 files with the sm-guard label" $?
grep -q -- "--label bug" "$TMP/stub/create_args.log"
check "AC6 files with the bug label" $?

echo
if [ "$fails" -eq 0 ]; then
  echo "sm_merge_guard_selftest: all checks passed"
  exit 0
fi
echo "sm_merge_guard_selftest: $fails check(s) FAILED"
exit 1
