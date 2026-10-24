#!/usr/bin/env python3
"""Unit tests for the gh-182 ProgramBench leaderboard tooling.

Run: python3 -m unittest discover -s bench/leaderboard

Hermetic: the record tests build synthetic _stats dirs in a temp dir and
the render tests feed ledger dicts directly — no test touches the
network (the run/artifact URLs are plain strings by contract).
"""
import json
import tempfile
import unittest
from pathlib import Path

import pbench_record
import pbench_render

HERE = Path(__file__).resolve().parent
# The committed board itself — the honesty contract is checked against
# the real file, not a synthetic copy (gh-182 review, thread 1).
COMMITTED_LEDGER = HERE / "pbench_results.json"
REPO_ROOT = HERE.parent.parent
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "bench-programbench.yml"


def _write_stats(stats_dir: Path, score: dict, costs: dict = None,
                 calls: dict = None) -> Path:
    stats_dir.mkdir(parents=True, exist_ok=True)
    (stats_dir / "score.json").write_text(json.dumps(score))
    (stats_dir / "cost.json").write_text(json.dumps(costs or {}))
    (stats_dir / "calls.json").write_text(json.dumps(calls or {}))
    return stats_dir


def _ledger_row(**kw) -> dict:
    """A minimal full-run row for render tests.

    Fixtures model rows the tool can actually produce: solved=true only
    at 100.0 (summary.py's ✅ convention) — a non-100 instance is
    solved=false (the gh-182 review's seed-row lesson).
    """
    fields = dict(
        taskset_ref="895f65916bc5", pbench_version="1.2.5",
        model="kimi-for-coding", mode="full", total=201,
        date="2026-11-02", fa_version="abc123456789",
        run_urls=["https://github.com/o/r/actions/runs/500"],
        artifacts=[{"label": "programbench-submission",
                    "url": "https://github.com/o/r/actions/runs/500/artifacts/42"}],
        instances={
            "cmatrix": {"score_pct": 98.0, "tests": 506, "solved": False,
                        "cost_usd": 0.42, "calls": 57},
        },
    )
    fields.update(kw)
    doc = {"schema": 1, "results": []}
    pbench_record.upsert(doc, **fields)
    return doc


class PbenchRecordTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Path(self.tmp.name) / "pbench_results.json"

    def tearDown(self):
        self.tmp.cleanup()

    def _record(self, **kw):
        doc = pbench_record.load_ledger(self.ledger)
        row = pbench_record.upsert(doc, **kw)
        pbench_record.save_ledger(doc, self.ledger)
        return json.loads(self.ledger.read_text())

    def test_seed_row_is_self_reported(self):
        doc = self._record(
            taskset_ref="895f65916bc5", pbench_version="1.2.5",
            model="kimi-for-coding", mode="smoke", total=201,
            date="2026-10-24",
            instances={"cmatrix": {"score_pct": 100.0, "tests": 506,
                                   "solved": True}})
        row = doc["results"][0]
        self.assertTrue(row["self_reported"])
        self.assertEqual(row["mode"], "smoke")
        self.assertEqual(row["attempted"], 1)
        self.assertEqual(row["solved"], 1)
        self.assertEqual(row["score_pct"], 100.0)
        self.assertEqual(row["taskset_ref"], "895f65916bc5")

    def test_committed_ledger_satisfies_honesty_contract(self):
        """gh-182 review thread 1 (BLOCKING): everything the committed
        board publishes must be producible by this tooling from a green
        run — no red-run numbers, no solved-true/non-100 pair, no row
        without its run-proof link or fa ref. The seed row violated all
        of these; this pins the contract on the real committed file."""
        doc = json.loads(COMMITTED_LEDGER.read_text())
        for row in doc["results"]:
            label = f"{row.get('model')}/{row.get('mode')}"
            self.assertTrue(row.get("run_urls"),
                            f"{label}: a committed row carries its run link")
            self.assertTrue(row.get("fa_version"),
                            f"{label}: a recorded row carries --fa-version")
            solved = sum(1 for e in (row.get("instances") or {}).values()
                         if e.get("solved") is True)
            self.assertEqual(row.get("solved"), solved,
                             f"{label}: headline solved matches instances")
            for iid, e in (row.get("instances") or {}).items():
                if e.get("solved") is True:
                    self.assertEqual(
                        e.get("score_pct"), 100.0,
                        f"{label}/{iid}: solved=true implies score 100.0 "
                        "(summary.py's ✅ convention)")

    def test_rerun_same_job_updates_not_duplicates(self):
        url = "https://github.com/o/r/actions/runs/40072410719"
        self._record(taskset_ref="895f65916bc5", pbench_version="1.2.5",
                     model="kimi-for-coding", mode="smoke", total=201,
                     date="2026-10-24", run_urls=[url],
                     instances={"cmatrix": {"score_pct": 90.0, "tests": 10,
                                            "solved": False}})
        doc = self._record(taskset_ref="895f65916bc5", pbench_version="1.2.5",
                           model="kimi-for-coding", mode="smoke", total=201,
                           date="2026-10-25", run_urls=[url],
                           instances={"cmatrix": {"score_pct": 98.0,
                                                  "tests": 506,
                                                  "solved": True}})
        self.assertEqual(len(doc["results"]), 1)
        row = doc["results"][0]
        self.assertEqual(row["run_urls"], [url])  # deduped, not doubled
        self.assertEqual(row["date"], "2026-10-25")
        self.assertEqual(row["instances"]["cmatrix"]["score_pct"], 98.0)

    def test_mode_change_is_a_new_row(self):
        # A later full run must NOT overwrite the smoke proof row — the
        # smoke row stays recorded as the pipeline proof it was.
        self._record(taskset_ref="895f65916bc5", pbench_version="1.2.5",
                     model="kimi-for-coding", mode="smoke", total=201,
                     date="2026-10-24", instances={})
        doc = self._record(taskset_ref="895f65916bc5", pbench_version="1.2.5",
                           model="kimi-for-coding", mode="full", total=201,
                           date="2026-11-02", instances={})
        self.assertEqual(len(doc["results"]), 2)
        self.assertEqual({r["mode"] for r in doc["results"]},
                         {"smoke", "full"})

    def test_multi_run_and_artifact_union(self):
        doc = self._record(
            taskset_ref="895f65916bc5", pbench_version="1.2.5",
            model="kimi-for-coding", mode="smoke", total=201,
            date="2026-10-24",
            run_urls=["https://github.com/o/r/actions/runs/1"],
            artifacts=[{"label": "programbench-submission",
                        "url": "https://github.com/o/r/a/1"}])
        doc = self._record(
            taskset_ref="895f65916bc5", pbench_version="1.2.5",
            model="kimi-for-coding", mode="smoke", total=201,
            date="2026-10-25",
            run_urls=["https://github.com/o/r/actions/runs/1",
                      "https://github.com/o/r/actions/runs/2"],
            artifacts=[{"label": "programbench-submission",
                        "url": "https://github.com/o/r/a/2"}])
        row = doc["results"][0]
        self.assertEqual(row["run_urls"], [
            "https://github.com/o/r/actions/runs/1",
            "https://github.com/o/r/actions/runs/2"])
        # Same label -> URL updated in place, never duplicated.
        self.assertEqual(row["artifact_urls"], [
            {"label": "programbench-submission",
             "url": "https://github.com/o/r/a/2"}])

    def test_read_stats_parses_score_cost_calls(self):
        stats = _write_stats(
            Path(self.tmp.name) / "_stats",
            score={"cmatrix": {"t/a": True, "t/b": True, "t/c": False},
                   "zip-password-finder": {"t/a": True}},
            costs={"cmatrix": 0.41678, "zip-password-finder": 0.5},
            calls={"cmatrix": 57, "zip-password-finder": 61})
        instances = pbench_record.read_stats(stats)
        self.assertEqual(instances["cmatrix"]["score_pct"], 66.7)
        self.assertEqual(instances["cmatrix"]["tests"], 3)
        self.assertFalse(instances["cmatrix"]["solved"])
        self.assertAlmostEqual(instances["cmatrix"]["cost_usd"], 0.4168)
        self.assertEqual(instances["cmatrix"]["calls"], 57)
        self.assertTrue(instances["zip-password-finder"]["solved"])
        # An instance with calls but no score map still lands (honest
        # gap: rendered as "no score"), never silently dropped.
        self.assertIn("zip-password-finder", instances)

    def test_read_stats_missing_score_json_errors(self):
        with self.assertRaises(FileNotFoundError):
            pbench_record.read_stats(Path(self.tmp.name) / "nope")

    def test_read_stats_tolerates_null_and_non_numeric_cost_calls(self):
        # gh-182 review thread 5: a hand-backfilled cost.json/calls.json
        # with nulls or strings must degrade to "no field" — the
        # instance still lands, the tool never dies on a TypeError.
        stats = _write_stats(
            Path(self.tmp.name) / "_stats",
            score={"cmatrix": {"t/a": True}},
            costs={"cmatrix": None, "ghost": "0.13"},
            calls={"cmatrix": "many"})
        instances = pbench_record.read_stats(stats)
        self.assertEqual(instances["cmatrix"],
                         {"score_pct": 100.0, "tests": 1, "solved": True})
        # Known only from a malformed cost entry — an honest empty gap,
        # rendered as "no score", never a crash.
        self.assertEqual(instances["ghost"], {})

    def test_main_survives_a_null_cost_entry(self):
        stats = _write_stats(
            Path(self.tmp.name) / "_stats",
            score={"cmatrix": {"t/a": True}},
            costs={"cmatrix": None})
        rc = pbench_record.main([
            "--ledger", str(self.ledger), "--stats-dir", str(stats),
            "--mode", "smoke", "--model", "kimi-for-coding",
            "--taskset-ref", "895f65916bc5", "--total", "201",
        ])
        self.assertEqual(rc, 0)
        row = json.loads(self.ledger.read_text())["results"][0]
        self.assertNotIn("cost_usd", row["instances"]["cmatrix"])
        self.assertIsNone(row["cost_usd"])

    def test_main_writes_ledger_from_stats_dir(self):
        stats = _write_stats(
            Path(self.tmp.name) / "_stats",
            score={"cmatrix": {"t/a": True, "t/b": True}},
            costs={"cmatrix": 0.25}, calls={"cmatrix": 9})
        rc = pbench_record.main([
            "--ledger", str(self.ledger), "--stats-dir", str(stats),
            "--mode", "smoke", "--model", "kimi-for-coding",
            "--pbench-version", "1.2.5", "--taskset-ref", "895f65916bc5",
            "--total", "201", "--fa-version", "abc123456789",
            "--date", "2026-10-24",
            "--run-url", "https://github.com/o/r/actions/runs/7",
            "--artifact",
            "programbench-submission=https://github.com/o/r/actions/runs/7/artifacts/42",
        ])
        self.assertEqual(rc, 0)
        row = json.loads(self.ledger.read_text())["results"][0]
        self.assertEqual(row["mode"], "smoke")
        self.assertEqual(row["attempted"], 1)
        self.assertEqual(row["cost_usd"], 0.25)
        self.assertEqual(row["calls"], 9)
        self.assertEqual(row["artifact_urls"][0]["label"],
                         "programbench-submission")

    def test_main_rejects_unknown_mode(self):
        rc = pbench_record.main([
            "--ledger", str(self.ledger),
            "--stats-dir", str(Path(self.tmp.name)),
            "--mode", "yolo", "--model", "m",
            "--taskset-ref", "r", "--total", "201",
        ])
        self.assertEqual(rc, 2)

    def test_main_rejects_malformed_artifact(self):
        rc = pbench_record.main([
            "--ledger", str(self.ledger),
            "--stats-dir", str(Path(self.tmp.name)),
            "--mode", "smoke", "--model", "m",
            "--taskset-ref", "r", "--total", "201",
            "--artifact", "no-equals-sign",
        ])
        self.assertEqual(rc, 2)


class PbenchRenderTest(unittest.TestCase):
    def _smoke_ledger(self) -> dict:
        return _ledger_row(
            mode="smoke", date="2026-10-24", fa_version=None,
            run_urls=["https://github.com/o/r/actions/runs/40072410719"],
            artifacts=[],
            instances={
                "cmatrix": {"score_pct": 100.0, "tests": 506, "solved": True},
                "zip-password-finder": {"score_pct": 100.0, "tests": 680,
                                        "solved": True},
            })

    def test_smoke_row_is_marked_pipeline_proof(self):
        section = pbench_render.render_section(self._smoke_ledger())
        self.assertIn("pipeline proof", section)
        self.assertIn("not a leaderboard row", section.lower())
        self.assertIn("2 of 201", section)
        self.assertIn("⭐ kimi-for-coding", section)
        self.assertIn("self-reported", section.lower())
        # Honesty contract: never reads as an official submission.
        self.assertIn("never auto-submitted", section)

    def test_full_row_sorts_above_smoke(self):
        doc = self._smoke_ledger()
        pbench_record.upsert(
            doc, taskset_ref="895f65916bc5", pbench_version="1.2.5",
            model="glm-5.3-flash", mode="full", total=201,
            date="2026-11-02", instances={})
        section = pbench_render.render_section(doc)
        # The headline-worthy full row comes first even though the smoke
        # row was recorded first.
        self.assertLess(section.index("⭐ glm-5.3-flash"),
                        section.index("⭐ kimi-for-coding"))

    def test_run_and_artifact_links_render(self):
        doc = _ledger_row()
        section = pbench_render.render_section(doc)
        self.assertIn(
            "[500](https://github.com/o/r/actions/runs/500)", section)
        self.assertIn(
            "https://github.com/o/r/actions/runs/500/artifacts/42", section)
        # Per-instance detail: score, tests, solved, cost, calls.
        self.assertIn("| cmatrix | 98.0% | 506 | — | $0.42 | 57 |", section)

    def test_row_table_labels_the_test_pass_metric(self):
        # gh-182 review thread 2 (IMPORTANT): the Score column shows the
        # mean per-instance test-pass rate, NOT pass@1 — the column says
        # so, and the intro pins pass@1 to the Solved fraction.
        section = pbench_render.render_section(_ledger_row())
        self.assertIn("| Model | Mode | Solved | Test-pass % | Cost |",
                      section)
        self.assertNotIn("| Solved | Score |", section)
        intro = section.split("| Model | Mode |")[0]
        self.assertIn("Test-pass %", intro)
        self.assertIn("mean share of scored tests", intro)
        self.assertIn("pass@1", intro)
        # Per-instance detail table uses the same metric name.
        self.assertIn("| Instance | Test-pass % | Tests | Solved |", section)

    def test_html_labels_the_test_pass_metric(self):
        page = pbench_render.render_html(_ledger_row())
        self.assertIn("<th>Test-pass %</th>", page)
        self.assertNotIn("<th>Score</th>", page)
        self.assertIn("mean share of scored tests", page)
        self.assertIn("<th>Instance</th><th>Test-pass %</th>", page)

    def test_artifact_links_note_the_retention_window(self):
        # gh-182 review thread 4: artifact URLs expire with GitHub's
        # retention window — the renders say so instead of presenting
        # them as the lasting surface.
        section = pbench_render.render_section(_ledger_row())
        self.assertIn("retention window", section)
        page = pbench_render.render_html(_ledger_row())
        self.assertIn("retention window", page)

    def test_missing_artifacts_fall_back_to_run_link(self):
        section = pbench_render.render_section(self._smoke_ledger())
        self.assertIn("see the [run page]", section.lower())
        self.assertIn(
            "https://github.com/o/r/actions/runs/40072410719", section)

    def test_html_falls_back_to_run_link_when_artifact_has_no_url(self):
        # gh-182 review thread 6: a HAND-EDITED ledger row whose
        # artifact_urls lost its url (merge casualty) must get the same
        # run-page fallback the Markdown render gives — never a
        # linkless, fallbackless page. Raw row dict (upsert would
        # sanitize the url-less entry away — the reviewer's scenario
        # skips that filter).
        doc = {"schema": 1, "results": [{
            "taskset_ref": "895f65916bc5", "pbench_version": "1.2.5",
            "model": "kimi-for-coding", "mode": "full", "total": 201,
            "attempted": 1, "solved": 0, "score_pct": 98.0,
            "cost_usd": 0.42, "calls": 57, "date": "2026-11-02",
            "fa_version": "abc123456789", "self_reported": True,
            "run_urls": ["https://github.com/o/r/actions/runs/500"],
            "artifact_urls": [{"label": "programbench-submission"}],
            "instances": {"cmatrix": {"score_pct": 98.0, "tests": 506,
                                      "solved": False}},
        }]}
        page = pbench_render.render_html(doc)
        self.assertIn("run page", page)
        self.assertIn("https://github.com/o/r/actions/runs/500", page)
        # No dead artifact anchor without a url.
        self.assertNotIn('href="">', page)

    def test_splice_orphaned_begin_marker_fails_loudly(self):
        # gh-182 review thread 7 (1): a begin marker without its end
        # marker means the generated region is corrupt — appending a
        # second block would dual-section the README forever.
        section = pbench_render.render_section(self._smoke_ledger())
        text = "# Title\n\n" + pbench_render.MARKER_BEGIN + "\nleftover\n"
        with self.assertRaises(ValueError):
            pbench_render.splice_readme(text, section)
        with tempfile.TemporaryDirectory() as tmp:
            readme = Path(tmp) / "README.md"
            readme.write_text(text)
            ledger = Path(tmp) / "pbench_results.json"
            ledger.write_text(json.dumps(self._smoke_ledger()))
            rc = pbench_render.main(["--readme", str(readme),
                                     "--ledger", str(ledger)])
            self.assertEqual(rc, 2)
            # Nothing was written — no second block next to the orphan.
            self.assertNotIn(pbench_render.MARKER_END, readme.read_text())
            self.assertNotIn("leftover and", readme.read_text())

    def test_splice_never_swallows_text_after_the_end_marker(self):
        # gh-182 review thread 7 (2): the end marker at EOF without a
        # trailing newline must not eat the character(s) after it.
        section = pbench_render.render_section(self._smoke_ledger())
        text = (pbench_render.MARKER_BEGIN + "\nold\n"
                + pbench_render.MARKER_END + "TRAILING")
        out = pbench_render.splice_readme(text, section)
        self.assertIn("TRAILING", out)
        # Pure EOF shape: no trailing newline at all.
        out2 = pbench_render.splice_readme(
            pbench_render.MARKER_BEGIN + "\nold\n" + pbench_render.MARKER_END,
            section)
        self.assertTrue(out2.endswith(pbench_render.MARKER_END + "\n"))

    def test_splice_roundtrip_and_idempotency(self):
        section = pbench_render.render_section(self._smoke_ledger())
        text = ("<!-- leaderboard:end (gh-1682) -->\n\n"
                "## What's inside\n\nbody\n")
        once = pbench_render.splice_readme(text, section)
        self.assertIn(pbench_render.MARKER_BEGIN, once)
        self.assertIn(pbench_render.MARKER_END, once)
        # Inserted after the Terminal-Bench region, before the anchor
        # heading, which survives.
        self.assertLess(once.index("<!-- leaderboard:end (gh-1682) -->"),
                        once.index(pbench_render.SECTION_HEADER))
        self.assertLess(once.index(pbench_render.SECTION_HEADER),
                        once.index("## What's inside"))
        # A second splice replaces — no duplicated blocks.
        twice = pbench_render.splice_readme(once, section)
        self.assertEqual(once.count(pbench_render.MARKER_BEGIN), 1)
        self.assertEqual(twice, once)

    def test_splice_without_anchor_inserts_before_heading(self):
        section = pbench_render.render_section(self._smoke_ledger())
        out = pbench_render.splice_readme("# Only a title\n", section)
        self.assertIn(pbench_render.MARKER_BEGIN, out)

    def test_html_page_renders_same_block(self):
        html = pbench_render.render_html(self._smoke_ledger())
        self.assertIn("<!doctype html>", html.lower())
        self.assertIn("ProgramBench", html)
        self.assertIn("pipeline proof", html)
        self.assertIn("2 of 201", html)
        self.assertIn("⭐ kimi-for-coding", html)
        self.assertIn("https://github.com/o/r/actions/runs/40072410719", html)
        # Instance ids are machine data — never interpolated raw.
        self.assertNotIn("<cmatrix>", html)

    def test_html_escapes_instance_ids(self):
        doc = _ledger_row(instances={
            "<script>alert(1)</script>": {"score_pct": 50.0, "tests": 2,
                                          "solved": False},
        })
        html = pbench_render.render_html(doc)
        self.assertNotIn("<script>alert(1)</script>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_main_writes_readme_and_html_and_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            readme = Path(tmp) / "README.md"
            readme.write_text(
                "<!-- leaderboard:end (gh-1682) -->\n\n"
                "## What's inside\n\nbody\n")
            html = Path(tmp) / "programbench.html"
            ledger = Path(tmp) / "pbench_results.json"
            ledger.write_text(json.dumps(self._smoke_ledger()))
            argv = ["--readme", str(readme), "--ledger", str(ledger),
                    "--html", str(html)]
            self.assertEqual(pbench_render.main(argv + ["--check"]), 1)
            self.assertEqual(pbench_render.main(argv), 0)
            self.assertIn(pbench_render.MARKER_BEGIN, readme.read_text())
            self.assertIn("pipeline proof", html.read_text())
            # Second run is a no-op (idempotent), --check agrees.
            self.assertEqual(pbench_render.main(argv + ["--check"]), 0)

    def test_main_requires_a_surface(self):
        with tempfile.TemporaryDirectory() as tmp:
            ledger = Path(tmp) / "pbench_results.json"
            ledger.write_text(json.dumps({"schema": 1, "results": []}))
            self.assertEqual(
                pbench_render.main(["--ledger", str(ledger)]), 2)


class WorkflowLedgerStepTest(unittest.TestCase):
    """Structural pins on the bench-programbench.yml aggregate steps the
    review threads target — hermetic (reads the committed YAML)."""

    def _step_body(self, name: str) -> str:
        text = WORKFLOW.read_text()
        marker = f"- name: {name}"
        start = text.index(marker)
        nxt = text.find("\n      - name: ", start + len(marker))
        return text[start:nxt if nxt >= 0 else len(text)]

    def test_record_step_syncs_the_branch_before_recording(self):
        # gh-182 review thread 3 (IMPORTANT): the checkout pins the
        # dispatch sha — re-running an old green run must not record
        # from (and push) a stale tree that would silently drop rows
        # landed since. The step syncs to the branch tip BEFORE
        # pbench_record.py, so the push appends or fails loudly.
        body = self._step_body("Update ProgramBench ledger & README")
        self.assertLess(body.index("git fetch origin"),
                        body.index("git rebase"))
        self.assertLess(body.index("git rebase"),
                        body.index("pbench_record.py"))
        self.assertLess(body.index("pbench_record.py"),
                        body.index("git push origin"))

    def test_submission_artifact_outlives_the_default_retention(self):
        # gh-182 review thread 4: the ledger links the submission
        # artifact as the analysis surface — it must not expire on the
        # default 90-day window while the README still points at it.
        body = self._step_body("Upload submission folder")
        self.assertIn("retention-days:", body)


if __name__ == "__main__":
    unittest.main()
