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

Usage:
  PYTHONPATH=bench/harbor_fa harbor run -d terminal-bench/terminal-bench@4.0.0 \
    -a fa_agent:FaAgent -e docker -m glm-5.3-flash
"""

import base64
import json
import os
import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

_VERSION = "0.1.0"

# Sessions are written here inside the environment; harbor syncs /logs/agent
# back to the host trial dir after the trial (Trial._download_agent_logs).
_SESSION_ROOT = "/logs/agent/fah-sessions"


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
        # No user is present during benchmark runs; unattended skips the
        # critical-pattern bash interceptor that headless mode would deny.
        await self.exec_as_agent(
            environment,
            command=(
                "mkdir -p ~/.fah && "
                "grep -q approvalMode ~/.fah/config.yaml 2>/dev/null || "
                "printf 'approvalMode: unattended\\n' > ~/.fah/config.yaml"
            ),
        )
        await self.exec_as_agent(environment, command="fa --version")

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        # shlex-quote the instruction: backticks/$()/markdown spans in task
        # descriptions must reach fa verbatim (same reason cline quotes).
        cmd = (
            "set -o pipefail; "
            f"mkdir -p {_SESSION_ROOT} && "
            f"fa --session-root {_SESSION_ROOT} "
            f"-p {shlex.quote(instruction)} < /dev/null 2>&1 | "
            "tee /logs/agent/fa.txt; "
            "status=${PIPESTATUS[0]}; "
            'echo "__FA_EXIT=${status}" | tee -a /logs/agent/fa.txt; '
            'exit "${status}"'
        )
        await self.exec_as_agent(environment, command=cmd, env=self._provider_env)

    def populate_context_post_run(self, context: AgentContext) -> None:
        """Fold fa's session token accounting into the agent context.

        fa session JSONL assistant records carry inputTokens / outputTokens /
        cacheReadTokens / cacheWriteTokens per step; summed across steps this
        is the billed usage for the trial.
        """
        sessions_dir = self.logs_dir / "fah-sessions"
        if not sessions_dir.is_dir():
            return
        n_in = n_out = n_cache = 0
        for path in sessions_dir.rglob("*.jsonl"):
            for line in path.read_text(errors="replace").splitlines():
                if '"inputTokens"' not in line and '"outputTokens"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                n_in += rec.get("inputTokens") or 0
                n_out += rec.get("outputTokens") or 0
                n_cache += (rec.get("cacheReadTokens") or 0) + (
                    rec.get("cacheWriteTokens") or 0
                )
        if n_in or n_out:
            context.n_input_tokens = (context.n_input_tokens or 0) + n_in
            context.n_output_tokens = (context.n_output_tokens or 0) + n_out
            context.n_cache_tokens = (context.n_cache_tokens or 0) + n_cache


def _b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()
