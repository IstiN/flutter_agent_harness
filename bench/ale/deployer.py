"""FaDeployer — drives the fa coding agent on an ALE task VM.

Modeled on ``ale_run/agents/claude_code/deployer.py`` (the canonical
sandbox-CLI deployer, upstream doc "Build on ALE → Add an agent") with
fa's invocation contract from ``bench/harbor_fa/fa_agent.py``:

* install(): fetch the fa bundle release asset in-VM (pinned sha256),
  unpack to the install prefix, shim `fa` on PATH, write
  ``~/.fah/config.yaml`` (autopilot approval + the cua MCP bridge so
  fa gets the GUI action space), ensure the bridge at
  ``sandbox.mcp_server_dir``, probe ``fa --version``.
* launch(prompt): spawn ``fa --session-root <wd>/fah-sessions -p
  <prompt>`` detached, poll with the round-3 stall/ceiling watch
  (knobs via config — see FaConfig), reap the process group on
  cancellation (ALE's wall budget wraps launch() in asyncio.wait_for),
  then best-effort export the ATIF trajectory (``fa trajectory export
  --format atif`` — the conversion logic lives in ONE place, Dart).
* parse_artifacts(): map the exported ATIF-v1.7 JSON onto the
  TrajectoryBuilder (contract cross-validated upstream-side by
  bench/harbor_fa/test_atif_contract.py against fixtures/atif_sample.json).

Pure Python stdlib + ale_run.base_interface imports, exactly like the
shipped reference deployers — whatever substrate the framework places
the deployer in, the agent code is identical.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import signal
import subprocess
import time
import urllib.request
from pathlib import Path
from typing import Any, ClassVar

from ale_run.base_interface import (
    AgentRunResult,
    BaseAgentDeployer,
    ContentPart,
    Observation,
    StepMetrics,
    ToolCall,
    ToolResult,
    TrajectoryBuilder,
)

from .config import FaConfig

# Shared timeout-knob machinery (bench/fa_agent_timeout.py at repo root;
# build_run.py stage copies it NEXT TO this file when vendoring into the
# ALE checkout as ale_run/agents/fa_code/). Try the staged flat copy
# first, fall back to the repo layout (bench/ parent dir) so the same
# file works in both.
try:  # staged: fa_code/fa_agent_timeout.py
    from .fa_agent_timeout import CapResolution, TimeoutKnobs, resolve_deadline
except ImportError:  # repo layout: bench/fa_agent_timeout.py
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from fa_agent_timeout import CapResolution, TimeoutKnobs, resolve_deadline  # noqa: E402

logger = logging.getLogger(__name__)

_POLL_INTERVAL_S = 2.0
_TERM_GRACE_S = 10.0
_DOWNLOAD_TIMEOUT_S = 300.0
# gh-1681 Gap 2 parity: the ATIF export reads the session ledger through
# fa's bounded chunked scan — seconds in practice; the cap bounds a
# wedged VM only. Never masks the trial's own outcome.
_ATIF_EXPORT_TIMEOUT_S = 180.0
# In-container job-log dir OUTSIDE any graded workspace (issue #1408
# AC1, same constant as the terminal-bench + harbor adapters — a
# relocation must move all three adapters together).
_FAH_JOB_LOG_DIR = "/tmp/fa-harness-artifacts/bash_jobs"

_SESSION_ROOT_NAME = "fah-sessions"
_ATIF_FILENAME = "trajectory-atif.json"
_STDOUT_FILENAME = "fa-stdout.log"
_STDERR_FILENAME = "stderr.log"
_AUDIT_FILENAME = "fa-timeout-metadata.json"


def _kill_process_group(proc: subprocess.Popen, sig: int) -> None:
    """Signal the fa process GROUP (start_new_session made pgid == pid).

    fa spawns bash jobs; a bare proc.terminate() would reap only the CLI
    and orphan its children. No os.killpg on Windows — fall back to the
    direct child (docker-profile ALE tasks are linux-only anyway).
    """
    try:
        if hasattr(os, "killpg"):
            os.killpg(proc.pid, sig)
        else:
            proc.send_signal(sig)
    except (ProcessLookupError, PermissionError):
        pass


class FaDeployer(BaseAgentDeployer):
    """Stdlib-only deployer for the fa CLI, vendored as fa_code."""

    # Sandbox executor only: fa is a coding agent whose native bash/file
    # tools must run ON the task machine — that is exactly what the
    # sandbox executor provides (the deployer runs inside the VM; local
    # and docker executors would point fa's tools at the wrong host).
    default_executor: ClassVar[str] = "sandbox"
    supported_executors: ClassVar[frozenset[str]] = frozenset({"sandbox"})

    # Tail the run output + stderr off the VM while the agent runs, so a
    # killed 5h-class trial still leaves a partial trace.
    hot_artifacts: ClassVar[tuple[str, ...]] = (
        _STDOUT_FILENAME,
        _STDERR_FILENAME,
    )

    def __init__(self, executor: Any) -> None:
        super().__init__(executor)
        self._fa_version: str | None = None

    # ─────────────────────────────────────────────────────────── install ──

    async def install(self) -> None:
        cfg: FaConfig = self.config  # type: ignore[assignment]
        sandbox = self.executor.sandbox
        wd = Path(self.executor.work_dir)
        wd.mkdir(parents=True, exist_ok=True)

        # 1. fetch + unpack the pinned bundle (in-VM; the framework ships
        #    only ale_run/**, so the bundle arrives by release URL).
        fah_bin = await asyncio.to_thread(
            self._install_bundle, cfg, wd
        )

        # 2. PATH shim (best-effort: probes and launch use the resolved
        #    binary path directly, so a denied /usr/local/bin write is
        #    cosmetic, never fatal).
        await asyncio.to_thread(self._shim, fah_bin)

        # 3. CA roots bootstrap — same best-effort shape as the harbor
        #    adapter's install (a thin image without CA roots dies with
        #    CERTIFICATE_VERIFY_FAILED on the provider handshake).
        await asyncio.to_thread(self._bootstrap_ca)

        # 4. ~/.fah/config.yaml: autopilot approval (no user in the
        #    loop) + the cua MCP bridge (GUI action space; fa's native
        #    bash/file tools already run on the task machine — an
        #    in-sandbox agent takes only the GUI bridge, per ALE docs).
        await asyncio.to_thread(
            self._write_fah_config, cfg, sandbox
        )
        from ale_run.agents._bootstrap import ensure_cua_mcp_server

        await ensure_cua_mcp_server(sandbox)

        # 5. prove it runs.
        version = await asyncio.to_thread(self._probe_version, fah_bin)
        self._fa_version = version
        logger.info("fa deployer: installed fa %s at %s", version, fah_bin)

    def _install_bundle(self, cfg: FaConfig, wd: Path) -> Path:
        """Download, verify, unpack; return the resolved bin/fah path."""
        prefix = Path(cfg.install_prefix)
        tarball = wd / "fa-bundle.tar.gz"
        unpack = wd / "fa-unpack"

        req = urllib.request.Request(  # noqa: S310 — pinned https URL
            cfg.bundle_url, headers={"User-Agent": "fa-ale-deployer"}
        )
        with urllib.request.urlopen(  # noqa: S310
            req, timeout=_DOWNLOAD_TIMEOUT_S
        ) as resp:
            data = resp.read()
        import hashlib

        if cfg.bundle_sha256:
            digest = hashlib.sha256(data).hexdigest()
            if digest != cfg.bundle_sha256:
                raise RuntimeError(
                    f"fa bundle sha256 mismatch: expected {cfg.bundle_sha256}, "
                    f"got {digest} ({cfg.bundle_url})"
                )
        tarball.write_bytes(data)

        shutil.rmtree(unpack, ignore_errors=True)
        unpack.mkdir(parents=True)
        subprocess.run(
            ["tar", "-xzf", str(tarball), "-C", str(unpack)],
            check=True,
            timeout=120,
        )
        candidates = sorted(
            p for p in unpack.rglob("fah") if p.is_file() and p.parent.name == "bin"
        )
        if not candidates:
            raise RuntimeError(
                f"fa bundle has no bin/fah under {unpack} — is this a "
                f"fa-linux-x64.tar.gz release asset?"
            )
        bundle_root = candidates[0].parent.parent  # …/bin/fah → bundle root

        shutil.rmtree(prefix, ignore_errors=True)
        prefix.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(bundle_root), str(prefix))
        fah_bin = prefix / "bin" / "fah"
        fah_bin.chmod(0o755)
        return fah_bin

    @staticmethod
    def _shim(fah_bin: Path) -> None:
        shim = Path("/usr/local/bin/fa")
        try:
            shim.parent.mkdir(parents=True, exist_ok=True)
            if shim.is_symlink() or shim.exists():
                shim.unlink()
            shim.symlink_to(str(fah_bin))
        except OSError as exc:
            logger.warning("fa deployer: PATH shim skipped (%s)", exc)

    @staticmethod
    def _bootstrap_ca() -> None:
        if Path("/etc/ssl/certs/ca-certificates.crt").exists():
            return
        try:
            subprocess.run(
                ["apt-get", "update", "-qq"],
                check=True,
                timeout=120,
                stdin=subprocess.DEVNULL,
            )
            subprocess.run(
                ["apt-get", "install", "-y", "-qq", "ca-certificates"],
                check=True,
                timeout=300,
                stdin=subprocess.DEVNULL,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            logger.warning("fa deployer: CA bootstrap skipped (%s)", exc)

    @staticmethod
    def _yaml_str(value: str) -> str:
        """One deterministic YAML double-quoted scalar (JSON escaping is
        valid YAML flow-scalar escaping)."""
        return json.dumps(value)

    def _write_fah_config(self, cfg: FaConfig, sandbox: Any) -> None:
        """Write ~/.fah/config.yaml with approval mode + the cua bridge.

        Paths are READ from the sandbox handle, never hardcoded (the
        one ALE deployer rule): node binary + mcp_server_dir come from
        the image's declared conventions.
        """
        from ale_run.agents._bootstrap import cua_bridge_env

        is_linux = bool(sandbox.is_linux)
        index_js = self._join(sandbox.mcp_server_dir, "src", "index.js", is_linux=is_linux)
        bridge_env = cua_bridge_env(self.executor)
        lines = [
            "# Written by the fa ALE deployer (FaDeployer.install) — do not edit.",
            "approvalMode: autopilot",
            "mcp:",
            f"  toolCallTimeoutMs: {int(cfg.mcp_tool_call_timeout_ms)}",
            "  servers:",
            "    cua:",
            f"      command: {self._yaml_str(str(sandbox.node))}",
            "      args:",
            f"        - {self._yaml_str(index_js)}",
            "      env:",
        ]
        for key in sorted(bridge_env):
            lines.append(
                f"        {self._yaml_str(key)}: {self._yaml_str(str(bridge_env[key]))}"
            )
        home = Path.home()
        fah_dir = home / ".fah"
        fah_dir.mkdir(parents=True, exist_ok=True)
        (fah_dir / "config.yaml").write_text("\n".join(lines) + "\n", encoding="utf-8")

    @staticmethod
    def _join(*parts: str, is_linux: bool) -> str:
        """OS-aware path join in the substrate convention (upstream
        claude_code deployer shape)."""
        sep = "/" if is_linux else "\\"
        head = parts[0].rstrip("/\\")
        tail = sep.join(p.strip("/\\") for p in parts[1:])
        return f"{head}{sep}{tail}" if tail else head

    def _probe_version(self, fah_bin: Path) -> str | None:
        try:
            probe = subprocess.run(
                [str(fah_bin), "--version"],
                capture_output=True,
                text=True,
                timeout=60,
                stdin=subprocess.DEVNULL,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        out = (probe.stdout or "") + (probe.stderr or "")
        return out.strip().splitlines()[0].strip() if probe.returncode == 0 and out.strip() else None

    @property
    def version(self) -> str | None:
        return self._fa_version

    # ───────────────────────────────────────────────────────────── launch ──

    def _knob_env(self, cfg: FaConfig) -> dict[str, str]:
        """Config knobs → the bench/fa_agent_timeout.py env contract.

        Absent knobs stay absent: the no-clock contract (fa never
        invents a clock the dispatch didn't declare).
        """
        env: dict[str, str] = {}
        if cfg.progress_extension:
            env["FA_PROGRESS_EXTENSION"] = "1"
        if cfg.stall_gap_sec is not None:
            env["FA_STALL_GAP_SEC"] = str(cfg.stall_gap_sec)
        if cfg.abs_ceiling_sec is not None:
            env["FA_AGENT_TIMEOUT_ABS_CEILING_SEC"] = str(cfg.abs_ceiling_sec)
        if cfg.external_cap_sec is not None:
            env["FA_EXTERNAL_CAP_SEC"] = str(cfg.external_cap_sec)
        return env

    def _child_env(self, cfg: FaConfig) -> tuple[dict[str, str], Any, float | None]:
        # Watch knobs (stall gap / abs ceiling) are extension-mode knobs:
        # without FA_PROGRESS_EXTENSION the knob module pins the
        # effective cap to the flat base (360s default) and fa would
        # self-terminate minutes into a 5h-class trial — a half-declared
        # watch is a surprise clock. Fail loud instead (AGENTS.md
        # round-3: never lie about the clock).
        watch_knob_set = (
            cfg.stall_gap_sec is not None or cfg.abs_ceiling_sec is not None
        )
        if watch_knob_set and not cfg.progress_extension:
            raise RuntimeError(
                "FaConfig: stall_gap_sec/abs_ceiling_sec require "
                "progress_extension=true — without the progress extension "
                "the effective cap collapses to the flat 360s base and fa "
                "would get a surprise clock"
            )
        env = os.environ.copy()
        for key, value in (self.executor.env or {}).items():
            env[key] = value
        # Provider preconfig + key ride the child env directly (dict
        # transport, no shell export lines — so plain forms, unlike the
        # harbor adapter's base64 twins). Values are never echoed.
        env["FA_PROVIDER_TYPE"] = cfg.provider_type
        env["FA_PROVIDER_CONFIG"] = cfg.provider_config
        key_var = json.loads(cfg.provider_config).get("apiKeyEnvVar")
        if key_var and cfg.api_key:
            env[key_var] = cfg.api_key
        env["FAH_JOB_LOG_DIR"] = _FAH_JOB_LOG_DIR

        knob_env = self._knob_env(cfg)
        knobs = TimeoutKnobs.from_env(knob_env)
        cap, deadline = resolve_deadline(knobs, env=knob_env)
        if deadline is not None:
            env["FA_DEADLINE_EPOCH_MS"] = str(deadline)
        return env, cap, deadline

    async def launch(self, prompt: str) -> AgentRunResult:
        cfg: FaConfig = self.config  # type: ignore[assignment]
        wd = Path(self.executor.work_dir)
        wd.mkdir(parents=True, exist_ok=True)
        sessions = wd / _SESSION_ROOT_NAME

        prompt_file = wd / "prompt.txt"
        stdout_log = wd / _STDOUT_FILENAME
        stderr_log = wd / _STDERR_FILENAME
        pid_file = wd / "fa.pid"
        for f in (stdout_log, stderr_log, pid_file):
            f.unlink(missing_ok=True)
        prompt_file.write_text(prompt, encoding="utf-8")

        fah_bin = Path(cfg.install_prefix) / "bin" / "fah"
        if not fah_bin.exists():
            fah_bin = Path(shutil.which("fa") or (fah_bin))
        # shlex-free argv list: backticks/$()/markdown in task prompts
        # reach fa verbatim (same reason the harbor adapter quotes).
        argv = [str(fah_bin), "--session-root", str(sessions), "-p", prompt]
        env, cap, _deadline = self._child_env(cfg)

        t0 = time.monotonic()
        outcome = "completed"
        with open(stdout_log, "wb") as tout, \
                open(stderr_log, "wb") as terr:
            proc = await asyncio.to_thread(
                subprocess.Popen,
                argv,
                stdin=subprocess.DEVNULL,
                stdout=tout,
                stderr=terr,
                env=env,
                cwd=str(wd),
                start_new_session=True,
            )
        pid_file.write_text(str(proc.pid), encoding="ascii")
        logger.info("fa deployer: spawned pid=%s (cap=%s)", proc.pid, cap)

        cancelled = False
        try:
            outcome = await self._watch(proc, wd, cfg, t0)
        except asyncio.CancelledError:
            cancelled = True
            outcome = "external_kill"
            _kill_process_group(proc, signal.SIGTERM)
            try:
                await asyncio.wait_for(
                    asyncio.to_thread(proc.wait), timeout=_TERM_GRACE_S
                )
            except (asyncio.TimeoutError, asyncio.CancelledError):
                _kill_process_group(proc, signal.SIGKILL)
                await asyncio.to_thread(proc.wait)
            raise
        finally:
            self._write_audit(wd, cfg, cap, outcome, proc, t0, cancelled)

        duration_s = time.monotonic() - t0
        exit_code = proc.returncode
        status = "completed" if exit_code == 0 else "failed"
        atif = await self._export_atif(fah_bin, sessions, wd)
        error = None
        if status == "failed":
            error = _tail(stderr_log) or _tail(stdout_log) or f"fa exited {exit_code}"
        return AgentRunResult(
            status=status,
            transcript_path=str(atif) if atif else None,
            stderr_path=str(stderr_log),
            pid=proc.pid,
            exit_code=exit_code,
            duration_s=duration_s,
            error=error,
        )

    async def _watch(
        self,
        proc: subprocess.Popen,
        wd: Path,
        cfg: FaConfig,
        t0: float,
    ) -> str:
        """Poll loop with the round-3 stall/ceiling watch.

        Progress = combined growth of the tee'd output streams (the same
        signal the harbor adapter's progress watch measures). Only
        declared knobs can kill — with no knobs this is a plain join and
        ALE's wall budget stays the authoritative kill.
        """
        stdout_log = wd / _STDOUT_FILENAME
        stderr_log = wd / _STDERR_FILENAME
        last_size = 0
        last_progress = time.monotonic()
        while proc.poll() is None:
            await asyncio.sleep(_POLL_INTERVAL_S)
            now = time.monotonic()
            size = _safe_size(stdout_log) + _safe_size(stderr_log)
            if size > last_size:
                last_size = size
                last_progress = now
            if cfg.abs_ceiling_sec is not None and now - t0 >= cfg.abs_ceiling_sec:
                logger.warning("fa deployer: abs ceiling %.0fs hit", cfg.abs_ceiling_sec)
                await self._reap(proc)
                return "agent_timeout"
            if cfg.stall_gap_sec is not None and now - last_progress >= cfg.stall_gap_sec:
                logger.warning(
                    "fa deployer: stall %.0fs (no output growth)", cfg.stall_gap_sec
                )
                await self._reap(proc)
                return "agent_timeout"
        return "completed" if proc.returncode == 0 else "failed"

    async def _reap(self, proc: subprocess.Popen) -> None:
        _kill_process_group(proc, signal.SIGTERM)
        try:
            await asyncio.wait_for(
                asyncio.to_thread(proc.wait), timeout=_TERM_GRACE_S
            )
        except (asyncio.TimeoutError, asyncio.CancelledError):
            _kill_process_group(proc, signal.SIGKILL)
            await asyncio.to_thread(proc.wait)

    async def _export_atif(
        self, fah_bin: Path, sessions: Path, wd: Path
    ) -> Path | None:
        """Best-effort `fa trajectory export --format atif`. Never raises;
        a missing export degrades to parse_artifacts' system note."""
        atif = wd / _ATIF_FILENAME
        cmd = [
            str(fah_bin),
            "--session-root",
            str(sessions),
            "trajectory",
            "export",
            "--format",
            "atif",
            "--output",
            str(atif),
        ]
        try:
            proc = await asyncio.to_thread(
                subprocess.Popen, cmd,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
            )
            await asyncio.wait_for(
                asyncio.to_thread(proc.wait), timeout=_ATIF_EXPORT_TIMEOUT_S
            )
            if proc.returncode != 0:
                logger.warning(
                    "fa deployer: ATIF export exited %s: %s",
                    proc.returncode,
                    (proc.stderr.read() or b"")[-200:].decode(errors="replace"),
                )
        except (OSError, subprocess.SubprocessError, asyncio.TimeoutError) as exc:
            logger.warning("fa deployer: ATIF export failed: %s", exc)
        return atif if atif.exists() else None

    def _write_audit(
        self,
        wd: Path,
        cfg: FaConfig,
        cap: CapResolution | None,
        outcome: str,
        proc: subprocess.Popen,
        t0: float,
        cancelled: bool,
    ) -> None:
        """One audit record per trial: outcome class + the exact cap
        resolution that produced the deadline fa saw (AGENTS.md round-3
        audit contract; no env dumps — the key never lands here)."""
        audit: dict[str, Any] = {
            "outcome": outcome,
            "cancelled": cancelled,
            "exit_code": proc.returncode if proc.poll() is not None else None,
            "duration_s": round(time.monotonic() - t0, 2),
            "knobs": {
                "progress_extension": cfg.progress_extension,
                "stall_gap_sec": cfg.stall_gap_sec,
                "abs_ceiling_sec": cfg.abs_ceiling_sec,
                "external_cap_sec": cfg.external_cap_sec,
            },
            "cap_resolution": (
                {
                    "winning_cap_source": cap.winning_cap_source,
                    "effective_cap_sec": cap.effective_cap_sec,
                    "knob_cap_sec": cap.knob_cap_sec,
                    "external_cap_sec": cap.external_cap_sec,
                    "external_cap_status": cap.external_cap_status,
                }
                if cap is not None
                else None
            ),
        }
        (wd / _AUDIT_FILENAME).write_text(
            json.dumps(audit, indent=2) + "\n", encoding="utf-8"
        )

    # ──────────────────────────────────────────────── parse_artifacts ──

    @classmethod
    def parse_artifacts(
        cls,
        *,
        work_dir: Path,
        config: Any,
        run_result: AgentRunResult,
        builder: TrajectoryBuilder,
    ) -> None:
        """ATIF-v1.7 → TrajectoryBuilder. Pure; runs host-side on the
        gathered work_dir. Missing/cut-off export = one system note."""
        path = Path(work_dir) / _ATIF_FILENAME
        if not path.exists():
            builder.add_step(
                "system",
                message="no fa trajectory (ATIF export missing from work_dir)",
            )
            return
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except ValueError as exc:
            builder.add_step("system", message=f"fa trajectory unparsable: {exc}")
            return
        for step in data.get("steps") or []:
            builder.add_step(**atif_step_kwargs(step))
        final = data.get("final_metrics") or {}
        builder.override_final_metrics(
            total_input_tokens=final.get("total_prompt_tokens"),
            total_output_tokens=final.get("total_completion_tokens"),
            total_cache_read_tokens=final.get("total_cached_tokens"),
            total_cost_usd=final.get("total_cost_usd"),
        )


def atif_step_kwargs(step: dict[str, Any]) -> dict[str, Any]:
    """Map ONE ATIF step dict onto TrajectoryBuilder.add_step kwargs.

    Exported for tests (the fixture contract is cross-validated with
    bench/harbor_fa/test_atif_contract.py's atif_sample.json).
    """
    source = {"user": "user", "system": "system", "agent": "agent"}.get(
        step.get("source"), "system"
    )
    kwargs: dict[str, Any] = {"source": source}
    if step.get("message") is not None:
        kwargs["message"] = str(step["message"])
    if step.get("reasoning_content"):
        kwargs["reasoning"] = str(step["reasoning_content"])
    calls = []
    for call in step.get("tool_calls") or []:
        calls.append(
            ToolCall(
                id=str(call.get("tool_call_id", "")),
                name=str(call.get("function_name", "")),
                arguments=call.get("arguments") or {},
            )
        )
    if calls:
        kwargs["tool_calls"] = calls
    obs = step.get("observation")
    if obs:
        results = []
        for res in obs.get("results") or []:
            content = res.get("content")
            results.append(
                ToolResult(
                    tool_call_id=str(res.get("source_call_id", "")),
                    content=[
                        ContentPart(type="text", text=content)
                        if isinstance(content, str)
                        else ContentPart(type="text", text=json.dumps(content))
                    ],
                    is_error=bool(res.get("is_error", False)),
                )
            )
        kwargs["observation"] = Observation(results=results)
    metrics = step.get("metrics")
    if metrics:
        kwargs["metrics"] = StepMetrics(
            input_tokens=_int_or_none(metrics.get("prompt_tokens")),
            output_tokens=_int_or_none(metrics.get("completion_tokens")),
            cache_read_tokens=_int_or_none(metrics.get("cached_tokens")),
            cost_usd=_float_or_none(metrics.get("cost_usd")),
        )
    return kwargs


def _int_or_none(value: Any) -> int | None:
    try:
        return None if value is None else int(value)
    except (TypeError, ValueError):
        return None


def _float_or_none(value: Any) -> float | None:
    try:
        return None if value is None else float(value)
    except (TypeError, ValueError):
        return None


def _safe_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def _tail(path: Path, limit: int = 400) -> str | None:
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return None
    return text[-limit:] or None
