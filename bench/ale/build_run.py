#!/usr/bin/env python3
"""build_run.py — stage + plan the fa-on-ALE run (issue #1686).

Subcommands (stdlib-only, mirroring bench/mls_bench/build_run.py):

  stage      vendor the deployer package + write the agent preset into
             the ALE checkout (no fork: files are copied from THIS repo
             at run time; the framework ships + imports them in-VM).
  plan       resolve the subset against the pinned docker allowlist,
             verify the asset pins, slice shards (≤ MAX_PARALLEL_SHARDS
             — the quota discipline from the kimi saga: few parallel
             shards, never burn trials into dead quota windows), emit
             the experiment yamls + the run identity bundle.
  check-env  fail fast on missing secrets, naming the exact key.
  command    print the per-shard ale_run invocation.

Pins (releases/v1.1/assets.json, published 2026-10-14; verified live
2026-11-09) — every one is checked in plan so a drifted ``--ale-sha``
fails in one setup minute instead of mid-run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn

ALE_REPO = "rdi-berkeley/agents-last-exam"
DEFAULT_ALE_SHA = "2e91edd3cd26baa35a38127c90c8e5241dfbe62f"  # main, 2026-11-09

# releases/v1.1/assets.json @ DEFAULT_ALE_SHA.
DOCKER_IMAGE = "agentslastexam/ale-ubuntu22-docker:v1.1"
DOCKER_IMAGE_DIGEST = (
    "sha256:0b223c5042bedfa78f37f17881f6b410aa3d745310b667e5dff62637363c5085"
)
TASK_DATA_ARCHIVE_REVISION = "46225f1caa4f43c275cc06a5da47d886f64feb6c"
TASK_DATA_ARCHIVE_SHA256 = "a7fd6eafbffcebf393580c45ce7afa4908dcd1e2ceaabcebbc867e28c7cea0a2"
DOCKER_SUPPORT_SHA256 = "2112356ad3df9379380297905f55860d3f6c47f2dd3fcaaa2367e5080998f76c"

# The docker allowlist has no dedicated demo pair (demo/hello* need the
# full VM images); the smoke default is the smallest-looking pure-compute
# task. Swap via --tasks (validated against the allowlist either way).
SMOKE_TASKS = ["computing_math/cost_optimization_1"]

# Quota discipline (issue #1686 design sketch): ≤3 parallel shards.
MAX_PARALLEL_SHARDS = 3
FULL_RUN_TASK_COUNT = 78

PKG_FILES = ("__init__.py", "config.py", "deployer.py")
STAGED_PKG_DIR = "ale_run/agents/fa_code"
PRESET_PATH = "configs/agents/fa.yaml"


def _die(msg: str) -> NoReturn:
    print(f"::error::{msg}", file=sys.stderr)
    raise SystemExit(2)


# ── CodeQL taint barriers (gh-1686 review) ────────────────────────────────
# The dispatch-supplied strings that flow into the two flagged sinks —
# _die's log line and the staged preset file — are validated BEFORE any
# of them can reach a sink, and each barrier returns only a value whose
# shape proves it carries no credential material:
#
#   * --api-key-env / apiKeyEnvVar hold an env var NAME (the
#     ${env:NAME} reference the ALE config_loader substitutes host-side
#     at parse time); only an UPPER_SNAKE name passes. The key VALUE
#     itself never crosses this CLI at all — fa reads it from its own
#     env at runtime.
#   * --provider-config is re-serialized field-by-field from the
#     allowlisted set (same policy the gh-1471 resolve step enforces in
#     the workflow — mirrored here so a stage invocation cannot bypass
#     it): any off-whitelist field, any key-like field beyond
#     apiKeyEnvVar, a non-https baseUrl, or a non-name apiKeyEnvVar
#     refuses the stage. The preset therefore provably contains only
#     the ${env:NAME} reference and key-free config fields.
_ENV_NAME_RE = re.compile(r"[A-Z][A-Z0-9_]*\Z")
_PROVIDER_CONFIG_KEYS = (
    "baseUrl", "model", "apiKeyEnvVar", "contextWindow", "maxTokens",
    "input", "thinkingLevel", "type",
)
# gh-1471 parity: whole-WORD match on the field name split into
# camelCase/snake words — "maxTokens" (→ max, tokens) passes, while
# "accessToken" (→ access, token) and "apiKey" are caught.
_WORD_SPLIT_RE = re.compile(r"([a-z0-9])([A-Z])")
_KEY_WORD_RE = re.compile(
    r"^(api[_-]?key|apikey|key|token|secret|password|passwd|credential)$",
    re.IGNORECASE,
)
_MODEL_RE = re.compile(r"[A-Za-z0-9._/+-]{1,100}\Z")
_PROVIDER_TYPE_RE = re.compile(r"[a-z0-9_-]{1,64}\Z")
_SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")


def _field_is_keylike(name: str) -> bool:
    snake = _WORD_SPLIT_RE.sub(r"\1_\2", name)
    words = [w.lower() for w in snake.replace("-", "_").split("_") if w]
    return any(_KEY_WORD_RE.fullmatch(w) for w in words)


def _validated_key_env_name(raw: str, flag: str) -> str:
    if _ENV_NAME_RE.fullmatch(raw):
        return raw
    _die(f"{flag} must be an UPPER_SNAKE env var name (e.g. FA_BENCH_ZAI_KEY) — a value of any other shape cannot name an environment variable, so it is refused before it can reach a log line or the preset file")
    raise AssertionError  # unreachable; keeps type checkers honest


def _validated_provider_config(raw: str) -> str:
    try:
        obj = json.loads(raw)
    except ValueError:
        _die("--provider-config must be a JSON object")
        raise AssertionError
    if not isinstance(obj, dict):
        _die("--provider-config must be a JSON object")
    unsupported = sorted(k for k in obj if k not in _PROVIDER_CONFIG_KEYS)
    if unsupported:
        _die(
            "--provider-config has unsupported key(s): "
            + ", ".join(unsupported)
            + " — supported: " + ", ".join(_PROVIDER_CONFIG_KEYS)
        )
    keylike = sorted(k for k in obj if k != "apiKeyEnvVar" and _field_is_keylike(k))
    if keylike:
        # Field NAMES matching key/token/secret/password are refused
        # outright (e.g. a pasted "apiKey"/"token" field) — the sole
        # key-worded field allowed is apiKeyEnvVar, and it must hold a
        # NAME, not a value.
        _die(
            "--provider-config must not carry key material — offending "
            "field name(s): " + ", ".join(keylike)
            + "; the key comes only from the secret env the preset references"
        )
    rebuilt: dict = {}
    for key in _PROVIDER_CONFIG_KEYS:
        if key not in obj:
            continue
        value = obj[key]
        if isinstance(value, str) and not value.strip():
            continue  # blank = absent (the Dart preconfig's contract)
        if key in ("contextWindow", "maxTokens") and (
            not isinstance(value, int) or isinstance(value, bool)
        ):
            _die(f"--provider-config {key} must be an integer capability cap")
        if key == "baseUrl":
            if not isinstance(value, str) or not value.startswith("https://"):
                _die("--provider-config baseUrl must start with https:// (a plaintext endpoint would expose the bench key)")
        if key == "apiKeyEnvVar":
            value = _validated_key_env_name(value, "--provider-config apiKeyEnvVar")
        rebuilt[key] = value
    return json.dumps(rebuilt, separators=(",", ":"), sort_keys=True)


def _validated_stage_args(args: argparse.Namespace) -> argparse.Namespace:
    """Validate every dispatch-supplied string that a sink consumes
    (single funnel — cmd_stage runs this FIRST)."""
    args.api_key_env = _validated_key_env_name(args.api_key_env, "--api-key-env")
    args.provider_config = _validated_provider_config(args.provider_config)
    if not _PROVIDER_TYPE_RE.fullmatch(args.provider_type):
        _die("--provider-type must be a short lowercase provider id (e.g. zai, openai)")
    if not _MODEL_RE.fullmatch(args.model):
        _die("--model must be a plain model id (letters/digits/._/+-) — a newline or quote would break the preset YAML")
    if not args.bundle_url.startswith("https://"):
        _die("--bundle-url must be an https:// URL")
    if args.bundle_sha256 and not _SHA256_RE.fullmatch(args.bundle_sha256):
        _die("--bundle-sha256 must be 64 lowercase hex chars (the release SHA256SUMS value)")
    for knob in ("stall_gap_sec", "abs_ceiling_sec", "external_cap_sec"):
        value = getattr(args, knob)
        if value is not None and (value <= 0 or value > 1e9):
            _die(f"--{knob.replace('_', '-')} must be a positive second count")
    return args


# ─────────────────────────────────────────────────────────────── stage ────


def cmd_stage(args: argparse.Namespace) -> int:
    # Taint barrier FIRST: every sink-consumed string (the ::error log
    # line below and the preset file write) is validated/normalized
    # before any of them runs.
    args = _validated_stage_args(args)
    ale = Path(args.ale_root)
    if not (ale / "ale_run" / "orchestration" / "factory.py").is_file():
        _die(f"not an agents-last-exam checkout: {ale} — pass --ale-root")
    src = Path(__file__).resolve().parent
    timeout_src = src.parent / "fa_agent_timeout.py"
    if not timeout_src.is_file():
        _die(f"missing shared knobs module: {timeout_src}")

    pkg_dir = ale / STAGED_PKG_DIR
    pkg_dir.mkdir(parents=True, exist_ok=True)
    staged = []
    for name in PKG_FILES:
        target = pkg_dir / name
        shutil.copyfile(src / name, target)
        staged.append(str(target))
    target = pkg_dir / "fa_agent_timeout.py"
    shutil.copyfile(timeout_src, target)
    staged.append(str(target))

    preset = ale / PRESET_PATH
    preset.parent.mkdir(parents=True, exist_ok=True)
    preset.write_text(_preset_yaml(args), encoding="utf-8")
    staged.append(str(preset))

    for path in staged:
        print(f"staged: {path}")
    return 0


def _preset_yaml(args: argparse.Namespace) -> str:
    """The agent preset — harness FQN + model + config kwargs.

    api_key rides the ${env:VAR} host-side substitution (config_loader;
    KeyError when unset = fail-loud preflight). provider_config carries
    NO key material (the gh-1471 resolve step already guarantees that).
    """
    lines = [
        "# fa on ALE (issue #1686) — generated by bench/ale/build_run.py stage.",
        "# Harness: the vendored deployer (ale_run/agents/fa_code/). Fully-",
        "# qualified path: resolve_agent accepts any importable FQN.",
        "harness: ale_run.agents.fa_code.deployer.FaDeployer",
        "id: fa",
        f"model: {args.model}",
        "config:",
        f"  provider_type: {args.provider_type}",
        f"  provider_config: {json.dumps(args.provider_config)}",
        f"  api_key: \"${{env:{args.api_key_env}}}\"",
        f"  bundle_url: {args.bundle_url}",
    ]
    if args.bundle_sha256:
        lines.append(f"  bundle_sha256: {args.bundle_sha256}")
    lines.append(f"  mcp_tool_call_timeout_ms: {args.tool_call_timeout_ms}")
    if args.progress_extension:
        lines.append("  progress_extension: true")
    if args.stall_gap_sec is not None:
        lines.append(f"  stall_gap_sec: {args.stall_gap_sec}")
    if args.abs_ceiling_sec is not None:
        lines.append(f"  abs_ceiling_sec: {args.abs_ceiling_sec}")
    if args.external_cap_sec is not None:
        lines.append(f"  external_cap_sec: {args.external_cap_sec}")
    return "\n".join(lines) + "\n"


# ──────────────────────────────────────────────────────────────── plan ────


def cmd_plan(args: argparse.Namespace) -> int:
    ale = Path(args.ale_root)
    allowlist = ale / "selected_tasks" / "docker_support.txt"
    if not allowlist.is_file():
        _die(f"missing docker allowlist: {allowlist}")

    raw = allowlist.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if args.check_pins and digest != DOCKER_SUPPORT_SHA256:
        _die(
            "docker_support.txt sha256 drifted: expected "
            f"{DOCKER_SUPPORT_SHA256}, got {digest} — the ale-sha pin no "
            "longer matches the v1.1 assets; re-pin deliberately or pick "
            "the matching --ale-sha"
        )
    tasks_all = [
        line.strip()
        for line in raw.decode().splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]

    tasks = _resolve_tasks(args, tasks_all)
    shards = _resolve_shards(args, tasks)

    out_lines = [f"count={len(tasks)}"]
    matrix = []
    for index, (start, end) in enumerate(shards):
        slice_tasks = tasks[start:end]
        matrix.append(
            {"i": index, "count": len(slice_tasks), "tasks": slice_tasks}
        )
        exp = ale / f"exp-fa-shard-{index}.yaml"
        task_file = ale / "selected_tasks" / f"fa-shard-{index}.txt"
        task_file.write_text("\n".join(slice_tasks) + "\n", encoding="utf-8")
        exp.write_text(_experiment_yaml(args, index), encoding="utf-8")
        out_lines.append(f"shard_{index}_tasks={len(slice_tasks)}")
    out_lines.append(f"matrix={json.dumps({'include': matrix}, separators=(',', ':'))}")

    identity = {
        "ale_repo": ALE_REPO,
        "ale_sha": args.ale_sha,
        "docker_image": DOCKER_IMAGE,
        "docker_image_digest": DOCKER_IMAGE_DIGEST,
        "task_data_archive_revision": TASK_DATA_ARCHIVE_REVISION,
        "task_data_archive_sha256": TASK_DATA_ARCHIVE_SHA256,
        "docker_support_sha256": digest,
        "fa_commit": args.fa_commit,
        "fa_bundle_url": args.bundle_url,
        "fa_bundle_sha256": args.bundle_sha256,
        "model": args.model,
        "provider": args.provider,
        "subset": args.subset,
        "requested_tasks": args.tasks or "",
        "shards": len(shards),
        "max_attempts": args.max_attempts,
        # Budget fidelity (mls precedent): the builder never emits a
        # wall_time_s override — task-card budgets (18000s-class) govern.
        "budget": "task-card timeout_s; no wall_time_s override emitted",
    }
    Path(args.run_config_out).write_text(
        json.dumps(identity, indent=2) + "\n", encoding="utf-8"
    )
    with open(args.out, "w", encoding="utf-8") as handle:
        for line in out_lines:
            handle.write(line + "\n")
    print(f"plan: {len(tasks)} tasks, {len(shards)} shards")
    return 0


def _resolve_tasks(args: argparse.Namespace, tasks_all: list[str]) -> list[str]:
    known = set(tasks_all)
    if args.subset == "smoke":
        requested = SMOKE_TASKS
    elif args.subset == "docker":
        if args.confirm_full != "yes":
            _die(
                f"subset=docker runs the full {FULL_RUN_TASK_COUNT}-task "
                "allowlist (multi-hour, token-burning) — dispatch with "
                "confirm-full=yes. Smoke first: subset=smoke."
            )
        requested = tasks_all
    else:
        requested = [t.strip() for t in args.tasks.split(",") if t.strip()]
        if not requested:
            _die("subset=tasks requires a non-empty --tasks csv")
    unknown = [t for t in requested if t not in known]
    if unknown:
        _die(
            "task(s) not in the docker allowlist (the docker profile runs "
            "the 78-task Linux subset only): "
            + ", ".join(unknown)
            + " — Windows/GPU/nested-docker tasks need a VM provider, "
            "not configs/environments/docker.yaml"
        )
    return [t for t in tasks_all if t in set(requested)]  # allowlist order


def _resolve_shards(args: argparse.Namespace, tasks: list[str]) -> list[tuple[int, int]]:
    count = args.shards
    if count < 1:
        _die(f"--shards must be >= 1, got {count}")
    if count > MAX_PARALLEL_SHARDS:
        _die(
            f"--shards {count} exceeds the quota cap ({MAX_PARALLEL_SHARDS} "
            "parallel shards — issue #1686: 5h-class trials must never burn "
            "into dead quota windows)"
        )
    if count > len(tasks):
        count = len(tasks)
    per, remainder = divmod(len(tasks), count)
    bounds = []
    start = 0
    for index in range(count):
        size = per + (1 if index < remainder else 0)
        bounds.append((start, start + size))
        start += size
    return bounds


def _experiment_yaml(args: argparse.Namespace, index: int) -> str:
    """The per-shard experiment: upstream presets verbatim, run-level
    knobs only. wall_time_s deliberately ABSENT (task-card budgets
    govern; mls precedent). max_attempts defaults to 1 — a failed
    5h-class trial must not silently re-burn."""
    return "\n".join(
        [
            f"# fa on ALE shard {index} — generated by build_run.py plan.",
            f"name: fa-ale-shard-{index}",
            "secret_file: secret/.env",
            "agents:",
            f"  - {PRESET_PATH}",
            "environment: configs/environments/docker.yaml",
            f"tasks: selected_tasks/fa-shard-{index}.txt",
            "output:",
            f"  root: .logs/ale-shard-{index}",
            "concurrency: 1",
            f"max_attempts: {args.max_attempts}",
            "auto_resume: true",
            "cleanup_mode: delete",
        ]
    ) + "\n"


# ──────────────────────────────────────────────────────────── check-env ────


def cmd_check_env(args: argparse.Namespace) -> int:
    # Barrier first: the message below names the (validated) env var
    # NAME only — a non-name value is refused before any log line.
    args.api_key_env = _validated_key_env_name(args.api_key_env, "--api-key-env")
    missing = []
    if not os.environ.get(args.api_key_env):
        missing.append(args.api_key_env)
    if args.stage != "plan" and not os.environ.get("HF_TOKEN"):
        missing.append("HF_TOKEN")
    if missing:
        _die(
            "missing required secret(s): "
            + ", ".join(missing)
            + " — provision them as repo secrets before dispatching "
            "(HF_TOKEN needs manual-approval access to "
            "agents-last-exam/agents-last-exam-data-archive; see issue #1686)"
        )
    print(f"check-env: OK ({args.stage})")
    return 0


# ────────────────────────────────────────────────────────────── command ────


def cmd_command(args: argparse.Namespace) -> int:
    ale = Path(args.ale_root).resolve()
    exp = Path(args.exp).name
    print(f"cd {ale} && uv run python -m ale_run run {exp}")
    return 0


# ────────────────────────────────────────────────────────────────── main ────


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    stage = sub.add_parser("stage", help="vendor deployer + preset into the ALE checkout")
    stage.add_argument("--ale-root", default="ale")
    stage.add_argument("--provider-type", default="zai")
    stage.add_argument("--provider-config", required=True)
    stage.add_argument("--api-key-env", default="FA_BENCH_ZAI_KEY")
    stage.add_argument("--model", default="glm-5.3-flash")
    stage.add_argument("--bundle-url", required=True)
    stage.add_argument("--bundle-sha256", default="")
    stage.add_argument("--tool-call-timeout-ms", type=int, default=120000)
    stage.add_argument("--progress-extension", action="store_true")
    stage.add_argument("--stall-gap-sec", type=float, default=None)
    stage.add_argument("--abs-ceiling-sec", type=float, default=None)
    stage.add_argument("--external-cap-sec", type=float, default=None)
    stage.set_defaults(func=cmd_stage)

    plan = sub.add_parser("plan", help="resolve subset, verify pins, slice shards")
    plan.add_argument("--subset", choices=["smoke", "docker", "tasks"], default="smoke")
    plan.add_argument("--tasks", default="")
    plan.add_argument("--ale-root", default="ale")
    plan.add_argument("--ale-sha", default=DEFAULT_ALE_SHA)
    plan.add_argument("--shards", type=int, default=MAX_PARALLEL_SHARDS)
    plan.add_argument("--max-attempts", type=int, default=1)
    plan.add_argument("--confirm-full", default="")
    plan.add_argument("--fa-commit", required=True)
    plan.add_argument("--provider", default="zai-glm-5.3-flash")
    plan.add_argument("--model", default="glm-5.3-flash")
    plan.add_argument("--bundle-url", required=True)
    plan.add_argument("--bundle-sha256", default="")
    plan.add_argument("--check-pins", action="store_true", default=True)
    plan.add_argument("--no-check-pins", dest="check_pins", action="store_false")
    plan.add_argument("--out", required=True, help="GITHUB_OUTPUT path")
    plan.add_argument("--run-config-out", required=True)
    plan.set_defaults(func=cmd_plan)

    check = sub.add_parser("check-env", help="fail fast on missing secrets")
    check.add_argument("--stage", choices=["plan", "agent"], default="plan")
    check.add_argument(
        "--api-key-env",
        default="FA_BENCH_ZAI_KEY",
        help="the env var carrying the provider key in THIS shell — "
        "the GH secret name (FA_BENCH_*) for the workflow preflight, "
        "or the resolved key env name if you export it directly",
    )
    check.set_defaults(func=cmd_check_env)

    command = sub.add_parser("command", help="emit the shard's ale_run command")
    command.add_argument("--ale-root", default="ale")
    command.add_argument("--exp", required=True)
    command.set_defaults(func=cmd_command)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
