#!/usr/bin/env python3
"""fa-setup.sh.j2 pre-seeds a system-level git identity (gh-1210).

The template runs in every terminal-bench task container at install time;
git-touching tasks (configure-git-webserver, sanitize-git-repo,
git-workflow-hack, fix-git) used to burn agent turns discovering and
working around `Author identity unknown` before attempting the task.

Run: python3 -m unittest discover -s bench/terminal_bench
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent

SEED_SENTINEL = "__SETUP_STILL_ALIVE__"

try:
    from jinja2 import StrictUndefined, Template
except ImportError:  # the template has no placeholders; raw text suffices
    Template = None


def render_setup_script() -> str:
    """Render the install template the way AbstractInstalledAgent does."""
    text = (HERE / "fa-setup.sh.j2").read_text()
    if Template is not None:
        # The script uses no variables; StrictUndefined keeps that enforced
        # (a future placeholder fails loudly instead of rendering empty).
        return Template(text, undefined=StrictUndefined).render({})
    return text


def git_identity_block(script: str) -> str:
    """The AND-OR list pre-seeding the identity (may span physical lines)."""
    lines = script.splitlines()
    start = next(
        (i for i, l in enumerate(lines) if l.startswith("command -v git")), None
    )
    if start is None:
        raise AssertionError("git identity seed block not found in fa-setup.sh.j2")
    block = [lines[start]]
    while block[-1].rstrip().endswith("&&") and start + len(block) < len(lines):
        block.append(lines[start + len(block)])
    return "\n".join(block)


class TemplateShapeTest(unittest.TestCase):
    def setUp(self):
        self.script = render_setup_script()

    def test_script_is_valid_posix_sh(self):
        subprocess.run(
            ["sh", "-n"], input=self.script, text=True, check=True
        )

    def test_identity_seeded_at_system_scope(self):
        # System scope: repo-local / task-specific config still wins.
        block = git_identity_block(self.script)
        self.assertIn("git config --system user.name fa-bench", block)
        self.assertIn("git config --system user.email fa@bench.local", block)

    def test_guard_precedes_the_writes(self):
        # Images without git must not abort the install (`set -e` ignores a
        # failed non-final command of an && list).
        self.assertTrue(git_identity_block(self.script).startswith("command -v git"))

    def test_identity_seeded_after_bundle_untar(self):
        lines = self.script.splitlines()
        untar = next(i for i, l in enumerate(lines) if l.startswith("tar -xzf"))
        seed = next(i for i, l in enumerate(lines) if l.startswith("command -v git"))
        self.assertGreater(seed, untar)


@unittest.skipUnless(shutil.which("git"), "git not available")
class IdentityBehaviorTest(unittest.TestCase):
    def setUp(self):
        self.block = git_identity_block(render_setup_script())

    def _env(self, system_cfg: Path, home: Path) -> dict:
        # GIT_CONFIG_SYSTEM redirects git's system scope for reads AND
        # writes, so the test never touches the real /etc/gitconfig.
        return dict(os.environ, GIT_CONFIG_SYSTEM=str(system_cfg), HOME=str(home))

    def test_writes_land_in_the_system_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = self._env(Path(tmp) / "gitconfig", Path(tmp))
            subprocess.run(["sh", "-ec", self.block], env=env, check=True)
            out = subprocess.run(
                ["git", "config", "--system", "--list"],
                env=env, capture_output=True, text=True, check=True,
            ).stdout
        self.assertIn("user.name=fa-bench", out.splitlines())
        self.assertIn("user.email=fa@bench.local", out.splitlines())

    def test_repo_local_config_still_wins(self):
        # The reason for --system scope: a task's own repo config keeps
        # precedence over the pre-seeded identity.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            env = self._env(root / "gitconfig", root)
            subprocess.run(["sh", "-ec", self.block], env=env, check=True)
            repo = root / "task-repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], env=env, check=True)
            subprocess.run(
                ["git", "config", "--local", "user.name", "task-user"],
                cwd=repo, env=env, check=True,
            )
            out = subprocess.run(
                ["git", "config", "user.name"],
                cwd=repo, env=env, capture_output=True, text=True, check=True,
            ).stdout
        self.assertEqual(out.strip(), "task-user")

    def test_missing_git_is_a_noop_under_set_e(self):
        # A bare failing `git config` under `set -e` would abort the whole
        # install on git-less images; the guard must keep the script alive.
        proc = subprocess.run(
            ["sh", "-ec", f"PATH=/nonexistent; {self.block}\necho {SEED_SENTINEL}"],
            capture_output=True, text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(SEED_SENTINEL, proc.stdout)


class SeedFailureGuardTest(unittest.TestCase):
    """Every failure path of the seed list must keep the install alive.

    `set -e` exempts the non-final commands of an && list but NOT the final
    one — so a failed `user.email` write aborts the whole install unless the
    list ends in `|| true`. A fake `git` shim pinpoints each write path; no
    real git is needed for these.
    """

    def setUp(self):
        self.block = git_identity_block(render_setup_script())

    def _run_with_git_shim(self, fail_on: str) -> subprocess.CompletedProcess:
        # The shim dir is PREPENDED to PATH inside the child shell, so the
        # outer `sh` still resolves while `git` resolves to the shim.
        with tempfile.TemporaryDirectory() as tmp:
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            git_sh = bindir / "git"
            git_sh.write_text(
                f'#!/bin/sh\ncase "$*" in *{fail_on}*) exit 128;; *) exit 0;; esac\n'
            )
            git_sh.chmod(0o755)
            return subprocess.run(
                ["sh", "-ec",
                 f"PATH={bindir}:$PATH; {self.block}\necho {SEED_SENTINEL}"],
                capture_output=True, text=True,
            )

    def test_failing_user_name_write_is_a_noop_under_set_e(self):
        # A failed `user.name` write is a NON-final command of the && list,
        # so `set -e` exempts it — the install must continue.
        proc = self._run_with_git_shim("user.name")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(SEED_SENTINEL, proc.stdout)

    def test_failing_user_email_write_is_a_noop_under_set_e(self):
        # The `user.email` write is the FINAL command of the && list, so it
        # is NOT exempt: without the trailing `|| true` the whole install
        # aborts right here (gh-1210 review). The guard must keep it alive.
        proc = self._run_with_git_shim("user.email")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn(SEED_SENTINEL, proc.stdout)


if __name__ == "__main__":
    unittest.main()
