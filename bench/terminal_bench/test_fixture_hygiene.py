#!/usr/bin/env python3
"""gh-1677: bench test fixtures must never masquerade as production runs.

The unit-test step runs `unittest discover` WITHOUT --buffer, so anything
a test prints lands verbatim in the CI step log next to real run
summaries. A fixture that binds a production provider string to a
run-label carrier (BENCH_RUN_LABEL env, run_label= kwarg) renders a
report byte-shaped like a real run and has already been mistaken for one
(a real kimi-for-coding run was suspected of being a glm run because the
fixture's `Provider: zai-glm-5.3-flash (glm-5.3-flash)` line was quoted
from the unit-test step's log).

Guard rules, scanned over every bench test file (all three CI discovery
roots):

1. A production provider token (zai-glm, kimi-for-coding) may never be
   bound to a run-label carrier on a non-assertion line — assigning it
   as fixture data is the sin; referencing it in an assertion about the
   resolve-step plumbing is fine.
2. The combined production run label 'zai-glm-5.3-flash (glm-5.3-flash)'
   may appear only on assertion lines (the resolve-mapping contract).

Out of scope by design: model-id fixtures that must reference a
bench/pricing.json key (pricing/usage math tests) and the resolve-step
tests' provider-name INPUTS — those exercise the real provider mapping,
not a rendered run identity.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import unittest
from pathlib import Path

_BENCH_DIR = Path(__file__).resolve().parent.parent
_DISCOVERY_ROOTS = ("terminal_bench", "harbor_fa", "mls_bench")

_PRODUCTION_TOKENS = ("zai-glm", "kimi-for-coding")
_RUN_LABEL_CARRIERS = ("BENCH_RUN_LABEL", "run_label")
_COMBINED_RUN_LABEL = "zai-glm-5.3-flash (glm-5.3-flash)"


def _test_files():
    files = []
    for root in _DISCOVERY_ROOTS:
        files.extend(sorted((_BENCH_DIR / root).glob("test_*.py")))
    # The guard file itself carries the banned strings as its rules'
    # data — never a fixture.
    return [p for p in files if p.resolve() != Path(__file__).resolve()]


def _violations(path: Path) -> list:
    """(lineno, line, rule) for every fixture-as-production binding."""
    hits = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if "assert" in line:
            # Assertions ABOUT the plumbing may reference the real
            # strings; only assignments as fixture data are banned.
            continue
        if _COMBINED_RUN_LABEL in line:
            hits.append(
                (lineno, line, "combined production run label outside an assertion")
            )
            continue
        carriers = [c for c in _RUN_LABEL_CARRIERS if c in line]
        tokens = [t for t in _PRODUCTION_TOKENS if t in line]
        if carriers and tokens:
            hits.append(
                (
                    lineno,
                    line,
                    "production provider string bound to a run-label carrier as fixture data",
                )
            )
    return hits


class FixtureHygieneGuardTest(unittest.TestCase):
    """gh-1677: no bench fixture may render as a production run identity."""

    def test_no_fixture_binds_a_production_provider_string(self):
        failures = []
        for path in _test_files():
            for lineno, line, rule in _violations(path):
                failures.append(f"{path.name}:{lineno}: {rule}: {line.strip()}")
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
