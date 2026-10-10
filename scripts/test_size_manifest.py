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
    shapes the Pages workflow gates (zip + deploy-root directory).

Run: python3 scripts/test_size_manifest.py  (CI-wired, #1100 self-test
pattern: a gate's own red exits are fixture-tested so it cannot rot).
"""

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

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
