# Benchmarks

fa runs two benchmark pipelines:

| workflow | dataset | framework | runner |
|---|---|---|---|
| `Bench` (`.github/workflows/bench.yml`) | terminal-bench-core 0.1.1 (LEGACY — board closed) | terminal-bench `tb` | ubuntu-latest |
| `Bench Harbor` (`.github/workflows/bench-harbor.yml`) | the Terminal-Bench family — `2.0` / `2.1` / `3.0` / `4.0` via the `dataset` input (issue #1124) | Harbor (`harbor` CLI) | self-hosted (CPU/docker) + Modal (GPU) |

The official leaderboard (tbench.ai) reads Terminal-Bench 4.0 jobs from
Harbor Hub — legacy submissions are closed, so 4.0 is the live
leaderboard path; 2.0–3.0 are the intermediate versions where harness or
model deltas are still meaningfully comparable (issue #1124).

## Terminal-Bench family (Harbor)

One dispatch surface (`Bench Harbor`) serves the whole family. The
`dataset` input takes a family label or a full Harbor dataset id; it is
resolved and validated by `bench/harbor_fa/families.py` — unknown,
out-of-family, or version-less specs fail fast at the setup job (never a
silent fallback to 4.0).

| family | Harbor dataset id | tasks | smoke task (attempts=1) |
|---|---|---|---|
| 2.0 | `terminal-bench/terminal-bench-2@latest` | 89 | `fix-git` |
| 2.1 | `terminal-bench/terminal-bench-2-1@latest` | 89 | `fix-git` |
| 3.0 | `terminal-bench/terminal-bench@3.0.0` | 74 | `bun-sourcemap-leak` |
| 4.0 | `terminal-bench/terminal-bench@4.0.0` | 66 | `bun-sourcemap-leak` |

Ids verified against the Harbor Hub registry on 2026-09-30 (issue OQ1):
harbor resolves `<org>/<name>@<ref>` through the Hub's tag table —
`4.0.0` and `3.0.0` are tags on the `terminal-bench` package (the 4.0.0
tag serves content v3.0.1), while the 2.x sets live under separate
package names whose only tag is `latest`. `@latest` is mutable: the
resolved content hash appears in the harbor download log — record the
run date in the ledger so a set stays comparable.

Adapter: `bench/harbor_fa/fa_agent.py` — a Harbor `BaseInstalledAgent`
(same shape as the shipped cline-cli adapter). `harbor run` imports it via
`-a fa_agent:FaAgent` with `PYTHONPATH=bench/harbor_fa`. It uploads the
`dart build cli` bundle into the task environment, installs it to `/opt/fa`,
and runs `fa -p "<instruction>"` as the environment's agent user with the
provider preconfigured from the environment (see below). The adapter is
dataset-agnostic — new families are inputs, not code paths.

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

Dispatch **Bench Harbor** (`workflow_dispatch`). Inputs:

- `dataset` — family label (`2.0`/`2.1`/`3.0`/`4.0`), a bare version
  (`4.0.0`), or a full Harbor id; default `terminal-bench/terminal-bench@4.0.0`.
- `tasks` — comma fnmatch globs narrowing the dataset. Empty = the full
  dataset (size per family above). The family smoke task is the
  one-task check.
- `confirm-full-run` — must be `true` for a full (tasks-less) run of an
  intermediate family (2.0/2.1/3.0); a full family sweep is hours of GPU
  + LLM spend. Smoke runs and 4.0 are unaffected (the historical 4.0
  default dispatch keeps its no-confirmation behaviour).
- `model` — default `glm-5.3-flash` (recorded with the run; the provider
  preconfig below is what fa actually connects with).
- `attempts` — harbor `-k` trials per task, default `5` (leaderboard protocol).
- `n-concurrent` — default `1` (z.ai rate limits; raise with care).
- `shards` — CPU docker shards, default `16` (~4 tasks/shard keeps each
  job inside the job window; raise to ~22 for the 89-task 2.x sets).
  Shards queue serially on a single self-hosted runner.
- `cpu-runner` — runner label for the docker shards, default `self-hosted`.

Smoke first, per family: dispatch with `tasks: <smoke task from the
table>, attempts: 1` (e.g. `dataset: 2.1, tasks: fix-git, attempts: 1`).
Once green, dispatch the full run (`tasks:` empty,
`confirm-full-run: true` for 2.0/2.1/3.0).

Comparability discipline (issue #1124): a cross-version run set uses the
**same model and the same fa bundle** (commit) for every version, and
each ledger row names both.

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

Any family id works as `-d` (e.g.
`terminal-bench/terminal-bench-2-1@latest` for 2.1).

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

1. **Harbor Hub** — each shard is uploaded
   (`harbor upload jobs/fa-<family>-*`, public) when `HARBOR_API_KEY` is
   set; the job links land in the workflow logs and this is what
   tbench.ai's leaderboard reads.
2. **Job summary** — the `Aggregate resolution rate` step writes the
   resolution table (resolved/attempted per split + overall) to the
   GitHub job summary (`bench/harbor_fa/summary.py`), with per-split
   token totals and derived cost from `bench/pricing.json` (issue #1123;
   unpriced models render n/a), followed by a paste-ready ledger row for
   the table below. Report jobs are keyed per
   dataset version (`fa-<family>-*` job names) — results from different
   versions never mix.
3. **Artifacts** — `harbor-jobs-merged` carries every trial's full
   `result.json` + agent session logs (fa sessions under
   `<trial>/agent/fah-sessions/`) even when the Hub upload is skipped.

### Results ledger (per dataset version)

One row per full run: **append-only**, keyed by dataset version. Copy the
`Ledger row` block from the run's job summary. Resolution = scored
trials resolved/attempted (trials = tasks × attempts). Cost is the
run's priced total from `bench/pricing.json` (issue #1123) — `n/a` when
the model is unpriced.

| dataset | model | fa | date | resolution | cost | run |
|---|---|---|---|---|---|---|
| terminal-bench-core==0.1.1 | glm-5.3-flash | baseline | 2026-06 | 26/80 tasks (32.5%) | — | run 34576017658 |
| *(append new rows below; template: `<harbor dataset id>` / `<model>` / `<fa commit>` / `<YYYY-MM-DD>` / `<r>/<n> trials (<rate%)>` / `<$cost | n/a>` / `<run url>`)* | | | | | | |

The 0.1.1 row is the legacy `Bench` regression baseline (issue #142);
it is not comparable with the Harbor families (different harness
generation) and is kept only as the harness-regression anchor.

## Legacy: terminal-bench-core 0.1.1

`bench/terminal_bench/` + `Bench` workflow — kept for regression runs of
the 0.1.1 baseline (32.5% with fa + glm-5.3-flash; harness-side failure
clusters tracked in issue #142). See `bench/terminal_bench/run.sh` for the
local path. Not valid for leaderboard submissions.
