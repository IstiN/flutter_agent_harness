#!/usr/bin/env python3
"""UTs for summary.py's verdict wording + pricing resolution (gh-1838).

Root causes under test:

1. `## ✅ Verdict — all N attempted instances solved, …` printed the word
   "solved" for a merely STRUCTURAL success (ran + evaluated + packaged),
   directly under `**Solved 0/N attempted.**` in the same summary — a
   self-contradictory official report. The ✅ path must state structural
   facts only and carry the strict outcome adjacent when solved_n <
   attempted; the word "solved" may sit next to ✅ only when every
   attempted instance is strictly solved (AC1/AC2).
2. `fa_usage.load_pricing` swallows load/parse errors and returns {} —
   a pricing file that failed to resolve silently rendered `cost n/a`
   for EVERY model (run 40072410719 priced kimi-for-coding n/a although
   its explicit $0 entry existed). Resolution must be loud (path +
   error), overridable via FA_BENCH_PRICING (inline JSON or file,
   merged per model key over the repo default, source logged in the
   summary), alias-aware (plan → API-model LABELLED estimate, never
   mixed into the _stats/cost.json wire), and must keep the cache_read
   component visible (AC5/AC6/AC7/AC8).

Run: python3 -m unittest discover -s bench/programbench
"""
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import summary

_BENCH = Path(__file__).resolve().parent.parent
if str(_BENCH) not in sys.path:
    sys.path.insert(0, str(_BENCH))

import fa_usage  # noqa: E402

REPO_PRICING = Path(__file__).resolve().parent.parent / "pricing.json"


def _session_line(model: str, inp: int, out: int, cr: int = 0, cw: int = 0) -> str:
    return json.dumps(
        {
            "type": "message",
            "message": {
                "role": "assistant",
                "model": model,
                "usage": {
                    "input": inp,
                    "output": out,
                    "cacheRead": cr,
                    "cacheWrite": cw,
                },
            },
        }
    )


def make_run(
    tmp: Path,
    ids,
    score: dict,
    sessions: dict | None = None,
    healthy: bool = True,
) -> Path:
    """A ProgramBench run dir: per-instance packaging + eval.json, the
    _stats/score.json map, and optional {iid: [session jsonl lines]}."""
    run = tmp / "run"
    for iid in ids:
        d = run / iid
        (d / "fa-artifacts" / "sessions").mkdir(parents=True, exist_ok=True)
        if healthy:
            (d / "submission.tar.gz").write_bytes(b"tarball")
            (d / f"{iid}.eval.json").write_text("{}", encoding="utf-8")
        for i, line in enumerate((sessions or {}).get(iid, [])):
            (d / "fa-artifacts" / "sessions" / f"s{i}.jsonl").write_text(
                line + "\n", encoding="utf-8"
            )
    stats = run / "_stats"
    stats.mkdir(parents=True, exist_ok=True)
    (stats / "score.json").write_text(json.dumps(score), encoding="utf-8")
    return run


class SummaryTestBase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="pbench-summtest-")
        self.addCleanup(shutil.rmtree, self._tmp, ignore_errors=True)
        self.tmp = Path(self._tmp)

    def write_pricing(self, name: str, doc) -> str:
        path = self.tmp / name
        path.write_text(
            doc if isinstance(doc, str) else json.dumps(doc), encoding="utf-8"
        )
        return str(path)

    def resolved(self, pricing_path: str | None = REPO_PRICING, override=None):
        return fa_usage.load_pricing_resolved(pricing_path, override=override)


class VerdictWordingTest(SummaryTestBase):
    """gh-1838 AC1/AC2: no ✅ verdict may claim "solved" unless every
    attempted instance is strictly solved; the ❌ path is unchanged."""

    def render(self, run: Path, expected: int = 2):
        return summary.render(
            run,
            expected=expected,
            total=2,
            mode="smoke",
            run_label="smoke",
            fa_ref="0123456789abcdef",
            run_url="https://run.example/1",
            resolved=self.resolved(),
        )

    def test_partial_pass_has_strict_solved_line_and_no_solved_verdict(self):
        run = make_run(
            self.tmp,
            ["a", "b"],
            score={"a": {"t1": True, "t2": False}, "b": {"t1": True, "t2": False}},
        )
        result = self.render(run)
        self.assertEqual(result.exit_code, 0)
        self.assertIn("**Solved 0/2", result.text, "strict headline line present")
        self.assertIn(
            "Strictly solved 0/2 — solved requires 100% of scored tests",
            result.text,
            "adjacent strict-outcome line present",
        )
        for line in result.text.splitlines():
            if "✅" in line:
                self.assertNotIn(
                    "solved", line, f"✅ verdict must not claim solved: {line!r}"
                )
        self.assertIn(
            "ran, were evaluated, and packaged",
            result.text,
            "structural facts stated",
        )

    def test_all_green_keeps_positive_solved_verdict(self):
        run = make_run(
            self.tmp,
            ["a", "b"],
            score={"a": {"t1": True, "t2": True}, "b": {"t1": True, "t2": True}},
        )
        result = self.render(run)
        self.assertEqual(result.exit_code, 0)
        verdict = [ln for ln in result.text.splitlines() if "✅" in ln]
        self.assertTrue(verdict)
        self.assertIn("all 2 attempted instances solved", verdict[-1])

    def test_partial_but_some_solved_reports_exact_fraction(self):
        run = make_run(
            self.tmp,
            ["a", "b"],
            score={"a": {"t1": True, "t2": True}, "b": {"t1": True, "t2": False}},
        )
        result = self.render(run)
        self.assertIn("Strictly solved 1/2", result.text)
        for line in result.text.splitlines():
            if "✅" in line:
                self.assertNotIn("solved", line)

    def test_structural_problem_path_unchanged(self):
        run = make_run(
            self.tmp,
            ["a", "b"],
            score={"a": {"t1": True}, "b": {"t1": True}},
            healthy=False,
        )
        result = self.render(run)
        self.assertEqual(result.exit_code, 1)
        self.assertIn("## ❌ Verdict — structural problems", result.text)


class PricingResolutionTest(SummaryTestBase):
    """gh-1838 AC5: an entry that exists must never render n/a; a pricing
    file that fails to load is a LOUD named warning, never silent n/a."""

    def test_repo_entry_renders_zero_cost_never_na(self):
        run = make_run(
            self.tmp,
            ["a"],
            score={"a": {"t1": True}},
            sessions={"a": [_session_line("kimi-for-coding", 100, 50, 10, 2)]},
        )
        result = summary.render(
            run,
            expected=1,
            total=1,
            mode="smoke",
            run_label="s",
            fa_ref="x",
            run_url="",
            resolved=self.resolved(),
        )
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.costs.get("a"), 0.0, "explicit $0 entry prices")
        self.assertIn("| a |", result.text)
        self.assertIn("0.0000", result.text)
        self.assertNotIn("n/a", result.text)
        self.assertNotIn("unpriced", result.text)

    def test_missing_pricing_file_warns_loud_with_path(self):
        missing = str(self.tmp / "nope" / "pricing.json")
        resolved = self.resolved(missing)
        self.assertEqual(resolved.table, {})
        self.assertTrue(resolved.warnings, "missing table must warn")
        self.assertIn(missing, resolved.warnings[0])
        run = make_run(
            self.tmp,
            ["a"],
            score={"a": {"t1": True}},
            sessions={"a": [_session_line("glm-5.3", 10, 5)]},
        )
        result = summary.render(
            run,
            expected=1,
            total=1,
            mode="smoke",
            run_label="s",
            fa_ref="x",
            run_url="",
            resolved=resolved,
        )
        self.assertIn("⚠️ pricing:", result.text)
        self.assertIn(missing, result.text)

    def test_corrupt_pricing_file_warns_with_parse_error(self):
        bad = self.write_pricing("bad.json", "{definitely not json")
        resolved = self.resolved(bad)
        self.assertEqual(resolved.table, {})
        self.assertIn(bad, resolved.warnings[0])
        self.assertIn("failed to load", resolved.warnings[0])

    def test_shapeless_pricing_doc_warns(self):
        bad = self.write_pricing("shape.json", {"rates": {}})
        resolved = self.resolved(bad)
        self.assertEqual(resolved.table, {})
        self.assertTrue(any("usd_per_mtok" in w for w in resolved.warnings))


class PricingOverrideTest(SummaryTestBase):
    """gh-1838 AC6: FA_BENCH_PRICING (inline JSON or file) merges OVER the
    repo default per model key; the source is logged; failures are loud."""

    BASE = {
        "usd_per_mtok": {
            "m1": {"input": 1.0, "output": 2.0, "cache_read": 0.1},
            "plan": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0},
        }
    }

    def test_env_var_name(self):
        self.assertEqual(fa_usage.PRICING_OVERRIDE_ENV, "FA_BENCH_PRICING")

    def test_override_file_merges_per_model_key(self):
        base = self.write_pricing("base.json", self.BASE)
        over = self.write_pricing(
            "over.json",
            {
                "usd_per_mtok": {
                    "m1": {"input": 9.0},
                    "m2": {"input": 5.0, "output": 7.0},
                }
            },
        )
        resolved = self.resolved(base, override=over)
        self.assertEqual(resolved.table["m1"]["input"], 9.0, "override wins")
        self.assertEqual(resolved.table["m1"]["output"], 2.0, "base rate kept")
        self.assertEqual(resolved.table["m2"]["input"], 5.0, "new model added")
        self.assertIn("FA_BENCH_PRICING", resolved.source)
        self.assertIn(over, resolved.source, "file path logged")

    def test_override_inline_json(self):
        base = self.write_pricing("base.json", self.BASE)
        resolved = self.resolved(
            base, override='{"usd_per_mtok": {"m3": {"input": 3.0}}}'
        )
        self.assertEqual(resolved.table["m3"]["input"], 3.0)
        self.assertIn("inline JSON", resolved.source)

    def test_corrupt_override_falls_back_loudly(self):
        base = self.write_pricing("base.json", self.BASE)
        over = self.write_pricing("over.json", "{nope")
        resolved = self.resolved(base, override=over)
        self.assertEqual(resolved.table["m1"]["input"], 1.0, "base intact")
        self.assertTrue(any(over in w for w in resolved.warnings))

    def test_repo_default_source_without_override(self):
        resolved = self.resolved()
        self.assertIn("repo default", resolved.source)
        self.assertIn("kimi-for-coding", resolved.table)

    def test_render_logs_pricing_source(self):
        run = make_run(self.tmp, ["a"], score={"a": {"t1": True}})
        over = self.write_pricing("over.json", {"usd_per_mtok": {}})
        result = summary.render(
            run,
            expected=1,
            total=1,
            mode="smoke",
            run_label="s",
            fa_ref="x",
            run_url="",
            resolved=self.resolved(REPO_PRICING, override=over),
        )
        self.assertIn("| Pricing |", result.text)
        self.assertIn("FA_BENCH_PRICING", result.text)


class AliasEstimateTest(SummaryTestBase):
    """gh-1838 AC7: a pricing alias maps a plan onto an API model for a
    LABELLED estimate — never mixed with real billing (wire excluded)."""

    PRICING = {
        "usd_per_mtok": {
            "plan": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0},
            "kimi-k3": {"input": 3.0, "output": 15.0, "cache_read": 0.3},
        },
        "aliases": {"plan": "kimi-k3"},
    }

    def test_resolve_entry_direct(self):
        doc = self.PRICING
        table, aliases = doc["usd_per_mtok"], doc["aliases"]
        entry, alias = fa_usage.resolve_entry(table, aliases, "kimi-k3")
        self.assertIsNone(alias)
        self.assertEqual(entry["input"], 3.0)

    def test_resolve_entry_via_alias(self):
        doc = self.PRICING
        table, aliases = doc["usd_per_mtok"], doc["aliases"]
        entry, alias = fa_usage.resolve_entry(table, aliases, "plan")
        self.assertEqual(alias, "kimi-k3")
        self.assertEqual(entry["input"], 3.0, "priced at the TARGET's rates")

    def test_resolve_entry_unknown_stays_unpriced(self):
        entry, alias = fa_usage.resolve_entry({"a": {"input": 1}}, {}, "zzz")
        self.assertIsNone(entry)
        self.assertIsNone(alias)

    def test_alias_estimate_labeled_and_kept_out_of_wire(self):
        pricing = self.write_pricing("alias.json", self.PRICING)
        run = make_run(
            self.tmp,
            ["a"],
            score={"a": {"t1": True}},
            sessions={"a": [_session_line("plan", 1_000_000, 100_000, 0, 0)]},
        )
        result = summary.render(
            run,
            expected=1,
            total=1,
            mode="smoke",
            run_label="s",
            fa_ref="x",
            run_url="",
            resolved=self.resolved(pricing),
        )
        self.assertNotIn("a", result.costs, "estimate must not enter the wire")
        self.assertIn("estimate @ kimi-k3 rates", result.text)
        self.assertIn("0.3000", result.text, "cell shows the labelled estimate")

    def test_main_excludes_alias_estimate_from_cost_json(self):
        pricing = self.write_pricing("alias.json", self.PRICING)
        run = make_run(
            self.tmp,
            ["a"],
            score={"a": {"t1": True}},
            sessions={"a": [_session_line("plan", 1_000_000, 100_000, 0, 0)]},
        )
        argv = [
            "summary.py",
            str(run),
            "--expected",
            "1",
            "--total",
            "1",
            "--mode",
            "smoke",
            "--run-label",
            "s",
            "--fa-ref",
            "x",
        ]
        saved_argv, saved_env = sys.argv, os.environ.get("FA_BENCH_PRICING")
        sys.argv = argv
        os.environ.pop("FA_BENCH_PRICING", None)
        # main() reads the repo default; point the test at the alias file by
        # rendering through main's own path with a patched default.
        saved_default = summary.DEFAULT_PRICING_PATH
        summary.DEFAULT_PRICING_PATH = Path(pricing)
        try:
            code = summary.main()
        finally:
            sys.argv, summary.DEFAULT_PRICING_PATH = saved_argv, saved_default
            if saved_env is None:
                os.environ.pop("FA_BENCH_PRICING", None)
            else:
                os.environ["FA_BENCH_PRICING"] = saved_env
        self.assertEqual(code, 0)
        cost_doc = json.loads((run / "_stats" / "cost.json").read_text())
        self.assertNotIn("a", cost_doc, "estimate never rides the wire")


class CostSplitTest(SummaryTestBase):
    """gh-1838 AC8: the cache_read component stays visible in the summary."""

    PRICING = {
        "usd_per_mtok": {"m": {"input": 1.0, "output": 2.0, "cache_read": 0.5}}
    }

    def test_cost_components_helper(self):
        entry = {"input": 1.0, "output": 2.0, "cache_read": 0.5}
        parts = fa_usage.cost_components(entry, 1_000_000, 1_000_000, 2_000_000, 0)
        self.assertAlmostEqual(parts["input"], 1.0)
        self.assertAlmostEqual(parts["output"], 2.0)
        self.assertAlmostEqual(parts["cache_read"], 1.0)
        self.assertAlmostEqual(sum(parts.values()), 4.0)
        self.assertAlmostEqual(
            fa_usage.cost_usd(entry, 1_000_000, 1_000_000, 2_000_000, 0), 4.0
        )
        self.assertIsNone(fa_usage.cost_components(None, 1, 2))

    def test_split_line_keeps_cache_read_visible(self):
        pricing = self.write_pricing("split.json", self.PRICING)
        run = make_run(
            self.tmp,
            ["a"],
            score={"a": {"t1": True}},
            sessions={"a": [_session_line("m", 1_000_000, 500_000, 200_000_000, 0)]},
        )
        result = summary.render(
            run,
            expected=1,
            total=1,
            mode="full",
            run_label="s",
            fa_ref="x",
            run_url="",
            resolved=self.resolved(pricing),
        )
        self.assertIn("cache-read $", result.text)
        self.assertIn("$100.0000", result.text, "cache-read dominates and shows")


class KimiRateCardTest(SummaryTestBase):
    """gh-1838 AC7: the official Kimi API-model entries price correctly
    (verified against platform.kimi.ai/docs/pricing/chat, 2026-10-24)."""

    RATES = {
        "kimi-k2.7-code": (0.95, 4.0, 0.19),
        "kimi-k2.7-code-highspeed": (1.9, 8.0, 0.38),
        "kimi-k2.6": (0.95, 4.0, 0.16),
        "kimi-k3": (3.0, 15.0, 0.30),
        "kimi-k3.1-pro": (2.0, 10.0, 0.20),
        "kimi-k3.1-pro-highspeed": (4.0, 20.0, 0.20),
    }

    def setUp(self):
        super().setUp()
        doc = json.loads(REPO_PRICING.read_text(encoding="utf-8"))
        self.table = doc["usd_per_mtok"]

    def test_official_kimi_entries_present_with_verified_rates(self):
        for model, (inp, out, cr) in self.RATES.items():
            entry = self.table.get(model)
            self.assertIsNotNone(entry, f"missing rate-card entry: {model}")
            self.assertEqual(entry["input"], inp, model)
            self.assertEqual(entry["output"], out, model)
            self.assertEqual(entry["cache_read"], cr, model)

    def test_kimi_for_coding_keeps_explicit_zero_entry(self):
        entry = self.table["kimi-for-coding"]
        self.assertEqual(entry["input"], 0)
        self.assertEqual(entry["output"], 0)

    def test_k2_8_is_not_guessed(self):
        self.assertNotIn("kimi-k2.8", self.table, "not on the rate card — never guess")

    def test_api_billed_kimi_run_prices_end_to_end(self):
        run = make_run(
            self.tmp,
            ["a"],
            score={"a": {"t1": True}},
            sessions={
                "a": [_session_line("kimi-k2.7-code", 1_141_767, 779_011, 211_079_680, 0)]
            },
        )
        result = summary.render(
            run,
            expected=1,
            total=1,
            mode="smoke",
            run_label="s",
            fa_ref="x",
            run_url="",
            resolved=self.resolved(),
        )
        expected = round(
            (1_141_767 * 0.95 + 779_011 * 4.0 + 211_079_680 * 0.19) / 1e6, 4
        )
        self.assertEqual(result.costs.get("a"), expected)
        self.assertNotIn("n/a", result.text)
        # AC8 reference math: ≈$44.3, ~90% of it cached reads.
        self.assertGreater(expected, 44.0)
        self.assertIn("cache-read $", result.text)


if __name__ == "__main__":
    unittest.main()
