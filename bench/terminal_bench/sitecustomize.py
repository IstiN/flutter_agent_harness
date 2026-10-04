"""Make tb's docker compose failures visible on CI (gh-1208).

tb's DockerComposeManager runs compose with capture_output=True and logs
the captured stdout/stderr at DEBUG level only — CI runs at INFO, so a
compose build failure surfaces as a bare CalledProcessError and diagnosing
task-image rot costs a full local repro (gh-1208: two CI runs burned before
anyone saw `git clone` fail on a deleted GitHub repo).

This module is auto-imported by python's `site` startup whenever
bench/terminal_bench is on PYTHONPATH — which bench/terminal_bench/run.sh
and the Bench workflow already do for every `tb run`. It installs a
post-import hook that patches DockerComposeManager the moment
terminal_bench.terminal.docker_compose_manager is first imported (no eager
tb import: pulling the package costs ~4 s and would tax every python
startup). On a compose failure the captured output is re-logged at ERROR
(tail-capped) before the original exception re-raises — log level and exit
code are unchanged.

Opt-out: FA_TB_LOG_COMPOSE_FAILURES=0 (or false) disables the hook entirely.
Stdlib only, like the other bench scripts.
"""
import importlib.abc
import importlib.util
import logging
import os
import subprocess
import sys

_TARGET_MODULE = "terminal_bench.terminal.docker_compose_manager"
_TARGET_CLASS = "DockerComposeManager"
_TARGET_METHOD = "_run_docker_compose_command"
_TAIL_CAP = 32 * 1024  # per stream; a build log's fatal tail is what matters

_installed = False


def _tail(text):
    if text is None:
        return ""
    text = str(text)
    if len(text) <= _TAIL_CAP:
        return text
    return "[...truncated...]\n" + text[-_TAIL_CAP:]


def _patch(module):
    manager = getattr(module, _TARGET_CLASS, None)
    original = getattr(manager, _TARGET_METHOD, None) if manager else None
    if original is None:
        # API drift: tb restructured the compose manager. Never break the
        # run over a logging nicety — say so once, loudly, and move on.
        print(
            f"sitecustomize: {_TARGET_MODULE}.{_TARGET_CLASS}.{_TARGET_METHOD} "
            "not found; compose failure logging disabled",
            file=sys.stderr,
        )
        return
    original = original.__func__  # underlying plain function

    def logged_run(self, command, *_args, **_kwargs):
        try:
            return original(self, command, *_args, **_kwargs)
        except subprocess.CalledProcessError as exc:
            captured = _tail(exc.stdout) or _tail(exc.stderr)
            if captured:
                self._logger.error(
                    "docker compose %s failed with exit code %s; captured output:\n%s",
                    " ".join(str(part) for part in command),
                    exc.returncode,
                    captured,
                )
            raise

    setattr(manager, _TARGET_METHOD, logged_run)


class _ComposeLogHook(importlib.abc.MetaPathFinder):
    """Fire _patch exactly once, after the real module executes."""

    def __init__(self):
        self._finding = False

    def find_spec(self, fullname, path=None, target=None):
        if fullname != _TARGET_MODULE or self._finding:
            return None
        self._finding = True
        try:
            spec = importlib.util.find_spec(fullname)
        finally:
            self._finding = False
        if spec is None or spec.loader is None:
            return None
        original_exec = spec.loader.exec_module

        def exec_module(module, _original=original_exec):
            _original(module)
            try:
                _patch(module)
            except Exception as exc:  # never break tb over logging
                print(f"sitecustomize: compose log patch failed: {exc}", file=sys.stderr)

        spec.loader.exec_module = exec_module
        return spec


def install():
    """Install the post-import hook. Returns True when newly installed."""
    global _installed
    if _installed:
        return False
    flag = os.environ.get("FA_TB_LOG_COMPOSE_FAILURES", "1").strip().lower()
    if flag in ("0", "false", "off"):
        return False
    sys.meta_path.insert(0, _ComposeLogHook())
    _installed = True
    return True


try:
    install()
except Exception as exc:  # site startup must never fail over this
    print(f"sitecustomize: install failed: {exc}", file=sys.stderr)
