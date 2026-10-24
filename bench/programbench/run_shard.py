#!/usr/bin/env python3
"""Per-shard driver: fa solves ProgramBench tasks in airgapped containers.

One invocation = one shard from bench-programbench.yml's matrix. Per task:

  1. pull  programbench/<iid with __ -> _1776_>:task_cleanroom_v6  (x86_64)
  2. boot  on the boot network (internet ON) and bootstrap what inference
           may NOT fetch later: CA roots (the fa_agent.py live-smoke lesson
           — task images ship without them) + the fa CLI bundle
  3. cut   the internet: disconnect boot, connect the INTERNAL network
           (docker --internal = no external route), map the provider API
           hostname to that network's gateway where the host-side
           llm_forwarder.py listens — the container can reach the LLM API
           and nothing else (ProgramBench rule: no internet at inference)
  4. run   fa headless in /workspace with the provider preconfig env
           (base64 transport, byte-identical to bench/harbor_fa/fa_agent.py)
  5. pack  tar /workspace -> submission.tar.gz (the eval input), copy the
           session logs out for cost/calls accounting + traj.json
  6. eval  once per shard at the end: `programbench eval <run_dir>`
           (batched, skips already-evaluated instances)

Quota discipline (the tbench 2.1 kimi saga, gh-1674): a provider rate-limit
on task N aborts the remaining tasks of the shard (exit 2, never retried
inline — the owner reruns); only a ZERO-trial startup crash is retried
once, by the workflow (the gh-1658 shape).

Usage:
  run_shard.py <run_dir> --tasks "<iid iids...>" --agent-timeout SEC
               --net-boot NAME --net-llm NAME --gateway IP --api-host HOST
               [--status FILE] [--eval-workers N]

Env (secrets env-only, never echoed): FA_BUNDLE_TARBALL, FA_PROVIDER_TYPE,
FA_PROVIDER_CONFIG, <apiKeyEnvVar>, FA_REF.
"""

from __future__ import annotations

import base64
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

IMAGE_TAG = "task_cleanroom_v6"

# bench/harbor_fa/fa_agent.py gh-1592: unanchored `rate.?limit` substrings
# misclassify fa's own echoed notices (its `[roles] rate limited on … —
# retrying` lines) as provider 429s. Same anchor here: the structured
# provider-error context and the 429 token must share ONE line, guarded
# against digit/dot adjacency.
RATE_LIMIT_MARKERS = (
    "[roles] rate limited on",  # fa's own provider-429 notice (pre-429 backoff)
    "429: ",  # formatProviderError renders "<statusCode>: <message>"
    "HTTP/1.1 429 ",  # raw status line
    '"code": 429',  # JSON error body
)

SOLVE_PROMPT = """\
Rebuild, from scratch, a program that matches the reference executable's \
behavior. Work in the current directory (/workspace).

You are given a reference executable at ./executable and its bundled \
documentation. Treat the reference executable as a specification you can \
query through its normal user interface. Your submission must be an \
independent implementation: using the original source code, wrapping the \
reference executable, or installing an existing implementation does not \
satisfy the task and will receive no credit.

RULES (the benchmark's official contract):
- Do NOT search the internet, clone repos or forks, or fetch this project's \
source from package registries or project websites. There is no internet \
access, by design.
- Do NOT wrap, shim, or delegate to the reference ./executable or any \
pre-built version of the same tool; the final ./executable must not depend \
on it at runtime.
- Do NOT decompile ./executable or use disassemblers, strace, or ltrace on \
it. Running it with any inputs/flags to observe behavior IS allowed, as is \
reading the bundled documentation.

DELIVERABLE:
- Write source code implementing the observed behavior.
- Provide ./compile.sh (executable) that, on a fresh checkout, installs any \
needed dependencies and produces ./executable in the workspace root. If \
compile.sh fails on a fresh checkout, the task fails.
- Keep built artifacts out of git (add them to .gitignore) and commit your \
source changes with git.
- Test your own binary extensively against the reference before finishing \
(tmux/libtmux is installed for TUI tasks).\
"""


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def sh(cmd: str, **kw) -> subprocess.CompletedProcess:
    return run(["sh", "-c", cmd], **kw)


def die(msg: str, code: int = 1) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(code)


def b64(value: str) -> str:
    return base64.b64encode(value.encode()).decode()


def docker_ncpu() -> int:
    """CPUs the docker daemon can use — the ceiling `docker run --cpus`
    validates against. programbench's default DOCKER_CPUS is 10, and GH
    hosted runners expose 4, so every eval container died at `docker run`
    with "range of CPUs is from 0.01 to 4.00" (gh-1816)."""
    p = run(["docker", "info", "--format", "{{.NCPU}}"])
    if p.returncode == 0:
        try:
            return max(1, int(p.stdout.strip()))
        except ValueError:
            pass
    return max(1, os.cpu_count() or 1)


def eval_env() -> dict[str, str]:
    """Environment for the programbench eval subprocess: PROGRAMBENCH_DOCKER_CPUS
    defaults to the daemon's NCPU (an explicit env setting wins)."""
    env = os.environ.copy()
    if not env.get("PROGRAMBENCH_DOCKER_CPUS"):
        env["PROGRAMBENCH_DOCKER_CPUS"] = str(docker_ncpu())
    return env


class Shard:
    def __init__(self) -> None:
        a = sys.argv[1:]
        self.run_dir = Path(a[0])
        self.tasks = a[a.index("--tasks") + 1].split()
        self.agent_timeout = int(a[a.index("--agent-timeout") + 1])
        self.net_boot = a[a.index("--net-boot") + 1]
        self.net_llm = a[a.index("--net-llm") + 1]
        self.gateway = a[a.index("--gateway") + 1]
        self.api_host = a[a.index("--api-host") + 1]
        si = a.index("--status") + 1 if "--status" in a else None
        self.status_path = Path(a[si]) if si else self.run_dir / "shard-status.jsonl"
        self.eval_workers = int(a[a.index("--eval-workers") + 1]) if "--eval-workers" in a else 1

        self.bundle = os.environ.get("FA_BUNDLE_TARBALL", "fa-bundle.tar.gz")
        if not Path(self.bundle).is_file():
            die(f"fa bundle tarball not found: {self.bundle} — build it with `dart build cli --target=bin/fah.dart`")
        self.provider_type = os.environ.get("FA_PROVIDER_TYPE", "anthropic")
        config = os.environ.get("FA_PROVIDER_CONFIG", "")
        if not config:
            die("FA_PROVIDER_CONFIG is empty — the setup resolve step must run first")
        self.config = config
        key_var = json.loads(config).get("apiKeyEnvVar", "")
        self.key_value = os.environ.get(key_var, "") if key_var else ""
        self.key_var = key_var
        self.fa_ref = os.environ.get("FA_REF", "")
        self.model = json.loads(config).get("model", "")
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.status_file = self.status_path.open("a")

    def record(self, iid: str, outcome: str, exit_code: int | None, wall: float) -> None:
        self.status_file.write(
            json.dumps({"iid": iid, "outcome": outcome, "exit_code": exit_code, "wall_sec": round(wall, 1)}) + "\n"
        )
        self.status_file.flush()

    # ── container lifecycle ────────────────────────────────────────────

    def image_for(self, iid: str) -> str:
        return f"programbench/{iid.replace('__', '_1776_')}:{IMAGE_TAG}"

    def bootstrap_container(self, iid: str) -> str | None:
        """Boot on the internet-facing network and install everything
        inference itself must not download. Returns the container name."""
        name = f"pbench-{iid}"
        img = self.image_for(iid)
        pull = run(["docker", "pull", img])
        if pull.returncode != 0:
            print(f"::error::docker pull failed for {img}: {pull.stderr.strip()[-400:]}", file=sys.stderr)
            return None
        boot = run(
            ["docker", "run", "-d", "--name", name, "--network", self.net_boot,
             "--entrypoint", "sh", img, "-c", "sleep infinity"]
        )
        if boot.returncode != 0:
            print(f"::error::docker run failed for {img}: {boot.stderr.strip()[-400:]}", file=sys.stderr)
            return None
        # CA roots (fa_agent.py: Dart TLS dies with CERTIFICATE_VERIFY_FAILED
        # otherwise) — best-effort across distros, no-op where present.
        sh(
            "docker exec -u root " + name + " sh -c '"
            "if [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then "
            "if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq ca-certificates; "
            "elif command -v apk >/dev/null; then apk add --no-cache ca-certificates; "
            "elif command -v dnf >/dev/null; then dnf install -y ca-certificates; "
            "elif command -v yum >/dev/null; then yum install -y ca-certificates; "
            "fi; fi || true'"
        )
        # fa bundle: same install surface as harbor's install(): /opt/fa +
        # `fa` on PATH + autopilot approval + version sanity.
        if run(["docker", "cp", self.bundle, f"{name}:/tmp/fa-bundle.tar.gz"]).returncode != 0:
            print(f"::error::bundle copy failed for {iid}", file=sys.stderr)
            run(["docker", "rm", "-f", name])
            return None
        inst = sh(
            f"docker exec -u root {name} sh -c "
            f"'mkdir -p /opt/fa && tar -xzf /tmp/fa-bundle.tar.gz -C /opt/fa"
            f" && chmod +x /opt/fa/bin/fah && ln -sf /opt/fa/bin/fah /usr/local/bin/fa'"
        )
        if inst.returncode != 0:
            print(f"::error::bundle install failed for {iid}: {inst.stderr.strip()[-400:]}", file=sys.stderr)
            run(["docker", "rm", "-f", name])
            return None
        sh(f"docker exec {name} sh -c 'mkdir -p ~/.fah && printf \"approvalMode: autopilot\\n\" > ~/.fah/config.yaml'")
        ver = run(["docker", "exec", name, "fa", "--version"])
        if ver.returncode != 0:
            print(f"::error::fa --version failed in {iid}'s container: {ver.stderr.strip()[-300:]}", file=sys.stderr)
            run(["docker", "rm", "-f", name])
            return None
        # Cut the internet: off the boot bridge, onto the internal network,
        # then /etc/hosts points the provider hostname at the gateway where
        # llm_forwarder.py listens (the only reachable route).
        if run(["docker", "network", "disconnect", self.net_boot, name]).returncode != 0:
            print(f"::error::network disconnect failed for {iid}", file=sys.stderr)
            run(["docker", "rm", "-f", name])
            return None
        if run(["docker", "network", "connect", self.net_llm, name]).returncode != 0:
            print(f"::error::network connect failed for {iid}", file=sys.stderr)
            run(["docker", "rm", "-f", name])
            return None
        sh(f"docker exec -u root {name} sh -c 'echo {shlex.quote(self.gateway)} {shlex.quote(self.api_host)} >> /etc/hosts'")
        return name

    def solve_one(self, iid: str) -> tuple[str, int | None, float]:
        """Returns (outcome, fa_exit_code, wall_seconds). outcome ∈
        solved | failed | killed | rate_limited | pull_failed."""
        started = time.monotonic()
        tdir = self.run_dir / iid
        tdir.mkdir(parents=True, exist_ok=True)
        name = self.bootstrap_container(iid)
        if name is None:
            return "pull_failed", None, time.monotonic() - started
        outcome, code = "failed", None
        try:
            session_root = "/tmp/pbench-fa/sessions"
            out_file = "/tmp/pbench-fa/fa.txt"
            inner = (
                f"mkdir -p {session_root} && "
                f"fa --session-root {session_root} -p {shlex.quote(SOLVE_PROMPT)}"
                f" < /dev/null > {out_file} 2>&1; st=$?; cat {out_file}; exit $st"
            )
            exec_env = [
                "-e", f"FA_PROVIDER_TYPE={self.provider_type}",
                "-e", f"FA_PROVIDER_CONFIG_BASE64={b64(self.config)}",
                "-e", "FAH_JOB_LOG_DIR=/tmp/fa-harness-artifacts/bash_jobs",
            ]
            if self.key_var and self.key_value:
                exec_env += ["-e", f"{self.key_var}_BASE64={b64(self.key_value)}"]
            proc = run(
                ["timeout", "-k", "60", str(self.agent_timeout), "docker", "exec",
                 "-w", "/workspace", *exec_env, name, "sh", "-c", inner],
            )
            code = proc.returncode
            (tdir / "fa.txt").write_text(proc.stdout or "")
            if code == 124 or code == 137:
                outcome = "killed"  # the host-side cap (timeout -k escalation)
            elif code != 0 and self._is_rate_limited(proc.stdout or ""):
                outcome = "rate_limited"
            elif code == 0:
                outcome = "solved"
            # else: failed (fa's own nonzero exit)
            # Trajectory + artifacts out of the container (also the cost/
            # calls source, bench/fa_usage.py parses these session files).
            sh(f"docker cp {name}:/tmp/pbench-fa {shlex.quote(str(tdir))}/fa-artifacts")
            self._write_traj(tdir, outcome, code, time.monotonic() - started)
            # The eval input: tar of /workspace — produced even for failed/
            # killed tasks (partial work evaluates honestly to a low score,
            # the frontier norm on MLS-Bench).
            sh(f"docker exec {name} sh -c 'cd /workspace && tar -czf /tmp/submission.tar.gz .'")
            sh(f"docker cp {name}:/tmp/submission.tar.gz {shlex.quote(str(tdir))}/submission.tar.gz")
        finally:
            run(["docker", "rm", "-f", name])
        return outcome, code, time.monotonic() - started

    @staticmethod
    def _is_rate_limited(text: str) -> bool:
        return any(m in text for m in RATE_LIMIT_MARKERS)

    def _write_traj(self, tdir: Path, outcome: str, code: int | None, wall: float) -> None:
        events: list = []
        sess = tdir / "fa-artifacts" / "sessions"
        if sess.is_dir():
            for f in sorted(sess.rglob("*.jsonl")):
                for line in f.read_text(errors="replace").splitlines():
                    line = line.strip()
                    if line:
                        try:
                            events.append(json.loads(line))
                        except ValueError:
                            pass
        traj = {
            "instance_id": tdir.name,
            "agent": "fa (flutter_agent_harness)",
            "fa_ref": self.fa_ref,
            "model": self.model,
            "provider": self.provider_type,
            "outcome": outcome,
            "exit_code": code,
            "wall_sec": round(wall, 1),
            "messages": events,
        }
        (tdir / f"{tdir.name}.traj.json").write_text(json.dumps(traj))

    def eval_all(self) -> bool:
        proc = run(
            ["programbench", "eval", str(self.run_dir), "--workers", str(self.eval_workers)],
            env=eval_env(),
        )
        # gh-1816: the diagnosing traceback (programbench logs it via
        # log.error(..., exc_info=True)) lands on STDERR and was dropped
        # entirely, while stdout was tail-capped to 4k — CI kept only the
        # summary table and could never see the crash. Tee BOTH streams in
        # full into the run dir (they ride the shard artifact) and surface
        # a generous stderr tail on failure.
        (self.run_dir / "eval-stdout.log").write_text(proc.stdout or "")
        (self.run_dir / "eval-stderr.log").write_text(proc.stderr or "")
        sys.stdout.write(proc.stdout[-8000:])
        if proc.returncode != 0:
            sys.stdout.write(proc.stderr[-8000:])
            print(
                f"::warning::programbench eval exited {proc.returncode} — full output: "
                f"{self.run_dir}/eval-stdout.log + eval-stderr.log (eval.json may be missing "
                f"for some instances; the aggregate verdict catches this)",
                file=sys.stderr,
            )
            return False
        return True

    def main(self) -> int:
        started = 0  # tasks that got a booted container (a "trial")
        aborted = False
        for iid in self.tasks:
            if aborted:
                self.record(iid, "skipped", None, 0.0)
                continue
            outcome, code, wall = self.solve_one(iid)
            if outcome != "pull_failed":
                started += 1
            self.record(iid, outcome, code, wall)
            print(f"{iid}: {outcome} ({wall:.0f}s)", flush=True)
            # Dead-window guard: a provider rate limit means the quota
            # window is gone — remaining tasks would burn into 429s
            # (gh-1674). No inline retry; the owner reruns the dispatch.
            if outcome == "rate_limited":
                print(f"::error::{iid}: provider rate limit — aborting the remaining shard tasks (rerun to resume; remaining tasks marked skipped)", file=sys.stderr)
                aborted = True
        self.eval_all()
        # Exit contract the workflow's retry block keys on (gh-1658 shape):
        #   0  clean (individual task failures included — the aggregate
        #      verdict owns completeness)
        #   2  rate-limited abort — NEVER retried (dead quota window)
        #   3  zero-trial startup crash (pull/airgap/resolve transient) —
        #      the workflow retries exactly once
        if aborted:
            sys.exit(2)
        if started == 0:
            print("::error::zero trials started — every task failed before a container booted", file=sys.stderr)
            sys.exit(3)
        sys.exit(0)


if __name__ == "__main__":
    Shard().main()
