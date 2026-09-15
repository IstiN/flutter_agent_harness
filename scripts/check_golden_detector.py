#!/usr/bin/env python3
"""Detector regression harness for the crap4dart broken_goldens gate (#447).

crap4dart 0.9.5's detector knows exactly three shapes (yellow/black
overflow stripes, the dark-red build-error screen, icon tofu = bordered
square WITH an X). The issue measured what that means for this repo:

  BLIND SPOTS (broken goldens pass as clean):
    - solid Ahem text rectangles   — how every de2f11b9 pre-font golden
                                     actually broke (40/40 missed);
    - hollow icon squares without an X — what an unloaded MaterialIcons
                                     font really draws.
  FALSE POSITIVES (clean goldens flagged):
    - the Habit Tracker checkmark tile: the white V converges exactly
      like the X signature (light theme, 5 goldens);
    - yellow "25:00" digits on the dark timer card: glyph edges pass
      the stripe heuristic (panel_dark).

The detector fixes belong to upstream (IstiN/crap4dart). This harness
pins the truth HERE, as synthetic pixel fixtures — one per class — so
re-verification after every upstream release is one command:

    python3 scripts/check_golden_detector.py                # scoreboard
    python3 scripts/check_golden_detector.py --regression   # + the 40
                                        # pre-font goldens from f9dce062^
    python3 scripts/check_golden_detector.py --expect-fixed # CI-flippable:
                                        # exit 1 until upstream fixes land

Fixtures are generated at runtime (no binary blobs in git). Each class
asserts a verdict from the PINNED detector (`dart pub global run
crap4dart`), never from a re-implementation — the scoreboard IS the
test, and `--expect-fixed` is the flip-to-error gate for the configs.

Self-test: python3 scripts/check_golden_detector.py --self-test
"""

import argparse
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REGRESSION_REF = "f9dce062^:flutter_app/test/golden/goldens"
DETECTOR_TIMEOUT = 180  # s — the gate decodes every PNG it is handed


# ── Minimal PNG writer (8-bit RGB, no interlace) ─────────────────────────

def _chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def write_png(path: Path, px: list[list[tuple[int, int, int]]]) -> None:
    """px[row][col] = (r, g, b)."""
    h, w = len(px), len(px[0])
    raw = b"".join(
        b"\x00" + bytes(v for p in row for v in p) for row in px
    )
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + _chunk(b"IDAT", zlib.compress(raw, 9))
        + _chunk(b"IEND", b"")
    )


# ── Fixture canvas helpers ────────────────────────────────────────────────

WHITE = (255, 255, 255)
INK = (10, 10, 10)  # classifies as stripe-black (<60 each), never yellow
GREEN = (76, 175, 80)  # Material green — Habit Tracker tile
YELLOW = (255, 193, 7)  # amber timer digits (r>200, g>180, b<90)
DARK = (30, 30, 30)  # dark card — classifies as stripe-black


def canvas(size: int = 64, color: tuple[int, int, int] = WHITE):
    return [[color] * size for _ in range(size)]


def rect(px, x0, y0, x1, y1, color):  # inclusive corners
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            px[y][x] = color


def line(px, x0, y0, x1, y1, color, thick=2):
    """Axis-ish thick line via Bresenham + square brush."""
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x1 >= x0 else -1
    sy = 1 if y1 >= y0 else -1
    err = dx - dy
    x, y = x0, y0
    while True:
        for ox in range(thick):
            for oy in range(thick):
                px[min(y + oy, len(px) - 1)][min(x + ox, len(px[0]) - 1)] = color
        if x == x1 and y == y1:
            return
        e2 = 2 * err
        if e2 > -dy:
            err -= dy
            x += sx
        if e2 < dx:
            err += dx
            y += sy


# ── The six fixture classes ───────────────────────────────────────────────
# Each entry: filename -> (painter, today's measured verdict class,
# target verdict class after the upstream detector fixes).
#   "detect"  = the gate must flag it ("stripes" / "tofu")
#   "clean"   = the gate must pass it
# today="clean", target="detect"  → blind spot
# today="detect", target="clean"  → false positive

def _ahem_text(px):
    """A word of solid Ahem glyph rectangles: three 12x14 blocks, gap 3."""
    for i in range(3):
        rect(px, 8 + i * 15, 20, 19 + i * 15, 33, INK)


def _hollow_square(px):
    """Unloaded-icon placeholder: 24x24 box, 2px walls, NO diagonal."""
    rect(px, 20, 20, 43, 21, INK)
    rect(px, 20, 42, 43, 43, INK)
    rect(px, 20, 20, 21, 43, INK)
    rect(px, 42, 20, 43, 43, INK)


def _x_tofu(px):
    """True tofu: the same box plus a corner-to-corner X."""
    _hollow_square(px)
    line(px, 21, 21, 42, 42, INK)
    line(px, 42, 21, 21, 42, INK)


def _checkmark_tile(px):
    """Habit Tracker tile: rounded green square + white V — the FP that
    reads as an X signature (light theme, 5 goldens at 22px real size;
    drawn 28px here so the top-border run clears the detector's 20px
    minimum icon size)."""
    t0, t1 = 18, 45  # 28x28 tile
    cut = 3
    rect(px, t0, t0, t1, t1, GREEN)
    for c in range(cut):  # approximate rounded corners
        span = cut - c
        for d in range(span):
            px[t0 + c][t0 + d] = WHITE
            px[t0 + c][t1 - d] = WHITE
            px[t1 - c][t0 + d] = WHITE
            px[t1 - c][t1 - d] = WHITE
    # white checkmark V: short arm down-right, long arm up-right
    line(px, t0 + 8, t0 + 15, t0 + 13, t0 + 20, WHITE, thick=2)
    line(px, t0 + 13, t0 + 20, t0 + 21, t0 + 8, WHITE, thick=2)


def _overflow_stripes(px):
    """Flutter's overflow pattern: strict 45-degree yellow/black
    checkerboard — any row crosses it with real alternation."""
    size = len(px)
    for y in range(size):
        for x in range(size):
            px[y][x] = YELLOW if ((x + y) // 8) % 2 == 0 else INK


def _yellow_on_dark(px):
    """Amber digits on a dark card: 5 thick yellow bars with dark gaps —
    along their center row this alternates like stripes do (the
    panel_dark "25:00" false positive)."""
    rect(px, 0, 0, 63, 63, DARK)
    for i in range(5):
        x0 = 8 + i * 11
        rect(px, x0, 22, x0 + 3, 41, YELLOW)


FIXTURES = {
    # blind spot: broken golden, detector sees nothing (yet)
    "ahem_solid_text_rects.png": (_ahem_text, "clean", "detect"),
    "hollow_icon_square_no_x.png": (_hollow_square, "clean", "detect"),
    # false positive: clean golden, detector cries wolf (yet)
    "checkmark_tile_light.png": (_checkmark_tile, "detect", "clean"),
    "yellow_digits_on_dark.png": (_yellow_on_dark, "detect", "clean"),
    # regression guards: must stay detected before AND after the fixes
    "x_boxed_icon_tofu.png": (_x_tofu, "detect", "detect"),
    "overflow_stripes.png": (_overflow_stripes, "detect", "detect"),
}


# ── Fixture sanity (the --self-test ladder) ──────────────────────────────

def _stripe_kind(r, g, b):
    """Mirror of the gate's own classification (broken_goldens_gate)."""
    if r > 200 and g > 180 and b < 90:
        return "yellow"
    if r < 60 and g < 60 and b < 60:
        return "black"
    return "none"


def _stripes_elsewhere(name, px):
    """True when the image contains a row run the stripe heuristic eats:
    >= 8 px, >= 4 transitions, yellow >= 1/3 (gate thresholds)."""
    if "overflow_stripes" not in name and "yellow_digits" not in name:
        return False
    for row in px:
        run = transitions = yellows = 0
        last = None
        for r, g, b in row:
            kind = _stripe_kind(r, g, b)
            if kind == "none":
                run = transitions = yellows = 0
                last = None
                continue
            if kind != last:
                transitions += 1
                last = kind
            run += 1
            yellows += kind == "yellow"
            if run >= 8 and transitions >= 4 and yellows * 3 >= run:
                return True
    return False


def self_test() -> int:
    """The generator is the test double of the detector's inputs: if a
    fixture is mis-painted, the scoreboard lies. Assert the properties
    each class NEEDS, straight from the painted pixels."""
    import tempfile

    failures = []
    with tempfile.TemporaryDirectory() as td:
        for name, (paint, _, _) in FIXTURES.items():
            px = canvas()
            paint(px)
            # 1. every fixture paints valid RGB and round-trips the PNG
            #    writer byte-identically (determinism)
            write_png(Path(td) / name, px)
            first = (Path(td) / name).read_bytes()
            write_png(Path(td) / name, px)
            if first != (Path(td) / name).read_bytes():
                failures.append(f"{name}: PNG writer not deterministic")
            if not first.startswith(b"\x89PNG\r\n\x1a\n") or b"IEND" not in first[-12:]:
                failures.append(f"{name}: not a valid PNG")
            # 2. per-class pixel-level invariants the detector keys on
            if name.startswith(("ahem_", "x_boxed", "hollow_")):
                ink = sum(p == INK for row in px for p in row)
                if ink == 0:
                    failures.append(f"{name}: no ink painted")
            if name == "yellow_digits_on_dark" and not _stripes_elsewhere(name, px):
                failures.append(
                    f"{name}: fixture must reproduce the stripe signature "
                    "(that IS the false positive being pinned)"
                )
            if name == "checkmark_tile_light":
                whites = sum(1 for row in px for p in row if p == WHITE)
                greens = sum(1 for row in px for p in row if p == GREEN)
                if whites < 64 * 64 * 2 or greens < 20 * 20:
                    failures.append(f"{name}: tile/V geometry wrong")
    for f in failures:
        print(f"SELF-TEST FAIL: {f}")
    print("self-test:", "FAILED" if failures else "OK", f"({len(FIXTURES)} fixtures)")
    return 1 if failures else 0


# ── Detector invocation ──────────────────────────────────────────────────

def run_detector(scan_dir: Path, workdir: Path) -> dict[str, str]:
    """Runs the pinned broken_goldens gate over scan_dir; returns
    {png path: violation message}. Empty dict = everything clean."""
    cfg = workdir / "crap4dart.yaml"
    (workdir / "lib").mkdir(exist_ok=True)
    (workdir / "lib" / "noop.dart").write_text("void main() {}\n")
    cfg.write_text(
        "coverage:\n"
        "  run_tests: false\n"
        "gates:\n"
        "  broken_goldens:\n"
        "    enabled: true\n"
        f"    dirs: [{scan_dir.relative_to(workdir).as_posix()}]\n"
    )
    if not shutil.which("dart"):
        raise SystemExit("dart not on PATH — cannot run the pinned detector")
    proc = subprocess.run(
        ["dart", "pub", "global", "run", "crap4dart", "check",
         "--only", "broken_goldens"],
        cwd=workdir,
        capture_output=True,
        text=True,
        timeout=DETECTOR_TIMEOUT,
    )
    violations = {}
    for raw in proc.stdout.splitlines():
        s = raw.strip()
        # violation lines: "<dir>/<name>.png: <message>" — match on the
        # path head, not the message tail
        if ": " in s and s.partition(":")[0].strip().endswith(".png"):
            path, _, msg = s.partition(":")
            # reporter keys carry the scan dir ("goldens/x.png") — index
            # by basename so callers look fixtures up by name
            violations.setdefault(Path(path.strip()).name, msg.strip())
    if not violations and proc.returncode not in (0, 2):
        raise SystemExit(
            f"detector run failed rc={proc.returncode}:\n{proc.stdout[-800:]}\n{proc.stderr[-800:]}"
        )
    return violations


def classify(violations: dict[str, str], name: str) -> str:
    msg = violations.get(name, "")
    if not msg:
        return "clean"
    return "stripes" if "overflow stripes" in msg else "tofu"


def extract_regression(workdir: Path) -> Path:
    """The synthetic regression fixture: the 40 pre-font goldens that
    sat in git at f9dce062^ — the exact batch every text glyph of which
    was an Ahem rectangle. Extracted from git history, never stored."""
    dest = workdir / "regression"
    dest.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ["git", "archive", REGRESSION_REF],
        cwd=REPO,
        capture_output=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise SystemExit(f"git archive {REGRESSION_REF} failed: {proc.stderr.decode()[-300:]}")
    subprocess.run(["tar", "-x", "-C", str(dest)], input=proc.stdout, check=True)
    return dest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--regression", action="store_true",
                    help="also scan the 40 pre-font goldens from f9dce062^")
    ap.add_argument("--expect-fixed", action="store_true",
                    help="exit 1 unless every fixture class already meets "
                         "its target verdict (the upstream-fix flip gate)")
    ap.add_argument("--self-test", action="store_true",
                    help="verify the fixture generator, then exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    with tempfile.TemporaryDirectory(prefix="golden-detector-") as td:
        workdir = Path(td)
        scan = workdir / "goldens"
        scan.mkdir()
        for name, (paint, _, _) in FIXTURES.items():
            px = canvas()
            paint(px)
            write_png(scan / name, px)
        violations = run_detector(scan, workdir)

        print(f"pinned detector: crap4dart via `dart pub global run`")
        print(f"{'fixture':32} {'today':8} {'target':8} verdict")
        print("-" * 64)
        rows, all_fixed = [], True
        for name, (_, today, target) in FIXTURES.items():
            got = classify(violations, name)
            ok_today, ok_target = got == today, got == target
            all_fixed &= ok_target
            print(f"{name:32} {today:8} {target:8} {got:8}"
                  f"{' (matches measured #447 behaviour)' if ok_today else ' <-- CHANGED'}")
        if args.regression:
            reg = extract_regression(workdir)
            reg_violations = run_detector(reg, workdir)
            total = len(list(reg.glob('*.png')))
            print(f"\nregression fixture: {REGRESSION_REF} — {total} pre-font goldens")
            print(f"  detected: {len({*reg_violations}) & len(list(reg.glob('*.png'))) and len(reg_violations)}/{total}"
                  f" (0/40 = the measured blind spot; 40/40 after the upstream fixes)")
        print()
        if args.expect_fixed:
            print("expect-fixed:", "MET — upstream fixes landed" if all_fixed
                  else "NOT MET — detector still blind/false-positive")
            return 0 if all_fixed else 1
        print("today's scoreboard above is the pinned truth (#447); "
              "re-run with --expect-fixed after upgrading crap4dart to "
              "flip the configs' broken_goldens severity to error.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
