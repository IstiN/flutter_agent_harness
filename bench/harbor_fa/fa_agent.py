"""Harbor adapter for the `fa` coding agent (flutter_agent_harness).

Same shape as the shipped cline-cli adapter: a BaseInstalledAgent that
uploads the `dart build cli` bundle into the task environment, installs it
to /opt/fa, and runs `fa -p "<instruction>"` as the environment's agent
user, so fa's bash/read/write tools operate on the container filesystem.
Reuses the legacy env-provider-preconfig contract from
bench/terminal_bench/fa_agent.py:

Host-side inputs (environment):
  FA_BUNDLE_TARBALL      tar.gz of a `dart build cli` bundle (bin/fah),
                         uploaded and extracted to /opt/fa by install().
  FA_PROVIDER_TYPE       provider kind (default: anthropic).
  FA_PROVIDER_CONFIG     JSON {"baseUrl": ..., "model": ..., "apiKeyEnvVar": ...}
                         (or FA_PROVIDER_CONFIG_BASE64).
  <apiKeyEnvVar>         the API key itself, e.g. FA_KEY_API_Z_AI_Z_AI.

  Timeout knobs (issue #1122): same env contract as
  bench/terminal_bench/fa_agent.py (shared bench/fa_agent_timeout.py) —
  FA_AGENT_TIMEOUT_SEC / FA_PROGRESS_EXTENSION / FA_AGENT_IDLE_WINDOW_SEC /
  FA_AGENT_CEILING_MULTIPLIER. With any knob set, run() supervises the fa
  exec under the progress-aware ladder (progress = growth of
  /logs/agent/fa.txt, the tee'd agent output that already exists) and
  kills + reports an asyncio.TimeoutError (harbor's native
  AgentTimeoutError classification) on stall or hard ceiling; the audit
  trail lands in /logs/agent/fa-timeout-metadata.json, synced back with
  the other agent logs. No knobs set => today's single awaited exec.

Usage:
  PYTHONPATH=bench/harbor_fa harbor run -d terminal-bench/terminal-bench@4.0.0 \
    -a fa_agent:FaAgent -e docker -m glm-5.3-flash
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import shlex
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import fa_agent_timeout as _timeout

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

# Shared extraction lives one level up (bench/fa_usage.py); PYTHONPATH only
# carries this dir.
_BENCH_DIR = str(Path(__file__).resolve().parent.parent)
if _BENCH_DIR not in sys.path:
    sys.path.insert(0, _BENCH_DIR)
import fa_usage  # noqa: E402

_VERSION = "0.1.0"

# Pinned $/Mtok table (data, not code) for est_cost_usd (issue #1123).
_PRICING_PATH = Path(__file__).resolve().parent.parent / "pricing.json"

# Sessions are written here inside the environment; harbor syncs /logs/agent
# back to the host trial dir after the trial (Trial._download_agent_logs).
_SESSION_ROOT = "/logs/agent/fah-sessions"

_POLL_SEC = 5.0
_AUDIT_PATH = "/logs/agent/fa-timeout-metadata.json"


class FaAgent(BaseInstalledAgent):
    @staticmethod
    def name() -> str:
        return "fa"

    def version(self) -> str | None:
        return self._version or _VERSION

    def get_version_command(self) -> str | None:
        return "fa --version"

    @property
    def _bundle_tarball(self) -> Path:
        return Path(os.environ.get("FA_BUNDLE_TARBALL", "fa-bundle.tar.gz"))

    @property
    def _provider_env(self) -> dict[str, str]:
        # Everything crosses base64-encoded: exec env values pass through
        # shell export lines, and base64 keeps arbitrary JSON/keys safe.
        # Secrets live env-only, never echoed (only masked in CI logs).
        env = {
            "FA_PROVIDER_TYPE": os.environ.get("FA_PROVIDER_TYPE", "anthropic"),
            "FA_PROVIDER_CONFIG_BASE64": _b64(os.environ["FA_PROVIDER_CONFIG"]),
        }
        key_var = json.loads(os.environ["FA_PROVIDER_CONFIG"]).get("apiKeyEnvVar")
        if key_var and os.environ.get(key_var):
            env[f"{key_var}_BASE64"] = _b64(os.environ[key_var])
        return env

    async def install(self, environment: BaseEnvironment) -> None:
        tarball = self._bundle_tarball
        if not tarball.is_file():
            raise FileNotFoundError(
                f"fa bundle tarball not found: {tarball} — build it with "
                f"`dart build cli --target=bin/fah.dart`"
            )
        remote_tarball = "/tmp/fa-bundle.tar.gz"
        await environment.upload_file(tarball, remote_tarball)
        await self.exec_as_root(
            environment,
            command=(
                f"mkdir -p /opt/fa && tar -xzf {remote_tarball} -C /opt/fa && "
                "chmod +x /opt/fa/bin/fah && ln -sf /opt/fa/bin/fah /usr/local/bin/fa"
            ),
        )
        # Task images ship without CA roots — Dart TLS then dies with
        # CERTIFICATE_VERIFY_FAILED on the provider handshake (live smoke,
        # run 34741686224). Best-effort bootstrap across common distros;
        # a no-op where the store already exists.
        await self.exec_as_root(
            environment,
            command=(
                "if [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then "
                "if command -v apt-get >/dev/null; then "
                "apt-get update -qq && apt-get install -y -qq ca-certificates; "
                "elif command -v apk >/dev/null; then apk add --no-cache ca-certificates; "
                "elif command -v dnf >/dev/null; then dnf install -y ca-certificates; "
                "elif command -v yum >/dev/null; then yum install -y ca-certificates; "
                "fi; fi || true"
            ),
        )
        # No user is present during benchmark runs; autopilot skips the
        # critical-pattern bash interceptor that headless mode would deny.
        await self.exec_as_agent(
            environment,
            command=(
                "mkdir -p ~/.fah && "
                "grep -q approvalMode ~/.fah/config.yaml 2>/dev/null || "
                "printf 'approvalMode: autopilot\\n' > ~/.fah/config.yaml"
            ),
        )
        await self.exec_as_agent(environment, command="fa --version")

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        knobs = _timeout.TimeoutKnobs.from_env()
        if knobs is None:
            await self.exec_as_agent(
                environment, command=self._agent_command(instruction),
                env=self._provider_env,
            )
            return
        await self._run_with_deadline(knobs, instruction, environment)

    def _agent_command(self, instruction: str) -> str:
        # shlex-quote the instruction: backticks/$()/markdown spans in task
        # descriptions must reach fa verbatim (same reason cline quotes).
        return (
            "set -o pipefail; "
            f"mkdir -p {_SESSION_ROOT} && "
            f"fa --session-root {_SESSION_ROOT} "
            f"-p {shlex.quote(instruction)} < /dev/null 2>&1 | "
            "tee /logs/agent/fa.txt; "
            "status=${PIPESTATUS[0]}; "
            'echo "__FA_EXIT=${status}" | tee -a /logs/agent/fa.txt; '
            'exit "${status}"'
        )

    async def _run_with_deadline(
        self, knobs: "_timeout.TimeoutKnobs", instruction: str, environment
    ) -> None:
        """Supervise the fa exec under the issue #1122 ladder.

        Progress = growth of /logs/agent/fa.txt (the tee'd agent output the
        command already writes). On stall/hard-ceiling: pkill fa, then raise
        asyncio.TimeoutError — inside harbor's own wait_for this is
        indistinguishable from the harness's native timeout, so the trial
        classifies as AgentTimeoutError exactly as today. Natural
        completion (including a non-zero fa exit) re-raises whatever the
        exec raised, byte-for-byte today's semantics.
        """
        ladder = _timeout.ProgressLadder(knobs)
        loop = asyncio.get_running_loop()
        start = loop.time()
        outcome = None
        exec_task = asyncio.create_task(
            self.exec_as_agent(
                environment, command=self._agent_command(instruction),
                env=self._provider_env,
            )
        )
        while not exec_task.done():
            remaining = ladder.kill_at - (loop.time() - start)
            await asyncio.sleep(min(_POLL_SEC, max(remaining, 0.05)))
            outcome = ladder.evaluate(
                loop.time() - start, await self._progress_bytes(environment)
            )
            if outcome:
                # procps may be missing in slim task images; if neither
                # signal nor pkill lands, harbor's own task timeout still
                # bounds the trial.
                await self.exec_as_root(
                    environment, command="pkill -f 'fa --session-root' || true",
                    timeout_sec=15,
                )
                try:
                    await asyncio.wait_for(asyncio.shield(exec_task), timeout=60)
                except Exception:
                    pass
                if not exec_task.done():
                    exec_task.cancel()
                    # An abandoned cancelled task is GC-destroyed with
                    # "pending task" warnings and its exception never
                    # retrieved - await the cancellation instead. Only our
                    # own cancellation is swallowed; an external cancel of
                    # this coroutine still propagates.
                    try:
                        await exec_task
                    except asyncio.CancelledError:
                        if not exec_task.cancelled():
                            raise
                    except Exception:
                        pass
                break
        # Natural completion: awaiting the task surfaces the exec's own
        # failure (e.g. NonZeroAgentExitCodeError) - today's semantics
        # verbatim. The audit records the true outcome class: a crash must
        # not be labelled "completed" (issue #1122 round 1).
        error = None
        if not outcome:
            try:
                await exec_task
            except BaseException as exc:  # noqa: BLE001 - re-raised below
                error = exc
        await self._write_audit(
            environment, knobs, ladder,
            outcome or ("crashed" if error is not None else "completed"),
        )
        if outcome:
            raise asyncio.TimeoutError(
                f"fa agent killed by bench timeout ladder: {outcome}"
            )
        if error is not None:
            raise error

    async def _progress_bytes(self, environment) -> int | None:
        try:
            result = await self.exec_as_agent(
                environment,
                command="wc -c < /logs/agent/fa.txt 2>/dev/null",
                timeout_sec=15,
            )
            if result.return_code == 0 and result.stdout:
                return int(result.stdout.strip() or 0)
        except Exception:
            pass
        return None

    async def _write_audit(self, environment, knobs, ladder, outcome) -> None:
        # AC4 (issue #1122): audit trail synced back with the agent logs.
        payload = base64.b64encode(
            json.dumps(_timeout.audit_dict(knobs, ladder, outcome)).encode()
        ).decode()
        try:
            await self.exec_as_agent(
                environment,
                command=(
                    f"mkdir -p /logs/agent && printf %s {payload} "
                    f"| base64 -d > {_AUDIT_PATH}"
                ),
                timeout_sec=15,
            )
        except Exception:
            pass

    def populate_context_post_run(self, context: AgentContext) -> None:
        """Fold fa's session token accounting into the agent context (issue #1123).

        fa session JSONL assistant records embed
        ``message.usage = {input, output, cacheRead, cacheWrite, ...}``
        (Usage.toJson in lib/src/types.dart); summed across records this is
        the billed usage for the trial. Extraction is shared with the legacy
        adapter (bench/fa_usage.py): rglob covers retries and subagent
        sessions (E1/E2), records with omitted usage contribute a chars/4
        estimate tallied in context.metadata, and a missing/corrupt log
        leaves zeros + a warning.

        Harbor semantics: n_input_tokens INCLUDES cache tokens. cost_usd
        comes from the pinned bench price table (bench/pricing.json);
        unpriced model → None, which the summary renders as n/a.
        """
        usage = fa_usage.extract_from_dir(self.logs_dir / "fah-sessions")
        for warning in usage.warnings:
            print(f"[fa_agent] warning: {warning}", file=sys.stderr)
        if not (
            usage.input_tokens
            or usage.output_tokens
            or usage.cache_read_tokens
            or usage.cache_write_tokens
            or usage.estimated_tokens
        ):
            return
        context.n_input_tokens = (
            context.n_input_tokens or 0
        ) + usage.input_tokens + usage.cache_read_tokens + (
            usage.cache_write_tokens + usage.estimated_input_tokens
        )
        context.n_output_tokens = (
            context.n_output_tokens or 0
        ) + usage.output_tokens + usage.estimated_output_tokens
        context.n_cache_tokens = (
            context.n_cache_tokens or 0
        ) + usage.cache_read_tokens + usage.cache_write_tokens
        pricing = fa_usage.load_pricing(_PRICING_PATH)
        total = 0.0
        priced = bool(usage.models)
        for model, tally in sorted(usage.models.items()):
            cost = fa_usage.cost_usd(
                fa_usage.price_entry(pricing, model),
                tally["input"],
                tally["output"],
                tally["cacheRead"],
                tally["cacheWrite"],
            )
            if cost is None:
                # E3: a model the table doesn't pin → no made-up total.
                priced = False
                print(
                    f"[fa_agent] warning: no bench price for model '{model or '?'}'; "
                    f"cost_usd stays n/a",
                    file=sys.stderr,
                )
            else:
                total += cost
        context.cost_usd = total if priced else None
        if usage.estimated_tokens:
            context.metadata = {
                **(context.metadata or {}),
                "estimated_tokens": usage.estimated_tokens,
            }


def _b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()
