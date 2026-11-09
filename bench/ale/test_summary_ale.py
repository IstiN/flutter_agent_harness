"""summary_ale.py tests (issue #1686) — run-dir aggregation, verdict
rules, and the record.py-compatible JSON summary."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import summary_ale  # noqa: E402


def _write_run(root: Path, task: str, variant: int, ts: str, *, status="completed",
               eval_status="success", score=1.0, steps=12, in_tok=1000, out_tok=50):
    run_dir = root / "fa" / task / str(variant) / ts
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "run.json").write_text(json.dumps({
        "task_path": task, "agent_id": "fa", "status": status,
        "total_duration_s": 123.4,
    }))
    (run_dir / "eval_result.json").write_text(json.dumps({
        "eval_status": eval_status, "score": score,
        "eval_duration_s": 5.0, "error": None,
    }))
    (run_dir / "trajectory.json").write_text(json.dumps({
        "schema_version": "ALE-v1.0",
        "final_metrics": {
            "total_steps": steps, "total_input_tokens": in_tok,
            "total_output_tokens": out_tok, "total_cost_usd": 0.1,
            "reward": score, "status": status,
        },
    }))


class CollectTrialsTest(unittest.TestCase):
    def test_rows_from_two_shard_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            s0 = Path(tmp) / "ale-shard-0"
            s1 = Path(tmp) / "ale-shard-1"
            _write_run(s0, "demo/t1", 0, "2026-11-09T00:00:00", score=1.0)
            _write_run(s1, "demo/t2", 0, "2026-11-09T00:01:00", score=0.5,
                       eval_status="success")
            rows = summary_ale.collect_trials([s0, s1])
        self.assertEqual(len(rows), 2)
        by_task = {r["task"]: r for r in rows}
        self.assertEqual(by_task["demo/t1"]["score"], 1.0)
        self.assertEqual(by_task["demo/t2"]["score"], 0.5)
        self.assertEqual(by_task["demo/t1"]["input_tokens"], 1000)

    def test_unreadable_run_dirs_are_skipped_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            s0 = Path(tmp) / "ale-shard-0"
            _write_run(s0, "demo/t1", 0, "ts")
            (s0 / "fa" / "broken" / "0" / "ts").mkdir(parents=True)
            (s0 / "fa" / "broken" / "0" / "ts" / "run.json").write_text("{bad json")
            rows = summary_ale.collect_trials([s0])
        self.assertEqual(len(rows), 1)


class VerdictTest(unittest.TestCase):
    def _rows(self, tasks):
        return [
            {"shard": "ale-shard-0", "task": t, "eval_status": "success",
             "score": 1.0, "status": "completed"}
            for t in tasks
        ]

    def test_empty_roots_fail(self):
        ok, problems = summary_ale.build_verdict([], expected_tasks=2, expected_shards=1)
        self.assertFalse(ok)
        self.assertTrue(any("no trials" in p for p in problems))

    def test_coverage_shortfall_named(self):
        ok, problems = summary_ale.build_verdict(
            self._rows(["t1"]), expected_tasks=2, expected_shards=1
        )
        self.assertFalse(ok)
        self.assertTrue(any("coverage 1/2" in p for p in problems))

    def test_missing_shard_artifacts_named(self):
        ok, problems = summary_ale.build_verdict(
            self._rows(["t1", "t2"]), expected_tasks=2, expected_shards=3
        )
        self.assertFalse(ok)
        self.assertTrue(any("1/3 shards" in p for p in problems))

    def test_complete_run_passes(self):
        ok, problems = summary_ale.build_verdict(
            self._rows(["t1", "t2"]), expected_tasks=2, expected_shards=1
        )
        self.assertTrue(ok, problems)


class ResolvedTest(unittest.TestCase):
    def test_partial_credit_is_not_a_resolution(self):
        self.assertFalse(summary_ale.resolved({"eval_status": "success", "score": 0.5}))
        self.assertFalse(summary_ale.resolved({"eval_status": "failed", "score": 1.0}))
        self.assertTrue(summary_ale.resolved({"eval_status": "success", "score": 1.0}))
        self.assertFalse(summary_ale.resolved({"eval_status": "success", "score": None}))


class JsonSummaryTest(unittest.TestCase):
    def test_exact_record_py_consumer_contract(self):
        # bench/leaderboard/record.py --summary requires family, model,
        # resolved, total, date — missing any = exit 2 upstream.
        rows = [
            {"shard": "s0", "task": "t1", "eval_status": "success", "score": 1.0},
            {"shard": "s0", "task": "t2", "eval_status": "success", "score": 0.5},
        ]
        summary = summary_ale.json_summary(
            rows, model="glm-5.3-flash", fa_ref="abc1234",
            run_url="https://example/run/1", family="ALE-v1.1-docker",
        )
        for key in ("family", "model", "resolved", "total", "date"):
            self.assertIn(key, summary)
        self.assertEqual(summary["resolved"], 1)   # t2's 0.5 ≠ resolved
        self.assertEqual(summary["total"], 2)
        self.assertEqual(summary["fa_ref"], "abc1234")
        self.assertEqual(summary["run_url"], "https://example/run/1")

    def test_repeated_attempts_dedupe_to_one_task_row(self):
        rows = [
            {"shard": "s0", "task": "t1", "eval_status": "success", "score": 1.0},
            {"shard": "s0", "task": "t1", "eval_status": "failed", "score": 0.0},
        ]
        summary = summary_ale.json_summary(
            rows, model="m", fa_ref="r", run_url="", family="f"
        )
        self.assertEqual(summary["total"], 1)


class MarkdownTest(unittest.TestCase):
    def test_markdown_names_problems_on_fail(self):
        rows = [{"shard": "ale-shard-0", "task": "t1", "status": "completed",
                 "eval_status": "success", "score": 1.0, "duration_s": 10.0,
                 "steps": 5, "input_tokens": 10, "output_tokens": 2}]
        text = summary_ale.render_markdown(
            rows, ok=False, problems=["coverage 1/2 (1 task(s) produced no run dir)"],
            model="glm-5.3-flash", run_label="ALE-V1",
        )
        self.assertIn("verdict: FAIL", text)
        self.assertIn("coverage 1/2", text)
        self.assertIn("| t1 |", text)
        self.assertIn("## fa on Agents' Last Exam", text)


if __name__ == "__main__":
    unittest.main()
