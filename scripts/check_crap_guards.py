#!/usr/bin/env python3
"""CRAP ratchet config guards (issue #433).

Three checks over every `crap4dart.yaml` in the repo:

1. Badge sync (AC1): the README shields badge for a package must encode
   the SAME threshold as that package's `crap4dart.yaml`
   (`CRAP%20max-<N>` for the core, `CRAP%20app-<N>` for flutter_app).
   They drifted once already (badge 8.0 vs threshold 12.0).
2. Exclude parity (E1): both configs must exclude the same generated-code
   patterns, so generated drift cannot open a CRAP hole in one package.
3. Only-down (AC3): a config's `crap.threshold` may never RISE above the
   threshold recorded in git history at the base ref — the ratchet, like
   the coverage baseline, goes only down. New config files (bootstrap)
   are allowed.

Usage:
  python3 scripts/check_crap_guards.py                 # badge + parity
  python3 scripts/check_crap_guards.py --only-down SHA # + git-history guard
  python3 scripts/check_crap_guards.py --self-test     # fixture checks

Exit 0 = all green, 1 = any guard failed, 2 = usage error.
"""

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# package key -> (config path relative to repo root, README badge marker).
# The badge URL encodes the threshold as .../badge/<marker><value>-<color>.
# ponytail: fixed map, not discovery — adding a third package is one entry
# plus its crap4dart.yaml.
PACKAGES = {
    "core": ("crap4dart.yaml", "CRAP%20max-"),
    "flutter_app": ("flutter_app/crap4dart.yaml", "CRAP%20app-"),
}

README = "README.md"

# Generated-code exclude patterns that MUST be present in every package's
# config (E1). Extra package-specific excludes (e.g. core's vendor/**)
# are allowed and unchecked.
GENERATED_EXCLUDES = {"**.g.dart", "**.freezed.dart", "**.mocks.dart", "build/**"}


def parse_config(path: Path):
    """Returns (threshold, excludes) or None when the file does not exist.

    crap4dart 0.2.1 rejects unknown keys, so a `threshold:` line in a
    valid config can only be `crap.threshold`; the `exclude:` block is
    the top-level list. A line-walker beats a yaml dependency here.
    """
    if not path.exists():
        return None
    threshold = None
    excludes = []
    in_exclude = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if not line[0].isspace():
            in_exclude = line.strip() == "exclude:"
            continue
        # crap4dart 0.2.1 allows `threshold:` only under `crap:`, so an
        # indented `threshold:` line IS the CRAP threshold.
        m = re.fullmatch(r"threshold:\s*([0-9.]+)\s*", line.strip())
        if m:
            threshold = float(m.group(1))
        elif in_exclude:
            m = re.fullmatch(r'-\s+["\']?(.+?)["\']?\s*', line.strip())
            if m:
                excludes.append(m.group(1))
    if threshold is None:
        raise SystemExit(f"{path}: no `threshold:` found — malformed config?")
    return threshold, frozenset(excludes)


def read_threshold_at(ref: str, rel_path: str):
    """Threshold of `rel_path` as of git `ref`, or None when absent there."""
    proc = subprocess.run(
        ["git", "show", f"{ref}:{rel_path}"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as tmp:
        tmp.write(proc.stdout)
        tmp_path = Path(tmp.name)
    try:
        return parse_config(tmp_path)[0]
    finally:
        tmp_path.unlink()


def check_badges(root: Path):
    """AC1: every existing config's threshold must match its README badge."""
    readme = (root / README).read_text(encoding="utf-8")
    failures = []
    checked = 0
    for name, (rel, marker) in PACKAGES.items():
        cfg = parse_config(root / rel)
        if cfg is None:
            continue  # package not bootstrapped yet — nothing to assert
        checked += 1
        threshold = cfg[0]
        m = re.search(re.escape(marker) + r"([0-9.]+)", readme)
        if m is None:
            failures.append(
                f"{README}: no badge for {name} (expected .../badge/"
                f"{marker}<threshold>) while {rel} pins {threshold}"
            )
            continue
        badge = float(m.group(1))
        if badge != threshold:
            failures.append(
                f"{README}: {name} badge says CRAP {badge} but {rel} "
                f"pins {threshold} — sync them"
            )
    return checked, failures


def check_exclude_parity(root: Path):
    """E1: both configs must carry the same generated-code exclude set."""
    failures = []
    found_any = False
    for name, (rel, _) in PACKAGES.items():
        cfg = parse_config(root / rel)
        if cfg is None:
            continue
        found_any = True
        missing = GENERATED_EXCLUDES - cfg[1]
        if missing:
            failures.append(
                f"{rel}: generated-code excludes drifted — missing {sorted(missing)} "
                f"(must match the other package's generated set)"
            )
    return found_any, failures


def check_only_down(root: Path, base_ref: str):
    """AC3: no config's threshold may rise above its base-ref value."""
    failures = []
    for name, (rel, _) in PACKAGES.items():
        current = parse_config(root / rel)
        if current is None:
            continue
        base = read_threshold_at(base_ref, rel)
        if base is None:
            continue  # new config (bootstrap) — nothing recorded yet
        if current[0] > base + 1e-9:
            failures.append(
                f"{rel}: threshold rose {base} -> {current[0]} since {base_ref} "
                f"— the CRAP ratchet is only-down; fix code, not config"
            )
    return failures


def self_test():
    """Fixture-driven checks for every guard mode (AC1 RED/GREEN, E1, AC3)."""
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        def write(readme_badge, yaml_threshold, excludes=GENERATED_EXCLUDES):
            (root / README).write_text(
                f"[![x](https://img.shields.io/badge/CRAP%20max-{readme_badge}"
                f"-brightgreen)](https://example.com)\n",
                encoding="utf-8",
            )
            (root / "crap4dart.yaml").write_text(
                "sources: [lib]\n"
                "exclude:\n"
                + "".join(f"  - '{p}'\n" for p in sorted(excludes))
                + f"crap:\n  threshold: {yaml_threshold}\n",
                encoding="utf-8",
            )

        # AC1 RED: badge drifted from threshold.
        write("8.0", 12.0)
        _, fails = check_badges(root)
        if not fails:
            failures.append("self-test: badge drift was NOT detected")

        # AC1 GREEN: equal.
        write("12.0", 12.0)
        checked, fails = check_badges(root)
        if fails or checked != 1:
            failures.append(f"self-test: equal badge flagged {fails}")

        # E1: missing generated exclude.
        write("12.0", 12.0, GENERATED_EXCLUDES - {"build/**"})
        _, fails = check_exclude_parity(root)
        if not fails:
            failures.append("self-test: exclude drift was NOT detected")

        # AC3 needs git history: create a repo with a lowered threshold.
        (root / "crap4dart.yaml").write_text(
            "sources: [lib]\ncrap:\n  threshold: 12.0\n", encoding="utf-8"
        )
        env_git = ["git", "-C", str(root)]
        for cmd in (
            ["init", "-q"],
            ["config", "user.email", "t@t"],
            ["config", "user.name", "t"],
            ["add", "."],
            ["commit", "-qm", "base"],
        ):
            subprocess.run(env_git + cmd, capture_output=True, check=True)
        subprocess.run(
            env_git + ["mv", "crap4dart.yaml", "base.yaml"], capture_output=True
        )
        (root / "crap4dart.yaml").write_text(
            "sources: [lib]\ncrap:\n  threshold: 40.0\n", encoding="utf-8"
        )
        for cmd in (["add", "."], ["commit", "-qm", "raise"]):
            subprocess.run(env_git + cmd, capture_output=True, check=True)
        raised = check_only_down(root, "HEAD~1")
        if not raised:
            failures.append("self-test: threshold raise was NOT detected")
        # The same diff lowered (40 -> 12 reversed) must pass.
        (root / "crap4dart.yaml").write_text(
            "sources: [lib]\ncrap:\n  threshold: 12.0\n", encoding="utf-8"
        )
        lowered = check_only_down(root, "HEAD~1")
        if lowered:
            failures.append(f"self-test: lowering flagged: {lowered}")

    if failures:
        print("\n".join(failures))
        return 1
    print("self-test OK: badge sync, exclude parity, only-down all verified")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only-down",
        metavar="BASE_REF",
        help="also assert thresholds did not rise since BASE_REF (git history)",
    )
    parser.add_argument(
        "--self-test", action="store_true", help="run fixture checks and exit"
    )
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    root = Path(subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True,
    ).stdout.strip())

    failures = []
    checked, badge_fails = check_badges(root)
    if checked:
        print(f"badge sync: {checked} config/badge pair(s) checked")
    failures += badge_fails
    found, parity_fails = check_exclude_parity(root)
    if found:
        print("exclude parity: generated patterns asserted in every config")
    failures += parity_fails
    if args.only_down:
        failures += check_only_down(root, args.only_down)

    if failures:
        print("\n".join(f"❌ {f}" for f in failures), file=sys.stderr)
        print("CRAP config guards FAILED", file=sys.stderr)
        return 1
    print("✅ CRAP config guards OK (badge sync, exclude parity"
          + (", only-down" if args.only_down else "") + ")")
    return 0


if __name__ == "__main__":
    sys.exit(main())
