#!/usr/bin/env python3
"""Per-artifact uncompressed size manifest + budget gate (#1096 AC1).

Emits the per-entry uncompressed size table (the issue's inventory format)
for a shipped artifact and fails the build when any tracked line regresses
beyond the budget (default +5%).

Usage:
  size_manifest.py emit   <artifact> [--min-bytes N]        # TSV to stdout
  size_manifest.py check  <artifact> --baseline FILE
                          [--budget-pct 5] [--init-if-missing]
                          [--manifest-out FILE]
  size_manifest.py selftest

`<artifact>` is a zip-family file (.zip/.ipa/.aab — uncompressed entry sizes
via zipfile) or a directory (tree of file sizes, for the web deploy root).

Manifest format (TSV; every row is `<bytes>\t<name>`, path-sorted. TOTAL
is an ordinary row — `<total_bytes>\tTOTAL` — and sorts among the paths;
do not rely on its position, the parser keys by name):
  <uncompressed_bytes>\t<path>
  <total_bytes>\tTOTAL

Gate semantics (`check`):
  - growth > budget%% on any baseline line or on TOTAL  -> FAIL
  - NEW line heavier than 5%% of the baseline TOTAL     -> FAIL
    (catches re-adding removed weight, e.g. a dropped interpreter coming
    back; canvaskit rev-dir churn on Flutter upgrades trips this too —
    that is by design: re-growth must be a conscious ack)
  - removed lines are improvements, reported only
  - --init-if-missing: no baseline file yet -> write it and pass with a
    loud notice (ratchet bootstrap; commit the file to arm the gate)
  - --reseed: overwrite an EXISTING baseline from this artifact and pass
    with a notice — the escape hatch for intentional growth; commit the
    rewritten file to make the new shape the floor

CI escape hatch for intentional growth: re-run locally with the same
artifact and `--reseed`, commit the rewritten baseline.
"""

import argparse
import sys
import zipfile
from pathlib import Path

# Per-line tracking floor: smaller files are noise (thousands of them
# jitter by whole percentages); the TOTAL line covers their aggregate.
MIN_BYTES = 64 * 1024
# A brand-new tracked line heavier than this share of the old TOTAL is
# re-growth, not rounding — fail it.
NEW_LINE_SHARE = 0.05


def iter_sizes(artifact: Path):
    """Yield (path, uncompressed_bytes) for every file in the artifact."""
    if artifact.is_file():
        # zip-family: .zip / .ipa / .aab / .apk
        with zipfile.ZipFile(artifact) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                yield info.filename.replace("\t", " "), info.file_size
        return
    if artifact.is_dir():
        for p in sorted(artifact.rglob("*")):
            if p.is_file() and not p.is_symlink():
                yield p.relative_to(artifact).as_posix().replace("\t", " "), p.stat().st_size
        return
    raise SystemExit(f"size_manifest: artifact not found: {artifact}")


def build_manifest(artifact: Path, min_bytes: int) -> "dict[str, int]":
    sizes = dict(iter_sizes(artifact))
    manifest = {p: n for p, n in sizes.items() if n >= min_bytes}
    manifest["TOTAL"] = sum(sizes.values())
    return manifest


def fmt_table(manifest: "dict[str, int]") -> str:
    width = max((len(p) for p in manifest), default=5)
    lines = [f"{manifest[p]:>12}  {p.ljust(width)}" for p in sorted(manifest) if p != "TOTAL"]
    lines.append("-" * (width + 14))
    lines.append(f"{manifest['TOTAL']:>12}  TOTAL")
    return "\n".join(lines)


def load_baseline(path: Path) -> "dict[str, int]":
    baseline = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        size, _, name = line.partition("\t")
        baseline[name] = int(size)
    if "TOTAL" not in baseline:
        raise SystemExit(f"size_manifest: baseline {path} has no TOTAL line")
    return baseline


def write_baseline(path: Path, manifest: "dict[str, int]") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{manifest[p]}\t{p}" for p in sorted(manifest)]
    path.write_text("\n".join(lines) + "\n")


def check(artifact: Path, baseline_path: Path, budget_pct: float,
          init_if_missing: bool = False, reseed: bool = False,
          manifest_out=None) -> int:
    manifest = build_manifest(artifact, MIN_BYTES)
    if manifest_out:
        write_baseline(manifest_out, manifest)

    if not baseline_path.exists():
        if init_if_missing:
            write_baseline(baseline_path, manifest)
            print(f"::notice::size_manifest: baseline initialized from this "
                  f"artifact — COMMIT {baseline_path} to arm the gate")
            print(fmt_table(manifest))
            return 0
        print(f"::error::size_manifest: baseline {baseline_path} missing "
              f"(run with --init-if-missing to seed it)")
        return 2

    if reseed:
        write_baseline(baseline_path, manifest)
        print(f"::notice::size_manifest: baseline RESEEDED from this "
              f"artifact — {baseline_path} rewritten; COMMIT it to make "
              f"the new shape the floor")
        print(fmt_table(manifest))
        return 0

    baseline = load_baseline(baseline_path)
    base_total = baseline["TOTAL"]
    failures = []
    grew, shrank, new, removed = [], [], [], []

    for name in sorted(set(baseline) | set(manifest)):
        if name == "TOTAL":
            continue
        old, cur = baseline.get(name), manifest.get(name)
        if old is None and cur is not None:
            new.append((name, cur))
        elif cur is None:
            removed.append((name, old))
        elif cur > old:
            grew.append((name, old, cur))
        elif cur < old:
            shrank.append((name, old, cur))

    for name, old, cur in grew:
        pct = (cur - old) / old * 100 if old else float("inf")
        if pct > budget_pct:
            failures.append(f"  GREW    +{pct:6.1f}%  {name}  {old} -> {cur}")
    total_pct = (manifest["TOTAL"] - base_total) / base_total * 100 if base_total else 0.0
    if total_pct > budget_pct:
        failures.append(f"  TOTAL   +{total_pct:6.1f}%  {base_total} -> {manifest['TOTAL']}")
    for name, cur in new:
        if cur > NEW_LINE_SHARE * base_total:
            failures.append(f"  NEW     {'':>8}  {name}  {cur} bytes "
                            f"(> {NEW_LINE_SHARE:.0%} of baseline TOTAL)")

    print(f"size manifest: {artifact}  (budget: +{budget_pct}% per line, "
          f"baseline: {baseline_path})")
    print(fmt_table(manifest))
    if shrank:
        print(f"improvements: {len(shrank)} line(s) shrank, "
              f"{len(removed)} line(s) removed")
        for name, old, cur in shrank[:10]:
            print(f"  shrank  {name}  {old} -> {cur}")
        for name, old in removed[:10]:
            print(f"  removed {name}  ({old} bytes)")
    if failures:
        print(f"::error::size budget regression in {artifact} "
              f"({len(failures)} line(s) beyond +{budget_pct}%):")
        for f in failures:
            print(f)
        print("intentional growth? re-seed the floor with: python3 "
              "scripts/size_manifest.py check <artifact> --baseline "
              f"{baseline_path} --reseed")
        return 1
    print(f"size budget OK (TOTAL {total_pct:+.1f}% vs baseline)")
    return 0


def selftest() -> int:
    """Synthetic-artifact assertions; exits nonzero on any failure."""
    import tempfile

    ok = True

    def expect(label, actual, wanted):
        nonlocal ok
        status = "ok" if actual == wanted else "FAIL"
        if actual != wanted:
            ok = False
        print(f"  [{status}] {label}: exit {actual} (want {wanted})")

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)

        def make_zip(path: Path, a_size: int, extra: "dict[str, int] | None" = None):
            with zipfile.ZipFile(path, "w") as zf:
                zf.writestr("bin/a.bin", b"\0" * a_size)
                zf.writestr("bin/b.bin", b"\0" * (10 * 1024))
                for name, size in (extra or {}).items():
                    zf.writestr(name, b"\0" * size)

        base_zip, cur_zip = td / "base.zip", td / "cur.zip"
        make_zip(base_zip, 100 * 1024)
        make_zip(cur_zip, 100 * 1024)
        base = td / "base.tsv"
        r = check(cur_zip, base, 5.0, init_if_missing=True)
        expect("init-if-missing seeds + passes", r, 0)

        make_zip(cur_zip, 104 * 1024)  # +4%: within budget
        expect("within-budget growth passes", check(cur_zip, base, 5.0), 0)

        make_zip(cur_zip, 106 * 1024)  # +6%: regression
        expect("over-budget growth fails", check(cur_zip, base, 5.0), 1)

        make_zip(cur_zip, 100 * 1024, {"bin/new.bin": 6 * 1024 * 1024})
        expect("heavy new line fails", check(cur_zip, base, 5.0), 1)

        make_zip(cur_zip, 80 * 1024)  # still tracked (> 64 KB), 20% smaller
        expect("tracked-line shrink passes", check(cur_zip, base, 5.0), 0)

        make_zip(cur_zip, 106 * 1024)  # reseed overwrites an EXISTING baseline
        expect("reseed rewrites + passes", check(cur_zip, base, 5.0, reseed=True), 0)
        expect("smaller-than-floor still passes", check(base_zip, base, 5.0), 0)
        bigger = td / "bigger.zip"
        make_zip(bigger, 120 * 1024)  # +13% vs the reseeded floor
        expect("post-reseed regrowth fails", check(bigger, base, 5.0), 1)

        tree = td / "root" / "app"
        (tree / "assets").mkdir(parents=True)
        (tree / "index.html").write_bytes(b"\0" * (200 * 1024))
        (tree / "assets" / "x.bin").write_bytes(b"\0" * (150 * 1024))
        dir_base = td / "dir.tsv"
        expect("dir artifact init", check(tree, dir_base, 5.0, init_if_missing=True), 0)
        (tree / "index.html").write_bytes(b"\0" * (220 * 1024))  # +10%
        expect("dir over-budget fails", check(tree, dir_base, 5.0), 1)

    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_emit = sub.add_parser("emit", help="print the TSV manifest")
    p_emit.add_argument("artifact", type=Path)
    p_emit.add_argument("--min-bytes", type=int, default=MIN_BYTES)

    p_chk = sub.add_parser("check", help="manifest + budget gate")
    p_chk.add_argument("artifact", type=Path)
    p_chk.add_argument("--baseline", type=Path, required=True)
    p_chk.add_argument("--budget-pct", type=float, default=5.0)
    p_chk.add_argument("--init-if-missing", action="store_true")
    p_chk.add_argument("--reseed", action="store_true",
                       help="overwrite an EXISTING baseline from this "
                            "artifact and pass (intentional-growth escape "
                            "hatch; commit the rewritten file)")
    p_chk.add_argument("--manifest-out", type=Path)

    sub.add_parser("selftest", help="synthetic end-to-end assertions")

    args = ap.parse_args()
    if args.cmd == "emit":
        manifest = build_manifest(args.artifact, args.min_bytes)
        for name in sorted(manifest):
            print(f"{manifest[name]}\t{name}")
        return 0
    if args.cmd == "check":
        return check(args.artifact, args.baseline, args.budget_pct,
                     args.init_if_missing, reseed=args.reseed,
                     manifest_out=args.manifest_out)
    return selftest()


if __name__ == "__main__":
    sys.exit(main())
