#!/usr/bin/env python3
"""Unit tests for the gh-1682 leaderboard tooling.

Run: python3 -m unittest discover -s bench/leaderboard

Hermetic: fetch-parse tests run against fixture captures (a real
tbench.ai page and a real Harbor Hub leaderboard-read response, both
captured 2026-10-18); no test touches the network.
"""
import json
import tempfile
import unittest
from pathlib import Path

import fetch
import record
import render

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"


def load_json(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())


class FetchHubParseTest(unittest.TestCase):
    def test_hub_fixture_normalizes(self):
        payload = load_json("hub_2-1_main.json")
        doc = fetch.normalize_hub_payload(payload, "2.1")
        self.assertEqual(doc["schema"], 1)
        self.assertEqual(doc["version"], "2.1")
        self.assertEqual(doc["source"], "harbor-hub")
        self.assertEqual(doc["package"], "terminal-bench/terminal-bench-2-1")
        self.assertEqual(doc["leaderboard"], "main")
        rows = doc["rows"]
        self.assertEqual(len(rows), payload["pagination"]["total"])
        first = rows[0]
        # Sorted by accuracy desc, labels unwrapped from {label,url}.
        self.assertEqual(first["agent"], "Codex")
        self.assertEqual(first["model"], "GPT-6 Astra")
        self.assertEqual(first["agent_url"],
                         "https://openai.com/codex/")
        self.assertEqual(first["accuracy"], 87.42)
        self.assertEqual(first["n_trials"], 445)
        self.assertEqual(first["date"], "2026-09-03")
        accs = [r["accuracy"] for r in rows]
        self.assertEqual(accs, sorted(accs, reverse=True))

    def test_board_mapping_covers_all_families(self):
        for version in ("2.0", "2.1", "3.0", "4.0"):
            package, name = fetch.board_for(version)
            self.assertTrue(package.startswith("terminal-bench/"))
            self.assertTrue(name)
        with self.assertRaises(SystemExit):
            fetch.board_for("9.9")


class FetchTbenchPageParseTest(unittest.TestCase):
    """Parse the REAL captured tbench.ai page (Next.js RSC payloads) —
    never an HTML-table scrape."""

    def setUp(self):
        self.html = (FIXTURES / "tbench_ai_4-0-0.html").read_text()

    def test_extracts_dehydrated_rows(self):
        rows = fetch.parse_tbench_page(
            self.html, "terminal-bench/terminal-bench", "4-0-0")
        self.assertEqual(len(rows), 35)
        doc = fetch.normalize_tbench_rows(
            rows, "4.0", "terminal-bench/terminal-bench", "4-0-0",
            title="Terminal-Bench 4.0")
        self.assertEqual(doc["source"], "tbench.ai")
        self.assertEqual(doc["title"], "Terminal-Bench 4.0")
        first = doc["rows"][0]
        self.assertEqual(first["model"], "Opus 5.5")
        self.assertEqual(first["agent"], "Claude Code")
        self.assertAlmostEqual(first["accuracy"], 64.85)

    def test_other_board_not_in_page_returns_empty(self):
        # The captured page dehydrates only the 4.0 board — a 2.1 query
        # must come back empty, never a partial/wrong-board match.
        rows = fetch.parse_tbench_page(
            self.html, "terminal-bench/terminal-bench-2-1", "main")
        self.assertEqual(rows, [])

    def test_garbage_html_returns_empty(self):
        self.assertEqual(fetch.parse_tbench_page("<html>nope</html>",
                                                 "a/b", "main"), [])

    def test_unicode_labels_decode_cleanly(self):
        rows = fetch.parse_tbench_page(
            self.html, "terminal-bench/terminal-bench", "4-0-0")
        doc = fetch.normalize_tbench_rows(
            rows, "4.0", "terminal-bench/terminal-bench", "4-0-0")
        joined = json.dumps(doc, ensure_ascii=False)
        # The ± in display_accuracy survived the RSC string decode —
        # no unicode_escape mojibake anywhere in the output.
        self.assertNotIn("Â", joined)


class RecordTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Path(self.tmp.name) / "fa_results.json"

    def tearDown(self):
        self.tmp.cleanup()

    def _record(self, **kw):
        doc = record.load_ledger(self.ledger)
        row = record.upsert(doc, **kw)
        record.save_ledger(doc, self.ledger)
        return json.loads(self.ledger.read_text())

    def test_seed_rows(self):
        doc = self._record(
            dataset_version="2.1", model="kimi-for-coding",
            resolved=300, total=445, date="2026-10-18",
            fa_version="2fd100169e",
            run_urls=["https://x/actions/runs/1",
                      "https://x/actions/runs/2"])
        row = doc["results"][0]
        self.assertTrue(row["self_reported"])
        self.assertEqual(row["resolved"], 300)
        self.assertEqual(len(row["run_urls"]), 2)

    def test_rerun_same_job_updates_not_duplicates(self):
        url = "https://x/actions/runs/39028127116"
        self._record(dataset_version="2.1", model="kimi-for-coding",
                     resolved=100, total=445, date="2026-10-17",
                     fa_version="a", run_urls=[url])
        doc = self._record(dataset_version="2.1", model="kimi-for-coding",
                           resolved=300, total=445, date="2026-10-18",
                           fa_version="b", run_urls=[url])
        self.assertEqual(len(doc["results"]), 1)
        row = doc["results"][0]
        self.assertEqual(row["resolved"], 300)
        self.assertEqual(row["run_urls"], [url])  # deduped, not doubled
        self.assertEqual(row["fa_version"], "b")

    def test_multi_run_aggregate_unions_run_urls(self):
        # The 2.1 kimi seed: three workflow runs, one aggregate row.
        self._record(dataset_version="2.1", model="kimi-for-coding",
                     resolved=140, total=200, date="2026-10-17",
                     run_urls=["https://x/actions/runs/1"])
        doc = self._record(dataset_version="2.1", model="kimi-for-coding",
                           resolved=300, total=445, date="2026-10-18",
                           run_urls=["https://x/actions/runs/2",
                                     "https://x/actions/runs/3"])
        self.assertEqual(len(doc["results"]), 1)
        self.assertEqual(doc["results"][0]["run_urls"], [
            "https://x/actions/runs/1", "https://x/actions/runs/2",
            "https://x/actions/runs/3"])

    def test_sorted_by_version_then_accuracy(self):
        doc = self._record(dataset_version="2.1", model="glm-5.3-flash",
                           resolved=257, total=445, date="2026-10-15",
                           run_urls=[])
        doc = self._record(dataset_version="2.1", model="kimi-for-coding",
                           resolved=300, total=445, date="2026-10-18",
                           run_urls=[])
        self.assertEqual(
            [r["model"] for r in doc["results"]],
            ["kimi-for-coding", "glm-5.3-flash"])

    def test_main_requires_fields(self):
        self.assertEqual(
            record.main(["--dataset-version", "2.1", "--model", "m"]),
            2)

    def test_main_summary_mode(self):
        summary = {
            "family": "2.1", "model": "kimi-for-coding",
            "fa_ref": "abc123", "run_url": "https://x/actions/runs/9",
            "resolved": 10, "total": 20, "date": "2026-10-18",
        }
        s = Path(self.tmp.name) / "summary.json"
        s.write_text(json.dumps(summary))
        self.assertEqual(
            record.main(["--ledger", str(self.ledger),
                         "--summary", str(s)]), 0)
        doc = json.loads(self.ledger.read_text())
        self.assertEqual(doc["results"][0]["resolved"], 10)

    def test_main_summary_missing_field_errors(self):
        s = Path(self.tmp.name) / "summary.json"
        s.write_text(json.dumps({"family": "2.1"}))
        self.assertEqual(
            record.main(["--ledger", str(self.ledger),
                         "--summary", str(s)]), 2)


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.doc21 = fetch.normalize_hub_payload(
            load_json("hub_2-1_main.json"), "2.1")
        self.ledger = {
            "schema": 1,
            "results": [
                {"dataset_version": "2.1", "model": "kimi-for-coding",
                 "resolved": 300, "total": 445, "date": "2026-10-18",
                 "run_urls": ["https://github.com/o/r/actions/runs/39028127116"],
                 "self_reported": True, "fa_version": "2fd100169e"},
                {"dataset_version": "2.1", "model": "glm-5.3-flash",
                 "resolved": 257, "total": 445, "date": "2026-10-15",
                 "run_urls": ["https://github.com/o/r/actions/runs/38823577512"],
                 "self_reported": True, "fa_version": "9201d8b387"},
            ],
        }

    def test_fa_rows_never_blend_into_official_table(self):
        section = render.render_section(
            ["2.1"], {"2.1": self.doc21}, self.ledger, top=15,
            offline_notes=set())
        official_part, _, fa_part = section.partition(
            "#### fa on Terminal-Bench 2.1")
        # fa models must not appear inside the official table...
        for model in ("kimi-for-coding", "glm-5.3-flash"):
            self.assertNotIn(model, official_part.split("| # |")[1])
            # ...but do appear, marked, in the self-reported table.
            self.assertIn(f"⭐ {model}", fa_part)
        # Honesty contract: marker + footnote + run links.
        self.assertIn("self-reported", section.lower())
        self.assertIn("not on the official leaderboard", section)
        self.assertIn("[39028127116](https://github.com/o/r/actions/runs/39028127116)",
                      section)
        self.assertIn("67.4%", section)
        self.assertIn("57.8%", section)
        self.assertIn("`2fd100169e`", section)

    def test_fa_rows_sorted_by_accuracy(self):
        section = render.render_section(
            ["2.1"], {"2.1": self.doc21}, self.ledger, top=15,
            offline_notes=set())
        self.assertLess(section.index("⭐ kimi-for-coding"),
                        section.index("⭐ glm-5.3-flash"))

    def test_official_rows_sorted_and_capped(self):
        section = render.render_section(
            ["2.1"], {"2.1": self.doc21}, self.ledger, top=5,
            offline_notes=set())
        official = section.split("#### fa ")[0]
        self.assertIn("top 5 of 22", official)
        self.assertNotIn("| 6 |", official)
        self.assertIn("87.4%", official)

    def test_missing_official_renders_explicit_note(self):
        section = render.render_section(
            ["2.1"], {"2.1": None}, self.ledger, top=15,
            offline_notes={"2.1"})
        self.assertIn("No official leaderboard rows", section)
        self.assertIn("⭐ kimi-for-coding", section)

    def test_splice_roundtrip_and_idempotency(self):
        versions = ["2.1"]
        section = render.render_section(
            versions, {"2.1": self.doc21}, self.ledger, 15, set())
        text = "# Title\n\n## What's inside\n\nbody\n"
        once = render.splice_readme(text, section)
        self.assertIn(render.MARKER_BEGIN, once)
        self.assertIn(render.MARKER_END, once)
        # Inserted before the anchor heading, which survives.
        self.assertLess(once.index(render.SECTION_HEADER),
                        once.index("## What's inside"))
        # A second splice replaces — no duplicated blocks.
        twice = render.splice_readme(once, section)
        self.assertEqual(once.count(render.MARKER_BEGIN), 1)
        self.assertEqual(twice.count(render.MARKER_BEGIN), 1)
        self.assertEqual(once, twice)

    def test_splice_without_anchor_appends(self):
        section = render.render_section(
            ["2.1"], {"2.1": self.doc21}, self.ledger, 15, set())
        out = render.splice_readme("# Only a title\n", section)
        self.assertIn(render.MARKER_BEGIN, out)


class RenderCliTest(unittest.TestCase):
    def test_offline_render_writes_readme(self):
        with tempfile.TemporaryDirectory() as tmp:
            readme = Path(tmp) / "README.md"
            readme.write_text("## What's inside\n\nbody\n")
            ledger = Path(tmp) / "fa_results.json"
            ledger.write_text(json.dumps({"schema": 1, "results": []}))
            rc = render.main([
                "--offline", "--readme", str(readme),
                "--ledger", str(ledger), "--version", "2.1",
            ])
            self.assertEqual(rc, 0)
            out = readme.read_text()
            self.assertIn(render.MARKER_BEGIN, out)
            self.assertIn("Terminal-Bench 2.1 (official)", out)
            self.assertIn("⭐", out)
            # Second run is a no-op (idempotent).
            self.assertEqual(render.main([
                "--offline", "--readme", str(readme),
                "--ledger", str(ledger), "--version", "2.1",
            ]), 0)

    def test_check_flag_reports_stale(self):
        with tempfile.TemporaryDirectory() as tmp:
            readme = Path(tmp) / "README.md"
            readme.write_text("## What's inside\n")
            ledger = Path(tmp) / "fa_results.json"
            ledger.write_text(json.dumps({"schema": 1, "results": []}))
            self.assertEqual(render.main([
                "--offline", "--check", "--readme", str(readme),
                "--ledger", str(ledger), "--version", "2.1",
            ]), 1)
            render.main(["--offline", "--readme", str(readme),
                         "--ledger", str(ledger), "--version", "2.1"])
            self.assertEqual(render.main([
                "--offline", "--check", "--readme", str(readme),
                "--ledger", str(ledger), "--version", "2.1",
            ]), 0)


if __name__ == "__main__":
    unittest.main()
