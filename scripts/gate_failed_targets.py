#!/usr/bin/env python3
"""Failed-file extractor for the fast gate's flake budget (gh-1026).

Consumes dart test ``--file-reporter=json:<log>`` output (the same reporter
the CI legs already emit) and prints the suite paths of every failed test,
one per line, sorted and deduped — the exact rerun targets for
``FA_GATE_PTY_RETRIES`` (scripts/ci_fast_gate.sh, integration-mock stage).

Design notes:
- ``result`` ``failure`` AND ``error`` both count; ``success``/``skip`` do
  not. Hidden tests count too — a suite that fails to load reports its
  failure on a hidden ``loading <path>`` test, and that path is exactly
  what a rerun needs.
- A load failure can arrive without a ``suite`` event for the path; in
  that case the path falls back to the loading test's name (``loading
  <path>``).
- A missing or unparsable log is a CLEAN EMPTY result (exit 0, no
  output): the gate never reruns blind — rerunning everything is the
  2.5-hour lottery this budget exists to avoid. The caller treats empty
  output as "cannot rerun, fail the stage".
"""

from __future__ import annotations

import json
import sys

FAILURE_RESULTS = {"failure", "error"}


def failed_paths(log_path: str) -> set[str]:
    """Suite paths of the failed tests in one dart json file-reporter log."""
    suites: dict[int, str] = {}
    # testID -> (suiteID, name); kept until the matching testDone lands.
    pending: dict[int, tuple[int | None, str]] = {}
    failed: set[str] = set()

    def resolve(suite_id: int | None, name: str) -> str | None:
        if suite_id is not None and suite_id in suites:
            return suites[suite_id]
        # No suite event (load failure): the loading test's name carries
        # the path — "loading <path>".
        if name.startswith("loading "):
            return name[len("loading "):]
        return None

    try:
        with open(log_path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue  # torn tail line — the reporter's own output is line-complete
                kind = event.get("type")
                if kind == "suite":
                    suite = event.get("suite") or {}
                    if suite.get("path"):
                        suites[suite.get("id")] = suite["path"]
                elif kind == "testStart":
                    test = event.get("test") or {}
                    if "id" in test:
                        pending[test["id"]] = (
                            test.get("suiteID"),
                            test.get("name") or "",
                        )
                elif kind == "testDone":
                    if event.get("result") not in FAILURE_RESULTS:
                        pending.pop(event.get("testID"), None)
                        continue
                    entry = pending.pop(event.get("testID"), None)
                    if entry is None:
                        continue
                    path = resolve(entry[0], entry[1])
                    if path:
                        failed.add(path)
    except OSError as exc:
        print(f"gate_failed_targets: cannot read {log_path}: {exc}",
              file=sys.stderr)
    return failed


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            "usage: gate_failed_targets.py <dart-test-json-log> [...]",
            file=sys.stderr,
        )
        return 2
    failed: set[str] = set()
    for log_path in argv[1:]:
        failed |= failed_paths(log_path)
    for path in sorted(failed):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
