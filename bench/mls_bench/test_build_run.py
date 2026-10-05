#!/usr/bin/env python3
"""UTs for the bench-mls command builder (issue #1160).

AC4  - no timeout knob in any built invocation, across every
       stage x provider x subset combination.
AC2  - secret fail-fast names the exact key to add.
E3   - subset=full requires confirm-full=yes.
REG-1/AC5 - bench.yml / bench-harbor.yml byte-for-byte today's surfaces:
       defining lines intact, zero MLS contamination, and the new workflow
       is dispatch-only.

Run: python3 -m unittest discover -s bench/mls_bench
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import build_run

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


class SubsetParseTest(unittest.TestCase):
    def test_named_subsets(self):
        self.assertEqual(build_run.parse_subset("smoke-cpu"), ("smoke-cpu", None))
        self.assertEqual(build_run.parse_subset("lite"), ("lite", None))
        self.assertEqual(build_run.parse_subset("full"), ("full", None))

    def test_task_forms_normalize(self):
        self.assertEqual(build_run.parse_subset("task=ml-clustering-algorithm"),
                         ("task", "ml-clustering-algorithm"))
        self.assertEqual(build_run.parse_subset("mls-bench__ml-clustering-algorithm"),
                         ("task", "ml-clustering-algorithm"))
        self.assertEqual(build_run.parse_subset("mls-bench/ts-classification"),
                         ("task", "ts-classification"))

    def test_garbage_rejected(self):
        with self.assertRaises(SystemExit):
            build_run.parse_subset("task=with space")
        with self.assertRaises(SystemExit):
            build_run.parse_subset("")


class FullConfirmTest(unittest.TestCase):
    """E3: default subset is cheap; full sweeps need the explicit opt-in."""

    def test_full_requires_yes(self):
        with self.assertRaises(SystemExit):
            build_run.confirm_full("full", "")
        with self.assertRaises(SystemExit):
            build_run.confirm_full("full", "no")

    def test_full_with_yes_passes(self):
        build_run.confirm_full("full", "yes")

    def test_other_subsets_unaffected(self):
        build_run.confirm_full("smoke-cpu", "")
        build_run.confirm_full("lite", "")


class EnvFailFastTest(unittest.TestCase):
    """AC2: missing secret fails fast naming the exact key to add."""

    ENV = {"DAYTONA_API_KEY": "d", "MODAL_TOKEN_ID": "i", "MODAL_TOKEN_SECRET": "s",
           build_run.MODEL_ENV_VAR: "k"}

    def test_daytona_missing_names_key(self):
        missing = build_run.missing_env_names("daytona", "agent", env={})
        self.assertEqual(missing, ["DAYTONA_API_KEY", build_run.MODEL_ENV_VAR])

    def test_modal_missing_names_both_tokens(self):
        missing = build_run.missing_env_names("modal", "plan", env={"MODAL_TOKEN_ID": "i"})
        self.assertEqual(missing, ["MODAL_TOKEN_SECRET", build_run.MODEL_ENV_VAR])

    def test_ladder_stages_skip_model_key(self):
        # nop/oracle provision no model tokens; only the agent leg needs the key.
        self.assertEqual(build_run.missing_env_names("daytona", "nop", env={}),
                         ["DAYTONA_API_KEY"])
        self.assertEqual(build_run.missing_env_names("daytona", "oracle", env={"DAYTONA_API_KEY": "d"}), [])

    def test_cli_exits_naming_env_var(self):
        env = {k: v for k, v in os.environ.items()
               if k not in self.ENV and k not in ("DAYTONA_API_KEY", build_run.MODEL_ENV_VAR)}
        proc = subprocess.run(
            [sys.executable, "-m", "build_run", "check-env",
             "--provider", "daytona", "--stage", "agent", "--subset", "smoke-cpu"],
            capture_output=True, text=True, env=env,
            cwd=Path(__file__).resolve().parent,
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("::error::DAYTONA_API_KEY secret is not set", proc.stderr)
        self.assertIn(f"::error::{build_run.MODEL_ENV_VAR} secret is not set", proc.stderr)

    def test_cli_passes_with_all_env_set(self):
        env = dict(os.environ)
        env.update(self.ENV)
        proc = subprocess.run(
            [sys.executable, "-m", "build_run", "check-env",
             "--provider", "daytona", "--stage", "agent", "--subset", "smoke-cpu"],
            capture_output=True, text=True, env=env,
            cwd=Path(__file__).resolve().parent,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)


def build(**overrides):
    """Builder entry as the workflow calls it (stage output under test)."""
    args = dict(
        stage="agent", provider="daytona", subset="smoke-cpu",
        tasks=["mls-bench__ml-clustering-algorithm"],
        job_name="fa-mls-daytona-agent-shard-0", model="glm-5.3-flash", gpu_type="H100",
    )
    args.update(overrides)
    return build_run.build_command(**args)


class CommandBuilderTest(unittest.TestCase):
    """AC4: the generated command line carries the ladder, the adapter
    wiring, and NEVER a timeout knob."""

    def test_no_timeout_knobs_anywhere(self):
        for stage in ("nop", "oracle", "agent"):
            for provider in ("daytona", "modal"):
                for subset in ("smoke-cpu", "lite", "full", "task=ml-clustering-algorithm"):
                    line = build(stage=stage, provider=provider, subset=subset,
                                 tasks=["mls-bench__ml-clustering-algorithm"])
                    for knob in build_run.TIMEOUT_KNOBS:
                        self.assertNotIn(knob, line, f"{stage}/{provider}/{subset}")
                    self.assertNotIn("override_timeout_sec", line)

    def test_agent_wiring(self):
        line = build()
        self.assertIn("-a bench.harbor_fa.fa_agent:FaAgent", line)
        self.assertIn("-m glm-5.3-flash", line)
        self.assertIn("-i mls-bench__ml-clustering-algorithm", line)
        self.assertIn("-n 1", line)

    def test_ladder_stages(self):
        self.assertIn("-a nop --disable-verification",
                      build(stage="nop", tasks=["mls-bench__ml-clustering-algorithm"]))
        self.assertIn("-a oracle", build(stage="oracle", tasks=["mls-bench__t"]))
        self.assertNotIn("disable-verification", build(stage="agent", tasks=["mls-bench__t"]))

    def test_subset_selects_run_config(self):
        self.assertIn("-c run-daytona-lite.yaml",
                      build(subset="lite", provider="daytona"))
        self.assertIn("-c run-modal.yaml", build(subset="full", provider="modal"))
        self.assertIn("-c run-modal.yaml", build(subset="smoke-cpu", provider="modal"))

    def test_gpu_type_flows_through_ek(self):
        self.assertIn("--ek gpu_type=H100", build())
        self.assertIn("--ek gpu_type=H200", build(gpu_type="H200"))

    def test_shard_tasks_all_included(self):
        line = build(tasks=["mls-bench__a", "mls-bench__b", "mls-bench__c"])
        for task in ("mls-bench__a", "mls-bench__b", "mls-bench__c"):
            self.assertIn(f"-i {task}", line)


class PlanningTest(unittest.TestCase):
    """Subset resolution + shard matrix against fixture upstream files."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        harbor = root / "harbor"
        (harbor / "tasks-daytona").mkdir(parents=True)
        (harbor / "run-daytona-lite.yaml").write_text(
            "agents:\n  - name: oracle\ndatasets:\n  - path: tasks-daytona\n"
            "    task_names:\n      # Classical ML\n      - mls-bench__a\n"
            "      - mls-bench__b\n      - mls-bench__c\n"
        )
        (harbor / "run-daytona.yaml").write_text(
            "datasets:\n  - path: tasks-daytona\n"
            "    exclude_task_names:\n      - mls-bench__api-only\n"
        )
        # dataset.toml is real TOML: tomllib parses it like upstream's.
        (harbor / "tasks-daytona" / "dataset.toml").write_text(
            '[[tasks]]\nname = "mls-bench/a"\n'
            '[[tasks]]\nname = "mls-bench/b"\n'
            '[[tasks]]\nname = "mls-bench/api-only"\n'
        )
        for task, agent, verifier in (("a", 18000, 5700), ("b", 18000, 90000)):
            task_dir = harbor / "tasks-daytona" / f"mls-bench__{task}"
            task_dir.mkdir(parents=True, exist_ok=True)
            (harbor / "tasks-daytona" / f"mls-bench__{task}" / "task.toml").write_text(
                f"[agent]\ntimeout_sec = {agent}\n[verifier]\ntimeout_sec = {verifier}\n"
            )
        (root / "README.md").write_text(
            "| Area | Directory shorthand | Task |\n|---|---|---|\n"
            "| CAL | [a](tasks/a) | A |\n| RL | [b](tasks/b) | B |\n"
        )
        self.harbor = harbor
        self.root = root

    def tearDown(self):
        self.tmp.cleanup()

    def test_lite_tasks_parsed_verbatim(self):
        self.assertEqual(build_run.lite_tasks(self.harbor, "daytona"),
                         ["mls-bench__a", "mls-bench__b", "mls-bench__c"])

    def test_full_tasks_exclude_config_exclusions(self):
        self.assertEqual(build_run.full_tasks(self.harbor, "daytona"),
                         ["mls-bench__a", "mls-bench__b"])

    def test_shard_matrix_covers_each_task_once(self):
        matrix = build_run.shard_matrix(["t1", "t2", "t3", "t4", "t5"], 2)
        flat = [t for shard in matrix for t in shard["tasks"].split()]
        self.assertEqual(sorted(flat), ["t1", "t2", "t3", "t4", "t5"])
        self.assertEqual(len(matrix), 2)

    def test_clip_risk_computed_from_task_tomls(self):
        # b: 18000 + 90000 > 86400 (E1); a fits.
        self.assertEqual(build_run.clip_risk(self.harbor, "daytona"), ["mls-bench__b"])

    def test_area_map_from_readme(self):
        self.assertEqual(build_run.area_map(self.root), {"a": "CAL", "b": "RL"})


class RegressionPinsTest(unittest.TestCase):
    """REG-1 / AC5: bench-mls is a purely additive third surface. The
    existing workflows keep their defining lines and carry zero MLS
    contamination; the new workflow is dispatch-only."""

    def test_bench_yml_untouched(self):
        text = (WORKFLOWS / "bench.yml").read_text()
        self.assertIn("terminal-bench-core==0.1.1", text)
        self.assertIn("--global-timeout-multiplier 2", text)
        self.assertIn("fa_agent:FaAgent", text)
        self.assertNotIn("mls", text.lower())

    def test_bench_harbor_family_anchors(self):
        # #1128 folded the old bench-4.0.yml into the whole-family surface;
        # the 4.0 anchors and the MLS-free boundary move with it.
        text = (WORKFLOWS / "bench-harbor.yml").read_text()
        self.assertIn("terminal-bench/terminal-bench@4.0.0", text)
        self.assertIn("fa_agent:FaAgent", text)
        self.assertNotIn("mls", text.lower())

    def test_bench_mls_is_dispatch_only(self):
        text = (WORKFLOWS / "bench-mls.yml").read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertNotIn("schedule:", text)
        self.assertNotIn("cron:", text)
        self.assertIn("group: bench-mls", text)
        self.assertIn("permissions:", text)

    def test_bench_mls_no_forked_dataset(self):
        # Contract 2: consume the pinned upstream checkout, no vendored copy.
        text = (WORKFLOWS / "bench-mls.yml").read_text()
        self.assertIn("Imbernoulli/MLS-Bench", text)
        self.assertNotIn("git submodule", text.lower())

    def test_bench_mls_agent_precheck_exposes_model_env_var(self):
        # Structural pin for the AC2 seam (round-3 review): the agent check
        # step must map the z.ai secret under the exact name build_run
        # requires (MODEL_ENV_VAR). An aliased mapping (e.g.
        # FA_KEY: secrets.FA_BENCH_ZAI_KEY) strands the agent leg behind a
        # permanently-missing env var - every shard fails its first step.
        text = (WORKFLOWS / "bench-mls.yml").read_text()
        self.assertIn(
            f"{build_run.MODEL_ENV_VAR}: ${{{{ secrets.FA_BENCH_ZAI_KEY }}}}", text)
        self.assertNotIn("FA_KEY: ${{ secrets.", text)

    def test_bench_mls_inputs_via_env_indirection(self):
        # GHA script-injection pin (round-3 review): dispatch inputs reach
        # run: blocks only via env: indirection - never interpolated into a
        # quoted shell string.
        text = (WORKFLOWS / "bench-mls.yml").read_text()
        # env:/with:/name: lines legitimately carry ${{ inputs.* }}; the
        # sink is a quoted interpolation inside a run: block. Every run:
        # line in this file quotes shell vars, so any remaining quoted
        # interpolation is a violation.
        for line in text.splitlines():
            stripped = line.strip()
            if "'${{ inputs." in stripped or '"${{ inputs.' in stripped:
                self.fail(f"quoted input interpolation in run block: {stripped}")

    def test_bench_mls_preconfig_model_wired_from_input(self):
        # Round-3 review (-a5C): the run identity must name the model that
        # actually ran - the agent step builds FA_PROVIDER_CONFIG from the
        # --model input via the builder, never a hardcoded preconfig.
        text = (WORKFLOWS / "bench-mls.yml").read_text()
        self.assertIn("build_run.py preconfig --model \"$MODEL\"", text)
        self.assertNotIn('"model":"glm-5.3-flash"', text)


class PreconfigTest(unittest.TestCase):
    """Round-3 review (-a5C): the preconfig model comes from the dispatch
    input, json-escaped, so the archived identity names what ran."""

    def test_model_wired_through(self):
        cfg = json.loads(build_run.preconfig_json("glm-5.3-flash"))
        self.assertEqual(cfg["model"], "glm-5.3-flash")
        self.assertEqual(cfg["apiKeyEnvVar"], "FA_KEY_API_Z_AI_Z_AI")
        self.assertTrue(cfg["baseUrl"].startswith("https://"))

    def test_model_json_escaped(self):
        cfg = json.loads(build_run.preconfig_json('x"y\\z'))
        self.assertEqual(cfg["model"], 'x"y\\z')

    def test_cli_preconfig_matches_workflow_call_shape(self):
        # The workflow calls `preconfig --model "$MODEL"` with no other
        # flags; that exact shape must work (round-5 review: with_common's
        # required --provider/--subset broke it in every agent shard).
        proc = subprocess.run(
            [sys.executable, "-m", "build_run", "preconfig", "--model", "m1"],
            capture_output=True, text=True, env=os.environ,
            cwd=Path(__file__).resolve().parent,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout), json.loads(build_run.preconfig_json("m1")))


if __name__ == "__main__":
    unittest.main()
