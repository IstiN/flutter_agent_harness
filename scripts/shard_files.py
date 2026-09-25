#!/usr/bin/env python3
"""Print the test dirs/files of one shard from scripts/test_shards.json.

Usage:
    python3 scripts/shard_files.py <manifest> <index> [--exclude STR]...

Output: one path per line, suitable for
    dart test $(python3 scripts/shard_files.py scripts/test_shards.json 0)

Directory units are printed as-is (dart test accepts directories). The
special unit "test" (loose *_test.dart files at the test root) is expanded
to the individual root-level files so that `dart test` does not run the
entire suite. File-level manifests (every *_test.dart is a unit — e.g.
packages/fa_ui, issue #283) print their units directly.

Top-level test dirs that exist on disk but are MISSING from the manifest
(a PR added one after the last weekly rebalance) are bin-packed across the
shards at runtime by file count, so new suites run this PR — not at some
future rebalance (issue #194, AC5). For file-level manifests the same
runtime bin-pack applies per uncovered FILE (issue #283, E2).
test/integration is excluded from the core shards: issue #551 gives it a
dedicated per-PR gate stage (no-key legs) plus the tag-only provider smoke.
--exclude STR
drops paths containing STR (e.g. golden — host-locked suites stay out of
the shards even when a PR adds one post-rebalance, issue #283 E4).
--tags TAG (issue #931, integration shards)
inverts the integration exclusion: only files whose @Tags annotation names
TAG are bin-packed as uncovered, so an INTEGRATION manifest (e.g.
scripts/test_integration_shards.json) auto-runs a PR's new integration
tests — and never swallows untagged core files.

Pure stdlib.
"""

import glob
import json
import os
import re
import sys


def uncovered_units(covered: set, root: str) -> list:
    """Top-level test dirs missing from the manifest, as (path, filecount)."""
    out = []
    for entry in sorted(os.listdir(root)):
        path = os.path.join(root, entry)
        if entry == "integration" or path in covered or not os.path.isdir(path):
            continue  # integration runs in its own CI job
        files = glob.glob(os.path.join(path, "**", "*_test.dart"), recursive=True)
        if files:
            out.append((path.replace(os.sep, "/"), len(files)))
    return out


def file_has_tag(path: str, tag: str) -> bool:
    """True when the file's real (non-comment) code names `tag` in @Tags([...])."""
    try:
        with open(path, encoding="utf-8") as f:
            head = f.read()
    except OSError:
        return False
    # Full read: a truncated scan would silently drop a tagged file from
    # the bin-pack safety net; @Tags lives anywhere in the file's metadata.
    # But match CODE only — strip the `//` portion of every line first. A
    # `///` doc comment that merely MENTIONS `@Tags(['io', 'integration'])`
    # once phantom-tagged test/cli/fah_hub_serve_dispatch_test.dart into
    # the integration manifest (review #963): the file has no integration
    # tag and the shard step runs zero tests from it.
    code = "\n".join(re.sub(r"//.*", "", line) for line in head.splitlines())
    return re.search(r"@Tags\s*\(\s*\[[^\]]*['\"]" + re.escape(tag) + r"['\"]", code) is not None


def uncovered_files(covered: set, root: str, exclude: list,
                    required_tag=None) -> list:
    """Individual test files missing from a file-level manifest, as (path, 1).

    Default (no required_tag): files under test/ excluding integration and
    --exclude matches — the core/faui manifests. With required_tag (e.g.
    the integration shards, issue #931): only files whose @Tags annotation
    names the tag — an integration manifest must never bin-pack untagged
    core files (they would be filtered out by --tags anyway, but selecting
    them is noise) and must NOT skip test/integration.
    """
    out = []
    for path in sorted(glob.glob(os.path.join(root, "**", "*_test.dart"), recursive=True)):
        norm = path.replace(os.sep, "/")
        if any(x in norm for x in exclude):
            continue
        if required_tag is None:
            if "/integration/" in norm:
                continue  # integration runs in its own CI job; excludes stay out
        elif not file_has_tag(path, required_tag):
            continue
        if norm not in covered:
            out.append((norm, 1))
    return out


def bin_pack_by_count(units: list, n: int) -> list:
    buckets = [[] for _ in range(n)]
    loads = [0] * n
    for unit, count in sorted(units, key=lambda u: -u[1]):
        i = loads.index(min(loads))
        buckets[i].append(unit)
        loads[i] += count
    return buckets


def main() -> int:
    argv = sys.argv[1:]
    exclude = []
    tags = []
    while "--exclude" in argv or "--tags" in argv:
        for flag, sink in (("--exclude", exclude), ("--tags", tags)):
            while flag in argv:
                i = argv.index(flag)
                try:
                    sink.append(argv[i + 1])
                except IndexError:
                    print(f"ERROR: {flag} needs a value", file=sys.stderr)
                    return 2
                del argv[i:i + 2]
    if len(tags) > 1:
        print("ERROR: --tags supports one value (multi-tag "
              "selection is not defined for shard manifests)", file=sys.stderr)
        return 2
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    manifest_path, index_s = argv
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot read manifest {manifest_path}: {e}", file=sys.stderr)
        return 1
    try:
        index = int(index_s)
        shards = manifest["shards"]
        shard = shards[index]
    except (ValueError, KeyError, IndexError):
        print(f"ERROR: no shard with index {index_s} in {manifest_path}", file=sys.stderr)
        return 1

    # Loose root files expand via glob below, so only directory units can
    # go stale; anything new under test/ runs THIS PR, not next rebalance.
    covered = {u for s in shards for u in s}
    file_level = any(u.replace(os.sep, "/").endswith("_test.dart")
                     for s in shards for u in s)
    if file_level:
        # File-level manifest (issue #283): bin-pack uncovered FILES.
        extra = uncovered_files(covered, "test", exclude,
                                required_tag=(tags[0] if tags else None))
    else:
        extra = uncovered_units(covered, "test")
    if extra:
        print(
            "WARNING: test dirs missing from the manifest (new since the "
            f"last rebalance?): {[u for u, _ in extra]}; bin-packing by "
            "file count at runtime",
            file=sys.stderr,
        )
    extra_bucket = bin_pack_by_count(extra, len(shards))[index]

    for unit in list(shard) + extra_bucket:
        if os.path.isdir(unit):
            if os.path.normpath(unit) == "test":
                # Loose root files only — never the directory itself.
                for f in sorted(glob.glob(os.path.join(unit, "*_test.dart"))):
                    print(f.replace(os.sep, "/"))
            else:
                print(unit)
        elif os.path.isfile(unit):
            print(unit)
        else:
            print(f"WARNING: shard unit not found: {unit}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
