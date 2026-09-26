#!/usr/bin/env python3
"""Convert a dart test JSON report to JUnit XML (issue #194, AC3).

`dart test` has no built-in junit reporter, so CI emits the built-in
`json:` file-reporter per shard and this converts it:

    dart test --file-reporter="json:test-results/dart-shard-0.json" ...
    python3 scripts/junit_from_dart_json.py \
        test-results/dart-shard-0.json test-results/junit-shard-0.xml

The resulting junit-shard-N.xml artifacts are what
.github/workflows/shard-rebalance.yml consumes for duration-based shard
rebalancing (scripts/rebalance_shards.py --from-junit): `classname` is the
suite path, which is what the rebalancer matches units by. Since issue
#928 the SAME span walk (iter_test_spans) also feeds the duration budget
gate — one parser, both formats, no drift.

Only real tests are emitted: groups arrive as "group" events (never
testStart), and the "loading <file>" pseudo-test is filtered by its hidden
testDone — so group durations never double-count their children.
Durations are seconds (dart reports ms since runner start; paired
testStart/testDone give each test's real span).

Pure stdlib.
"""

import json
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape


def iter_test_spans(json_path):
    """Yield (suite_path, test_name, duration_seconds, failed) per test.

    The canonical dart-json span walk: paired testStart/testDone, hidden
    pseudo-tests excluded, torn/partial lines skipped (never fatal for
    timing data). Consumed by this converter AND
    scripts/check_test_durations.py.
    """
    suites = {}  # suiteID -> test file path
    starts = {}  # testID -> (name, suite path, start ms)
    with open(json_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue  # torn/partial line — never fatal for timing data
            kind = ev.get("type")
            if kind == "suite":
                suites[ev["suite"]["id"]] = ev["suite"].get("path", "")
            elif kind == "testStart":
                starts[ev["test"]["id"]] = (
                    ev["test"].get("name", ""),
                    suites.get(ev["test"]["suiteID"], ""),
                    ev["time"],
                )
            elif kind == "testDone":
                tid = ev["testID"]
                if tid in starts and not ev.get("hidden", False):
                    name, path, t0 = starts.pop(tid)
                    dur = max((ev["time"] - t0) / 1000.0, 0.0)
                    failed = ev.get("result") in ("failure", "error")
                    yield path, name, dur, failed


def convert(json_path: str, xml_path: str) -> int:
    cases = list(iter_test_spans(json_path))
    suite = ET.Element("testsuite", {
        "name": json_path,
        "tests": str(len(cases)),
    })
    for path, name, dur, failed in cases:
        tc = ET.SubElement(suite, "testcase",
                           {"name": escape(name), "classname": path,
                            "time": f"{dur:.3f}"})
        if failed:
            ET.SubElement(tc, "failure")
    tree = ET.ElementTree(suite)
    tree.write(xml_path, encoding="utf-8", xml_declaration=True)
    print(f"{xml_path}: {len(cases)} testcases")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        raise SystemExit(2)
    sys.exit(convert(sys.argv[1], sys.argv[2]))
