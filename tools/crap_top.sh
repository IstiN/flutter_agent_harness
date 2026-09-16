#!/usr/bin/env bash
# Issue #490 AC3 hygiene: download the latest crap_report.json artifact
# (published by the app-crap-gate CI job) and print a top-N CRAP table.
# Usage: tools/crap_top.sh [N]   (N defaults to 40)
# Requires: gh CLI authenticated for IstiN/flutter_agent_harness.
set -euo pipefail

REPO="${FA_REPO:-IstiN/flutter_agent_harness}"
TOP="${1:-40}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Walk recent ci.yml runs, any conclusion — a red ratchet still publishes
# the artifact (issue #490: the report is written before the non-zero exit).
for id in $(gh run list -R "$REPO" -w ci.yml -L 30 --json databaseId --jq '.[].databaseId'); do
  if gh run download "$id" -R "$REPO" -n crap_report -D "$tmp" 2>/dev/null; then
    echo "# crap_report.json from run $id"
    echo "# https://github.com/$REPO/actions/runs/$id"
    python3 - "$tmp/crap_report.json" "$TOP" <<'PY'
import json, sys

report = json.load(open(sys.argv[1]))
top = int(sys.argv[2])
print(f"# threshold={report['threshold']} maxCrap={report['maxCrap']} passed={report['passed']}")
rows = [m for m in report["methods"] if m.get("crap") is not None][:top]
width = max((len(f'{m["file"]}:{m["line"]}') for m in rows), default=0)
for i, m in enumerate(rows, 1):
    loc = f'{m["file"]}:{m["line"]}'.ljust(width)
    cov = m.get("lineCoverage")
    cov = f"{cov * 100:.0f}%" if cov is not None else "N/A"
    print(f'{i:>3}  {m["crap"]:>9.2f}  {cov:>5}  cx{m["complexity"]:<4} {loc}  {m["class"]}.{m["method"]}')
PY
    exit 0
  fi
done
echo "no crap_report artifact in the last 30 ci.yml runs" >&2
exit 1
