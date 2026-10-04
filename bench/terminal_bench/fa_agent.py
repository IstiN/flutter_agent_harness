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

  Timeout knobs (issue #1122, see bench/fa_agent_timeout.py): when any
  FA_AGENT_TIMEOUT_SEC / FA_PROGRESS_EXTENSION / FA_AGENT_IDLE_WINDOW_SEC /
  FA_AGENT_CEILING_MULTIPLIER is set, perform_task takes over the outer
  agent deadline from the harness's flat wait_for: the agent runs under a
  progress-aware ladder (silent => die at the base cap as today; output
  flowing => deadline recedes up to the hard ceiling). With no knobs set
  this module delegates to the stock AbstractInstalledAgent.perform_task
  byte-for-byte (historical comparability, issue #1122 REG-1).

  PYTHONPATH=bench/terminal_bench tb run -d terminal-bench-core==0.1.1 \
    --agent-import-path fa_agent:FaAgent -t hello-world
"""

import base64
import json
import logging
import os
import shlex
import sys
import tarfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import fa_agent_timeout as _timeout

_LOG = logging.getLogger(__name__)

from terminal_bench.agents.base_agent import AgentResult
from terminal_bench.agents.failure_mode import FailureMode
from terminal_bench.agents.installed_agents.abstract_installed_agent import (
    AbstractInstalledAgent,
)
from terminal_bench.terminal.models import TerminalCommand

# Shared extraction lives one level up (bench/fa_usage.py); PYTHONPATH only
# carries this dir.
_BENCH_DIR = str(Path(__file__).resolve().parent.parent)
if _BENCH_DIR not in sys.path:
    sys.path.insert(0, _BENCH_DIR)
import fa_usage  # noqa: E402

# Never-started trials: the only outcomes where fa cannot have produced a
# session, so the issue #1123 usage fold is skipped (gh-1209 — every
# outcome where the agent actually ran gets the fold).
_NEVER_STARTED_MODES = frozenset(
    {
        FailureMode.AGENT_INSTALLATION_FAILED,
        FailureMode.UNKNOWN_AGENT_ERROR,
    }
)

_VERSION = "0.1.0"

# Host-side pane tap: tmux pipe-pane mirrors the pane stream (the agent's
# rendered deltas/tool output) into this file; its byte size is the
# progress signal. The harness emits nothing into the pane on a timer, so
# there is no keep-alive noise (issue #1122 E1).
_PROGRESS_LOG = "/tmp/fa-progress.log"
_POLL_SEC = 5.0
# fa writes its session JSONL here inside the container (--session-root in
# _run_agent_commands); tb syncs /agent-logs to the host trial dir only
# after perform_task returns, so the container is the only read point.
_CONTAINER_SESSION_ROOT = "/agent-logs/fah-sessions"


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
        knobs = _timeout.TimeoutKnobs.from_env()
        if knobs is None:
            result = super().perform_task(instruction, session, logging_dir)
            # Issue #1123, corrected by gh-1209: fold fa's real session
            # usage into the result for ANY outcome where the agent process
            # actually ran — the timed-out trials are the expensive ones,
            # so skipping them reports zero spend on the costliest rows.
            # Only true never-started trials skip the fold: an installation
            # failure means fa never installed, and unknown_agent_error
            # means the harness never got the agent going. The fold itself
            # fails soft (zeros survive when no session file exists), so
            # folding a ran-but-empty trial is always safe.
            if result.failure_mode in _NEVER_STARTED_MODES:
                return result
            return self._fold_session_usage(session, result)
        return self._perform_task_with_deadline(
            knobs, instruction, session, logging_dir
        )

    def _perform_task_with_deadline(self, knobs, instruction, session, logging_dir):
        """Stock perform_task under the issue #1122 deadline ladder.

        The stock body runs in a worker thread exactly as the harness would
        call it; this thread watches the pane-tap byte counter and, when the
        ladder says the run is stuck (or at the hard ceiling), interrupts the
        agent and returns an AGENT_TIMEOUT result — same failure mode the
        harness's own wait_for produces, but decided by the ladder. On
        natural completion the stock result passes through untouched —
        except for the issue #1123 session-usage fold below, which never
        touches failure classification.
        """
        base_perform = super().perform_task
        box = {}

        def _run_stock():
            try:
                box["result"] = base_perform(
                    instruction=instruction, session=session, logging_dir=logging_dir
                )
            except BaseException as exc:  # noqa: BLE001 - re-raised below
                box["error"] = exc

        worker = threading.Thread(target=_run_stock, daemon=True, name="fa-agent")
        self._tap_pane(session, on=True)
        worker.start()

        ladder = _timeout.ProgressLadder(knobs)
        start = time.monotonic()
        outcome = None
        while worker.is_alive():
            remaining = ladder.kill_at - (time.monotonic() - start)
            time.sleep(min(_POLL_SEC, max(remaining, 0.05)))
            outcome = ladder.evaluate(
                time.monotonic() - start, self._progress_bytes(session)
            )
            if outcome:
                session.send_keys(["C-c"], block=False, min_timeout_sec=0.5)
                worker.join(15)
                if worker.is_alive():
                    # fa ignored SIGINT (or the shell wedged): kill it from
                    # outside so the pane is free for the harness's tests.
                    session.container.exec_run(
                        ["sh", "-c", "pkill -f 'fa --session-root' || true"]
                    )
                    worker.join(30)
                break

        self._tap_pane(session, on=False)
        crashed = "error" in box
        if logging_dir is not None:
            self._write_audit(
                logging_dir,
                knobs,
                ladder,
                # Audit the true outcome class (issue #1122): a stock-body
                # crash must not be recorded as a completed run.
                outcome or ("crashed" if crashed else "completed"),
            )
        # Our ladder's verdict outranks a late worker error: once we decided
        # the run is a stall/ceiling timeout, the harness must see exactly
        # the timeout classification it would have produced itself.
        if outcome:
            if crashed:
                # Never swallow the worker's failure silently - surface it
                # in the run log for the postmortem.
                _LOG.warning(
                    "stock body crashed after %s verdict; error: %r",
                    outcome,
                    box["error"],
                )
            # Timed-out trials still burned tokens: fold whatever the
            # partial session recorded (issue #1123, fail-soft).
            return self._fold_session_usage(
                session,
                AgentResult(
                    total_input_tokens=0,
                    total_output_tokens=0,
                    failure_mode=FailureMode.AGENT_TIMEOUT,
                    timestamped_markers=[(0.0, f"agent_timeout({outcome})")],
                ),
            )
        if crashed:
            raise box["error"]
        return self._fold_session_usage(
            session,
            box.get("result")
            or AgentResult(total_input_tokens=0, total_output_tokens=0),
        )

    @staticmethod
    def _tap_pane(session, on: bool) -> None:
        line = (
            f"rm -f {_PROGRESS_LOG}; tmux pipe-pane 'cat >> {_PROGRESS_LOG}'"
            if on
            else "tmux pipe-pane"
        )
        session.send_keys([line, "Enter"], block=False, min_timeout_sec=1.0 if on else 0.0)

    @staticmethod
    def _progress_bytes(session):
        try:
            result = session.container.exec_run(
                ["sh", "-c", f"wc -c < {_PROGRESS_LOG} 2>/dev/null"]
            )
            if result.exit_code == 0:
                return int(result.output.decode(errors="replace").strip() or 0)
        except Exception:
            # Best-effort sample: a broken/wedged container must never kill
            # a healthy run — None keeps the ladder's previous state, and a
            # genuinely dead container fails the stock body on its own.
            pass
        return None

    @staticmethod
    def _write_audit(logging_dir, knobs, ladder, outcome) -> None:
        # AC4 (issue #1122): extension decisions land in the trial artifact.
        path = Path(logging_dir) / "fa-agent-timeout.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(_timeout.audit_dict(knobs, ladder, outcome)))

    @staticmethod
    def _fold_session_usage(session, result):
        """Issue #1123: tb's AbstractInstalledAgent hardcodes
        AgentResult(total_input_tokens=0, total_output_tokens=0) — the
        source of the all-zero token columns. Fold fa's real session
        usage in after the run; tokens are measurement, so extraction
        fails soft (zeros + a warning, never a failed trial).
        """
        try:
            exit_code, output = session.container.exec_run(
                [
                    "sh",
                    "-c",
                    f"find {_CONTAINER_SESSION_ROOT} -name '*.jsonl' -type f"
                    " -exec cat {} + 2>/dev/null",
                ]
            )
            if exit_code != 0:
                print(
                    f"[fa_agent] warning: reading fa sessions in the container "
                    f"exited {exit_code}; token totals stay 0",
                    file=sys.stderr,
                )
                return result
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            usage = fa_usage.extract_from_text(output)
            for warning in usage.warnings:
                print(f"[fa_agent] warning: {warning}", file=sys.stderr)
            result.total_input_tokens = (
                usage.input_tokens + usage.estimated_input_tokens
            )
            result.total_output_tokens = (
                usage.output_tokens + usage.estimated_output_tokens
            )
        except Exception as exc:  # noqa: BLE001 — fail-soft by contract
            print(
                f"[fa_agent] warning: session usage extraction failed ({exc}); "
                f"token totals stay 0",
                file=sys.stderr,
            )
        return result

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
