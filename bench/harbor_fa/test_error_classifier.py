#!/usr/bin/env python3
"""gh-1592 REGs for the FaAgent ERROR_PATTERNS override (bench/harbor_fa).

Run: python3 -m unittest discover -s bench/harbor_fa

Incident (run 38271607849, shard fa-2.1-docker-cpu-5, trial
gpt2-codegolf__pKKQfqj): after the 900s timeout ladder kill, harbor's
failed-command classifier scanned the launch exec's tee'd output with
``ErrorPattern(r"rate.?limit", ApiRateLimitError)`` — an UNANCHORED
substring regex. fa's own output legitimately contains the words
"rate limit" (echoed provider-error text, fa's ``[roles] rate limited
on … — retrying`` notices), so the failed exec surfaced as
ApiRateLimitError (``Classified failed command as ApiRateLimitError
(pattern: 'rate.?limit')``) even though no provider 429 existed.

The fix (gh-1592) is the FaAgent ERROR_PATTERNS override in fa_agent.py:
the inherited harbor table minus the two unanchored ApiRateLimitError
entries, replaced with line-anchored equivalents that require the
structured provider-error context — ``429`` and the wording on the SAME
line (fa renders real provider errors as ``429: <message>``,
``HTTP/1.1 429 …``, or single-line JSON ``"code": 429 …``).

Two suites live here:

- AnchoredPatternSemanticsTest — stdlib-only: pins the anchored
  patterns' semantics against teardown-style and real-429 outputs by
  compiling FaAgent.ERROR_PATTERNS the way harbor does. Runs with or
  without the real harbor package.
- RealClassifierRegressionTest — needs the real harbor 0.23.0 (as
  installed by bench-harbor.yml before `unittest discover`): drives the
  REAL ``_classify_exec_error`` end to end.
"""
import importlib
import importlib.machinery
import importlib.util
import dataclasses
import re
import sys
import tempfile
import unittest
from pathlib import Path

_REPO_BENCH = Path(__file__).resolve().parent.parent
_REPO_ROOT = _REPO_BENCH.parent

# The harbor stub some sibling test modules install poisons sys.modules;
# gh-1592 needs the REAL error-pattern surface when the package is
# available (bench-harbor.yml installs harbor[modal]==0.23.0 before the
# discover step). Evict and re-import so this module always sees either
# the real classes or nothing.
for _name in [
    n for n in sys.modules if n == "harbor" or n.startswith("harbor.")
]:
    del sys.modules[_name]
try:
    harbor_base = importlib.import_module("harbor.agents.installed.base")
    REAL_HARBOR_BASE = harbor_base
except ImportError:
    REAL_HARBOR_BASE = None

# The anchored-only stdlib suite still needs fa_agent importable when the
# real harbor is absent: install a minimal harbor stub surface covering
# EVERY module fa_agent.py imports — `harbor.agents.installed.base`,
# `harbor.environments.base` AND `harbor.models.agent.context` (gh-1592
# review thread 1: stubbing only `harbor.agents.*` let the harbor-less
# run die with `ModuleNotFoundError: No module named
# 'harbor.environments'` at fa_agent import). Same shape as
# test_fa_agent._install_harbor_stubs(), without importing that module —
# unittest discovery orders modules alphabetically and this file may
# load first.
if REAL_HARBOR_BASE is None:
    def _module(name):
        mod = importlib.util.module_from_spec(
            importlib.machinery.ModuleSpec(name, None)
        )
        mod.__fa_harbor_stub__ = True
        sys.modules[name] = mod
        return mod

    harbor = _module("harbor")
    harbor.__path__ = []
    agents = _module("harbor.agents")
    harbor.agents = agents
    agents.__path__ = []
    installed = _module("harbor.agents.installed")
    agents.installed = installed
    installed.__path__ = []
    installed_base = _module("harbor.agents.installed.base")
    agents.installed.base = installed_base

    @dataclasses.dataclass
    class _StubErrorPattern:
        pattern: str
        exception: type

    class ApiRateLimitError(RuntimeError):
        pass

    class _StubBaseInstalledAgent:
        # Seed the INHERITED broad pair exactly as harbor 0.23.0 ships
        # it (gh-1592 review thread 1): FaAgent's override filters this
        # table, and test_override_replaces_unanchored_rate_limit_patterns
        # asserts the anchored entries replace the inherited ones
        # one-for-one — an empty stub table degenerates that assertion
        # to `2 == 0`.
        ERROR_PATTERNS = [
            _StubErrorPattern(r"rate.?limit", ApiRateLimitError),
            _StubErrorPattern(r"too many requests", ApiRateLimitError),
        ]

    installed_base.BaseInstalledAgent = _StubBaseInstalledAgent
    installed_base.ErrorPattern = _StubErrorPattern
    installed_base.ApiRateLimitError = ApiRateLimitError

    environments = _module("harbor.environments")
    harbor.environments = environments
    environments.__path__ = []
    env_base = _module("harbor.environments.base")
    environments.base = env_base

    class _StubBaseEnvironment:
        pass

    env_base.BaseEnvironment = _StubBaseEnvironment

    models = _module("harbor.models")
    harbor.models = models
    models.__path__ = []
    models_agent = _module("harbor.models.agent")
    models.agent = models_agent
    models_agent.__path__ = []
    context = _module("harbor.models.agent.context")
    models_agent.context = context
    context.AgentContext = dict


def _load_fa_agent():
    spec = importlib.util.spec_from_file_location(
        "fa_agent_gh1592", Path(__file__).resolve().parent / "fa_agent.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["fa_agent_gh1592"] = module
    spec.loader.exec_module(module)
    return module


fa_agent = _load_fa_agent()


# ---------------------------------------------------------------------------
# Fixtures. No stray standalone "429" tokens outside the intended provider
# error lines — the anchor is a 429 token free of adjacent digits/dots on
# the same line (see DECIMAL_ADJACENT_429_OUTPUTS for the guarded class).
# ---------------------------------------------------------------------------

# The incident shape: a timeout-killed launch exec whose tee'd output
# mentions rate limits in unrelated contexts (fa's own roles notice, an
# echoed provider 502 body quoting rate-limit guidance, a teardown grep).
TEARDOWN_OUTPUT = "\n".join([
    "[roles] rate limited on z_ai/glm-4.7 — retrying in 5.0s (attempt 2)",
    "the upstream 502 body echoed: Rate Limit guidance for org-ab12 "
    "(upstream outage, not throttling)",
    "teardown poll: grep -i \"rate limit\" /logs/agent/fa.txt || true",
    "Ratelimits doc referenced in task prose: see docs/rate-limiting.md",
    "__FA_EXIT=143",
])

# Free-text rate-limit wordings WITHOUT a 429 on their line must not
# classify — including when a real 429 exists on a DIFFERENT line (the
# same-line rule is deliberately line-scoped; gh-1592 fix note).
STATUSLESS_RATE_LIMIT_OUTPUTS = [
    TEARDOWN_OUTPUT,
    # 429 and the wording split across lines: no same-line context.
    "Error: 429 request rejected by gateway\n"
    "upstream said: rate limit exhausted for this org",
    "[roles] too many requests observed on dial/dial-model — backing off",
    "Provider chain exhausted: every chain model is rate limited and "
    "cooling down.",
]

# Decimal-adjacent 429 (gh-1592 review thread 2): `\b429\b` matched the
# `429` inside decimals (`.` is a non-word char, so both sides of `429`
# in `0.429` are word boundaries) — echoed output pairing a decimal with
# rate-limit wording re-triggered the misclassification. The anchored
# token must reject digits/dots on BOTH sides.
DECIMAL_ADJACENT_429_OUTPUTS = [
    # Decimal left of the token (the reviewer's verified shape).
    "tokens=0.429 rate limit guidance echoed for org-ab12",
    # Decimal right of the token (`429.5` must not tokenize as 429).
    "backoff 429.5s applied — rate limit advisory, not a hard failure",
    # Longer number swallowing the token on the left.
    "quota window 1429s while rate limited — nothing to classify",
]

# Real provider-error signatures: 429 and the wording share ONE line.
REAL_429_OUTPUTS = [
    # fa's formatProviderError shape (lib/src/providers/provider_common.dart):
    # '<statusCode>: <message>'.
    "Error: 429: Rate limit reached for gpt-x on tokens per min ( TPM )",
    # Raw HTTP status line.
    "HTTP/1.1 429 Too Many Requests",
    # Single-line JSON body with the structured error code.
    '{"error":{"message":"Rate limit reached","code":429}}',
    # Anthropic envelope wording, status prefix on the same line.
    "429: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}",
    # Wording first, status later on the same provider line.
    "rate limit exceeded — status 429, retry after 5s",
    # Case-insensitive over the whole match, buried mid-output.
    "step 1 ok\nREQUEST FAILED: 429 RATE LIMIT EXCEEDED\nstep 2 never ran",
]


def _rate_limit_patterns():
    """FaAgent's ApiRateLimitError patterns, compiled as harbor does."""
    return [
        (re.compile(p.pattern, re.IGNORECASE), p.exception)
        for p in fa_agent.FaAgent.ERROR_PATTERNS
        if p.exception.__name__ == "ApiRateLimitError"
    ]


def _any_rate_limit_match(text):
    return any(
        compiled.search(text) is not None for compiled, _ in _rate_limit_patterns()
    )


class AnchoredPatternSemanticsTest(unittest.TestCase):
    """Stdlib-only: the anchored ApiRateLimitError patterns' semantics."""

    def test_override_replaces_unanchored_rate_limit_patterns(self):
        # The override must exist and keep exactly the anchored
        # ApiRateLimitError entries — the inherited broad pair is gone
        # (replaced one-for-one, neither dropped nor grown).
        ApiRateLimitError = _api_rate_limit_error_cls()
        inherited = [
            p
            for p in _inherited_error_patterns()
            if p.exception is ApiRateLimitError
        ]
        overridden = [c.pattern for c, _ in _rate_limit_patterns()]
        self.assertEqual(len(overridden), len(inherited))
        self.assertEqual(
            len(overridden),
            2,
            f"expected exactly the two rate-limit wordings anchored; got "
            f"{overridden}",
        )
        for unanchored in (p.pattern for p in inherited):
            self.assertNotIn(
                unanchored,
                overridden,
                f"unanchored pattern {unanchored!r} survived the override",
            )

    def test_teardown_output_with_rate_limit_words_is_not_rate_limit(self):
        # THE gh-1592 REG: teardown/echo text containing "rate limit"
        # (and the toomany-requests sibling wording) must not match any
        # ApiRateLimitError pattern. Pre-fix the broad `rate.?limit`
        # substring regex matches TEARDOWN_OUTPUT.
        for text in STATUSLESS_RATE_LIMIT_OUTPUTS:
            with self.subTest(text=text[:60]):
                self.assertFalse(_any_rate_limit_match(text))

    def test_decimal_adjacent_429_is_not_rate_limit(self):
        # gh-1592 review thread 2: `\b429\b` matched inside decimals
        # (`0.429`, `429.5`, `1429`) — the token guard must reject
        # digit/dot adjacency on both sides so echoed decimals paired
        # with rate-limit wording stay unclassified.
        for text in DECIMAL_ADJACENT_429_OUTPUTS:
            with self.subTest(text=text[:60]):
                self.assertFalse(_any_rate_limit_match(text))

    def test_real_429_signatures_still_classify(self):
        # Recall guard: every structured provider-error signature keeps
        # classifying — 429 and the wording on the SAME line.
        self.assertGreaterEqual(len(_rate_limit_patterns()), 1)
        for text in REAL_429_OUTPUTS:
            with self.subTest(text=text[:60]):
                self.assertTrue(_any_rate_limit_match(text))

    def test_non_rate_limit_table_entries_survive_the_override(self):
        # The override filters ONLY the ApiRateLimitError family: every
        # other inherited exception keeps its entries.
        ApiRateLimitError = _api_rate_limit_error_cls()
        inherited_others = [
            p for p in _inherited_error_patterns()
            if p.exception is not ApiRateLimitError
        ]
        overridden_others = [
            p for p in fa_agent.FaAgent.ERROR_PATTERNS
            if p.exception is not ApiRateLimitError
        ]
        self.assertEqual(
            [(p.pattern, p.exception) for p in inherited_others],
            [(p.pattern, p.exception) for p in overridden_others],
        )


# The harbor base module THIS module's fa_agent copy was classified
# against, captured at import time: sibling test_fa_agent.py installs its
# own (empty-table) stub modules over sys.modules["harbor.*"] when it
# loads — discovery imports every module BEFORE running any test — so a
# late sys.modules lookup would return a different stub whose
# BaseInstalledAgent.ERROR_PATTERNS is empty and whose ApiRateLimitError
# is a different class, breaking the override assertions in harbor-less
# runs (gh-1592 review thread 1, pitfall 2).
_ERROR_PATTERN_BASE = installed_base if REAL_HARBOR_BASE is None else (
    harbor_base
)


def _api_rate_limit_error_cls():
    return _ERROR_PATTERN_BASE.ApiRateLimitError


def _inherited_error_patterns():
    return _ERROR_PATTERN_BASE.BaseInstalledAgent.ERROR_PATTERNS


@unittest.skipUnless(
    REAL_HARBOR_BASE is not None,
    "real harbor package not installed (pip install 'harbor[modal]==0.23.0')"
)
class RealClassifierRegressionTest(unittest.TestCase):
    """Drives harbor's REAL _classify_exec_error end to end (gh-1592)."""

    def setUp(self):
        # tempfile.TemporaryDirectory + addCleanup (gh-1592 review
        # thread 4): a bare mkdtemp() leaked its dir every test and
        # surfaced as ResourceWarning on GC.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.agent = fa_agent.FaAgent(Path(tmp.name) / "logs")

    def _classify(self, stdout):
        result = type("ExecResult", (), {})()
        result.return_code = 143
        result.stdout = stdout
        result.stderr = ""
        command = (
            "set -o pipefail; fa --session-root /logs/agent/fah-sessions "
            "-p 'instruction' < /dev/null 2>&1 | tee /logs/agent/fa.txt"
        )
        return self.agent._classify_exec_error(command, result)

    def test_timeout_killed_teardown_output_is_not_api_rate_limit(self):
        # THE incident: after the 900s ladder kill the launch exec fails
        # and its tee'd output mentions rate limits — the classification
        # must be the generic non-zero-exit error, never
        # ApiRateLimitError (which harbor's retry policy retries on).
        NonZeroAgentExitCodeError = REAL_HARBOR_BASE.NonZeroAgentExitCodeError
        error = self._classify(TEARDOWN_OUTPUT)
        self.assertNotIsInstance(error, REAL_HARBOR_BASE.ApiRateLimitError)
        self.assertIsInstance(error, NonZeroAgentExitCodeError)

    def test_statusless_rate_limit_prose_is_not_api_rate_limit(self):
        for text in STATUSLESS_RATE_LIMIT_OUTPUTS:
            with self.subTest(text=text[:60]):
                error = self._classify(text)
                self.assertNotIsInstance(
                    error, REAL_HARBOR_BASE.ApiRateLimitError
                )

    def test_decimal_adjacent_429_is_not_api_rate_limit(self):
        # gh-1592 review thread 2, driven through the REAL classifier:
        # decimals like `0.429` on a rate-limit-wording line must not
        # classify (harbor's retry policy would retry a non-429 failure).
        for text in DECIMAL_ADJACENT_429_OUTPUTS:
            with self.subTest(text=text[:60]):
                error = self._classify(text)
                self.assertNotIsInstance(
                    error, REAL_HARBOR_BASE.ApiRateLimitError
                )

    def test_real_429_output_still_classifies_api_rate_limit(self):
        for text in REAL_429_OUTPUTS:
            with self.subTest(text=text[:60]):
                error = self._classify(text)
                self.assertIsInstance(error, REAL_HARBOR_BASE.ApiRateLimitError)


if __name__ == "__main__":
    unittest.main()
