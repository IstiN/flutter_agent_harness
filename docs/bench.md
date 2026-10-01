# Benchmarks

fa runs two benchmark pipelines:

| workflow | dataset | framework | runner |
|---|---|---|---|
| `Bench` (`.github/workflows/bench.yml`) | terminal-bench-core 0.1.1 (LEGACY — board closed) | terminal-bench `tb` | ubuntu-latest |
| `Bench 4.0` (`.github/workflows/bench-4.0.yml`) | terminal-bench/terminal-bench@4.0.0 | Harbor (`harbor` CLI) | self-hosted (CPU/docker) + Modal (GPU) |

The official leaderboard (tbench.ai) reads Terminal-Bench 4.0 jobs from
Harbor Hub — legacy submissions are closed, so 4.0 is the live path.

## Bench 4.0 (Harbor)

Adapter: `bench/harbor_fa/fa_agent.py` — a Harbor `BaseInstalledAgent`
(same shape as the shipped cline-cli adapter). `harbor run` imports it via
`-a fa_agent:FaAgent` with `PYTHONPATH=bench/harbor_fa`. It uploads the
`dart build cli` bundle into the task environment, installs it to `/opt/fa`,
and runs `fa -p "<instruction>"` as the environment's agent user with the
provider preconfigured from the environment (see below).

### Secrets (owner-provisioned, env-only, never echoed)

| secret | used for |
|---|---|
| `FA_BENCH_ZAI_KEY` | z.ai key for `glm-5.3-flash` (shared with the legacy `Bench`) |
| `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET` | Modal token for the GPU shard (`-e modal`) |
| `HARBOR_API_KEY` | `harbor upload` to Harbor Hub; the upload step skips with a warning when absent (run artifacts still carry results) |

Keys pass into the task container base64-encoded (`fa_agent.py` ships them
in the exec env); CI masks both the raw and base64 forms before any log
output. Nothing is hardcoded — a run without a secret fails fast with a
`::error::` annotation.

### Running

Dispatch **Bench 4.0** (`workflow_dispatch`). Inputs:

- `tasks` — comma fnmatch globs narrowing the dataset. Empty = the full
  66-task dataset. `bun-sourcemap-leak` is a one-task smoke.
- `dataset` — default `terminal-bench/terminal-bench@4.0.0`.
- `model` — default `glm-5.3-flash` (recorded with the run; the provider
  preconfig below is what fa actually connects with).
- `attempts` — harbor `-k` trials per task, default `5` (leaderboard protocol).
- `n-concurrent` — default `1` (z.ai rate limits; raise with care).
- `shards` — CPU docker shards, default `16` (~4 tasks/shard keeps each job
  inside the job window; shards queue serially on a single self-hosted runner).
- `cpu-runner` — runner label for the docker shards, default `self-hosted`.

Smoke first: dispatch with `tasks: bun-sourcemap-leak, attempts: 1`. Once
green, dispatch with defaults for the full leaderboard run.

CLI equivalent (from a machine with docker + the fa bundle built):

```sh
uv tool install 'harbor[modal]'
export FA_BUNDLE_TARBALL=$PWD/fa-bundle.tar.gz   # tar of `dart build cli` bundle/
export FA_PROVIDER_TYPE=zai
export FA_PROVIDER_CONFIG='{"baseUrl":"https://api.z.ai/api/coding/paas/v4","model":"glm-5.3-flash","apiKeyEnvVar":"FA_KEY_API_Z_AI_Z_AI"}'
export FA_KEY_API_Z_AI_Z_AI=...                  # the key itself
PYTHONPATH=bench/harbor_fa harbor run \
  -d terminal-bench/terminal-bench@4.0.0 \
  -a fa_agent:FaAgent -e docker -m glm-5.3-flash -k 5 \
  -i bun-sourcemap-leak
```

GPU tasks (currently `fp8-rmsnorm-gemm`, `jax-speedrun-gpu`,
`math-eval-grader`) need `-e modal` — Apple Silicon (or any CPU box) cannot
substitute a CUDA sandbox. The workflow assigns them to a modal shard
automatically (`bench/harbor_fa/split_tasks.py` reads each task's
`task.toml` `gpus` declaration).

### Cost

- CPU shards: self-hosted runner, $0. GitHub-hosted minutes are reserved
  for the light setup/summary jobs.
- GPU shard (Modal): pay-per-second — T4 $0.59/h, A10 $1.10/h. A full 4.0
  run (3 GPU tasks × 5 attempts) is single-digit dollars and fits the
  Starter plan's free monthly credits.
- LLM spend runs on the z.ai key (glm-5.3-flash).

### Results

1. **Harbor Hub** — each shard is uploaded (`harbor upload jobs/fa-4.0-*`,
   public) when `HARBOR_API_KEY` is set; the job links land in the workflow
   logs and this is what tbench.ai's leaderboard reads.
2. **Job summary** — the `Aggregate resolution rate` step writes the
   resolution table (resolved/attempted per split + overall) to the
   GitHub job summary (`bench/harbor_fa/summary.py`).
3. **Artifacts** — `harbor-jobs-merged` carries every trial's full
   `result.json` + agent session logs (fa sessions under
   `<trial>/agent/fah-sessions/`) even when the Hub upload is skipped.

## MLS-Bench (Harbor)

`bench/mls_bench/` + `Bench MLS` workflow — runs fa on
[MLS-Bench](https://github.com/Imbernoulli/MLS-Bench) (140 ML-science
research tasks; the 30-task MLS-Bench-Lite slice is the cheap comparison
set) through the same Harbor runtime and `bench/harbor_fa/fa_agent.py`
adapter as Bench 4.0:

```
harbor run -c run-<provider>[-lite].yaml -a bench.harbor_fa.fa_agent:FaAgent
```

No fork: the workflow checks out Imbernoulli/MLS-Bench at a pinned SHA and
runs its own configs verbatim, including their `harbor_env:` provider
environment clamps (provider ceilings are upstream's).

### Staging ladder (cost discipline)

Each job needs the previous one, so a failure stops the spend before the
next stage: `plan` (bundle + subset + secret fail-fast) → `nop` (image
builds + sandbox start on the sanity CPU task, no agent) → `oracle`
(strongest declared baseline replay) → `agent` (fa over the subset).
Dispatch inputs: `subset` = `smoke-cpu` (default) | `lite` | `full`
(~138 GPU-sandboxed tasks; requires `confirm-full=yes`) | `task=<name>`;
`provider` = `daytona` | `modal` (required); `model`, `gpu-type` (H100
default), `mls-sha`, `shards`. The `model` input is wired into the z.ai
provider preconfig (the builder emits the JSON), so `-m`, the preconfig,
and the archived run identity all name the same model. Dispatch inputs
reach `run:` steps only via `env:` indirection (no shell interpolation of
free-form input). Runs are serialized (`concurrency: bench-mls`).

### Timeout discipline

Every task ships `[agent] timeout_sec = 18000` (5 h) and Harbor enforces
it; the builder (`bench/mls_bench/build_run.py`) never emits
`--*-timeout-multiplier` or override flags — changing the budget voids
comparability with the published leaderboard. The summary step re-checks
recorded trial configs and fails the run on a violation. Errored trials
(a routine 5 h-budget frontier outcome) are `::warning::` annotations and
stay out of the per-domain means — the step fails only on structural
problems (lost shard, comparability violation, unreadable artifacts).

### Secrets (owner-provisioned, env-only, never echoed)

| Secret | Used for |
|---|---|
| `FA_BENCH_ZAI_KEY` | z.ai key for glm-5.3-flash (shared with Bench 4.0) |
| `DAYTONA_API_KEY` | provider=daytona |
| `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET` | provider=modal |

A missing secret fails the `plan` job before any spend, naming the exact
key. On `modal`, tasks whose declared budgets exceed the 24 h sandbox cap
are flagged as clip-risk in the summary (not silently clipped).

### Results

1. **Job summary** — per-domain arithmetic-mean aggregate
   (`bench/mls_bench/summary_mls.py`) over the agent trials, plus run
   identity (dataset SHA, model, fa commit, budget statement) and a
   completeness verdict.
2. **Artifacts** — per-trial `result.json` + logs + `mls-run-config.json`
   with 90-day retention; `mls-jobs-merged` bundles everything.
3. **Permanent archive** — each run's bundle is attached to the
   `bench-mls-archive` release.

**Scores are pending until #1123 (token/cost accounting) lands** — the
workflow and aggregation are live, but leaderboard-comparable numbers
need cost attribution per trial.

## Legacy: terminal-bench-core 0.1.1

`bench/terminal_bench/` + `Bench` workflow — kept for regression runs of
the 0.1.1 baseline (32.5% with fa + glm-5.3-flash; harness-side failure
clusters tracked in issue #142). See `bench/terminal_bench/run.sh` for the
local path. Not valid for leaderboard submissions.
