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
3. A production run identity — a provider token (zai-glm,
   kimi-for-coding) or a production model token (glm-5.3) — may never
   sit in a run-config fixture's identity key ("model", "provider") on
   a non-assertion line: those keys replay verbatim into the
   CI-visible report. Exempt: the same line carrying a contract
   payload — provider-config JSON (apiKeyEnvVar/baseUrl) or an
   assistant usage record ("role"/"usage") — which exercises the real
   mapping/pricing contract, not a rendered run identity.
4. A bare production provider token assigned to ANY identifier on a
   non-assertion line is flagged: the same-line carrier heuristic is
   otherwise evadable via an intermediate constant
   (_LABEL = "zai-glm-..."; os.environ["BENCH_RUN_LABEL"] = _LABEL).

Assertion exemption: only lines STARTING with an assert statement are
exempt — a trailing comment merely mentioning "assert" must not
launder a fixture line.

Out of scope by design: model-id fixtures that must reference a
bench/pricing.json key (pricing/usage math tests) and the resolve-step
tests' provider-name INPUTS — those exercise the real provider mapping,
not a rendered run identity.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import re
import tempfile
import unittest
from pathlib import Path

_BENCH_DIR = Path(__file__).resolve().parent.parent
_DISCOVERY_ROOTS = ("terminal_bench", "harbor_fa", "mls_bench")

_PRODUCTION_TOKENS = ("zai-glm", "kimi-for-coding")
_PRODUCTION_MODEL_TOKENS = ("glm-5.3",)
_RUN_LABEL_CARRIERS = ("BENCH_RUN_LABEL", "run_label")
# gh-1677 review round 2: run-identity keys of a run-config fixture
# (the mls RUN_CONFIG dict) — replayed verbatim into the CI-visible
# report, so a production value there is the masquerade sin on a
# carrier the run-label rules cannot see.
_RUN_IDENTITY_KEYS = ('"model"', '"provider"')
_COMBINED_RUN_LABEL = "zai-glm-5.3-flash (glm-5.3-flash)"
# A line carrying one of these markers is a contract payload
# (provider-config JSON / assistant usage record), not a rendered run
# identity — the resolve-step inputs and pricing.json-key fixtures the
# docstring documents as out of scope.
_CONTRACT_FIXTURE_MARKERS = ("apiKeyEnvVar", "baseUrl", '"role"', '"usage"')
_ASSERT_PREFIXES = ("assert", "self.assert", "with self.assert")


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
        if stripped.startswith(_ASSERT_PREFIXES):
            # Assertions ABOUT the plumbing may reference the real
            # strings; only assignments as fixture data are banned.
            # startswith, not substring: a trailing comment merely
            # mentioning "assert" must not launder a fixture line.
            continue
        if _COMBINED_RUN_LABEL in line:
            hits.append(
                (lineno, line, "combined production run label outside an assertion")
            )
            continue
        providers = [t for t in _PRODUCTION_TOKENS if t in line]
        models = [t for t in _PRODUCTION_MODEL_TOKENS if t in line]
        carriers = [c for c in _RUN_LABEL_CARRIERS if c in line]
        if carriers and providers:
            hits.append(
                (
                    lineno,
                    line,
                    "production provider string bound to a run-label carrier as fixture data",
                )
            )
            continue
        if any(k in line for k in _RUN_IDENTITY_KEYS) and (providers or models):
            if not any(m in line for m in _CONTRACT_FIXTURE_MARKERS):
                hits.append(
                    (
                        lineno,
                        line,
                        "production run identity in a run-config fixture",
                    )
                )
                continue
        assign = re.match(
            r"^[A-Za-z_][A-Za-z0-9_]*\s*=\s*(?P<q>[\"'])(?P<val>.*?)(?P=q)", stripped
        )
        if providers and assign:
            hits.append(
                (
                    lineno,
                    line,
                    "production provider string assigned to a constant",
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
