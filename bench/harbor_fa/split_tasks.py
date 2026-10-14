#!/usr/bin/env python3
"""Split a downloaded harbor dataset into CPU and GPU task shards.

Usage:
    split_tasks.py <dataset-dir> [--filter <glob>[,<glob>...]] [--shards N]
                   [--cpu-env ENV] [--task-prefix PREFIX]

Scans every <dataset-dir>/*/task.toml for a `gpus > 0` declaration.
CPU tasks (gpus == 0 or absent) are chunked into `--shards` shards on the
env given by --cpu-env (default `docker` — issue #1316 makes local docker
the default sandbox on GH runners; pass modal for the self-hosted path).
GPU tasks always go on modal — the GPU split rides
the same matrix as a shard with env=modal.

harbor's `-i` filter matches fully-qualified task ids (`<org>/<name>`, as
`get_name()` reports them), so --task-prefix (e.g. `terminal-bench/`, the
org part of the dataset spec) is prepended to every emitted task name.

With --shards, writes the workflow matrix to $GITHUB_OUTPUT (or stdout):
    matrix={"include": [{"i": 0, "env": "modal", "tasks": "a b c"}, ...,
                        {"i": N,   "env": "modal",  "tasks": "gpu1 gpu2"}]}
    count=... cpu_count=... gpu_count=...

Without it, prints the plain split (CPU_TASKS=... GPU_TASKS=... counts).
`--filter` (comma fnmatch globs on task names) narrows both lists — the
smoke path passes one task name and gets a single-task shard.

gh-1576 — external-cap discovery: every task's declared agent timeout
(task.toml `[agent] timeout_sec`, the value harbor's runner feeds its own
`asyncio.wait_for` around the agent) is resolved HERE, pre-launch, and
exported per shard: with --shards each matrix `include` entry carries
`external_cap` (the MIN across the shard's tasks — one env value bounds
every task in the shard, and the smallest declared cap can never let fa's
deadline outlive any harness kill); without it, CPU_CAP/GPU_CAP lines.
A shard where no task declares a timeout emits NO cap (absent key renders
an empty env var — the adapter's knobs rule alone, byte-identical, AC5).
"""
import argparse
import fnmatch
import json
import math
import os
import sys
import tomllib
from pathlib import Path


def _max_gpus(obj) -> int:
    if isinstance(obj, dict):
        best = 0
        for key, value in obj.items():
            if key == "gpus" and isinstance(value, int):
                best = max(best, value)
            else:
                best = max(best, _max_gpus(value))
        return best
    if isinstance(obj, list):
        return max((_max_gpus(v) for v in obj), default=0)
    return 0


def _agent_timeout_sec(config: dict) -> float | None:
    """The task's declared agent timeout (gh-1576 cap discovery).

    Reads harbor's task.toml `[agent] timeout_sec` — the same value
    harbor's runner feeds its own `asyncio.wait_for` around the agent.
    None when undeclared or unusable: no cap is ever invented (E1), and
    a malformed declaration degrades to unknown exactly like a malformed
    FA_EXTERNAL_CAP_SEC does on the adapter side (AC8).
    """
    agent = config.get("agent")
    if not isinstance(agent, dict):
        return None
    value = agent.get("timeout_sec")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(float(value)) or value <= 0:
        return None
    return float(value)


def _split(dataset_dir: Path, globs: list[str]) -> tuple[list[str], list[str], dict]:
    """(cpu tasks, gpu tasks, declared agent caps by task name).

    caps[name] is None for a task without a declared agent timeout —
    such a task never constrains its shard's cap.
    """
    cpu: list[str] = []
    gpu: list[str] = []
    caps: dict = {}
    for task_dir in sorted(dataset_dir.iterdir()):
        task_toml = task_dir / "task.toml"
        if not task_toml.is_file():
            continue
        name = task_dir.name
        if globs and not any(fnmatch.fnmatch(name, g) for g in globs):
            continue
        config = tomllib.loads(task_toml.read_text())
        caps[name] = _agent_timeout_sec(config)
        (gpu if _max_gpus(config) > 0 else cpu).append(name)
    return cpu, gpu, caps


def _shard_cap(caps: dict, tasks: list[str]) -> float | None:
    """The MIN declared cap across a shard's tasks (gh-1576 I1).

    A shard runs several tasks under ONE exported FA_EXTERNAL_CAP_SEC;
    the conservative truth is the smallest declared cap — fa's deadline
    can then never outlive any task's harness kill. Tasks without a
    declared cap don't constrain; a shard with none exports no cap at
    all (the adapter's knobs rule alone, byte-identical — AC5/E1).
    """
    declared = [caps[t] for t in tasks if caps.get(t) is not None]
    return min(declared) if declared else None


def _cap_str(cap: float | None) -> str:
    if cap is None:
        return ""
    return str(int(cap)) if float(cap).is_integer() else str(cap)


def _chunk(tasks: list[str], shards: int) -> list[list[str]]:
    shards = max(1, min(shards, len(tasks) or 1))
    size, extra = divmod(len(tasks), shards)
    out, at = [], 0
    for i in range(shards):
        end = at + size + (1 if i < extra else 0)
        out.append(tasks[at:end])
        at = end
    return out


def _emit(pairs: list[tuple[str, str]]) -> None:
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a") as f:
            f.writelines(f"{k}={v}\n" for k, v in pairs)
    else:
        for k, v in pairs:
            print(f"{k}={v}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset_dir", type=Path)
    parser.add_argument("--filter", default="")
    parser.add_argument("--shards", type=int, default=0)
    parser.add_argument("--cpu-env", default="docker")
    parser.add_argument("--task-prefix", default="")
    args = parser.parse_args()

    globs = [g.strip() for g in args.filter.split(",") if g.strip()]
    cpu, gpu, caps = _split(args.dataset_dir, globs)
    if not cpu and not gpu:
        print("no tasks matched", file=sys.stderr)
        return 1

    if not args.shards:
        print(f'CPU_TASKS="{" ".join(cpu)}"')
        print(f'GPU_TASKS="{" ".join(gpu)}"')
        print(f"CPU_COUNT={len(cpu)}")
        print(f"GPU_COUNT={len(gpu)}")
        # gh-1576: the smallest declared agent cap per list (empty when
        # no task declares one — no cap is invented).
        print(f'CPU_CAP="{_cap_str(_shard_cap(caps, cpu))}"')
        print(f'GPU_CAP="{_cap_str(_shard_cap(caps, gpu))}"')
        return 0

    include = [
        {
            "i": i,
            "env": args.cpu_env,
            "kind": "cpu",
            "tasks": " ".join(args.task_prefix + t for t in chunk),
            # gh-1576: the shard's external harness cap — the min declared
            # agent timeout across its tasks, exported by the workflow as
            # FA_EXTERNAL_CAP_SEC (absent key renders empty = unknown).
            **(
                {"external_cap": _cap_str(_shard_cap(caps, chunk))}
                if _shard_cap(caps, chunk) is not None
                else {}
            ),
        }
        for i, chunk in enumerate(_chunk(cpu, args.shards))
        if chunk
    ]
    if gpu:
        gpu_chunk = gpu
        include.append(
            {
                "i": len(include),
                "env": "modal",
                "kind": "gpu",
                "tasks": " ".join(args.task_prefix + t for t in gpu_chunk),
                **(
                    {"external_cap": _cap_str(_shard_cap(caps, gpu_chunk))}
                    if _shard_cap(caps, gpu_chunk) is not None
                    else {}
                ),
            }
        )
    _emit(
        [
            ("matrix", json.dumps({"include": include})),
            ("count", str(len(cpu) + len(gpu))),
            ("cpu_count", str(len(cpu))),
            ("gpu_count", str(len(gpu))),
        ]
    )
    print(
        f"{len(cpu)} CPU task(s) across {len(include) - (1 if gpu else 0)}"
        f" {args.cpu_env} shard(s), {len(gpu)} GPU task(s) on modal"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
