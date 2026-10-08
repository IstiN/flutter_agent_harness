#!/usr/bin/env python3
"""Issue #1339 ACs: bench-summary observability.

AC1  a replay/takeover-recovered trial (recorded 0/0, real usage only in
     the synced fa session logs) shows its real usage and a `recovered`
     class in the agent_timeout split — distinct from provider hang and
     cap exhaustion.
AC2  a finished run never renders bare `pending` when a failure mode is
     recorded: terminal verify-phase outcomes (test_timeout) read as no,
     everything else as an honest `pending (mode)`.
AC3  the unpriced line names the model ids it could not price — or says
     the id is unknown when no session logs and no --model exist.
AC4  the fa session logs reach the artifact: fa_usage
   .extract_session_archive refuses traversal/absolute/link members
   (loudly, before anything extracts — on EVERY interpreter), and
   fa_agent._export_sessions lands the archive at the trial's host
   agent-logs dir the summary glob pins.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import contextlib
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import types
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


def _import_fa_agent():
    """Load fa_agent with stub terminal_bench modules so the AC4 wiring
    is testable on hosts without the tb package (CI has the real one —
    the stubs satisfy only the import surface, never behavior)."""
    if "fa_agent_1339" in sys.modules:
        return sys.modules["fa_agent_1339"]
    tb = types.ModuleType("terminal_bench")
    agents = types.ModuleType("terminal_bench.agents")
    base = types.ModuleType("terminal_bench.agents.base_agent")

    class AgentResult:
        def __init__(self, total_input_tokens=0, total_output_tokens=0,
                     failure_mode=None, timestamped_markers=None):
            self.total_input_tokens = total_input_tokens
            self.total_output_tokens = total_output_tokens
            self.failure_mode = failure_mode
            self.timestamped_markers = timestamped_markers or []

    base.AgentResult = AgentResult
    fm = types.ModuleType("terminal_bench.agents.failure_mode")

    class FailureMode:
        NONE = "none"
        AGENT_INSTALLATION_FAILED = "installation_error"
        UNKNOWN_AGENT_ERROR = "unknown_agent_error"
        AGENT_TIMEOUT = "agent_timeout"

    fm.FailureMode = FailureMode
    installed = types.ModuleType("terminal_bench.agents.installed_agents")
    abstract = types.ModuleType(
        "terminal_bench.agents.installed_agents.abstract_installed_agent"
    )

    class AbstractInstalledAgent:
        pass

    abstract.AbstractInstalledAgent = AbstractInstalledAgent
    terminal = types.ModuleType("terminal_bench.terminal")
    models = types.ModuleType("terminal_bench.terminal.models")

    class TerminalCommand:
        def __init__(self, **kwargs):
            self.__dict__.update(kwargs)

    models.TerminalCommand = TerminalCommand
    for name, mod in [
        ("terminal_bench", tb),
        ("terminal_bench.agents", agents),
        ("terminal_bench.agents.base_agent", base),
        ("terminal_bench.agents.failure_mode", fm),
        ("terminal_bench.agents.installed_agents", installed),
        (
            "terminal_bench.agents.installed_agents.abstract_installed_agent",
            abstract,
        ),
        ("terminal_bench.terminal", terminal),
        ("terminal_bench.terminal.models", models),
    ]:
        sys.modules.setdefault(name, mod)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    fa_agent_spec = importlib.util.spec_from_file_location(
        "fa_agent_1339", Path(__file__).resolve().parent / "fa_agent.py"
    )
    fa_agent = importlib.util.module_from_spec(fa_agent_spec)
    sys.modules["fa_agent_1339"] = fa_agent
    fa_agent_spec.loader.exec_module(fa_agent)
    return fa_agent


fa_agent = _import_fa_agent()


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

    def render_quiet(self):
        """render() with the stderr warnings swallowed; (lines, problems)."""
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            return summary.render(self.runs)

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
        lines, problems = self.render_quiet()
        out = "\n".join(lines)
        self.assertEqual(problems, [])
        # AC1: the real usage is surfaced from the synced sessions — the
        # run's row is 4000/2000 priced, not 0/0 n/a.
        self.assertIn(
            "| get-bitcoin-nodes | " + recovered
            + " | yes | agent_timeout | checklist: none | 4000/2000 | $0.0016 |",
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
        lines, _ = self.render_quiet()
        self.assertIn("| 100/50 |", "\n".join(lines))

    def test_ac2_terminal_verify_outcome_never_renders_pending(self):
        # gh-1206 shape: is_resolved=None with real usage — the run
        # finished, the tests burned their budget mid-verify: terminal no.
        # A non-verify mode (agent_timeout) stays honest: pending, named.
        self.write_run([
            trial("build-initramfs-qemu", "b.1-of-1.shard-1", None,
                  "test_timeout", 11640, 10368),
            trial("kill-trial", "k.1-of-1.shard-1", None, "agent_timeout", 0, 0),
            trial("lost-trial", "l.1-of-1.shard-1", None, None, 0, 0),
        ])
        lines, _ = self.render_quiet()
        out = "\n".join(lines)
        self.assertIn(
            "| build-initramfs-qemu | b.1-of-1.shard-1 | no (test_timeout)"
            " | test_timeout | checklist: none | 11640/10368 | n/a |",
            out,
        )
        self.assertIn(
            "| kill-trial | k.1-of-1.shard-1 | pending (agent_timeout)"
            " | agent_timeout | checklist: none | 0/0 | n/a |",
            out,
        )
        self.assertIn(
            "| lost-trial | l.1-of-1.shard-1 | pending |  | checklist: none"
            " | 0/0 | n/a |",
            out,
        )

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
        lines, _ = self.render_quiet()
        self.assertIn(
            "1 trial(s) unpriced: model id unknown (no fa session logs, no --model)",
            "\n".join(lines),
        )


def _tar_bytes(*members):
    """Build an in-memory tar: members are (name, kind) where kind is
    'file', 'dir', 'link' (target given as third element), or bytes."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for entry in members:
            name, kind = entry[0], entry[1]
            if kind == "file":
                data = (entry[2] if len(entry) > 2 else name).encode()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            elif kind == "dir":
                info = tarfile.TarInfo(name)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755  # 644 dirs are untraversable
                tar.addfile(info)
            elif kind == "link":
                info = tarfile.TarInfo(name)
                info.type = tarfile.SYMTYPE
                info.linkname = entry[2]
                tar.addfile(info)
    return buf.getvalue()


class ExtractSessionArchiveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dest = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_ac4_archive_unpacks_into_agent_logs_dir(self):
        n = fa_usage.extract_session_archive(_tar_bytes(
            ("fah-sessions", "dir"),
            ("fah-sessions/a/s.jsonl", "file"),
            ("fah-sessions/b/c/s.jsonl", "file"),
        ), self.dest)
        self.assertEqual(n, 2)
        self.assertTrue((self.dest / "fah-sessions" / "a" / "s.jsonl").is_file())
        self.assertTrue((self.dest / "fah-sessions" / "b" / "c" / "s.jsonl").is_file())

    def test_ac4_empty_archive_extracts_nothing(self):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w"):
            pass
        self.assertEqual(
            fa_usage.extract_session_archive(buf.getvalue(), self.dest), 0
        )

    def test_ac4_guard_denies_traversal_before_extracting(self):
        # A model-writable container path can plant .. members: the guard
        # must deny (raise) and land NOTHING outside dest — on every
        # interpreter, including ones without the tarfile data filter.
        with self.assertRaises(ValueError):
            fa_usage.extract_session_archive(_tar_bytes(
                ("fah-sessions/../../evil.jsonl", "file", "pwned"),
            ), self.dest)
        self.assertFalse((self.dest / "evil.jsonl").exists())
        self.assertFalse((self.dest.parent / "evil.jsonl").exists())

    def test_ac4_guard_denies_absolute_member(self):
        with self.assertRaises(ValueError):
            fa_usage.extract_session_archive(_tar_bytes(
                ("/tmp/evil.jsonl", "file", "pwned"),
            ), self.dest)
        self.assertFalse((self.dest / "tmp" / "evil.jsonl").exists())

    def test_ac4_guard_denies_link_member(self):
        # Symlinks/hardlinks are not regular files: a container-planted
        # outbound link must never become a host filesystem object.
        with self.assertRaises(ValueError):
            fa_usage.extract_session_archive(_tar_bytes(
                ("fah-sessions/escape", "link", "/etc/passwd"),
            ), self.dest)
        self.assertFalse((self.dest / "fah-sessions" / "escape").is_symlink())

    def test_ac4_legacy_fallback_extracts_screened_and_warns(self):
        # The pre-backport branch (except TypeError) never runs on CI's
        # Python — force it on any interpreter: a filter= call raising
        # TypeError must fall back to a LOUD warning plus the already
        # screened members= extraction, never a silent pass.
        real = tarfile.TarFile.extractall

        def legacy(self, path=".", members=None, **kwargs):
            if "filter" in kwargs:
                raise TypeError(
                    "extractall() got an unexpected keyword argument 'filter'"
                )
            return real(self, path, members=members)

        tarfile.TarFile.extractall = legacy
        self.addCleanup(setattr, tarfile.TarFile, "extractall", real)
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            n = fa_usage.extract_session_archive(
                _tar_bytes(("fah-sessions/s.jsonl", "file")), self.dest
            )
        self.assertEqual(n, 1)
        self.assertTrue((self.dest / "fah-sessions" / "s.jsonl").is_file())
        self.assertIn("lacks the tarfile data filter", err.getvalue())
        # The manual screen sits BEFORE the branch: a hostile member is
        # denied without ever reaching the fallback (no fallback noise,
        # nothing extracted).
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            with self.assertRaises(ValueError):
                fa_usage.extract_session_archive(
                    _tar_bytes(("fah-sessions/../../evil.jsonl", "file")), self.dest
                )
        self.assertNotIn("lacks the tarfile data filter", err.getvalue())
        self.assertFalse((self.dest.parent / "evil.jsonl").exists())


class _FakeContainer:
    def __init__(self, tar_bytes, fail=None):
        self.tar = tar_bytes
        self.fail = fail
        self.asked = []

    def get_archive(self, path):
        self.asked.append(path)
        if self.fail is not None:
            raise self.fail
        return iter([self.tar]), {}


class _FakeSession:
    def __init__(self, container):
        self.container = container


class ExportSessionsWiringTest(unittest.TestCase):
    """AC4's actual fix is the wiring: container session root → trial's
    host agent-logs dir. Stub container, no docker, no tb package."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dest = Path(self.tmp.name) / "trial" / "agent-logs"
        self.addCleanup(self.tmp.cleanup)

    def test_export_lands_at_agent_logs_fah_sessions(self):
        container = _FakeContainer(_tar_bytes(("fah-sessions/s.jsonl", "file")))
        fa_agent._export_sessions(_FakeSession(container), self.dest)
        self.assertEqual(container.asked, ["/agent-logs/fah-sessions"])
        self.assertTrue((self.dest / "fah-sessions" / "s.jsonl").is_file())

    def test_export_missing_container_root_is_fail_soft(self):
        container = _FakeContainer(None, fail=RuntimeError("no such container path"))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            fa_agent._export_sessions(_FakeSession(container), self.dest)
        self.assertIn("session export failed", err.getvalue())
        self.assertFalse(self.dest.exists())

    def test_export_without_logging_dir_never_touches_container(self):
        container = _FakeContainer(_tar_bytes())
        fa_agent._export_sessions(_FakeSession(container), None)
        self.assertEqual(container.asked, [])


if __name__ == "__main__":
    unittest.main()
