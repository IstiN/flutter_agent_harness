# Benchmarks

fa runs two benchmark pipelines:

| workflow | dataset | framework | runner |
|---|---|---|---|
| `Bench` (`.github/workflows/bench.yml`) | terminal-bench-core 0.1.1 (LEGACY — board closed) | terminal-bench `tb` | ubuntu-latest |
| `Bench Harbor` (`.github/workflows/bench-harbor.yml`) | the Terminal-Bench family — default `2.1`; `2.0` / `3.0` / `4.0` via the `dataset` input (issues #1124, #1316) | Harbor (`harbor` CLI) | ubuntu-latest (CPU/docker) + Modal (GPU) |
| `Bench ProgramBench` (`.github/workflows/bench-programbench.yml`) | facebookresearch/ProgramBench (~200 reverse-engineering tasks; issue #1685) | `programbench` CLI + docker | ubuntu-latest |

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
  (`4.0.0`), or a full Harbor id; default
  `terminal-bench/terminal-bench-2-1@latest` (the 2.1 family — issue
  #1316 migrated the default dispatch from 4.0 to Terminal-Bench 2.x).
- `tasks` — comma fnmatch globs narrowing the dataset. Empty = the full
  dataset (size per family above). The family smoke task is the
  one-task check.
- `confirm-full-run` — must be `true` for a full (tasks-less) run of an
  intermediate family (2.0/2.1/3.0); a full family sweep is hours of GPU
  + LLM spend. Smoke runs and 4.0 are unaffected (the historical 4.0
  default dispatch keeps its no-confirmation behaviour).
- `provider` — `zai-glm-5.3-flash` (default; byte-identical to the
  pre-gh-1503 wiring), `kimi-for-coding` (model id `kimi-for-coding` —
  the plan's own model name, needs the `FA_BENCH_KIMI_KEY` secret), or
  `custom` (needs `FA_BENCH_CUSTOM_KEY`
  + `provider-config`). Same contract as the legacy bench's gh-1471
  provider selection — the model is derived from the provider, so the
  old free-text `model` input is gone (gh-1503).
- `provider-config` — ONLY when `provider=custom`: the provider config
  JSON `{"type","baseUrl","model","contextWindow","maxTokens"}`. The
  API key never rides this input — it comes only from the
  `FA_BENCH_CUSTOM_KEY` secret.
- `attempts` — harbor `-k` trials per task, default `5` (leaderboard protocol).
- `n-concurrent` — default `1` (z.ai rate limits; the kimi coding plan
  tolerates more — the owner picks the level at dispatch).
- `shards` — CPU docker shards, default `16` (~4 tasks/shard keeps each
  job inside the job window; raise to ~22 for the 89-task 2.x sets).
  Shards run up to 5 in parallel on the default ubuntu runners.
- `cpu-env` — Harbor env for the CPU shards, default `docker` (issue
  #1316: local docker, no Modal/cloud dependency); `modal` for the
  self-hosted path.
- `cpu-runner` — runner label for the docker shards, default
  `ubuntu-latest` (GH runners ship docker); `self-hosted` for the modal
  path.

Smoke first, per family: dispatch with `tasks: <smoke task from the
table>, attempts: 1` (e.g. `dataset: 2.1, tasks: fix-git, attempts: 1`).
Once green, dispatch the full run (`tasks:` empty,
`confirm-full-run: true` for 2.0/2.1/3.0).

**gh-1556 gate (AC9)**: no full 2.1 dispatch until the gh-1556 bench
pipeline changes land AND a smoke dispatch (`family=2.0, tasks=<smoke
task>`) shows a green aggregate with a rendered step summary.

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

### Timeout policy (gh-1556)

Progress-watch is the bench default on every shard: the workflow exports
`FA_PROGRESS_EXTENSION=1`, `FA_STALL_GAP_SEC=360`, and
`FA_AGENT_TIMEOUT_ABS_CEILING_SEC=3600`, so the adapter's kill decision
is the gap-aware `ProgressWatch` (issues #1392/#1430) — a progressing
trial dies only at the flat 3600s absolute ceiling; a stalled one dies at
the gap boundary. The 360s stall-gap pins the gh-1430 invariant (never
below fa's 300s stream-idle watchdog + margin; the REG in
`test_fa_agent_timeout.py` reads the Dart source and fails on drift).
Removing those exports is the only way back to the legacy byte-growth
ladder (its round-2 byte-for-byte REG stays green). Harbor's own
dataset-declared per-task caps still apply underneath — the bench never
overrides them (leaderboard comparability); a trial may therefore end in
harbor's `AgentTimeoutError` without a ladder verdict, which the summary
counts as attempted, not lost.

The kill path itself is bulletproofed (gh-1556 AC1, the TB 2.0 Class-A
score loss): the ladder kill runs `pkill -f '[f]a --session-root'`
(bracket trick — the pre-fix plain pattern matched the exec wrapper's own
cmdline, SIGTERMed its own shell, and the exit-143 skipped both the audit
write and the `TimeoutError`, classifying a ladder kill as an agent
crash), and the kill is wrapped so its failure can never replace the
ladder's timeout classification.

Deadline awareness (gh-1556 AC7): when the adapter arms a cap it also
exports `FA_DEADLINE_EPOCH_MS` (= now + effective cap − 120s wrap-up
margin) into the fa session, so fa can steer its own wrap-up (drain
background jobs, land partial results) before the guillotine; the exact
value is audited in the trial's `fa-timeout-metadata.json`. With no
adapter cap the export is absent — fa never invents a clock.

### Shard startup failures (gh-1658)

A shard whose harbor run fails with zero `result.json` files retries the
harbor invocation once inline (same env/model/params) and marks a
still-failing shard `zero-trial startup failure (retried once)` in the
step summary; the aggregate verdict fails on any shard that contributed 0
trials to the merged export. A red shard WITH trials is a real result and
is never auto-retried (a retry would double-bill and mix attempts).

### Cost

- CPU shards: default ubuntu-latest runners (GitHub minutes; the
  self-hosted box remains a `cpu-runner` option for the modal path).
- GPU shard (Modal): pay-per-second — T4 $0.59/h, A10 $1.10/h. A full 4.0
  run (3 GPU tasks × 5 attempts) is single-digit dollars and fits the
  Starter plan's free monthly credits.
- LLM spend runs on the z.ai key (glm-5.3-flash).

### Results

1. **Harbor Hub** — each shard is uploaded
   (`harbor upload jobs/fa-<family>-*`, public) when `HARBOR_API_KEY` is
   set; the job links land in the workflow logs and this is what
   tbench.ai's leaderboard reads. Before uploading, the shard checks
   that every trial with a `result.json` also carries
   `agent/trajectory.json` (the ATIF trajectory, gh-1681) — warn-only in
   normal runs, a hard gate with `submission: true`. See
   [docs/leaderboard-submission.md](leaderboard-submission.md) for the
   submission runbook (pinned dataset, quota-window runner policy, lb
   CLI steps).
2. **Job summary** — the `Aggregate resolution rate` step writes the
   resolution table (resolved/scored per split + overall) to the
   GitHub job summary (`bench/harbor_fa/summary.py`, gh-1556 AC4 — TB1
   parity: reading a result never requires downloading the merged
   artifact), with per-split token totals and derived cost from
   `bench/pricing.json` (issue #1123; unpriced models render n/a), an
   errored-trials breakdown by exception class, and a paste-ready ledger
   row for the table below. Completeness is counted by presence (AC3):
   a trial whose `result.json` was written counts as attempted
   regardless of exception class — the step exits 1 ONLY on genuinely
   lost trials (no `result.json`); errored trials report as their own
   breakdown line, never a verdict. Report jobs are keyed per
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

**Scores are pending the first full run** — the workflow and aggregation
are live; ledger rows append per MLS dataset version per the ledger
discipline above, with cost from `bench/pricing.json` (#1123).

## ProgramBench

`bench/programbench/` + `Bench ProgramBench` workflow — runs fa on
[ProgramBench](https://github.com/facebookresearch/ProgramBench) (~200
tasks: given only a compiled binary and its docs, rebuild a complete
codebase whose behavior matches; issue #1685). Unlike the Harbor benches
there is no shared framework: the workflow drives plain docker plus the
official `programbench` CLI, and its output is SUBMISSION-READY — the
aggregate job runs `programbench submit package` + `submit verify`
(Tier-0) so the uploaded artifact is exactly the folder a registry PR
needs (the leaderboard at programbench.com is self-serve via PRs to
[ProgramBench/submissions](https://github.com/ProgramBench/submissions)).

Files: `tasks.py` (task inventory + shard split from the pinned
ProgramBench checkout), `run_shard.py` (per-shard docker/fa/eval driver),
`llm_forwarder.py` (single-endpoint L4 forwarder), `summary.py`
(accuracy/cost/calls table + structural verdict). Eval and packaging run
the PyPI `programbench` at the pinned `programbench-version` input —
`_stats` must come from one version (the submission guide requires
≥1.2.0).

### Inference airgap (the internet rule, enforced)

ProgramBench bans agent internet access at inference — fetching the
original source is disqualification — and fa's LLM calls originate inside
the task container (the harbor pattern, `bench/harbor_fa/fa_agent.py`).
So each task container is born on a normal bridge network (CA roots +
the fa bundle are installed there — inference must not download its own
prerequisites), then moved onto a docker `--internal` network (no
external route) whose only egress is the host-side
`llm_forwarder.py` bound to the network gateway, forwarding TCP to the
selected provider's API endpoint exactly. TLS stays end-to-end (the
container's /etc/hosts maps the provider hostname to the gateway; SNI and
certificates are the provider's real ones — fa's baseUrl is
byte-identical to a direct run). The agent cannot reach anything else.

Per task (`run_shard.py`): pull
`programbench/<iid __→_1776_>:task_cleanroom_v6` → install bundle to
`/opt/fa` + autopilot approval (harbor's install() surface) → cut the
internet → `fa -p` with the rebuild prompt (compile.sh deliverable, the
official no-wrap/no-decompile rules) under the `agent-timeout` wall cap →
tar `/workspace` to `submission.tar.gz` (produced even on kills — partial
work evaluates honestly) → trajectory + session logs copied out. Eval
runs once per shard: `programbench eval <run_dir>`.

### Running

Dispatch **Bench ProgramBench**. Inputs:

- `tasks` — `smoke` (default: the two lexicographically-first instances;
  a pipeline proof, NOT a leaderboard row), `lite` (deterministic
  ~20-instance stride), comma fnmatch globs, or empty = the full ~200
  instances (requires `confirm-full-run: true`).
- `provider` / `provider-config` — the gh-1471/1503 dispatch surface,
  byte-shared with `Bench` and `Bench Harbor` (zai glm-5.3-flash default,
  kimi-for-coding, custom).
- `programbench-ref` — git ref pinning the official task set (inventory
  is enumerated from this checkout, never from PyPI data).
- `programbench-version` — PyPI pin for eval + packaging (default 1.2.5).
- `shards` / `max-parallel` — chunking and concurrency; defaults ~4
  instances per 6h job, 3 shards in flight.
- `agent-timeout` — per-instance wall cap; default 21600s = the official
  mini-swe-agent baseline budget (the pass@1 comparability anchor — one
  attempt per instance, no attempts input by design).

### Quota discipline (kimi saga, gh-1674)

Tasks run sequentially inside a shard; shards run ≤3 in parallel by
default (`max-parallel`). A provider 429 aborts the shard's remaining
tasks immediately (exit 2 — never retried inline: no trial starts into a
dead quota window; rerun the dispatch to resume, remaining tasks are
marked skipped). Only a zero-trial startup crash (docker pull / airgap /
resolve transient) gets the gh-1658-style single inline retry; a failure
with trials is a real result and never retried. The setup resolve step
preflights the provider secret before any spend.

### Results

1. **Job summary** — the accuracy/cost/calls table per instance
   (`bench/programbench/summary.py`), the solved ✅ column, and the
   structural verdict (every attempted instance packed, evaluated, and
   scored — a lost shard fails the run, never a silent score). A partial
   run's headline is dilution-labeled in the table: `submit package`
   divides by the full official set. Verdict wording (gh-1838 AC1):
   "solved" is the strict score (100% of the instance's scored tests);
   the ✅ structural verdict states the facts only ("ran, were evaluated,
   and packaged") and, unless every attempted instance is strictly
   solved, an adjacent line carries the exact outcome ("Strictly solved
   0/2 — solved requires 100% of scored tests").
2. **Artifacts** — per-shard run dirs (`pbench-shard-*`) and
   `programbench-submission`: the packaged, Tier-0-verified folder with
   `submission.yaml`, `_stats/score.json` (the tool's ignored-test-
   filtered map — never recomputed harness-side), self-reported
   `_stats/cost.json` + `_stats/calls.json` computed from the fa session
   logs via `bench/fa_usage.py` + `bench/pricing.json`, per-instance
   `submission.tar.gz` + `*.eval.json` + `*.traj.json`.
3. **Verdict gate** — `programbench submit verify` (Tier-0) must pass in
   CI; a submission that cannot pass the registry's own check never
   leaves the run.

### Pricing resolution (gh-1838)

Costs come from the pinned table `bench/pricing.json` (USD per 1M tokens,
data only — a model missing from it renders `n/a`, never an invented
rate, #1123). The summary resolves it loudly and overridably:

- **Loud resolution (AC5)** — a pricing file that fails to load/parse
  prints a `⚠️ pricing:` warning naming the path and the error; an entry
  that exists never degrades to a silent `n/a` (`kimi-for-coding`'s
  explicit `$0` subscription-marginal entry renders `$0.0000`).
- **`FA_BENCH_PRICING` override (AC6)** — the dispatch input
  `pricing-override` (or the env var directly) supplies inline JSON or a
  path to a pricing JSON in the same `usd_per_mtok` shape; it merges OVER
  `bench/pricing.json` per model key (`input`/`output`/`cache_read`/
  `cache_write`), so a run can price or correct models without editing
  the repo. The effective source is logged in the summary's `Pricing`
  row (`repo default — …` / `env override FA_BENCH_PRICING (file <path>)
  over repo default …`). A failed override falls back loudly to the repo
  default. Unknown models still render `n/a`.
- **Aliases (AC7)** — a pricing doc may carry an `"aliases"` map
  (`{"plan-id": "api-model-id"}`); an aliased model prices at the target
  API model's rates and is LABELLED in the summary ("estimate @ <model>
  rates"). The estimate never mixes with real billing: it is excluded
  from `_stats/cost.json`. The official Kimi API rate-card entries
  (`kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `kimi-k2.6`, `kimi-k3`,
  `kimi-k3.1-pro`, `kimi-k3.1-pro-highspeed`) are in the repo default,
  verified against platform.kimi.ai/docs/pricing/chat (2026-10-24);
  `kimi-for-coding` — the coding PLAN, not an API model — keeps its
  explicit `$0` entry.
- **Cache-read visibility (AC8)** — priced runs render a cost split
  (input + output + cache-read + cache-write) under the table: cached
  reads dominate API-style cost (reference run ≈211M cacheRead tokens vs
  ≈1.1M fresh input) and must stay in view.

### Opening the submission PR (manual, by design)

The workflow stops at the verified artifact — publishing is a maintainer
decision. Per the official submission guide:

1. Download the `programbench-submission` artifact (one folder = one
   submission; the run dir name is the `submission_id`).
2. Fill in `submission.yaml`'s maintainer fields (package leaves `TODO`:
   submitter, model/provider display names, `is_os_model` /
   `is_os_scaffold` — fa is the scaffold, so `is_os_scaffold: true`) and
   finish the generated `README.md` checklist.
3. Push the folder to a public repo you own (e.g.
   `programbench submit publish <dir> --owner <your-org>`, or by hand) —
   this fork URL + pinned commit is what `pointer.yaml` carries.
4. Open the PR to ProgramBench/submissions adding
   `submissions/<id>/` (`programbench submit register <dir>` does it with
   `gh`, or copy `pointer.yaml` + `submission.yaml` + `_stats/` by hand).
   Registry CI recomputes the headline (Tier-0) on merge; Tier-1 re-runs
   eval from the uploaded solutions.
5. Only a full (`tasks: ''` + `confirm-full-run: true`) run is a
   leaderboard row — smoke/lite artifacts are pipeline proofs.

Task images are x86_64-only (dockerhub `programbench/*:task_cleanroom_v6`)
— hosted ubuntu runners only, no arm/self-hosted-mac path.

## Legacy: terminal-bench-core 0.1.1

`bench/terminal_bench/` + `Bench` workflow — kept for regression runs of
the 0.1.1 baseline (32.5% with fa + glm-5.3-flash; harness-side failure
clusters tracked in issue #142). See `bench/terminal_bench/run.sh` for the
local path. Not valid for leaderboard submissions.

### Dataset rot repairs (patch_dataset.py)

`tb datasets download` is re-fetched fresh per run and then patched in
place by `bench/terminal_bench/patch_dataset.py` before `tb run` (both in
the workflow and in run.sh):

- debian:-based task Dockerfiles get the archive.debian.org /
  snapshot.debian.org repoint + `Acquire::Check-Valid-Until "false"` conf
  (Debian archived bullseye; issue #142).
- `fix-git` gets its `setup.sh` replaced: the original clones
  `TheMikeMerrill/personal-site`, which was deleted (404 → `docker compose
  build` exit 128, no trial ever starts — gh-1208). The replacement
  rebuilds the identical task state locally, network-free: master one
  commit past a detached-HEAD "Move to Stanford" commit holding the
  shipped `resources/patch_files` payloads, with the HEAD reflog keeping
  that commit on line 4 — where the upstream `solution.sh` reads it.
  Marker for idempotency: the dead repo URL's presence in setup.sh.

### Compose failure visibility (sitecustomize.py)

tb logs captured `docker compose` stdout/stderr at DEBUG only, so a build
failure on CI surfaces as a bare `CalledProcessError` (gh-1208 cost two
full runs before anyone saw the real error). `bench/terminal_bench/`
is already on `PYTHONPATH` for every `tb run` (run.sh + the workflow), and
python auto-imports `sitecustomize` from it at startup: a post-import hook
patches `DockerComposeManager._run_docker_compose_command` to re-log the
captured output at ERROR (tail-capped to 32 KiB per stream) before the
exception propagates — no invocation changes, no eager tb import.
Opt-out: `FA_TB_LOG_COMPOSE_FAILURES=0`.
