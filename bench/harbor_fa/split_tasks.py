#!/usr/bin/env python3
"""Split a downloaded harbor dataset into CPU and GPU task shards.

Usage:
    split_tasks.py <dataset-dir> [--filter <glob>[,<glob>...]] [--shards N]

Scans every <dataset-dir>/*/task.toml for a `gpus > 0` declaration.
CPU tasks (gpus == 0 or absent) are chunked into `--shards` docker shards;
GPU tasks go into one modal shard — the GPU split rides the same matrix as
a shard with env=modal (issue #147: CPU tasks on the self-hosted runner,
GPU tasks via Modal).

With --shards, writes the workflow matrix to $GITHUB_OUTPUT (or stdout):
    matrix={"include": [{"i": 0, "env": "docker", "tasks": "a b c"}, ...,
                        {"i": N,   "env": "modal",  "tasks": "gpu1 gpu2"}]}
    count=... cpu_count=... gpu_count=...

Without it, prints the plain split (CPU_TASKS=... GPU_TASKS=... counts).
`--filter` (comma fnmatch globs on task names) narrows both lists — the
smoke path passes one task name and gets a single-task shard.
"""
import argparse
import fnmatch
import json
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


def _split(dataset_dir: Path, globs: list[str]) -> tuple[list[str], list[str]]:
    cpu: list[str] = []
    gpu: list[str] = []
    for task_dir in sorted(dataset_dir.iterdir()):
        task_toml = task_dir / "task.toml"
        if not task_toml.is_file():
            continue
        name = task_dir.name
        if globs and not any(fnmatch.fnmatch(name, g) for g in globs):
            continue
        config = tomllib.loads(task_toml.read_text())
        (gpu if _max_gpus(config) > 0 else cpu).append(name)
    return cpu, gpu


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
    args = parser.parse_args()

    globs = [g.strip() for g in args.filter.split(",") if g.strip()]
    cpu, gpu = _split(args.dataset_dir, globs)
    if not cpu and not gpu:
        print("no tasks matched", file=sys.stderr)
        return 1

    if not args.shards:
        print(f'CPU_TASKS="{" ".join(cpu)}"')
        print(f'GPU_TASKS="{" ".join(gpu)}"')
        print(f"CPU_COUNT={len(cpu)}")
        print(f"GPU_COUNT={len(gpu)}")
        return 0

    include = [
        {"i": i, "env": "docker", "tasks": " ".join(chunk)}
        for i, chunk in enumerate(_chunk(cpu, args.shards))
        if chunk
    ]
    if gpu:
        include.append({"i": len(include), "env": "modal", "tasks": " ".join(gpu)})
    _emit(
        [
            ("matrix", json.dumps({"include": include})),
            ("count", str(len(cpu) + len(gpu))),
            ("cpu_count", str(len(cpu))),
            ("gpu_count", str(len(gpu))),
        ]
    )
    print(
        f"{len(cpu)} CPU task(s) across {len(include) - (1 if gpu else 0)} docker"
        f" shard(s), {len(gpu)} GPU task(s) on modal"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
