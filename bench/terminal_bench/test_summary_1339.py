#!/usr/bin/env python3
"""Issue #1339 ACs: bench-summary observability.

AC1  a replay/takeover-recovered trial (recorded 0/0, real usage only in
     the synced fa session logs) shows its real usage and a `recovered`
     class in the agent_timeout split — distinct from provider hang and
     cap exhaustion.
AC2  a finished run never renders `pending` when a terminal failure mode
     is recorded.
AC3  the unpriced line names the model ids it could not price — or says
     the id is unknown when no session logs and no --model exist.
AC4  fa_usage.extract_session_archive unpacks the docker session archive
     into the trial's host agent-logs dir (the summary's pinned glob).

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import contextlib
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

_BENCH = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location(
    "summary_1339", Path(__file__).resolve().parent / "summary.py"
)
summary = importlib.util.module_from_spec(spec)
sys.modules["summary_1339"] = summary
spec.loader.exec_module(summary)
fa_usage_spec = importlib.util.spec_from_file_location(
    "fa_usage_1339", _BENCH / "fa_usage.py"
)
fa_usage = importlib.util.module_from_spec(fa_usage_spec)
sys.modules["fa_usage_1339"] = fa_usage
fa_usage_spec.loader.exec_module(fa_usage)


def trial(task, name, resolved, mode, tin, tout):
    return {
        "task_id": task,
        "trial_name": name,
        "is_resolved": resolved,
        "failure_mode": mode,
        "total_input_tokens": tin,
        "total_output_tokens": tout,
    }


def session_record(model, tin, tout):
    return json.dumps({
        "type": "message",
        "message": {
            "role": "assistant", "model": model,
            "usage": {"input": tin, "output": tout, "cacheRead": 0, "cacheWrite": 0},
        },
    })


class SummaryObservabilityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def write_run(self, results, sessions=None):
        run = self.runs / "shard-1"
        run.mkdir(parents=True)
        (run / "results.json").write_text(json.dumps({"results": results}))
        for trial_name, records in (sessions or {}).items():
            sessions_dir = run / "task" / trial_name / "agent-logs" / "fah-sessions"
            sessions_dir.mkdir(parents=True)
            (sessions_dir / "s.jsonl").write_text("\n".join(records) + "\n")

    def test_ac1_recovered_trial_shows_real_usage_and_class(self):
        # The run-37495405735 shape: tb's flat-cap timeout fabrication
        # discarded the adapter's fold, so the trial record is 0/0 even
        # though the takeover did the work recorded in the session logs.
        recovered = "get-bitcoin-nodes.1-of-1.shard-1"
        self.write_run(
            [
                trial("get-bitcoin-nodes", recovered, True, "agent_timeout", 0, 0),
                trial("hang-task", "hang.1-of-1.shard-1", False, "agent_timeout", 0, 0),
            ],
            sessions={recovered: [session_record("glm-5.3-flash", 4000, 2000)]},
        )
        lines, problems = summary.render(self.runs)
        out = "\n".join(lines)
        self.assertEqual(problems, [])
        # AC1: the real usage is surfaced from the synced sessions — the
        # run's row is 4000/2000 priced, not 0/0 n/a.
        self.assertIn(
            "| get-bitcoin-nodes | " + recovered
            + " | yes | agent_timeout | 4000/2000 | $0.0016 |",
            out,
        )
        # The split classifies the takeover distinct from hang and work;
        # the provider-hang guard counts only the true zero-byte hang.
        self.assertIn("agent_timeout (recovered — replay/takeover) / yes: 1", out)
        self.assertIn("agent_timeout (0 tokens — provider hang) / no: 1", out)
        self.assertIn("zero-token timeouts (provider hang): 1", out)
        self.assertIn("1 recovered after zero-byte takeover", out)
        # Totals fold the recovery in.
        self.assertIn("tokens in/out: 4000/2000", out)

    def test_ac1_recorded_tokens_are_never_double_folded(self):
        # A trial that already carries its fold (the normal path) must
        # keep its recorded totals, not add the session numbers on top.
        name = "t.1-of-1.shard-1"
        self.write_run(
            [trial("task-a", name, True, None, 100, 50)],
            sessions={name: [session_record("glm-5.3-flash", 100, 50)]},
        )
        lines, _ = summary.render(self.runs)
        self.assertIn("| 100/50 |", "\n".join(lines))

    def test_ac2_terminal_failure_mode_never_renders_pending(self):
        # gh-1206 shape: is_resolved=None with real usage — the run
        # finished, the tests burned their budget mid-verify.
        self.write_run([
            trial("build-initramfs-qemu", "b.1-of-1.shard-1", None,
                  "test_timeout", 11640, 10368),
            # No failure mode at all: genuinely unverifiable, stays pending.
            trial("lost-trial", "l.1-of-1.shard-1", None, None, 0, 0),
        ])
        lines, _ = summary.render(self.runs)
        out = "\n".join(lines)
        self.assertIn(
            "| build-initramfs-qemu | b.1-of-1.shard-1 | no (test_timeout)"
            " | test_timeout | 11640/10368 | n/a |",
            out,
        )
        self.assertIn("| lost-trial | l.1-of-1.shard-1 | pending |  | 0/0 | n/a |", out)

    def test_ac3_unpriced_warning_names_the_model_id(self):
        name = "m.1-of-1.shard-1"
        self.write_run(
            [trial("task-a", name, True, None, 500, 100)],
            sessions={name: [session_record("mystery-model", 500, 100)]},
        )
        lines, _ = summary.render(self.runs)
        self.assertIn(
            "1 trial(s) unpriced: no pricing.json entry for mystery-model",
            "\n".join(lines),
        )

    def test_ac3_unknown_model_id_is_said_so(self):
        self.write_run([trial("task-a", "u.1-of-1.shard-1", True, None, 500, 100)])
        lines, _ = summary.render(self.runs)
        self.assertIn(
            "1 trial(s) unpriced: model id unknown (no fa session logs, no --model)",
            "\n".join(lines),
        )


class ExtractSessionArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_ac4_archive_unpacks_into_agent_logs_dir(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            for name in ("fah-sessions/a/s.jsonl", "fah-sessions/b/c/s.jsonl"):
                data = name.encode()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        dest = Path(self.tmp.name)
        n = fa_usage.extract_session_archive(buf.getvalue(), dest)
        self.assertEqual(n, 2)
        self.assertTrue((dest / "fah-sessions" / "a" / "s.jsonl").is_file())
        self.assertTrue((dest / "fah-sessions" / "b" / "c" / "s.jsonl").is_file())

    def test_ac4_empty_archive_extracts_nothing(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            pass
        dest = Path(self.tmp.name)
        self.assertEqual(fa_usage.extract_session_archive(buf.getvalue(), dest), 0)


if __name__ == "__main__":
    unittest.main()
