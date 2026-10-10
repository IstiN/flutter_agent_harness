#!/usr/bin/env python3
"""Per-artifact uncompressed size manifest + budget gate (#1096 AC1).

Emits the per-entry uncompressed size table (the issue's inventory format)
for a shipped artifact and fails the build when any tracked line regresses
beyond the budget (default +5%).

Usage:
  size_manifest.py emit   <artifact> [--min-bytes N]        # TSV to stdout
  size_manifest.py check  <artifact> --baseline FILE
                          [--budget-pct 5] [--init-if-missing]
                          [--manifest-out FILE] [--forbid REGEX]...
                          [--vendored REGEX]... [--strict-vendored]
  size_manifest.py selftest

`<artifact>` is a zip-family file (.zip/.ipa/.aab — uncompressed entry sizes
via zipfile) or a directory (tree of file sizes, for the web deploy root).

Manifest format (TSV; every row is `<bytes>\t<name>`, path-sorted. TOTAL
is an ordinary row — `<total_bytes>\tTOTAL` — and sorts among the paths;
do not rely on its position, the parser keys by name):
  <uncompressed_bytes>\t<path>
  <total_bytes>\tTOTAL

Rev-hash path normalization (#1431): a path segment of 20+ hex chars is
a content/rev-hash directory — the Flutter engine renderer artifacts
(canvaskit/skwasm) move under a new one on every 3.47.x patch drop while
the byte sizes stay identical. Both the artifact scan and the baseline
load collapse such segments to `<rev>` BEFORE diffing, so an engine rev
bump lands as an in-place UPDATE (the usual size-band compare) instead
of N brand-new heavyweight lines. Normalization is idempotent, so
pre-fix baselines carrying the literal rev hash migrate on load — no
baseline rewrite needed. Colliding normalized rows (two rev dirs in one
artifact, e.g. stale files) merge to the heavier one.

Gate semantics (`check`):
  - growth > budget%% on any baseline line or on the first-party TOTAL
    -> FAIL
  - NEW line heavier than 5%% of the baseline first-party TOTAL -> FAIL
    (catches re-adding removed weight, e.g. a dropped interpreter coming
    back — re-growth must be a conscious ack)
  - VENDORED carve-out (#1431): rows under a vendored prefix (default:
    the canvaskit/ engine-renderer subtree; extend with --vendored
    REGEX) are engine payload, not our growth — their breaches print
    ::warning and stay out of the failure count, and they are excluded
    from the TOTAL the budget compares (first-party TOTAL = TOTAL minus
    vendored rows). The engine reving is not the payload growing.
    --strict-vendored turns the carve-out off (everything gates again).
  - removed lines are improvements, reported only
  - --init-if-missing: no baseline file yet -> write it and pass with a
    loud notice (ratchet bootstrap; commit the file to arm the gate)
  - --reseed: overwrite an EXISTING baseline from this artifact and pass
    with a notice — the escape hatch for intentional growth; commit the
    rewritten file to make the new shape the floor
  - --forbid REGEX (repeatable): any manifest row whose path matches
    REGEX fails the check immediately, regardless of the +5% budget or
    the NEW-line share — the deny-list for evicted artifacts (a re-added
    5.6 MB fixture slips under both: NEW share is 5% of TOTAL). Enforced
    on check, --init-if-missing AND --reseed: re-admitting an artifact
    means dropping its --forbid flag, a conscious ack. The deny-list
    floor equals the tracking floor: sub-MIN_BYTES rows never enter the
    manifest.

CI escape hatch for intentional growth: re-run locally with the same
artifact and `--reseed`, commit the rewritten baseline.
"""

import argparse
import re
import sys
import zipfile
from pathlib import Path

# Per-line tracking floor: smaller files are noise (thousands of them
# jitter by whole percentages); the TOTAL line covers their aggregate.
MIN_BYTES = 64 * 1024
# A brand-new tracked line heavier than this share of the old first-party
# TOTAL is re-growth, not rounding — fail it.
NEW_LINE_SHARE = 0.05
# A path segment of 20+ hex chars is a content/rev-hash directory: the
# Flutter engine renderer artifacts (canvaskit/skwasm wasm) ship under
# `canvaskit/<rev>/` and the rev changes on every 3.47.x patch drop
# (#1431). Collapsed to <rev> on BOTH the artifact scan and the baseline
# load so rev churn diffs as an in-place UPDATE, not N new lines.
REV_SEGMENT_RE = re.compile(r"(^|/)[0-9a-fA-F]{20,}(?=/|$)")
REV_PLACEHOLDER = "<rev>"
# Rows matching a vendored prefix are engine/vendor payload: their
# breaches warn instead of failing (#1431). The canvaskit/ subtree
# carries every engine renderer artifact (canvaskit/skwasm/wimp/
# webparagraph, chromium variant included). First-party paths —
# including our own shipped vendor/interpreters payload — keep the
# full rule.
VENDORED_DEFAULTS = [r"(^|/)canvaskit/"]


def normalize_revpaths(name: str) -> str:
    """Collapse 20+hex path segments (engine rev dirs) to <rev> (#1431)."""
    return REV_SEGMENT_RE.sub(lambda m: m.group(1) + REV_PLACEHOLDER, name)


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
    manifest = {}
    for p, n in sizes.items():
        if n < min_bytes:
            continue
        key = normalize_revpaths(p)
        # Two rev dirs in one artifact (stale files) collide post-
        # normalization: keep the heavier row on both floor and current.
        if key not in manifest or manifest[key] < n:
            manifest[key] = n
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
        key = normalize_revpaths(name)  # pre-fix literal-rev rows migrate
        if key not in baseline or baseline[key] < int(size):
            baseline[key] = int(size)
    if "TOTAL" not in baseline:
        raise SystemExit(f"size_manifest: baseline {path} has no TOTAL line")
    return baseline


def write_baseline(path: Path, manifest: "dict[str, int]") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{manifest[p]}\t{p}" for p in sorted(manifest)]
    path.write_text("\n".join(lines) + "\n")


def check(artifact: Path, baseline_path: Path, budget_pct: float,
          init_if_missing: bool = False, reseed: bool = False,
          manifest_out=None, forbid=None, vendored=None,
          strict_vendored=False) -> int:
    manifest = build_manifest(artifact, MIN_BYTES)
    if manifest_out:
        write_baseline(manifest_out, manifest)

    # Deny-list (gh-1331 review): a returning evicted artifact fails the
    # gate in every mode — budget and NEW-line share both miss sub-5%
    # re-adds, so eviction is pinned by pattern, not by the floor.
    forbid_res = [re.compile(p) for p in forbid or []]
    if forbid_res:
        banned = [name for name in sorted(manifest)
                  if name != "TOTAL" and any(r.search(name) for r in forbid_res)]
        if banned:
            for name in banned:
                print(f"::error::size_manifest: FORBIDDEN row in {artifact}: "
                      f"{name} ({manifest[name]} bytes) — matches --forbid; "
                      "the artifact was evicted and must not return")
            return 1

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
    failures, vendored_failures = [], []
    grew, shrank, new, removed = [], [], [], []

    # Vendored carve-out (#1431): engine/vendor rows breach with a
    # ::warning and never redden the job; the budget's TOTAL compares the
    # first-party aggregate only. --strict-vendored gives the teeth back.
    vendored_res = ([] if strict_vendored
                    else [re.compile(p) for p in VENDORED_DEFAULTS + list(vendored or [])])

    def is_vendored(name: str) -> bool:
        return any(r.search(name) for r in vendored_res)

    def fp_total(manifest: "dict[str, int]") -> int:
        return manifest["TOTAL"] - sum(n for k, n in manifest.items()
                                       if k != "TOTAL" and is_vendored(k))

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
            line = f"  GREW    +{pct:6.1f}%  {name}  {old} -> {cur}"
            (vendored_failures if is_vendored(name) else failures).append(line)
    cur_fp, base_fp = fp_total(manifest), fp_total(baseline)
    fp_total_pct = (cur_fp - base_fp) / base_fp * 100 if base_fp else 0.0
    if fp_total_pct > budget_pct:
        failures.append(f"  TOTAL-1P +{fp_total_pct:6.1f}%  {base_fp} -> {cur_fp} "
                        f"(first-party TOTAL; raw {base_total} -> {manifest['TOTAL']})")
    for name, cur in new:
        if cur > NEW_LINE_SHARE * base_fp:
            line = (f"  NEW     {'':>8}  {name}  {cur} bytes "
                    f"(> {NEW_LINE_SHARE:.0%} of baseline first-party TOTAL)")
            (vendored_failures if is_vendored(name) else failures).append(line)

    print(f"size manifest: {artifact}  (budget: +{budget_pct}% per line, "
          f"baseline: {baseline_path})")
    print(fmt_table(manifest))
    if vendored_failures:
        print(f"::warning::size budget: {len(vendored_failures)} vendored "
              f"line(s) breached in {artifact} — engine/vendor churn, not "
              f"gating (first-party floor untouched):")
        for f in vendored_failures:
            print(f)
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
    print(f"size budget OK (first-party TOTAL {fp_total_pct:+.1f}% vs baseline)")
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

        # Deny-list (gh-1331 review): a re-added evicted row below the
        # NEW-line share (5% of TOTAL) passes the plain gate — only
        # --forbid catches it. Floor: 8 MiB TOTAL -> NEW share ~410 KB;
        # the re-added 100 KB row is tracked (> 64 KB) but sub-share.
        deny_zip, deny_base = td / "deny.zip", td / "deny.tsv"
        make_zip(deny_zip, 100 * 1024, {"bin/big.bin": 8 * 1024 * 1024})
        expect("deny floor seeds", check(deny_zip, deny_base, 5.0, init_if_missing=True), 0)
        make_zip(cur_zip, 100 * 1024,
                 {"bin/big.bin": 8 * 1024 * 1024, "evicted/gone.dat": 100 * 1024})
        expect("re-added sub-NEW-share row passes without --forbid",
               check(cur_zip, deny_base, 5.0), 0)
        expect("re-added row fails with --forbid",
               check(cur_zip, deny_base, 5.0, forbid=["^evicted/"]), 1)
        expect("clean artifact passes with --forbid",
               check(deny_zip, deny_base, 5.0, forbid=["^evicted/"]), 0)
        expect("--forbid blocks reseeding the banned shape",
               check(cur_zip, deny_base, 5.0, reseed=True, forbid=["^evicted/"]), 1)

        # Rev-hash churn (#1431): the engine renderer moves under a new
        # 20+hex rev dir on every 3.47.x patch — pure path substitution,
        # identical bytes. Normalization must diff it as a no-op UPDATE,
        # not N brand-new heavyweight lines; vendored breaches warn; the
        # first-party rule keeps its teeth.
        rev_zip, rev_base = td / "rev.zip", td / "rev.tsv"
        old_rev, new_rev = "a" * 40, "b" * 40

        def make_rev_zip(path: Path, rev: str):
            with zipfile.ZipFile(path, "w") as zf:
                zf.writestr(f"panel/app/canvaskit/{rev}/canvaskit.wasm",
                            b"\0" * (7 * 1024 * 1024))
                zf.writestr(f"panel/app/canvaskit/{rev}/canvaskit.js",
                            b"\0" * (90 * 1024))
                zf.writestr("panel/app/main.dart.js", b"\0" * (1024 * 1024))

        make_rev_zip(rev_zip, old_rev)
        expect("rev baseline seeds", check(rev_zip, rev_base, 5.0, init_if_missing=True), 0)
        make_rev_zip(rev_zip, new_rev)
        expect("rev-dir rename is a no-op UPDATE", check(rev_zip, rev_base, 5.0), 0)
        with zipfile.ZipFile(rev_zip, "a") as zf:
            zf.writestr(f"panel/app/canvaskit/{new_rev}/skwasm_new.wasm",
                        b"\0" * (6 * 1024 * 1024))
        expect("new vendored heavyweight warns (passes)", check(rev_zip, rev_base, 5.0), 0)
        expect("strict mode gates the vendored file",
               check(rev_zip, rev_base, 5.0, strict_vendored=True), 1)
        with zipfile.ZipFile(rev_zip, "a") as zf:
            zf.writestr("panel/app/newbin/heavy.bin", b"\0" * (6 * 1024 * 1024))
        expect("new first-party heavyweight still fails", check(rev_zip, rev_base, 5.0), 1)
        # A pre-fix baseline carrying the literal rev hash migrates on load.
        literal_base = td / "rev_literal.tsv"
        literal_base.write_text(
            f"{7 * 1024 * 1024}\tpanel/app/canvaskit/{old_rev}/canvaskit.wasm\n"
            f"{90 * 1024}\tpanel/app/canvaskit/{old_rev}/canvaskit.js\n"
            f"{1024 * 1024}\tpanel/app/main.dart.js\n"
            f"{7 * 1024 * 1024 + 90 * 1024 + 1024 * 1024}\tTOTAL\n")
        make_rev_zip(rev_zip, new_rev)
        expect("literal-rev baseline migrates on load", check(rev_zip, literal_base, 5.0), 0)

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
    p_chk.add_argument("--forbid", action="append", default=[], metavar="REGEX",
                       help="deny-list: fail if any manifest row path matches "
                            "REGEX (repeatable; enforced on check/init/reseed)")
    p_chk.add_argument("--vendored", action="append", default=[], metavar="REGEX",
                       help="extra vendored-prefix regex: breaches on matching "
                            "rows warn instead of failing (#1431; repeatable, "
                            "extends the built-in canvaskit/ default)")
    p_chk.add_argument("--strict-vendored", action="store_true",
                       help="disable the vendored carve-out — every breach "
                            "fails, engine-renderer churn included")

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
                     manifest_out=args.manifest_out, forbid=args.forbid,
                     vendored=args.vendored,
                     strict_vendored=args.strict_vendored)
    return selftest()


if __name__ == "__main__":
    sys.exit(main())
