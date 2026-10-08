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

  Round 3 (issue #1392): when FA_STALL_GAP_SEC or
  FA_AGENT_TIMEOUT_ABS_CEILING_SEC activates the progress-watch mode, the
  kill decision is the gap-aware ProgressWatch (progressing trials die
  only at the absolute ceiling; a >= stall-gap gap is a provable stall).
  Every trial also gets: live per-request lines as they happen
  (LiveProgress over the pane's FA_CONN events), a per-trial
  bench_metrics.json (latency p50/p95, watchdog fires, fresh-vs-reused),
  a hang-*.json forensics dump on a stall verdict BEFORE the kill lands
  (StallSentinel), and an export-guard.json row when the agent produced
  output but the session export came back empty (ExportGuard).

  Issue #1406 (never-again): the launch line itself carries the
  non-secret FA_CONN_* env into the tmux pane (`export …; env |
  grep FA_CONN > /tmp/fa-conn-env.txt;` prefix — pane env belongs to the
  shell/server history, not to the step env that typed a later command),
  the capture folds into agent-logs/fa-conn-env.txt as runtime proof,
  and the loud-empty guard fires (conn-guard.json + a ::warning::
  annotation) when a trial's bench_metrics.json has requests == []
  despite real usage tokens — an instrumentation outage is never silent.

  PYTHONPATH=bench/terminal_bench tb run -d terminal-bench-core==0.1.1 \
    --agent-import-path fa_agent:FaAgent -t hello-world
"""

import base64
import json
import logging
import os
import shlex
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import fa_agent_timeout as _timeout
import bench_metrics as _bench_metrics

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
# _run_agent_commands); _export_sessions copies it to the trial's host
# agent-logs dir at fold time, since the task compose template's volume
# cannot be relied on (issue #1339 — datasets without it archived zero
# session logs).
_CONTAINER_SESSION_ROOT = "/agent-logs/fah-sessions"

# Round-3 forensics paths inside the container (issue #1392). The bench
# workflow sets FA_CONN_TRACE_FILE/_SNAPSHOT to these via the adapter env;
# the wrapper cats them at trial end / stall time.
_CONTAINER_TRACE_FILE = "/tmp/fa-conn-trace.jsonl"
_CONTAINER_SNAPSHOT = "/tmp/fa-conn-snapshot.json"

# Issue #1406: the launch-time `env | grep FA_CONN` capture inside the
# pane, folded into the trial's agent-logs as fa-conn-env.txt — runtime
# proof of what fa's pane environment actually contained at exec time.
_CONTAINER_ENV_PROOF = "/tmp/fa-conn-env.txt"

# Host env vars forwarded into the container (base64, like the provider
# config) when set: the ConnTrace flags drive fa's connection forensics.
_CONN_ENV_KEYS = (
    "FA_CONN_DEBUG",
    "FA_PROVIDER_DEBUG",
    "FA_CONN_TRACE_FILE",
    "FA_CONN_PAYLOAD_SNAPSHOT",
    "FA_CONN_PAYLOAD_KEEP_AUTH",
    "FA_BENCH_CONCURRENCY",
)


def pane_launch_env_prefix(env=None) -> str:
    """`export FA_CONN_…=…; env | grep FA_CONN > proof;` launch prefix.

    Issue #1406 (round-3 bench ran ConnTrace-dark, 29/29 empty
    bench_metrics.json): FA_CONN_DEBUG reached the container only through
    setup-env.sh, sourced once at install time. A tmux pane's environment
    belongs to the pane shell's history and the tmux server's env — not
    to the step env that types a later command — so any shell-state loss
    between install and launch (fresh pane, server-side env resolution,
    update-environment allowlisting) drops the vars silently. The launch
    line now carries the non-secret diagnostic env itself and captures
    `env | grep FA_CONN` at the instant fa execs, so a ConnTrace outage
    can neither happen nor hide. Secrets never ride this line: provider
    config/keys keep their base64 setup-env.sh transport, off the pane
    stream that pipe-pane and agent.cast mirror.
    """
    source = os.environ if env is None else env
    exports = " ".join(
        f"{name}={shlex.quote(source[name])}"
        for name in _CONN_ENV_KEYS
        if source.get(name)
    )
    proof = f"env | grep FA_CONN > {_CONTAINER_ENV_PROOF} 2>&1; "
    if not exports:
        # Nothing to forward — still capture: an inherited-DARK env is
        # exactly what the proof file must show (never silent).
        return proof
    return f"export {exports}; {proof}"


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
        # Round 3 (issue #1392): ConnTrace flags ride into the container
        # so fa's connection forensics reaches the pane/trace file. They
        # are non-secret booleans/paths — plain values (the base64 twins
        # were never decoded Dart-side and left ConnTrace dark).
        for name in _CONN_ENV_KEYS:
            value = os.environ.get(name)
            if value:
                env[name] = value
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
            return self._fold_session_usage(session, result, logging_dir)
        # test_budget_sec stays 0: the agent phase does not consume the
        # verifier's budget — tb enforces the test phase separately, so
        # the abs ceiling is flat.
        return self._perform_task_with_deadline(
            knobs, instruction, session, logging_dir
        )

    def _perform_task_with_deadline(self, knobs, instruction, session, logging_dir,
                                    test_budget_sec=0.0):
        """Stock perform_task under the issue #1122/#1392 deadline decider.

        The stock body runs in a worker thread exactly as the harness would
        call it; this thread watches the pane-tap byte counter and, when the
        decider says the run is stuck (or a ceiling is hit), interrupts the
        agent and returns an AGENT_TIMEOUT result — same failure mode the
        harness's own wait_for produces, but decided by the decider. On
        natural completion the stock result passes through untouched —
        except for the issue #1123 session-usage fold below, which never
        touches failure classification.

        Round 3 (issue #1392): the decider is the gap-aware ProgressWatch
        in watch mode, the legacy ProgressLadder otherwise; the pane tail
        feeds LiveProgress (per-request lines as they happen), the parsed
        FA_CONN events fold into the trial's bench_metrics.json, and a
        stall verdict captures the StallSentinel hang payload BEFORE the
        kill lands.
        """
        if knobs.progress_watch:
            decider = _timeout.ProgressWatch(knobs, test_budget_sec=test_budget_sec)
        else:
            decider = _timeout.ProgressLadder(knobs)
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

        live = _bench_metrics.LiveProgress()
        pane_offset = 0
        # Bytes of a line that has not seen its newline yet: an FA_CONN
        # record flushed across two polls would otherwise parse as nothing
        # (no prefix) and be dropped from the live view AND the pane
        # fallback metrics (issue #1392 review — ~720 slices per hour).
        pane_tail = b""
        conn_events = []
        start = time.monotonic()
        outcome = None

        def _feed_complete_lines():
            nonlocal pane_tail, pane_offset
            new_bytes, pane_offset = self._read_pane_increment(
                session, pane_offset
            )
            if not new_bytes:
                return
            pane_tail += new_bytes
            cut = pane_tail.rfind(b"\n")
            if cut < 0:
                return
            text = pane_tail[: cut + 1].decode("utf-8", errors="replace")
            pane_tail = pane_tail[cut + 1 :]
            # LiveProgress: per-request/per-turn lines flushed as they
            # happen, so a stall is visible forming in the live log.
            live.feed(text)
            conn_events.extend(_bench_metrics.parse_conn_events(text))

        while worker.is_alive():
            remaining = decider.kill_at - (time.monotonic() - start)
            time.sleep(min(_POLL_SEC, max(remaining, 0.05)))
            elapsed = time.monotonic() - start
            _feed_complete_lines()
            outcome = decider.evaluate(elapsed, self._progress_bytes(session))
            if outcome:
                if outcome == "stall":
                    # StallSentinel: capture the in-flight payload + socket
                    # meta BEFORE the kill lands (issue #1392 AC3).
                    self._capture_stall(
                        session, logging_dir, decider, conn_events, elapsed
                    )
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

        # Final partial line (no trailing newline at kill time): still an
        # event worth folding into the post-mortem.
        if pane_tail:
            tail_text = pane_tail.decode("utf-8", errors="replace")
            live.feed(tail_text)
            conn_events.extend(_bench_metrics.parse_conn_events(tail_text))
        self._tap_pane(session, on=False)
        self._write_trial_metrics(session, logging_dir, conn_events)
        crashed = "error" in box
        if logging_dir is not None:
            self._write_audit(
                logging_dir,
                knobs,
                decider,
                # Audit the true outcome class (issue #1122): a stock-body
                # crash must not be recorded as a completed run.
                outcome or ("crashed" if crashed else "completed"),
            )
        # Our decider's verdict outranks a late worker error: once we decided
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
                logging_dir,
            )
        if crashed:
            raise box["error"]
        return self._fold_session_usage(
            session,
            box.get("result")
            or AgentResult(total_input_tokens=0, total_output_tokens=0),
            logging_dir,
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
    def _read_pane_increment(session, offset):
        """(new_pane_bytes, new_offset) since `offset` — the LiveProgress feed.

        Returns BYTES; the offset is a raw byte count, so a partial
        multi-byte character at the slice boundary survives (the caller
        decodes only complete newline-terminated lines). Fail-soft: a
        broken exec returns (b"", offset) and the poll loop keeps
        running; the byte counter remains the progress signal.
        """
        try:
            result = session.container.exec_run(
                ["sh", "-c", f"tail -c +{offset + 1} {_PROGRESS_LOG} 2>/dev/null"]
            )
            if result.exit_code == 0 and result.output:
                data = result.output
                if isinstance(data, str):
                    # surrogateescape round-trips invalid bytes so the
                    # OFFSET stays byte-true (errors="replace" would inflate
                    # one bad byte to three U+FFFD bytes and the next tail
                    # would skip content).
                    data = data.encode("utf-8", errors="surrogateescape")
                return data, offset + len(data)
        except Exception:
            pass
        return b"", offset

    @staticmethod
    def _capture_stall(session, logging_dir, decider, conn_events, elapsed):
        """StallSentinel (issue #1392 AC3): hang-*.json BEFORE the kill.

        Names the in-flight request (the container's payload snapshot the
        Dart side keeps under FA_CONN_DEBUG), the gap that proved the
        stall, and the tail of the connection events — so a class-C trial
        ships its own repro case in the artifact.
        """
        if logging_dir is None:
            return
        payload = None
        try:
            result = session.container.exec_run(
                ["sh", "-c", f"cat {_CONTAINER_SNAPSHOT} 2>/dev/null"]
            )
            if result.exit_code == 0 and result.output:
                data = result.output
                if isinstance(data, bytes):
                    data = data.decode("utf-8", errors="replace")
                try:
                    payload = json.loads(data)
                except json.JSONDecodeError:
                    payload = data.strip() or None
        except Exception:
            payload = None
        record = {
            "elapsed_sec": round(elapsed, 3),
            "gap_sec": round(elapsed - decider.last_progress_at, 3),
            "last_progress_sec": round(decider.last_progress_at, 3),
            "payload": payload,
            "conn_events": conn_events[-50:],
            "replay": "scripts/replay_hang.sh <this-file>",
        }
        try:
            path = Path(logging_dir) / f"hang-{int(elapsed)}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(record, indent=2))
            print(
                f"[fa_agent] stall forensics captured: {path}",
                file=sys.stderr,
                flush=True,
            )
        except OSError:
            pass

    @staticmethod
    def _write_trial_metrics(session, logging_dir, pane_events):
        """Per-trial bench_metrics.json (issue #1392 AC2). Fail-soft."""
        if logging_dir is None:
            return
        events = list(pane_events)
        try:
            # The container-side ConnTrace file (when configured) is the
            # cleaner source: pane taps can truncate mid-line.
            result = session.container.exec_run(
                ["sh", "-c", f"cat {_CONTAINER_TRACE_FILE} 2>/dev/null"]
            )
            if result.exit_code == 0 and result.output:
                data = result.output
                if isinstance(data, bytes):
                    data = data.decode("utf-8", errors="replace")
                file_events = _bench_metrics.parse_conn_events(data)
                if file_events:
                    events = file_events
        except Exception:
            pass
        try:
            trial = Path(logging_dir).name
            concurrency = os.environ.get("FA_BENCH_CONCURRENCY")
            level = int(concurrency) if concurrency and concurrency.isdigit() else None
            metrics = _bench_metrics.summarize_trial(
                trial, events, concurrency_level=level
            )
            _bench_metrics.write_bench_metrics(
                Path(logging_dir) / "bench_metrics.json", metrics
            )
        except Exception as exc:  # noqa: BLE001 — metrics never fail a trial
            print(
                f"[fa_agent] warning: bench_metrics.json not written ({exc})",
                file=sys.stderr,
            )

    @staticmethod
    def _write_export_guard(session, logging_dir):
        """ExportGuard record (issue #1392 AC7): agent output vs export size.

        A trial whose agent produced pane output but whose session export
        came back empty is the class-D silent data loss; the guard row
        makes post_mortem_usage.py name it loudly.
        """
        if logging_dir is None:
            return
        try:
            output_bytes = FaAgent._progress_bytes(session)
            export_files = len(
                list(Path(logging_dir).glob("**/*.jsonl"))
            ) if Path(logging_dir).is_dir() else 0
            guard = {
                "trial": Path(logging_dir).name,
                # Proxy for "the agent had session records": pane output.
                "session_records": 1 if (output_bytes or 0) > 0 else 0,
                "agent_output_bytes": output_bytes or 0,
                "export_files": export_files,
                "ok": (output_bytes or 0) == 0 or export_files > 0,
            }
            path = Path(logging_dir) / "export-guard.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(guard))
            if not guard["ok"]:
                print(
                    f"[fa_agent] EXPORT GUARD: agent produced "
                    f"{output_bytes} pane bytes but the export has "
                    f"{export_files} session file(s) — class-D data loss",
                    file=sys.stderr,
                    flush=True,
                )
        except Exception as exc:  # noqa: BLE001 — fail-soft by contract
            print(
                f"[fa_agent] warning: export guard not written ({exc})",
                file=sys.stderr,
            )

    @staticmethod
    def _write_conn_env_proof(session, logging_dir):
        """Issue #1406 AC1: fold the launch-time `env | grep FA_CONN`
        capture into the trial's agent-logs (fa-conn-env.txt) — runtime
        proof of the pane environment fa actually inherited. Fail-soft.
        """
        if logging_dir is None:
            return
        try:
            result = session.container.exec_run(
                ["sh", "-c", f"cat {_CONTAINER_ENV_PROOF} 2>/dev/null"]
            )
            if result.exit_code == 0 and result.output:
                data = result.output
                if isinstance(data, bytes):
                    data = data.decode("utf-8", errors="replace")
                (Path(logging_dir) / "fa-conn-env.txt").write_text(data)
        except Exception as exc:  # noqa: BLE001 — proof never fails a trial
            print(
                f"[fa_agent] warning: conn env proof not written ({exc})",
                file=sys.stderr,
            )

    @staticmethod
    def _guard_loud_empty(logging_dir, usage_tokens) -> None:
        """Issue #1406 loud-empty guard (ExportGuard pattern): a trial
        whose bench_metrics.json folded requests == [] while the usage
        fold proves real model spend ran ConnTrace-dark — write the
        conn-guard.json row and warn LOUDLY (::warning:: renders as a
        GitHub Actions annotation). An instrumentation outage must never
        be silent again. Fail-soft by contract.
        """
        if logging_dir is None:
            return
        try:
            metrics = json.loads(
                (Path(logging_dir) / "bench_metrics.json").read_text()
            )
        except (OSError, ValueError):
            return  # no/corrupt metrics row (stock path) — nothing to guard
        violated = _bench_metrics.loud_empty_violation(metrics, usage_tokens)
        requests = metrics.get("requests") if isinstance(metrics, dict) else None
        guard = {
            "trial": Path(logging_dir).name,
            "requests": len(requests) if isinstance(requests, list) else None,
            "usage_tokens": usage_tokens,
            "ok": not violated,
            "guard": "loud_empty",
        }
        try:
            (Path(logging_dir) / "conn-guard.json").write_text(json.dumps(guard))
        except OSError:
            pass
        if not violated:
            return
        print(
            f"[fa_agent] BENCH METRICS GUARD: trial {guard['trial']} recorded "
            f"0 ConnTrace requests but the usage fold found {usage_tokens} "
            "tokens of real model spend — ConnTrace ran dark (FA_CONN_* "
            "never reached fa; issue #1406). Its latency/watchdog columns "
            "are void.",
            file=sys.stderr,
            flush=True,
        )
        print(
            f"::warning::[fa_agent] ConnTrace dark in trial {guard['trial']}: "
            f"0 FA_CONN requests vs {usage_tokens} usage tokens — "
            "instrumentation outage, not a quiet trial (issue #1406)",
            file=sys.stderr,
            flush=True,
        )

    @staticmethod
    def _write_audit(logging_dir, knobs, ladder, outcome) -> None:
        # AC4 (issue #1122): extension decisions land in the trial artifact.
        path = Path(logging_dir) / "fa-agent-timeout.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(_timeout.audit_dict(knobs, ladder, outcome)))

    @staticmethod
    def _fold_session_usage(session, result, logging_dir=None):
        """Issue #1123: tb's AbstractInstalledAgent hardcodes
        AgentResult(total_input_tokens=0, total_output_tokens=0) — the
        source of the all-zero token columns. Fold fa's real session
        usage in after the run; tokens are measurement, so extraction
        fails soft (zeros + a warning, never a failed trial).
        """
        _export_sessions(session, logging_dir)
        FaAgent._write_export_guard(session, logging_dir)
        FaAgent._write_conn_env_proof(session, logging_dir)
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
            # Issue #1406: with usage known, the loud-empty guard can name
            # a ConnTrace-dark trial instead of shipping an empty shell.
            FaAgent._guard_loud_empty(logging_dir, usage.total_tokens())
        except Exception as exc:  # noqa: BLE001 — fail-soft by contract
            print(
                f"[fa_agent] warning: session usage extraction failed ({exc}); "
                f"token totals stay 0",
                file=sys.stderr,
            )
        return result

    def _run_agent_commands(self, instruction: str) -> list[TerminalCommand]:
        # Issue #1406: the env prefix rides the SAME line that launches
        # fa, so the pane environment cannot be lost between the
        # install-time setup-env.sh sourcing and the launch; the grep
        # capture doubles as AC1's runtime proof (folded into agent-logs
        # as fa-conn-env.txt at trial end).
        return [
            TerminalCommand(
                command=f"{pane_launch_env_prefix()}"
                f"fa --session-root /agent-logs/fah-sessions "
                f"-p {shlex.quote(instruction)}",
                min_timeout_sec=0.0,
                max_timeout_sec=float("inf"),
                block=True,
                append_enter=True,
            ),
        ]


def _export_sessions(session, logging_dir) -> None:
    """Issue #1339 AC4: copy the container's fa session logs into the
    trial's host agent-logs dir (tb passes it as logging_dir). The task
    compose template's /agent-logs volume was the only archive path, and
    datasets whose compose files skip it archived zero session logs (run
    37495405735: every shard's summary priced n/a and the recovered
    trial's real usage was unverifiable). Fail-soft by contract: a broken
    export degrades to the old volume-dependent behavior, never a failed
    trial.
    """
    if logging_dir is None:
        return
    try:
        bits, _ = session.container.get_archive(_CONTAINER_SESSION_ROOT)
        dest = Path(logging_dir)
        dest.mkdir(parents=True, exist_ok=True)
        n = fa_usage.extract_session_archive(b"".join(bits), dest)
        if n:
            print(
                f"[fa_agent] exported {n} fa session file(s) to {dest}",
                file=sys.stderr,
            )
    except Exception as exc:  # noqa: BLE001 — fail-soft by contract
        print(
            f"[fa_agent] warning: fa session export failed ({exc}); "
            "relying on the task compose /agent-logs volume",
            file=sys.stderr,
        )


def _b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()
