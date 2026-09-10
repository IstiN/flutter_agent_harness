"""Terminal-Bench adapter for the `fa` coding agent (flutter_agent_harness).

Follows the AbstractInstalledAgent pattern (same as the claude-code agent):
a setup script installs fa inside the task container, and the agent runs as
`fa -p "<instruction>"` in the container's tmux session, so fa's bash/read/
write tools operate on the container filesystem.

Host-side inputs (environment):
  FA_BUNDLE_TARBALL      tar.gz of a `dart build cli` bundle (bin/fah + lib/),
                         extracted to /opt/fa by the setup script.
  FA_PROVIDER_TYPE       provider kind (default: anthropic).
  FA_PROVIDER_CONFIG     JSON {"baseUrl": ..., "model": ..., "apiKeyEnvVar": ...}
                         (or FA_PROVIDER_CONFIG_BASE64).
  <apiKeyEnvVar>         the API key itself, e.g. ANTHROPIC_API_KEY.

  PYTHONPATH=bench/terminal_bench tb run -d terminal-bench-core==0.1.1 \
    --agent-import-path fa_agent:FaAgent -t hello-world
"""

import base64
import json
import os
import shlex
import tarfile
from pathlib import Path

from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand

_VERSION = "0.1.0"


class FaAgent(AbstractInstalledAgent):
    @staticmethod
    def name() -> str:
        return "fa"

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._bundle_tarball = Path(
            os.environ.get("FA_BUNDLE_TARBALL", "fa-bundle.tar.gz")
        )
        if not self._bundle_tarball.is_file():
            raise FileNotFoundError(
                f"fa bundle tarball not found: {self._bundle_tarball} — build it "
                f"with bench/terminal_bench/run.sh"
            )

    @property
    def version(self) -> str:
        return self._version or _VERSION

    @property
    def _env(self) -> dict[str, str]:
        # Everything is passed base64-encoded: AbstractInstalledAgent emits
        # `export K='v'` lines, and base64 keeps arbitrary JSON/keys safe.
        env = {
            "FA_PROVIDER_TYPE": os.environ.get("FA_PROVIDER_TYPE", "anthropic"),
            "FA_PROVIDER_CONFIG_BASE64": _b64(os.environ["FA_PROVIDER_CONFIG"]),
        }
        key_var = json.loads(os.environ["FA_PROVIDER_CONFIG"]).get("apiKeyEnvVar")
        if key_var and os.environ.get(key_var):
            env[f"{key_var}_BASE64"] = _b64(os.environ[key_var])
        return env

    @property
    def _install_agent_script_path(self) -> Path:
        return self._get_templated_script_path("fa-setup.sh.j2")

    def perform_task(
        self,
        instruction: str,
        session,
        logging_dir=None,
    ):
        session.copy_to_container(
            self._bundle_tarball,
            container_dir="/installed-agent",
        )
        return super().perform_task(instruction, session, logging_dir)

    def _run_agent_commands(self, instruction: str) -> list[TerminalCommand]:
        return [
            TerminalCommand(
                command=f"fa --session-root /agent-logs/fah-sessions "
                f"-p {shlex.quote(instruction)}",
                min_timeout_sec=0.0,
                max_timeout_sec=float("inf"),
                block=True,
                append_enter=True,
            ),
        ]


def _b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()
