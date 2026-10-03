#!/usr/bin/env python3
"""Plan + command builder for bench-mls.yml (issue #1160).

Run through the existing Harbor adapter (bench/harbor_fa/fa_agent.py):

    harbor run -c run-<provider>[-lite].yaml -a bench.harbor_fa.fa_agent:FaAgent

MLS-Bench is consumed as an external pinned dataset (checkout at --mls-sha);
the upstream run configs (run-daytona*.yaml / run-modal*.yaml) are used
verbatim, including their harbor_env:DaytonaEnvironment /
harbor_env:ModalEnvironment clamp layers (E2 - no local re-invention).

Subcommands:
    plan          validate inputs, fail fast on secrets (AC2), resolve the
                  subset into a shard matrix + run-config.json (AC6 identity
                  bundle: dataset SHA, model, fa commit, budget statement,
                  per-task areas, modal clip-risk list)
    command       print the harbor command line for one stage (nop / oracle /
                  agent). AC4: the builder NEVER emits a timeout knob -
                  dataset-declared [agent] timeout_sec = 18000 is the budget,
                  and changing it voids leaderboard comparability.
    check-env    exit 1 naming the exact missing env var(s) (AC2)
    preconfig    print the z.ai provider preconfig JSON with the --model
                 input wired in, so the archived run identity names the
                 model that actually ran

stdlib-only (tomllib needs 3.11+); the upstream run configs' simple
task_names blocks are parsed line-wise so no YAML dep is added.
"""
import argparse
import json
import os
import re
import shlex
import sys
import tomllib
from pathlib import Path

HARBOR_VERSION = "0.23.0"  # the adapter's pin (see bench-harbor.yml)
SANITY_TASK = "ml-clustering-algorithm"  # upstream documented harness-sanity CPU task
AGENT_IMPORT = "bench.harbor_fa.fa_agent:FaAgent"
MODEL_ENV_VAR = "FA_BENCH_ZAI_KEY"  # standing z.ai key, shared with bench.yml / bench-harbor.yml

# Constant NAME literals only. Values are never read anywhere in this
# module (membership tests in missing_env_names) — the fail-fast print
# interpolates these constants and nothing else.
REQUIRED_ENV_NAMES = {
    "daytona": ("DAYTONA_API_KEY",),
    "modal": ("MODAL_TOKEN_ID", "MODAL_TOKEN_SECRET"),
}

# Contract 4 / AC4: any of these voids leaderboard comparability - never emit.
TIMEOUT_KNOBS = (
    "--timeout-multiplier",
    "--agent-timeout-multiplier",
    "--verifier-timeout-multiplier",
    "--agent-setup-timeout-multiplier",
    "--environment-build-timeout-multiplier",
)

# E1: Modal caps a sandbox at 24h; a task whose agent+verifier budgets exceed
# it can be cut off while verifying (upstream documents 29 such tasks).
MODAL_SANDBOX_CAP_SEC = 86400

# z.ai coding endpoint; same preconfig shape as bench.yml / bench-harbor.yml,
# with the model taken from the dispatch input (review round 3, -a5C).
ZAI_BASE_URL = "https://api.z.ai/api/coding/paas/v4"
ZAI_KEY_ENV = "FA_KEY_API_Z_AI_Z_AI"


def preconfig_json(model: str) -> str:
    """The z.ai provider preconfig for `model` (json.dumps-escaped).

    apiKeyEnvVar is the harbor-process env name the workflow maps the
    FA_BENCH_ZAI_KEY secret into (adapter contract, unchanged); the env-var
    name check-env requires stays the secret's own name.
    """
    return json.dumps({"baseUrl": ZAI_BASE_URL, "model": model, "apiKeyEnvVar": ZAI_KEY_ENV})

_AREA_ROW = re.compile(r"^\| ([A-Za-z&]+) \| \[([a-z0-9-]+)\]\(tasks/\2\) \|")


def parse_subset(value: str) -> tuple[str, str | None]:
    """-> (kind, task-short-name); kind in smoke-cpu | lite | full | task."""
    v = (value or "").strip()
    if v in ("smoke-cpu", "lite", "full"):
        return (v, None)
    name = v[len("task="):] if v.startswith("task=") else v
    for prefix in ("mls-bench__", "mls-bench/"):
        if name.startswith(prefix):
            name = name[len(prefix):]
    if not name or "/" in name or "__" in name or any(c.isspace() for c in name):
        raise SystemExit(
            f"::error::invalid subset {value!r}: expected "
            "smoke-cpu | lite | full | task=<name>"
        )
    return ("task", name)


def dir_name(short: str) -> str:
    """Dataset task dir name (the form -i/--include-task-name matches,
    LocalTaskId.get_name() = directory name)."""
    return f"mls-bench__{short}"


def confirm_full(kind: str, confirm: str) -> None:
    """E3: full sweeps the whole GPU bench; require the explicit opt-in."""
    if kind == "full" and confirm != "yes":
        raise SystemExit(
            "::error::subset=full runs ~138 GPU-sandboxed tasks; "
            "pass confirm-full=yes to proceed"
        )


def missing_env_names(provider: str, stage: str, env=None) -> list[str]:
    """AC2: exact secret names the run needs. plan pre-flights everything so
    the ladder dies before any spend; stage checks re-run per job.

    Membership test only — secret VALUES are never read or bound; the only
    strings that reach the fail-fast print are the constant name literals.
    """
    env = os.environ if env is None else env
    need = list(REQUIRED_ENV_NAMES[provider])
    if stage in ("agent", "plan"):
        need.append(MODEL_ENV_VAR)
    return [name for name in need if name not in env]


def check_required_env(provider: str, stage: str, env=None) -> None:
    missing = missing_env_names(provider, stage, env)
    for name in missing:
        print(f"::error::{name} secret is not set", file=sys.stderr)  # codeql[py/clear-text-logging-sensitive-data] false positive: constant NAME literals only, values never read (AC2 fail-fast contract)
    if missing:
        raise SystemExit(1)


def _yaml_simple_list(path: Path, key: str) -> list[str]:
    """Line-parse `key:` followed by `- value` items from a run config.

    The upstream run-*.yaml files are plain enough that a real YAML parser
    would be the only dependency in this directory - not worth it.
    """
    items: list[str] = []
    lines = path.read_text().splitlines()
    in_block = False
    indent = ""
    for line in lines:
        if not in_block:
            m = re.match(rf"^(\s*){re.escape(key)}:\s*$", line)
            if m:
                in_block, indent = True, m.group(1)
            continue
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # Items nest DEEPER than the key (upstream: datasets: → - path: →
        # task_names:); a list item or any sibling key at the key's own
        # indent or lower ends the block.
        if re.match(rf"^\s{{{len(indent) + 1},}}- ", line):
            items.append(stripped[2:].strip())
            continue
        break
    return items


def lite_tasks(harbor_dir: Path, provider: str) -> list[str]:
    """The 30 MLS-Bench-Lite task dir names, verbatim from upstream's config."""
    tasks = _yaml_simple_list(harbor_dir / f"run-{provider}-lite.yaml", "task_names")
    if not tasks:
        raise SystemExit(f"::error::no task_names parsed from run-{provider}-lite.yaml")
    return tasks


def full_tasks(harbor_dir: Path, provider: str) -> list[str]:
    """All dataset tasks (dataset.toml, TOML so stdlib-parsed) minus the run
    config's exclude_task_names (the two API-backed evaluators)."""
    data = tomllib.loads((harbor_dir / f"tasks-{provider}" / "dataset.toml").read_text())
    excludes = set(_yaml_simple_list(harbor_dir / f"run-{provider}.yaml", "exclude_task_names"))
    tasks = [name.replace("/", "__", 1) for name in (t["name"] for t in data["tasks"])]
    return [t for t in tasks if t not in excludes]


def resolve_tasks(kind: str, task: str | None, harbor_dir: Path, provider: str) -> list[str]:
    if kind == "smoke-cpu":
        return [dir_name(SANITY_TASK)]
    if kind == "task":
        return [dir_name(task or "")]
    if kind == "lite":
        return lite_tasks(harbor_dir, provider)
    return full_tasks(harbor_dir, provider)


def shard_matrix(tasks: list[str], shards: int) -> list[dict]:
    """Contiguous chunks in the caller's task order; empty chunks dropped."""
    shards = max(1, min(shards, len(tasks) or 1))
    size = -(-len(tasks) // shards)
    return [
        {"i": i, "tasks": " ".join(tasks[i * size:(i + 1) * size])}
        for i in range(shards)
        if tasks[i * size:(i + 1) * size]
    ]


def clip_risk(harbor_dir: Path, provider: str) -> list[str]:
    """E1: task dir names whose agent+verifier budgets exceed Modal's 24h
    sandbox cap (computed from the pinned task.tomls - upstream documents 29)."""
    out = []
    for path in sorted((harbor_dir / f"tasks-{provider}").glob("*/task.toml")):
        data = tomllib.loads(path.read_text())
        total = (
            data.get("agent", {}).get("timeout_sec", 0)
            + data.get("verifier", {}).get("timeout_sec", 0)
        )
        if total > MODAL_SANDBOX_CAP_SEC:
            out.append(path.parent.name)
    return out


def area_map(mls_root: Path) -> dict[str, str]:
    """Task short name -> upstream research area, parsed from the pinned
    README's 140-task catalog table (the only machine-readable domain map
    upstream publishes)."""
    areas: dict[str, str] = {}
    for line in (mls_root / "README.md").read_text().splitlines():
        m = _AREA_ROW.match(line)
        if m:
            areas[m.group(2)] = m.group(1)
    return areas


def build_command(
    stage: str,
    provider: str,
    subset: str,
    tasks: list[str],
    job_name: str,
    model: str,
    gpu_type: str,
) -> str:
    """The one place harbor command lines are born; UT asserts on this output.

    Stage ladder (per-stage spend-stop lives in the workflow's job chain):
      nop    - image builds + sandbox starts, no agent, no verification
      oracle - strongest declared baseline replay over the target subset
      agent  - fa via the Harbor adapter, model recorded with the run
    """
    kind, _ = parse_subset(subset)
    config = f"run-{provider}-lite.yaml" if kind == "lite" else f"run-{provider}.yaml"
    argv = [
        "harbor", "run", "-c", config,
        "--job-name", job_name,
        "-o", "jobs",
        "-n", "1",  # z.ai rate-limit safe, same discipline as bench-harbor.yml
        "-y",       # non-interactive CI: auto-confirm host-environment prompts
        "--ek", f"gpu_type={gpu_type}",
    ]
    for task in tasks:
        argv += ["-i", task]
    if stage == "nop":
        argv += ["-a", "nop", "--disable-verification"]
    elif stage == "oracle":
        argv += ["-a", "oracle"]
    elif stage == "agent":
        argv += ["-a", AGENT_IMPORT, "-m", model]
    else:
        raise SystemExit(f"::error::unknown stage {stage!r}")
    knobs = [knob for knob in TIMEOUT_KNOBS if knob in argv]
    if knobs:  # AC4 invariant; unreachable by construction, kept as the guard
        raise SystemExit(f"::error::comparability violation: {', '.join(knobs)}")
    return shlex.join(argv)


def _emit(mapping: dict, out: str | None) -> None:
    text = "".join(f"{k}={v}\n" for k, v in mapping.items())
    if out:
        with Path(out).open("a") as f:
            f.write(text)
    else:
        print(text, end="")


def cmd_plan(args: argparse.Namespace) -> int:
    kind, task = parse_subset(args.subset)
    confirm_full(kind, args.confirm_full)
    check_required_env(args.provider, "plan")  # AC2: die before any stage spends
    harbor_dir = Path(args.mls_root) / "harbor"
    tasks = resolve_tasks(kind, task, harbor_dir, args.provider)
    matrix = shard_matrix(tasks, args.shards)
    run_config = {
        "workflow": "bench-mls",
        "mls_bench_url": "https://github.com/Imbernoulli/MLS-Bench",
        "mls_bench_sha": args.mls_sha,
        "provider": args.provider,
        "gpu_type": args.gpu_type,
        "subset": args.subset,
        "tasks": tasks,
        "model": args.model,
        "model_env_var": MODEL_ENV_VAR,
        "fa_commit": args.fa_commit,
        "adapter": f"{AGENT_IMPORT} (bench/harbor_fa/fa_agent.py)",
        "harbor_version": HARBOR_VERSION,
        "attempts": 1,
        "n_concurrent": 1,
        "agent_budget": (
            "dataset-declared [agent] timeout_sec = 18000 (5h) per task; NO "
            "--*-timeout-multiplier or override_timeout_sec emitted (contract 4)"
        ),
        "verifier_budget": "task-specific [verifier] timeout_sec, untouched",
        "expected_trials": len(tasks),
        "areas": area_map(Path(args.mls_root)),
        "clip_risk_modal": clip_risk(harbor_dir, args.provider),
    }
    Path(args.run_config_out).write_text(json.dumps(run_config, indent=2) + "\n")
    # matrix only: expected_trials travels in the run-config bundle the
    # summary job replays; an undeclared job output would be dead weight.
    _emit(
        {"matrix": json.dumps({"include": matrix}, separators=(",", ":"))},
        args.out,
    )
    return 0


def cmd_command(args: argparse.Namespace) -> int:
    kind, task = parse_subset(args.subset)
    if args.stage == "nop":
        tasks = [dir_name(task)] if task else [dir_name(SANITY_TASK)]
    else:
        tasks = args.tasks.split()
    if not tasks:
        raise SystemExit("::error::no tasks for the command")
    print(build_command(
        args.stage, args.provider, args.subset,
        tasks, args.job_name, args.model, args.gpu_type,
    ))
    return 0


def cmd_check_required_env(args: argparse.Namespace) -> int:
    check_required_env(args.provider, args.stage)
    return 0


def cmd_preconfig(args: argparse.Namespace) -> int:
    print(preconfig_json(args.model))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    def with_common(p: argparse.ArgumentParser) -> argparse.ArgumentParser:
        p.add_argument("--provider", required=True, choices=("daytona", "modal"))
        p.add_argument("--subset", required=True)
        p.add_argument("--model", default="glm-5.3-flash")
        p.add_argument("--gpu-type", default="H100")
        return p

    p = with_common(sub.add_parser("plan"))
    p.add_argument("--mls-root", required=True)
    p.add_argument("--mls-sha", required=True)
    p.add_argument("--fa-commit", required=True)
    p.add_argument("--shards", type=int, default=5)
    p.add_argument("--confirm-full", default="")
    p.add_argument("--out", default=None, help="GITHUB_OUTPUT file")
    p.add_argument("--run-config-out", default="mls-run-config.json")
    p.set_defaults(func=cmd_plan)

    p = with_common(sub.add_parser("command"))
    p.add_argument("--stage", required=True, choices=("nop", "oracle", "agent"))
    p.add_argument("--tasks", default="", help="space-separated task dir names (oracle/agent)")
    p.add_argument("--job-name", required=True)
    p.set_defaults(func=cmd_command)

    p = with_common(sub.add_parser("check-env"))
    p.add_argument("--stage", required=True, choices=("nop", "oracle", "agent", "plan"))
    p.set_defaults(func=cmd_check_required_env)

    # Self-sufficient: only --model, with the workflow's call shape
    # (`preconfig --model "$MODEL"`) valid as-is. provider/subset/gpu-type
    # are irrelevant to the preconfig and stay absent rather than required
    # (round-5 review: with_common's required flags broke every shard).
    p = sub.add_parser("preconfig")
    p.add_argument("--model", default="glm-5.3-flash")
    p.set_defaults(func=cmd_preconfig)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
