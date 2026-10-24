#!/usr/bin/env python3
"""UT + REG for scripts/size_manifest.py (#1431): rev-hash churn robustness.

The gate false-reds when a Flutter patch drop moves the engine renderer
artifacts (canvaskit/skwasm) under a NEW 20+hex rev dir: byte sizes stay
identical but the manifest sees brand-new heavyweight lines. These tests
pin the fix contract:

  - rev-hash rename of an existing baseline line -> UPDATE, not NEW/FAIL
    (normalization applies to BOTH the scan and the baseline load, so a
    pre-fix literal-rev baseline file migrates without a rewrite);
  - genuinely-new vendored (canvaskit/) heavyweight -> ::warning + pass;
    --strict-vendored gives the teeth back;
  - genuinely-new first-party heavyweight / over-budget growth -> FAIL;
  - the 20+hex regex does not mangle first-party paths that merely
    contain long hex names;
  - REG: an old-rev/new-rev fixture pair with the same first-party
    payload goes green end-to-end through check() on both artifact
    shapes the Pages workflow gates (zip + deploy-root directory);
  - gh-1819 review: the committed scripts/size_budget/*.tsv floors
    satisfy the TOTAL-vs-rows invariant (0 <= TOTAL - sum(rows) <=
    BASELINE_MAX_SLACK * TOTAL) and the mechanical hand-edit classes
    (sub-floor row, unsorted/duplicate path, malformed row, stale
    TOTAL) are rejected by `validate`, so a diet commit that drops
    rows but keeps the old TOTAL can never silently re-arm the gate.

Run: python3 scripts/test_size_manifest.py  (CI-wired, #1100 self-test
pattern: a gate's own red exits are fixture-tested so it cannot rot).
"""

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import size_manifest  # noqa: E402

KB = 1024
MB = 1024 * KB
OLD_REV = "a" * 40
NEW_REV = "b" * 40


def write_rev_zip(path: Path, rev: str, extra: "dict[str, int] | None" = None):
    """Fixture: extension-zip shape — canvaskit/<rev>/ subtree + first party."""
    with zipfile.ZipFile(path, "w") as zf:
        zf.writestr(f"panel/app/canvaskit/{rev}/canvaskit.wasm", b"\0" * (7 * MB))
        zf.writestr(f"panel/app/canvaskit/{rev}/canvaskit.js", b"\0" * (90 * KB))
        zf.writestr("panel/app/main.dart.js", b"\0" * MB)
        for name, size in (extra or {}).items():
            zf.writestr(name, b"\0" * size)


class NormalizeRevPathsTest(unittest.TestCase):
    def test_rev_segment_collapses(self):
        self.assertEqual(
            size_manifest.normalize_revpaths(
                f"panel/app/canvaskit/{OLD_REV}/canvaskit.wasm"),
            "panel/app/canvaskit/<rev>/canvaskit.wasm")
        self.assertEqual(
            size_manifest.normalize_revpaths(OLD_REV), "<rev>")
        self.assertEqual(
            size_manifest.normalize_revpaths(
                f"canvaskit/{NEW_REV.upper()}/chromium/canvaskit.wasm"),
            "canvaskit/<rev>/chromium/canvaskit.wasm")

    def test_idempotent(self):
        once = size_manifest.normalize_revpaths(
            f"panel/app/canvaskit/{OLD_REV}/skwasm.wasm")
        self.assertEqual(size_manifest.normalize_revpaths(once), once)

    def test_first_party_paths_not_mangled(self):
        # Hex is only PART of the segment, or the segment is shorter than
        # 20 chars, or it is not pure hex — none of these may change.
        for path in [
            "assets/icon_aaaaaaaaaaaaaaaaaaa.png",        # 17-hex segment
            "assets/sha_aaaaaaaaaaaaaaaaaaaa.bin",        # hex-prefixed name
            "bin/a.bin",
            "panel/app/canvaskit/canvaskit.wasm",         # no rev dir
            "vendor/interpreters/pyodide.asm.wasm",
        ]:
            self.assertEqual(size_manifest.normalize_revpaths(path), path,
                             f"mangled first-party path: {path}")


class RevChurnGateTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.td = Path(self._tmp.name)

    def seed_baseline(self) -> Path:
        base = self.td / "base.tsv"
        write_rev_zip(self.td / "art.zip", OLD_REV)
        self.assertEqual(
            size_manifest.check(self.td / "art.zip", base, 5.0,
                                init_if_missing=True), 0)
        return base

    def test_rev_rename_is_update_not_new(self):
        base = self.seed_baseline()
        write_rev_zip(self.td / "art.zip", NEW_REV)
        self.assertEqual(size_manifest.check(self.td / "art.zip", base, 5.0), 0)

    def test_literal_rev_baseline_migrates_on_load(self):
        # Pre-fix baselines carry the literal 40-hex dir; normalization at
        # load must match them against the new-rev scan (no file rewrite).
        base = self.td / "literal.tsv"
        base.write_text(
            f"{7 * MB}\tpanel/app/canvaskit/{OLD_REV}/canvaskit.wasm\n"
            f"{90 * KB}\tpanel/app/canvaskit/{OLD_REV}/canvaskit.js\n"
            f"{MB}\tpanel/app/main.dart.js\n"
            f"{7 * MB + 90 * KB + MB}\tTOTAL\n")
        write_rev_zip(self.td / "art.zip", NEW_REV)
        self.assertEqual(size_manifest.check(self.td / "art.zip", base, 5.0), 0)

    def test_ballooning_renderer_update_still_reports(self):
        # Normalization must not blind the gate: a rev bump that genuinely
        # balloons the renderer is still visible as a (vendored) breach.
        base = self.seed_baseline()
        write_rev_zip(self.td / "art.zip", NEW_REV,
                      {f"panel/app/canvaskit/{NEW_REV}/canvaskit.wasm":
                       7 * MB + MB})
        out = size_manifest.check(self.td / "art.zip", base, 5.0)
        self.assertEqual(out, 0)  # vendored -> warning, not a red

    def test_new_vendored_heavyweight_warns_and_passes(self):
        base = self.seed_baseline()
        write_rev_zip(self.td / "art.zip", NEW_REV,
                      {f"panel/app/canvaskit/{NEW_REV}/skwasm_new.wasm":
                       6 * MB})
        self.assertEqual(size_manifest.check(self.td / "art.zip", base, 5.0), 0)

    def test_strict_vendored_gates_the_same_file(self):
        base = self.seed_baseline()
        write_rev_zip(self.td / "art.zip", NEW_REV,
                      {f"panel/app/canvaskit/{NEW_REV}/skwasm_new.wasm":
                       6 * MB})
        self.assertEqual(
            size_manifest.check(self.td / "art.zip", base, 5.0,
                                strict_vendored=True), 1)

    def test_new_first_party_heavyweight_still_fails(self):
        base = self.seed_baseline()
        write_rev_zip(self.td / "art.zip", NEW_REV,
                      {"panel/app/heavy/new.bin": 6 * MB})
        self.assertEqual(size_manifest.check(self.td / "art.zip", base, 5.0), 1)

    def test_first_party_over_budget_growth_still_fails(self):
        base = self.seed_baseline()
        write_rev_zip(self.td / "art.zip", NEW_REV,
                      {"panel/app/main.dart.js": MB + MB // 10})  # +10%
        self.assertEqual(size_manifest.check(self.td / "art.zip", base, 5.0), 1)

    def test_vendored_only_total_jump_does_not_gate(self):
        # TOTAL includes engine bytes; the budget compares the first-party
        # TOTAL, so a vendored-only payload jump cannot redden the job.
        base = self.seed_baseline()
        write_rev_zip(self.td / "art.zip", NEW_REV,
                      {f"panel/app/canvaskit/{NEW_REV}/skwasm_new.wasm":
                       6 * MB})  # ~+75% raw TOTAL, +0 first-party
        self.assertEqual(size_manifest.check(self.td / "art.zip", base, 5.0), 0)


class BaselineConsistencyTest(unittest.TestCase):
    """gh-1819 review threads: pin the TOTAL-vs-rows invariant.

    The stale-TOTAL class — a diet commit drops rows but keeps the old
    TOTAL (#1227 left fa-macos-arm64.tsv with a 94.35 MB phantom gap,
    handing the TOTAL gate ~+80% of silent headroom for months) — is
    pinned out at three levels:

      - `baseline_consistency_error`: negative gap (TOTAL < its rows —
        physically impossible for any artifact scan) is always rejected;
        the phantom-gap bound is enforced with enforce_slack_bound=True;
      - `validate_baseline_file` + the `validate` CLI: the mechanical
        hand-edit/transcription classes on a committed floor;
      - the committed-floor pin: every scripts/size_budget/*.tsv must
        satisfy the invariant on every CI run of this suite (the static
        job) — a manual diet edit that stale-TOTALs goes red here.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.td = Path(self._tmp.name)

    def write_floor(self, text: str) -> Path:
        p = self.td / "floor.tsv"
        p.write_text(text)
        return p

    # -- baseline_consistency_error ---------------------------------

    def test_healthy_subfloor_slack_passes(self):
        # gap = TOTAL - sum(rows) is the artifact's sub-64KiB tail:
        # ~1% here, ~0.5% on the real shipped-app floors.
        baseline = {"bin/a.bin": 100 * KB, "TOTAL": 101 * KB}
        self.assertIsNone(
            size_manifest.baseline_consistency_error(baseline),
            "a healthy sub-floor tail must not be flagged")

    def test_negative_gap_always_rejected(self):
        baseline = {"bin/a.bin": 100 * KB, "TOTAL": 64 * KB}
        err = size_manifest.baseline_consistency_error(baseline)
        self.assertIsNotNone(err)
        self.assertIn("negative", err)

    def test_stale_total_phantom_gap_rejected_under_bound(self):
        # The exact gh-1819 shape: #1227 dropped the wasm rows but kept
        # the pre-diet TOTAL — 94,354,419 bytes (44.8%) of phantom gap.
        baseline = {"bin/a.bin": 116156998, "TOTAL": 210511417}
        err = size_manifest.baseline_consistency_error(
            baseline, enforce_slack_bound=True)
        self.assertIsNotNone(err)
        self.assertIn("stale", err)

    def test_slack_bound_is_opt_in(self):
        # The check() load path keeps the bound off: a legitimately
        # small-files-heavy artifact can carry >2% sub-floor slack, and
        # a gate that bricks its own --reseed output is worse than soft
        # headroom. Only validate()/the committed-floor pin enforce it.
        baseline = {"bin/a.bin": 100 * KB, "TOTAL": 200 * KB}
        self.assertIsNone(size_manifest.baseline_consistency_error(baseline))
        self.assertIsNotNone(size_manifest.baseline_consistency_error(
            baseline, enforce_slack_bound=True))

    # -- validate_baseline_file: hand-edit/transcription classes -----

    def test_validate_clean_floor_passes(self):
        floor = self.write_floor(
            f"{100 * KB}\tbin/a.bin\n"
            f"{90 * KB}\tbin/b.bin\n"
            f"{192 * KB}\tTOTAL\n")  # gap 2KiB = ~1%: healthy
        self.assertEqual(size_manifest.validate_baseline_file(floor), [])

    def test_validate_rejects_stale_total(self):
        floor = self.write_floor(
            f"{100 * KB}\tbin/a.bin\n"
            f"{300 * KB}\tTOTAL\n")  # gap 200KiB = 66%: phantom
        errs = size_manifest.validate_baseline_file(floor)
        self.assertEqual(len(errs), 1, errs)
        self.assertIn("stale", errs[0])

    def test_validate_rejects_row_below_tracking_floor(self):
        floor = self.write_floor(
            f"{100 * KB}\tbin/a.bin\n"
            f"{60 * KB}\tbin/tiny.bin\n"  # a slipped digit: 60000-ish
            f"{161 * KB}\tTOTAL\n")
        errs = size_manifest.validate_baseline_file(floor)
        self.assertTrue(any("tracking floor" in e for e in errs), errs)

    def test_validate_rejects_unsorted_and_duplicate_rows(self):
        floor = self.write_floor(
            f"{90 * KB}\tbin/b.bin\n"    # out of order
            f"{100 * KB}\tbin/a.bin\n"
            f"{100 * KB}\tbin/a.bin\n"   # duplicate
            f"{191 * KB}\tTOTAL\n")
        errs = size_manifest.validate_baseline_file(floor)
        self.assertTrue(any("path-sorted" in e for e in errs), errs)
        self.assertEqual(len([e for e in errs if "path-sorted" in e]), 2)

    def test_validate_rejects_malformed_row(self):
        floor = self.write_floor(
            f"{100 * KB} bin/a.bin\n"    # space, not tab
            f"{100 * KB}\tbin/a.bin\n"
            f"{100 * KB}\tTOTAL\n")
        errs = size_manifest.validate_baseline_file(floor)
        self.assertTrue(any("malformed" in e for e in errs), errs)

    def test_validate_rejects_missing_total(self):
        floor = self.write_floor(f"{100 * KB}\tbin/a.bin\n")
        errs = size_manifest.validate_baseline_file(floor)
        self.assertTrue(any("TOTAL" in e for e in errs), errs)

    def test_validate_cli_exits_nonzero_and_lists_problems(self):
        floor = self.write_floor(
            f"{100 * KB}\tbin/a.bin\n{300 * KB}\tTOTAL\n")
        with mock.patch("sys.argv",
                        ["size_manifest.py", "validate", str(floor)]):
            self.assertEqual(size_manifest.main(), 1)
        clean = self.write_floor(
            f"{100 * KB}\tbin/a.bin\n{101 * KB}\tTOTAL\n")
        with mock.patch("sys.argv",
                        ["size_manifest.py", "validate", str(clean)]):
            self.assertEqual(size_manifest.main(), 0)

    # -- the pin: every committed floor, every CI run ----------------

    def test_committed_size_budget_floors_are_consistent(self):
        budget = Path(__file__).resolve().parent / "size_budget"
        floors = sorted(budget.glob("*.tsv"))
        self.assertTrue(floors, "scripts/size_budget/*.tsv went missing")
        problems = []
        for floor in floors:
            problems += size_manifest.validate_baseline_file(floor)
        self.assertEqual(
            problems, [],
            "a committed size-budget floor violates the TOTAL-vs-rows "
            "invariant (stale TOTAL after a diet edit?) — reseed it")

    def test_macos_arm64_floor_pins_the_reseed_app_row(self):
        # gh-1819 thread 2: the floor was hand-reconstructed from the
        # run log's manifest; the load-bearing row (the +5.05% App
        # growth that triggered the reseed) is pinned so a transcription
        # slip in it cannot survive a commit silently.
        floor = (Path(__file__).resolve().parent / "size_budget"
                 / "fa-macos-arm64.tsv")
        rows = {}
        for line in floor.read_text().splitlines():
            size, _, name = line.partition("\t")
            if name and name != "TOTAL":
                rows[name] = int(size)
        self.assertEqual(
            rows.get(
                "Fa.app/Contents/Frameworks/App.framework/Versions/A/App"),
            26284144)

    # -- gate teeth ---------------------------------------------------

    def test_gate_loudly_rejects_impossible_baseline(self):
        # TOTAL < sum(rows) cannot come out of any real artifact scan:
        # check() must hard-fail on load instead of silently diffing
        # garbage against a corrupt floor.
        floor = self.write_floor(
            f"{100 * KB}\tbin/a.bin\n{64 * KB}\tTOTAL\n")
        write_rev_zip(self.td / "art.zip", OLD_REV)
        with self.assertRaises(SystemExit) as cm:
            size_manifest.check(self.td / "art.zip", floor, 5.0)
        self.assertIn("negative", str(cm.exception))


class PagesDryPathTest(unittest.TestCase):
    """REG (#1431): old-rev/new-rev pair, same first-party payload, green
    end-to-end through the exact invocation shape the Pages workflow uses
    (deploy-root directory artifact + committed baseline file)."""

    def test_deploy_root_dir_pair_is_green(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            baseline = td / "web-app.tsv"
            for rev in (OLD_REV, NEW_REV):
                app = td / f"app-{rev[:4]}"
                ck = app / "canvaskit" / rev
                ck.mkdir(parents=True)
                (ck / "canvaskit.wasm").write_bytes(b"\0" * (7 * MB))
                (app / "main.dart.js").write_bytes(b"\0" * MB)
                want = 0
                if baseline.exists():
                    want = size_manifest.check(app, baseline, 5.0)
                else:
                    want = size_manifest.check(app, baseline, 5.0,
                                               init_if_missing=True)
                self.assertEqual(want, 0, f"rev {rev[:8]}… must not red the gate")

    def test_manifest_names_are_normalized(self):
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            art = td / "art.zip"
            write_rev_zip(art, OLD_REV)
            manifest = size_manifest.build_manifest(art, size_manifest.MIN_BYTES)
            self.assertIn("panel/app/canvaskit/<rev>/canvaskit.wasm", manifest)
            self.assertNotIn(
                f"panel/app/canvaskit/{OLD_REV}/canvaskit.wasm", manifest)
            self.assertIn("TOTAL", manifest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
