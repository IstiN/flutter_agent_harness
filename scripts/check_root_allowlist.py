#!/usr/bin/env python3
"""gh-2185 AC7 — repo-root allow-list guard.

The repository root carries ONLY first-class project artifacts (source,
docs, configs, CI). gh-2185 purged the runtime-state JSONs, the tracked
log, the 920-file root memory store and the duplicate-store dirs; this
guard keeps the root that way:

  1. TRACKED LENS — every depth-0 entry of `git ls-files` must be
     allow-listed. A stray new root file fails the gate (pre-commit via
     ci_fast_gate.sh stage_analyze; whole-tree in the CI `static` job).
  2. TEMPLATE CLASS (gh-2185 AC6) — any filesystem entry at the root
     whose name embeds an unexpanded `${...}` fails outright, tracked or
     not: that is the artifact class of the empty
     `${Directory.systemTemp.path}` directory the audit found (a Dart
     string template executed verbatim as a path). No shipped writer
     produces such names — grep evidence in the gh-2185 PR — so the only
     way one appears is the same quoting bug class again.

Allow-list additions are NOT mechanical: they need a card-visibility
review (add the entry here AND to the inventory table in the ticket/PR).

Usage:
  python3 scripts/check_root_allowlist.py [--repo <path>] [--self-test]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

# Depth-0 entries allowed to be tracked at the repo root (gh-2185 KEEP
# table minus the purged rows: runtime-state JSONs, logs/, memory/,
# goal/, knowledgebase/, tools/ are NOT here on purpose).
ALLOWED = frozenset({
    # tracked root configs/docs (the KEEP rows)
    ".crap-baseline.json",
    ".gitattributes",
    ".gitignore",
    ".pubignore",
    "AGENTS.md",
    "CHANGELOG.md",
    "CHANGELOG_ARCHIVE.md",  # release tooling reads it at the root (gh-1452)
    "GOAL.md",
    "LICENSE",
    "PRIVACY.md",
    "README.md",
    "SECURITY.md",
    "analysis_options.yaml",
    "crap4dart.yaml",
    "crap4dart.loc-scope.yaml",
    "dart_test.yaml",
    "install_local.sh",
    "pubspec.yaml",
    "pubspec_overrides.yaml",  # the vendor-fork switch — deliberate, docs/vendor.md
    # source / content dirs
    "bench",
    "bin",
    "blog",
    "browser_ext",
    "docs",
    "example",
    "flutter_app",
    "js-ext-registry",
    "lib",
    "office_addin",
    "packages",
    "prompts",
    "schema",
    "scripts",
    "sdk",  # sdk/web — the wire-protocol reference client (conformance-gated)
    "site",
    "store_artefacts",  # store-metadata changelogs (docs/agents/commits-releases.md)
    "test",
    "tool",  # ONE tool dir (gh-2185 AC9)
    "vendor",  # patched forks — rationale: docs/vendor.md
    "yoclip",  # fa promo-video workspace (binaries purged per-class)
    # curated agent-tooling state
    ".fah",
    ".github",
    ".kimi-code",
    ".dmtools",
    ".pr-assets",
})

STATE_DIR_HINT = (
    "runtime state belongs in .fah/state/ (app stores, via "
    "flutter_app/lib/services/app_state_paths.dart) or .fah/memory/ "
    "(project memory); logs/dumps are gitignored (logs/, test-results/, "
    "profile-reports/, generated/). See docs/agents/project-layout.md "
    "(repo-root hygiene contract). Allow-list additions need a "
    "card-visibility review — edit scripts/check_root_allowlist.py "
    "deliberately, never to silence the gate."
)

TEMPLATE_HINT = (
    "an entry whose NAME embeds an unexpanded ${...} template — the "
    "gh-2185 artifact class (a Dart string template executed verbatim as "
    "a path). Delete it and fix the writer that quoted the expression."
)


def tracked_root_entries(repo: str) -> set:
    out = subprocess.run(
        ["git", "ls-files"], cwd=repo, capture_output=True, text=True,
        check=True,
    ).stdout
    return {line.split("/", 1)[0] for line in out.splitlines() if line.strip()}


def template_named_entries(repo: str) -> list:
    return [e for e in sorted(os.listdir(repo)) if "${" in e]


def check(repo: str) -> int:
    failures = []

    stray = sorted(tracked_root_entries(repo) - ALLOWED)
    if stray:
        failures.append(
            "tracked root entries outside the allow-list:\n"
            + "\n".join(f"  - {e}" for e in stray)
            + f"\n{STATE_DIR_HINT}"
        )

    tmpl = template_named_entries(repo)
    if tmpl:
        failures.append(
            "template-named root entries (unexpanded ${...}):\n"
            + "\n".join(f"  - {e}" for e in tmpl)
            + f"\n{TEMPLATE_HINT}"
        )

    if failures:
        print("root allow-list guard: FAILED\n")
        for f in failures:
            print(f)
        return 1
    print(f"root allow-list guard: ok ({len(ALLOWED)} allow-listed entries)")
    return 0


def self_test() -> int:
    """Fixture repo: clean passes; a stray file and the ${...} template
    class both fail."""
    tmp = tempfile.mkdtemp(prefix="root-allowlist-selftest-")
    try:
        repo = os.path.join(tmp, "repo")
        os.makedirs(repo)
        git = lambda *a: subprocess.run(  # noqa: E731
            ["git", *a], cwd=repo,
            capture_output=True, text=True, check=True,
        )
        git("init", "-q")
        for name, content in (("README.md", "# t\n"), ("pubspec.yaml", "name: t\n")):
            with open(os.path.join(repo, name), "w") as fh:
                fh.write(content)
        git("add", "-A")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
        here = os.path.dirname(os.path.abspath(__file__))
        guard = os.path.join(here, "check_root_allowlist.py")

        def run(*args):
            return subprocess.run(
                [sys.executable, guard, *args], cwd=repo,
                capture_output=True, text=True,
            )

        r = run()
        if r.returncode != 0:
            print(f"self-test: clean fixture FAILED\n{r.stdout}{r.stderr}")
            return 1

        with open(os.path.join(repo, "chat_read_cursors.json"), "w") as fh:
            fh.write("{}\n")
        git("add", "-A")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "stray")
        r = run()
        if r.returncode != 1 or "chat_read_cursors.json" not in r.stdout:
            print(f"self-test: stray-file case FAILED\n{r.stdout}{r.stderr}")
            return 1

        os.makedirs(os.path.join(repo, "${Directory.systemTemp.path}"))
        r = run()
        if r.returncode != 1 or "systemTemp" not in r.stdout:
            print(f"self-test: template-entry case FAILED\n{r.stdout}{r.stderr}")
            return 1

        print("self-test: PASS (clean ok, stray fails, template class fails)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", default=os.getcwd(), help="repo root (default: cwd)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    return check(args.repo)


if __name__ == "__main__":
    sys.exit(main())
