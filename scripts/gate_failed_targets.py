#!/usr/bin/env python3
"""Failed-file extractor for the fast gate's flake budget (gh-1026).

Consumes dart test ``--file-reporter=json:<log>`` output (the same reporter
the CI legs already emit) and prints the suite paths of every failed test,
one per line, sorted and deduped — the exact rerun targets for
``FA_GATE_PTY_RETRIES`` (scripts/ci_fast_gate.sh, integration-mock stage).

Two gh-2381 projections read the SAME log for the load_drop_retry wrapper:
``--unfinished`` prints the suite paths of tests that STARTED but never
reported a ``testDone`` (the engine-abandonment evidence: run 45200064457
shard 2/3 lost its queue mid-run when the resume_tail coverage gather
crashed — three tests were in flight, ten suites never loaded, and the
abandoned pty2 children wedged the VM exit handshake), and ``--loaded``
prints every path from a ``suite`` event (the never-loaded complement
source: an invocation target absent from this list AND from the console
drop signature was silently skipped). The DEFAULT projection stays
failure/error-only — the ci_fast_gate flake-budget contract is unchanged.

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


def _scan(log_path: str) -> tuple[set[str], set[str], set[str]]:
    """One pass over the log → (failed, unfinished, loaded) suite paths."""
    suites: dict[int, str] = {}
    # testID -> (suiteID, name); kept until the matching testDone lands.
    pending: dict[int, tuple[int | None, str]] = {}
    failed: set[str] = set()
    unfinished: set[str] = set()
    loaded: set[str] = set()

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
                        loaded.add(suite["path"])
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
    # Whatever never got a testDone is the abandoned in-flight set.
    for suite_id, name in pending.values():
        path = resolve(suite_id, name)
        if path:
            unfinished.add(path)
    return failed, unfinished, loaded


def failed_paths(log_path: str) -> set[str]:
    """Suite paths of the failed tests in one dart json file-reporter log."""
    return _scan(log_path)[0]


def main(argv: list[str]) -> int:
    mode = "--finished-failed"
    paths = []
    for arg in argv[1:]:
        if arg in ("--unfinished", "--loaded"):
            mode = arg
        else:
            paths.append(arg)
    if not paths:
        print(
            "usage: gate_failed_targets.py [--unfinished|--loaded] "
            "<dart-test-json-log> [...]",
            file=sys.stderr,
        )
        return 2
    failed: set[str] = set()
    for log_path in paths:
        scanned = _scan(log_path)
        failed |= scanned[0] if mode == "--finished-failed" else (
            scanned[1] if mode == "--unfinished" else scanned[2]
        )
    for path in sorted(failed):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
