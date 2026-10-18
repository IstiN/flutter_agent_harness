#!/usr/bin/env python3
"""gh-1681 Gap 2 — the ATIF fixture contract, validated from the harbor side.

`bench/harbor_fa/fixtures/atif_sample.json` is the GOLDEN output of the
Dart exporter (`lib/src/trajectory/atif_export.dart`, pinned by
test/trajectory/atif_export_test.dart). This test loads the same bytes and
validates them against the REAL harbor 0.23.0 trajectory stack — the
pydantic `Trajectory` model and the static-analysis
`validate_trajectory` gate — so a schema drift on either side fails the
bench-script gate the workflows run (bench-tests.yml installs the pinned
harbor; the test skips when harbor is not importable, e.g. a bare dev
box).

Run: python3 -m unittest discover -s bench/harbor_fa
"""
import json
import unittest
from pathlib import Path

_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "atif_sample.json"

try:
    from harbor.models.trajectories.trajectory import Trajectory
    from harbor.utils.trajectory_validator import validate_trajectory

    _HARBOR_AVAILABLE = True
except ImportError:  # pragma: no cover - exercised on bare dev boxes
    _HARBOR_AVAILABLE = False


@unittest.skipUnless(
    _HARBOR_AVAILABLE,
    "harbor not importable (install 'harbor[modal]==0.23.0' as the "
    "bench workflows do)",
)
class AtifFixtureContractTest(unittest.TestCase):
    """The Dart exporter's golden output must satisfy harbor's model and
    the leaderboard-style static validator."""

    @classmethod
    def setUpClass(cls):
        cls.data = json.loads(_FIXTURE.read_text())

    def test_fixture_parses_as_atif_trajectory(self):
        trajectory = Trajectory(**self.data)
        self.assertEqual(trajectory.schema_version, "ATIF-v1.7")
        self.assertEqual(trajectory.agent.name, "fa")
        self.assertEqual(len(trajectory.steps), 7)
        # Step ids are sequential from 1 (the model enforces it too).
        self.assertEqual(
            [s.step_id for s in trajectory.steps], list(range(1, 8))
        )

    def test_fixture_passes_the_static_analysis_validator(self):
        self.assertTrue(validate_trajectory(self.data))

    def test_tool_steps_are_deterministic_dispatches(self):
        tool_steps = [
            s for s in self.data["steps"] if "tool_calls" in s
        ]
        self.assertTrue(tool_steps)
        for step in tool_steps:
            self.assertEqual(step["llm_call_count"], 0)
            self.assertNotIn("metrics", step)
            self.assertNotIn("reasoning_content", step)
            self.assertIn("message", step)  # required on every step

    def test_non_agent_steps_carry_no_agent_only_fields(self):
        for step in self.data["steps"]:
            if step["source"] == "agent":
                continue
            for key in (
                "model_name",
                "metrics",
                "tool_calls",
                "reasoning_content",
                "llm_call_count",
            ):
                self.assertNotIn(key, step, f"{key} on {step['source']} step")

    def test_final_metrics_totals_match_the_steps(self):
        metrics = self.data["final_metrics"]
        self.assertEqual(metrics["total_steps"], len(self.data["steps"]))
        self.assertEqual(metrics["total_prompt_tokens"], 100)
        self.assertEqual(metrics["total_completion_tokens"], 20)
        self.assertEqual(metrics["total_cached_tokens"], 30)


if __name__ == "__main__":
    unittest.main()
