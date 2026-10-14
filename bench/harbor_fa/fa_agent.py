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

  Round 3 (gh-1556, harbor parity for #1392/#1430): when a watch knob is
  set (FA_STALL_GAP_SEC / FA_AGENT_TIMEOUT_ABS_CEILING_SEC — bench-harbor.yml
  sets both on every shard, so progress-watch is the bench default), the
  kill decision is the gap-aware ProgressWatch, not the byte-growth
  ladder; a stall/ceiling kill also exports FA_DEADLINE_EPOCH_MS to fa
  (effective cap minus a 120s wrap-up margin) so fa can land partial
  results before the guillotine. The kill path uses the `[f]a` bracket
  trick: the pre-fix self-matching `pkill -f 'fa --session-root'`
  SIGTERMed the exec wrapper's own shell (exit 143 skipped the audit AND
  the TimeoutError, classifying ladder kills as agent crashes) — and the
  kill is wrapped so its failure can never replace the TimeoutError.

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
import signal
import sys
import threading
import time
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import fa_agent_timeout as _timeout

from harbor.agents.installed.base import (
    ApiRateLimitError,
    BaseInstalledAgent,
    ErrorPattern,
)
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

# Shared extraction lives one level up (bench/fa_usage.py); PYTHONPATH only
# carries this dir.
_BENCH_DIR = str(Path(__file__).resolve().parent.parent)
if _BENCH_DIR not in sys.path:
    sys.path.insert(0, _BENCH_DIR)
import fa_usage  # noqa: E402

_VERSION = "0.1.0"

# gh-1592: harbor's failed-command classifier (_classify_exec_error) scans
# a failed exec's stdout+stderr with ERROR_PATTERNS, and its ApiRateLimit
# entries are UNANCHORED substrings — `rate.?limit` matched the tee'd fa
# output of run 38271607849 (shard fa-2.1-docker-cpu-5, trial
# gpt2-codegolf__pKKQfqj) after the 900s timeout kill: the output
# legitimately contains the words "rate limit" (echoed provider-error
# text, fa's own `[roles] rate limited on … — retrying` notices), so the
# failed launch exec surfaced as ApiRateLimitError with no provider 429
# anywhere. The anchor below requires the structured provider-error
# context: `429` and the wording must share ONE line — the shape every
# real 429 reaches fa's output in (`formatProviderError` renders
# `<statusCode>: <message>`, raw HTTP status lines are `HTTP/1.1 429 …`,
# JSON error bodies carry the `"code": 429` inline on one line), while
# fa's own notice lines and echoed prose carry no 429 on the line.
# The token itself is guarded against digit/dot adjacency —
# `(?<![\d.])429(?![\d.])` (gh-1592 review): `\b429\b` still matched the
# `429` inside decimals like `0.429` / `429.5` (`.` is a non-word char,
# so both sides of the token were boundaries), letting echoed output that
# pairs a decimal with rate-limit wording re-trigger the
# misclassification; the lookarounds keep every real shape (`429: …`,
# `HTTP/1.1 429 …`, `"code": 429`) while rejecting `0.429`, `429.5`,
# `1429`.
# `(?im)` rides the pattern because harbor compiles with re.IGNORECASE
# only; the `^` anchors each attempt to a line start so classification
# stays linear over multi-MB tee'd streams, and the `[^\r\n]*` spans keep
# every match line-scoped.
_429_TOKEN = r"(?<![\d.])429(?![\d.])"
_429_SAME_LINE = (
    r"(?im)^[^\r\n]*" + _429_TOKEN + r"[^\r\n]*{word}[^\r\n]*"
    r"|^[^\r\n]*{word}[^\r\n]*" + _429_TOKEN + r"[^\r\n]*"
)
_ANCHORED_RATE_LIMIT_PATTERNS = [
    # Replaces the inherited `rate.?limit` substring entry.
    ErrorPattern(_429_SAME_LINE.format(word=r"rate.?limit"), ApiRateLimitError),
    # Sibling audit (gh-1592): `too many requests` — same free-text
    # substring class, anchored the same way. The usage-limit, auth,
    # capacity and safety entries are full-sentence signatures with no
    # observed FP class and stay inherited verbatim.
    ErrorPattern(
        _429_SAME_LINE.format(word=r"too many requests"), ApiRateLimitError
    ),
]

# Issue #1408 AC1 (review 5456649624): the in-container job-log dir,
# OUTSIDE the graded task workspace — same constant the terminal-bench
# adapter defines (bench/terminal_bench/fa_agent.py); a future relocation
# must move the two adapters together.
_CONTAINER_JOB_LOG_DIR = "/tmp/fa-harness-artifacts/bash_jobs"

# Pinned $/Mtok table (data, not code) for est_cost_usd (issue #1123).
_PRICING_PATH = Path(__file__).resolve().parent.parent / "pricing.json"

# Sessions are written here inside the environment; harbor syncs /logs/agent
# back to the host trial dir after the trial (Trial._download_agent_logs).
_SESSION_ROOT = "/logs/agent/fah-sessions"

_POLL_SEC = 5.0
_AUDIT_PATH = "/logs/agent/fa-timeout-metadata.json"


# ── gh-1576: external-kill audit trail (I2) — signal lifecycle ──────────
# ONE process-level disposition per signal, held on behalf of every live
# FaAgent trial in the loop (the workflow exposes --n-concurrent):
# the FIRST trial captures the process's previous disposition and
# installs, overlapping trials attach to the same holder, and the LAST
# release removes the handler and RESTORES the captured disposition.
# (Review round 2, PRRT_kwDOTXdlLc6sD_xd: a bare
# loop.remove_signal_handler leaves SIG_DFL behind — the captured
# `previous` (harbor's graceful handler) permanently gone for the rest
# of the process — and per-trial installs clobber each other when
# trials overlap.)
_AUDIT_SIGNAL_HOLDER: dict = {}


def _previous_restorable(previous) -> bool:
    """False when the captured disposition cannot be restored from here.

    `asyncio.unix_events._sighandler_noop` means ANOTHER loop owns the
    signal via its own add_signal_handler registration — we can neither
    re-register their callback nor faithfully restore it, so we prefer
    NOT installing over half-restoring (the cancel-path flush still
    covers I2). Python-level callables, SIG_DFL, SIG_IGN and
    default_int_handler are all restorable via signal.signal.
    """
    unix_events = getattr(asyncio, "unix_events", None)
    noop = getattr(signal, "sighandler_noop", None) or getattr(
        unix_events, "_sighandler_noop", None
    )
    return not (noop is not None and previous is noop)


def _hold_signal_auditor(agent, sig, loop) -> bool:
    """Attach `agent` to the signal's audit holder; install if first.

    Returns False (installs nothing) when the disposition is owned by
    another loop or cannot be captured/restored — best-effort by
    contract.
    """
    entry = _AUDIT_SIGNAL_HOLDER.get(sig)
    if entry is not None:
        if entry["loop"] is not loop:
            return False  # another loop owns the disposition — skip
        if agent in entry["agents"]:
            return True  # idempotent attach
        entry["refs"] += 1
        entry["agents"].append(agent)
        return True
    previous = signal.getsignal(sig)
    if not _previous_restorable(previous):
        return False
    try:
        loop.add_signal_handler(
            sig, _dispatch_external_kill, sig.name, loop, previous
        )
    except (NotImplementedError, RuntimeError, ValueError, OSError):
        return False
    _AUDIT_SIGNAL_HOLDER[sig] = {
        "refs": 1,
        "previous": previous,
        "loop": loop,
        "agents": [agent],
    }
    return True


def _release_signal_auditor(agent, sig, loop) -> None:
    """Detach `agent`; the LAST release restores the previous disposition."""
    entry = _AUDIT_SIGNAL_HOLDER.get(sig)
    if entry is None:
        return
    if agent in entry["agents"]:
        entry["agents"].remove(agent)
        entry["refs"] -= 1
    if entry["refs"] > 0:
        return
    del _AUDIT_SIGNAL_HOLDER[sig]
    try:
        loop.remove_signal_handler(sig)
    except (NotImplementedError, RuntimeError, ValueError):
        pass
    previous = entry["previous"]
    if previous is not None:
        try:
            signal.signal(sig, previous)
        except (ValueError, OSError, TypeError):
            pass


def _dispatch_external_kill(signame: str, loop, previous) -> None:
    """Sync signal-handler body: flush EVERY live trial's audit.

    Runs on the main thread at an arbitrary bytecode boundary — all loop
    interaction goes through call_soon_threadsafe. With a `previous`
    disposition (the production signal path), the signal is restored and
    re-delivered once every flush write has landed — the process still
    dies, the audits just outlive the race. previous=None (tests) skips
    the re-delivery.
    """
    sig = getattr(signal, signame, None)
    entry = _AUDIT_SIGNAL_HOLDER.get(sig) if sig is not None else None
    agents = list(entry["agents"]) if entry else []

    def _flush_all() -> None:
        writes = []
        for agent in agents:
            task = agent._schedule_external_kill_write(signame, None)
            if task is not None:
                writes.append(task)

        def _rehonor(_done=None) -> None:
            if previous is None or sig is None:
                return
            try:
                signal.signal(sig, previous)
                os.kill(os.getpid(), sig)
            except (ValueError, OSError, TypeError):
                pass

        if previous is None or sig is None:
            return
        if writes:
            asyncio.gather(*writes).add_done_callback(_rehonor)
        else:
            _rehonor()

    try:
        loop.call_soon_threadsafe(_flush_all)
    except RuntimeError:
        pass  # loop already closed — nothing left to flush into


class FaAgent(BaseInstalledAgent):
    # gh-1592: the inherited table's rate-limit entries are free-text
    # substrings (see _ANCHORED_RATE_LIMIT_PATTERNS above) — replace the
    # pair, keep every other entry (auth, usage-limit, capacity, safety,
    # transport, the `API Error` catch-all) byte-identical so the rest of
    # harbor's classification policy is untouched. When several patterns
    # match the same text, harbor keeps the match with the LARGEST span
    # (exact ties go to the earlier-compiled pattern), so on a line
    # carrying both a 429 wording and the `API Error` catch-all the
    # anchored entries win because their match spans to END-OF-LINE —
    # table position is irrelevant here (appended-last would actually
    # LOSE an exact tie). That full-line span also flips one contrived
    # same-line tie vs the pre-fix table: rate-limit wording placed
    # before a later same-line transport needle (e.g. "could not resolve
    # host") now classifies ApiRateLimitError where the broad pair let
    # the transport class win on span. Both classes are retryable and
    # real provider-429 lines carry no transport phrasing, so the flip
    # is accepted (verified against harbor 0.23.0, gh-1592 review).
    ERROR_PATTERNS = [
        p
        for p in BaseInstalledAgent.ERROR_PATTERNS
        if p.exception is not ApiRateLimitError
    ] + _ANCHORED_RATE_LIMIT_PATTERNS

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
        # Issue #1408 AC1: fa's bash-job logs (.fah/bash_jobs/) used to land
        # INSIDE the task workspace, capturing raw secret values from the
        # agent's own greps; the graded diff (test_no_other_files_changed)
        # then failed on the agent sanitizing the harness's own logs.
        # Relocate them outside the workspace — /tmp is the in-container
        # twin of the runner's $RUNNER_TEMP (same dir the tb adapter uses).
        env["FAH_JOB_LOG_DIR"] = _CONTAINER_JOB_LOG_DIR
        key_var = json.loads(os.environ["FA_PROVIDER_CONFIG"]).get("apiKeyEnvVar")
        if key_var and os.environ.get(key_var):
            env[f"{key_var}_BASE64"] = _b64(os.environ[key_var])
        # gh-1556 AC7 + gh-1576: fa's deadline awareness rides the same env
        # — the effective cap (min of the external harness cap and the
        # adapter knobs) minus the wrap-up margin, resolved once in run()
        # via _timeout.resolve_deadline and stashed on self, so the audit
        # records the exact value this export carries. With no cap input
        # at all the export is absent: fa never invents a clock.
        deadline = getattr(self, "_deadline_epoch_ms", None)
        if deadline is not None:
            env["FA_DEADLINE_EPOCH_MS"] = str(deadline)
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
        # gh-1576 cap resolution (I1): the effective cap is min(external
        # harness cap, adapter knobs); with NO known input the contract is
        # byte-identical — no deadline export, no audit, plain exec.
        cap, deadline = _timeout.resolve_deadline(knobs)
        self._cap = cap
        self._deadline_epoch_ms = deadline
        if cap is None:
            await self.exec_as_agent(
                environment, command=self._agent_command(instruction),
                env=self._provider_env,
            )
            return
        if knobs is None:
            # A known external cap with no adapter knobs: the harness owns
            # the kill (we do not supervise), but fa still learns the true
            # budget (I1) and the trial still leaves an audit trail (I2).
            await self._run_external_cap_only(instruction, environment)
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

        gh-1576: the kill deadlines clamp to the external harness cap (the
        decider dies at min(knob deadline, external) and names the winner
        external_cap), the audit is checkpointed incrementally so even a
        SIGKILL leaves the last progress sample, and BOTH external kill
        paths — a cancellation of this coroutine (harbor's own wait_for
        firing first) and a SIGTERM/SIGINT to this process — flush a final
        outcome=external_kill record (I2). The incremental checkpoints are
        what survives a SIGKILL; nothing else can (non-goal E3).
        """
        cap, deadline = _timeout.resolve_deadline(knobs)
        self._cap = cap
        self._deadline_epoch_ms = deadline
        self._run_environment = environment
        self._external_kill_flushed = False
        ladder = (
            # gh-1556 (Class C): parity with bench/terminal_bench/
            # fa_agent.py — when a watch knob is set the kill decision is
            # the gap-aware ProgressWatch (issue #1392/#1430), not the
            # retired byte-growth ladder. bench-harbor.yml now sets the
            # knobs on every shard, so watch mode is the bench default;
            # with knobs removed the legacy ProgressLadder runs
            # byte-for-byte (round-2 REG). gh-1576: both deciders clamp
            # their kill deadline to the external cap when one is known.
            _timeout.ProgressWatch(
                knobs,
                external_cap_sec=cap.external_cap_sec if cap else None,
            )
            if knobs.progress_watch
            else _timeout.ProgressLadder(
                knobs,
                external_cap_sec=cap.external_cap_sec if cap else None,
            )
        )
        loop = asyncio.get_running_loop()
        start = loop.time()
        outcome = None
        self._checkpoint_state = None
        exec_task = asyncio.create_task(
            self.exec_as_agent(
                environment, command=self._agent_command(instruction),
                env=self._provider_env,
            )
        )
        try:
            with self._kill_auditors():
                while not exec_task.done():
                    remaining = ladder.kill_at - (loop.time() - start)
                    await asyncio.sleep(min(_POLL_SEC, max(remaining, 0.05)))
                    outcome = ladder.evaluate(
                        loop.time() - start, await self._progress_bytes(environment)
                    )
                    await self._maybe_checkpoint(environment, knobs, ladder)
                    if outcome:
                        # gh-1556 AC1: the kill is best-effort and can never
                        # replace the ladder's TimeoutError. The pre-fix command
                        # was `pkill -f 'fa --session-root'` — the exec wrapper's
                        # OWN cmdline contains that pattern, so pkill SIGTERMed
                        # its own shell (exit 143), the exception skipped the
                        # audit write AND the TimeoutError, and harbor recorded a
                        # ladder kill as an agent crash (TB 2.0 run 38150649548:
                        # a SOLVED task scored 0). The bracket trick matches the
                        # agent process but not this command line, and any kill
                        # failure is swallowed: harbor's own task timeout still
                        # bounds the trial.
                        try:
                            await self.exec_as_root(
                                environment,
                                command="pkill -f '[f]a --session-root' || true",
                                timeout_sec=15,
                            )
                        except Exception:
                            pass
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
                deadline_epoch_ms=self._deadline_epoch_ms,
                cap=cap,
            )
        except asyncio.CancelledError:
            # gh-1576 (I2): harbor's wait_for fired first — the incident's
            # exact kill class (run 38271607849: four trials killed at
            # 1800.000s, zero audit files). The container is still up
            # during teardown, so the flush lands. Never masked by an exec
            # failure; the cancellation always re-raises.
            await self._flush_external_kill_audit(
                environment, knobs, ladder, cap, cause="cancelled"
            )
            raise
        if outcome:
            raise asyncio.TimeoutError(
                f"fa agent killed by bench timeout ladder: {outcome}"
            )
        if error is not None:
            raise error

    async def _run_external_cap_only(self, instruction: str, environment) -> None:
        """Unsupervised exec under a known external cap (gh-1576).

        The harness owns the kill; the adapter's whole job here is I1+I2:
        fa sees the truthful deadline (via _provider_env) and every
        termination — clean exit, external cancellation, SIGTERM — leaves
        the audit record.
        """
        cap = self._cap
        self._run_environment = environment
        self._external_kill_flushed = False
        error = None
        try:
            with self._kill_auditors():
                await self.exec_as_agent(
                    environment, command=self._agent_command(instruction),
                    env=self._provider_env,
                )
        except asyncio.CancelledError:
            await self._flush_external_kill_audit(
                environment, None, None, cap, cause="cancelled"
            )
            raise
        except BaseException as exc:  # noqa: BLE001 - re-raised below
            # I2 (review round 2): a crashed exec (harbor's
            # NonZeroAgentExitCodeError after a non-zero fa exit) used to
            # propagate without any audit — the exact "the kill came from
            # outside, the audit writer never ran" gap this card closes.
            # Mirror the supervised sibling: audit, then re-raise.
            error = exc
        await self._write_audit(
            environment, None, None,
            "crashed" if error is not None else "completed",
            deadline_epoch_ms=self._deadline_epoch_ms,
            cap=cap,
        )
        if error is not None:
            raise error

    # ── gh-1576: external-kill audit trail (I2) ──────────────────────────

    @contextmanager
    def _kill_auditors(self):
        """SIGTERM/SIGINT handlers that flush the audit before dying.

        Installed for the duration of a supervised (or external-cap-only)
        run, main thread only, and restored afterwards. The disposition
        is held PER PROCESS (module-level holder): overlapping trials
        (--n-concurrent > 1) attach to the same handler, and the captured
        `previous` disposition is restored by the LAST release — a bare
        loop.remove_signal_handler would leave SIG_DFL behind, killing
        harbor's graceful handling for the rest of the process. A
        disposition we cannot faithfully restore (another loop's
        add_signal_handler registration) is never stolen: we skip the
        install (the cancel-path flush still covers I2).
        """
        loop = asyncio.get_running_loop()
        if (
            threading.current_thread() is not threading.main_thread()
            or not hasattr(loop, "add_signal_handler")
        ):
            yield
            return
        held = [
            sig
            for sig in (signal.SIGTERM, signal.SIGINT)
            if _hold_signal_auditor(self, sig, loop)
        ]
        try:
            yield
        finally:
            for sig in held:
                _release_signal_auditor(self, sig, loop)

    def _schedule_external_kill_write(self, signame: str, cause: str):
        """The once-per-trial external_kill audit write task (or None).

        Idempotent against the cancel-path flush (first writer wins);
        the signal dispatch rehonors the captured disposition after the
        LAST live trial's write lands.
        """
        if getattr(self, "_external_kill_flushed", False):
            return None
        self._external_kill_flushed = True
        environment = getattr(self, "_run_environment", None)

        async def _write():
            if environment is None:
                return
            await self._write_audit(
                environment,
                None,
                None,
                "external_kill",
                deadline_epoch_ms=getattr(self, "_deadline_epoch_ms", None),
                cap=getattr(self, "_cap", None),
                external_kill={"signal": signame, "cause": cause},
            )

        return asyncio.ensure_future(_write())

    async def _flush_external_kill_audit(
        self, environment, knobs, ladder, cap, cause: str
    ) -> None:
        """The cancellation-path flush: bounded, best-effort, then reraise."""
        if getattr(self, "_external_kill_flushed", False):
            return
        self._external_kill_flushed = True
        try:
            await asyncio.wait_for(
                self._write_audit(
                    environment,
                    knobs,
                    ladder,
                    "external_kill",
                    deadline_epoch_ms=getattr(self, "_deadline_epoch_ms", None),
                    cap=cap,
                    external_kill={"signal": None, "cause": cause},
                ),
                timeout=15,
            )
        except Exception:
            pass  # never mask the cancellation with an audit failure

    async def _maybe_checkpoint(self, environment, knobs, ladder) -> None:
        """Incremental audit checkpoint (I2/E3): a partial marker per
        changed sample, so even a SIGKILL leaves the last progress state.
        Fail-soft by contract; skipped when nothing changed (a silent
        agent checkpoints once, then stops touching the file).
        """
        state = (
            getattr(ladder, "last_bytes", 0),
            round(getattr(ladder, "kill_at", 0.0), 3),
            len(getattr(ladder, "events", []) or []),
        )
        if state == self._checkpoint_state:
            return
        self._checkpoint_state = state
        try:
            await asyncio.wait_for(
                self._write_audit(
                    environment,
                    knobs,
                    ladder,
                    "running",
                    deadline_epoch_ms=self._deadline_epoch_ms,
                    cap=getattr(self, "_cap", None),
                    checkpoint=True,
                ),
                timeout=10,
            )
        except Exception:
            pass  # a lost checkpoint must never fail the trial

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

    async def _write_audit(
        self, environment, knobs, ladder, outcome, deadline_epoch_ms=None,
        cap=None, checkpoint=False, external_kill=None,
    ) -> None:
        # AC4 (issue #1122): audit trail synced back with the agent logs.
        # AC6 (issue #1185): the audit also documents the harness-originated
        # share of the progress sample — the ⏳ liveness lines the pane
        # counter counts as progress. Both numbers are byte measures taken
        # where the file lives (one exec, no stream round-trip: a 600s+
        # trial can leave tens of MB of pane bytes, and a transport decode
        # would make len(utf-8) disagree with the ladder's live wc -c).
        # Fields drop when the stream is unreadable, never fabricated.
        # gh-1576: cap carries the cap-resolution block (winning source +
        # both inputs); checkpoint rows skip the stream measurement (they
        # are partial markers, written on the poll loop) and an
        # external_kill flush records which signal/cause ended the trial.
        if checkpoint:
            progress = liveness = None
        else:
            progress, liveness = await self._measure_streams(environment)
        record = _timeout.audit_dict(
            knobs,
            ladder if knobs is not None else None,
            outcome,
            progress_bytes=progress,
            liveness_bytes=liveness,
            deadline_epoch_ms=deadline_epoch_ms,
            cap=cap,
        )
        if checkpoint:
            record["checkpoint"] = True
        if external_kill:
            record["external_kill"] = external_kill
        payload = base64.b64encode(json.dumps(record).encode()).decode()
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

    async def _measure_streams(self, environment) -> tuple[int | None, int | None]:
        """Byte-exact (progress, liveness) for the AC6 audit.

        progress = `wc -c` on the pane stream — the same measure the
        ladder's `_progress_bytes` samples, so both auditors agree.
        liveness = byte count of fa's liveness lines inside it — BOTH
        families, matching [_timeout.liveness_bytes_of]: the ⏳
        tool-liveness lines (gh-1055) and the `… reasoning`
        reasoning-liveness lines (gh-1198/gh-1430). grep passes whole
        lines through, `wc -c` counts them; grep terminates a final
        unterminated line, the only ±1 w.r.t. the pure-Python rule in
        [_timeout.liveness_bytes_of] — an audit heuristic, not a spec).
        """
        try:
            result = await self.exec_as_agent(
                environment,
                command=(
                    "if p=$(wc -c < /logs/agent/fa.txt 2>/dev/null); then "
                    "l=$(grep -hF -e '\u23f3' -e '… reasoning' "
                    "/logs/agent/fa.txt 2>/dev/null "
                    "| wc -c); "
                    "printf '%s %s' \"$p\" \"$l\"; fi"
                ),
                timeout_sec=15,
            )
            if result.return_code == 0 and (result.stdout or "").strip():
                progress, _, liveness = result.stdout.strip().partition(" ")
                if progress:
                    return (int(progress), int(liveness or 0))
        except Exception:
            pass
        return (None, None)

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
