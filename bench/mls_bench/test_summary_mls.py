#!/usr/bin/env python3
"""UTs for the bench-mls summary aggregate (issue #1160).

AC3  - per-domain arithmetic mean over fixture result.jsons.
E1   - modal clip-risk flagging from the run-config bundle.
AC6  - restore-and-inspect: run identity replay, completeness verdict,
       comparability guard (contract 4).

Run: python3 -m unittest discover -s bench/mls_bench
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

import summary_mls

AREAS = {"alpha": "CAL", "beta": "RL", "gamma": "TS"}


def make_jobs(root: Path, job: str, trials: list[dict]) -> None:
    """trials: dicts shaped like harbor TrialResult JSON fragments."""
    for i, trial in enumerate(trials):
        d = root / job / f"trial-{i}"
        d.mkdir(parents=True)
        (d / "result.json").write_text(json.dumps(trial))


def trial(task, score=None, exception=None, multiplier=None, override=None):
    data = {"task_name": f"mls-bench__{task}"}
    if exception:
        data["exception_info"] = {"exception_type": exception}
    else:
        data["exception_info"] = None
        data["verifier_result"] = {"rewards": {"combined_score": score}}
    config = {}
    if multiplier is not None:
        config["timeout_multiplier"] = multiplier
    if override is not None:
        config["override_timeout_sec"] = override
    if config:
        data["config"] = config
    return data


RUN_CONFIG = {
    "workflow": "bench-mls",
    "mls_bench_sha": "80cf5c5" * 8,  # shape only
    "provider": "daytona",
    "subset": "lite",
    "model": "glm-5.3-flash",
    "fa_commit": "ff2faf9",
    "gpu_type": "H100",
    "harbor_version": "0.23.0",
    "attempts": 1,
    "agent_budget": "dataset-declared [agent] timeout_sec = 18000 (5h) per task; "
                    "NO --*-timeout-multiplier or override_timeout_sec emitted (contract 4)",
    "expected_trials": 3,
    "tasks": ["mls-bench__alpha", "mls-bench__beta", "mls-bench__gamma"],
    "areas": AREAS,
    "clip_risk_modal": ["mls-bench__beta"],
}


class AggregateTest(unittest.TestCase):
    """AC3: arithmetic mean of combined_score per upstream area."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.jobs = Path(self.tmp.name) / "jobs"
        make_jobs(self.jobs, "fa-mls-daytona-agent-shard-0", [
            trial("alpha", 0.5),
            trial("beta", 1.0),
            trial("gamma", 0.0),
        ])

    def tearDown(self):
        self.tmp.cleanup()

    def test_per_domain_arithmetic_mean(self):
        rows = summary_mls.load_trials(self.jobs)
        per, errored = summary_mls.aggregate(rows, AREAS)
        self.assertEqual(per, {"CAL": [0.5], "RL": [1.0], "TS": [0.0]})
        self.assertEqual(errored, [])

    def test_full_summary_text_and_exit(self):
        run_config = dict(RUN_CONFIG)
        lines, problems, warnings = summary_mls.build_summary(run_config, summary_mls.load_trials(self.jobs))
        text = "\n".join(lines)
        self.assertIn("80cf5c5", text)              # dataset SHA replayed
        self.assertIn("glm-5.3-flash", text)        # model replayed
        self.assertIn("ff2faf9", text)              # fa commit replayed
        self.assertIn("contract 4", text)           # budget statement replayed
        self.assertIn("| CAL | 1 | 0.5000 |", text)
        self.assertIn("| RL | 1 | 1.0000 |", text)
        self.assertIn("| **overall** | 3 | 0.5000 |", text)
        self.assertEqual(problems, [])

    def test_errored_trials_are_not_scores(self):
        make_jobs(self.jobs, "fa-mls-daytona-agent-shard-1", [
            trial("alpha", exception="AgentTimeoutError"),
        ])
        rows = summary_mls.load_trials(self.jobs)
        per, errored = summary_mls.aggregate(rows, AREAS)
        self.assertEqual(per["CAL"], [0.5])  # shard-0's score only
        self.assertEqual(errored, ["alpha"])

    def test_nop_and_oracle_jobs_never_scored(self):
        make_jobs(self.jobs, "fa-mls-daytona-oracle-shard-0", [trial("alpha", 1.0)])
        make_jobs(self.jobs, "fa-mls-daytona-nop", [trial("alpha", 1.0)])
        rows = summary_mls.load_trials(self.jobs)
        self.assertEqual(len(rows), 3)  # only the agent shard's trials


class ClipFlagTest(unittest.TestCase):
    """E1: modal runs flag their own >24h-budget tasks; daytona never does."""

    def test_modal_flags_intersecting_tasks(self):
        tmp = tempfile.TemporaryDirectory()
        jobs = Path(tmp.name) / "jobs"
        make_jobs(jobs, "fa-mls-modal-agent-shard-0", [trial("beta", 0.5)])
        run_config = dict(RUN_CONFIG, provider="modal")
        lines, _, _ = summary_mls.build_summary(run_config, summary_mls.load_trials(jobs))
        self.assertTrue(any("Modal 24h sandbox cap" in line for line in lines))
        self.assertTrue(any("mls-bench__beta" in line for line in lines))
        tmp.cleanup()

    def test_modal_flags_only_run_tasks(self):
        tmp = tempfile.TemporaryDirectory()
        jobs = Path(tmp.name) / "jobs"
        make_jobs(jobs, "fa-mls-modal-agent-shard-0", [trial("alpha", 0.5)])
        run_config = dict(RUN_CONFIG, provider="modal")
        lines, _, _ = summary_mls.build_summary(run_config, summary_mls.load_trials(jobs))
        self.assertFalse(any("Modal 24h sandbox cap" in line for line in lines))
        tmp.cleanup()

    def test_daytona_never_flags(self):
        tmp = tempfile.TemporaryDirectory()
        jobs = Path(tmp.name) / "jobs"
        make_jobs(jobs, "fa-mls-daytona-agent-shard-0", [trial("beta", 0.5)])
        lines, _, _ = summary_mls.build_summary(dict(RUN_CONFIG), summary_mls.load_trials(jobs))
        self.assertFalse(any("Modal 24h" in line for line in lines))
        tmp.cleanup()


class ComparabilityTest(unittest.TestCase):
    """Contract 4: a run that touched the 5h budget is flagged, not scored."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.jobs = Path(self.tmp.name) / "jobs"

    def tearDown(self):
        self.tmp.cleanup()

    def test_multiplier_violation(self):
        make_jobs(self.jobs, "fa-mls-daytona-agent-shard-0", [trial("alpha", 0.5, multiplier=2.0)])
        rows = summary_mls.load_trials(self.jobs)
        self.assertTrue(summary_mls.comparability_violations(rows))

    def test_override_violation(self):
        make_jobs(self.jobs, "fa-mls-daytona-agent-shard-0", [trial("alpha", 0.5, override=3600)])
        self.assertTrue(summary_mls.comparability_violations(summary_mls.load_trials(self.jobs)))

    def test_clean_run_passes(self):
        make_jobs(self.jobs, "fa-mls-daytona-agent-shard-0", [trial("alpha", 0.5, multiplier=1.0)])
        self.assertEqual(summary_mls.comparability_violations(summary_mls.load_trials(self.jobs)), [])


class BundleInspectTest(unittest.TestCase):
    """AC6: restore-and-inspect - identity fields present, completeness
    verdict, unreadable bundle fails loudly."""

    def test_missing_identity_field_is_a_problem(self):
        run_config = dict(RUN_CONFIG)
        del run_config["fa_commit"]
        lines, problems, warnings = summary_mls.build_summary(run_config, [])
        self.assertTrue(any("fa_commit" in p for p in problems))

    def test_incomplete_run_is_a_problem(self):
        tmp = tempfile.TemporaryDirectory()
        jobs = Path(tmp.name) / "jobs"
        make_jobs(jobs, "fa-mls-daytona-agent-shard-0", [trial("alpha", 0.5)])
        _, problems, _ = summary_mls.build_summary(dict(RUN_CONFIG), summary_mls.load_trials(jobs))
        self.assertTrue(any("1/3 expected trials" in p for p in problems))
        tmp.cleanup()

    def test_complete_run_has_no_completeness_problem(self):
        tmp = tempfile.TemporaryDirectory()
        jobs = Path(tmp.name) / "jobs"
        make_jobs(jobs, "fa-mls-daytona-agent-shard-0",
                  [trial("alpha", 0.5), trial("beta", 0.5), trial("gamma", 0.5)])
        _, problems, _ = summary_mls.build_summary(dict(RUN_CONFIG), summary_mls.load_trials(jobs))
        self.assertEqual(problems, [])
        tmp.cleanup()

    def test_empty_jobs_dir_is_a_problem(self):
        _, problems, _ = summary_mls.build_summary(dict(RUN_CONFIG), [])
        self.assertTrue(any("no agent trials" in p for p in problems))

    def test_unreadable_run_config_exits_1(self):
        tmp = tempfile.TemporaryDirectory()
        rc = Path(tmp.name) / "broken.json"
        rc.write_text("{not json")
        old = sys.argv
        sys.argv = ["summary_mls.py", "--run-config", str(rc), str(tmp.name)]
        try:
            code = summary_mls.main()
        finally:
            sys.argv = old
        self.assertEqual(code, 1)
        tmp.cleanup()


class ExitContractTest(unittest.TestCase):
    """Round-3 review: errored trials are routine frontier outcomes - they
    warn, never fail; only structural problems (comparability, completeness,
    unreadable artifacts) exit 1."""

    def run_main(self, tmp, trials, run_config=None):
        jobs = Path(tmp.name) / "jobs"
        make_jobs(jobs, "fa-mls-daytona-agent-shard-0", trials)
        rc = Path(tmp.name) / "mls-run-config.json"
        rc.write_text(json.dumps(run_config or dict(RUN_CONFIG, expected_trials=len(trials))))
        old = sys.argv
        sys.argv = ["summary_mls.py", "--run-config", str(rc), str(jobs)]
        try:
            code = summary_mls.main()
        finally:
            sys.argv = old
        return code

    def test_errored_trial_warns_and_exits_0(self):
        tmp = tempfile.TemporaryDirectory()
        # One clean task + one AgentTimeoutError: the realistic frontier run.
        code = self.run_main(tmp, [trial("alpha", 0.5), trial("beta", exception="AgentTimeoutError")])
        self.assertEqual(code, 0)

    def test_errored_trial_is_warning_not_problem(self):
        tmp = tempfile.TemporaryDirectory()
        jobs = Path(tmp.name) / "jobs"
        make_jobs(jobs, "fa-mls-daytona-agent-shard-0", [trial("beta", exception="AgentTimeoutError")])
        lines, problems, warnings = summary_mls.build_summary(
            dict(RUN_CONFIG, expected_trials=1), summary_mls.load_trials(jobs))
        self.assertEqual(problems, [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("1 trial(s) errored", warnings[0])
        self.assertTrue(any("Errored/unscored trials (1)" in line for line in lines))

    def test_unparseable_multiplier_is_structural(self):
        tmp = tempfile.TemporaryDirectory()
        code = self.run_main(tmp, [trial("alpha", 0.5, multiplier="2x")])
        self.assertEqual(code, 1)

    def test_nonnumeric_reward_is_errored_not_crash(self):
        rows = [{"job": "fa-mls-daytona-agent-shard-0", "trial": "t",
                 "data": {"task_name": "mls-bench__alpha", "exception_info": None,
                          "verifier_result": {"rewards": {"combined_score": "n/a"}}}}]
        per, errored = summary_mls.aggregate(rows, AREAS)
        self.assertEqual(errored, ["alpha"])
        self.assertNotIn("CAL", per)


if __name__ == "__main__":
    unittest.main()
