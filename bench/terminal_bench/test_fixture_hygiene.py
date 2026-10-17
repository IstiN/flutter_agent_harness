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


class GuardRuleTest(unittest.TestCase):
    """The guard's own heuristics, pinned against synthetic corpora."""

    def _scan(self, text):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "test_fake.py"
        path.write_text(text)
        return _violations(path)

    def test_run_identity_key_flags_a_production_model(self):
        # Review thread 2: a run-config fixture's identity key
        # ("model"/"provider") replays verbatim into the CI-visible
        # report — a production value there is the same masquerade sin
        # on a carrier the run-label rules cannot see.
        hits = self._scan('RUN_CONFIG = {"model": "glm-5.3-flash"}\n')
        self.assertEqual(len(hits), 1)

    def test_contract_payload_stays_exempt(self):
        # A provider-config JSON payload (apiKeyEnvVar/baseUrl) or an
        # assistant usage-record ("role"/"usage") exercises the real
        # mapping/pricing contract, not a rendered run identity.
        text = (
            'CFG = \'{"baseUrl":"https://x","model":"glm-5.3-flash",'
            '"apiKeyEnvVar":"K"}\'\n'
            'REC = {"message": {"role": "assistant", "model": '
            '"glm-5.3-flash", "usage": {}}}\n'
        )
        self.assertEqual(self._scan(text), [])

    def test_intermediate_constant_is_caught(self):
        # Review thread 3: the same-line heuristic is evadable via
        # indirection — a bare production token assigned to ANY
        # identifier is a fixture binding regardless of later use.
        hits = self._scan('_PROVIDER = "zai-glm-4.5"\n')
        self.assertEqual(len(hits), 1)

    def test_assert_word_in_trailing_comment_does_not_launder(self):
        # The old "assert" substring exemption skipped a fixture line
        # whose TRAILING COMMENT merely mentioned "assert".
        hits = self._scan(
            "label = fixture()  # assert 'zai-glm-5.3-flash (glm-5.3-flash)' renders\n"
        )
        self.assertEqual(len(hits), 1)


if __name__ == "__main__":
    unittest.main()
