# Issue #132 — bench.yml cannot run the full terminal-bench-core dataset (30-min job timeout)

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/132
- **PR:** https://github.com/IstiN/flutter_agent_harness/pull/134
- **Date:** 2026-09-11
- **Surface:** `.github/workflows/bench.yml`, `bench/terminal_bench/shard_tasks.py`, `bench/terminal_bench/summary.py`

## Symptom

`workflow_dispatch` of `bench.yml` with `tasks='*'`,
`dataset='terminal-bench-core==0.1.1'` could never finish: the single job had
`timeout-minutes: 30` while the dataset holds 80 tasks. Measured on run
34571522133: 4 tasks completed in ~28.5 min, a 5th died mid-run with the
runner; average ~640 s per task (docker build + agent + tests included) puts
the sequential full run at ~14 h — past even the 6 h GitHub-hosted job cap, so
raising `timeout-minutes` alone cannot fix it.

## Root cause

Single-job design: the 30-min default timeout was sized for the
`hello-world` smoke default, and the full-dataset path shares it with no way
to fit 80 × ~11 min of sequential work into any single job.

## Fix — setup → matrix shards → merge

1. **`setup`** (timeout 30): unchanged env prep (dart bundle build, Python
   3.13, `pip install terminal-bench`), then `tb datasets download` fetches
   the dataset and `shard_tasks.py` resolves the task-id list **exactly like
   `tb run -t`** (union of `Path.glob` matches per pattern against the
   dataset dir) and splits it into N contiguous shards, emitting the matrix
   plus the expected-task count through `$GITHUB_OUTPUT`. Empty shards are
   dropped, so a single-id input degenerates to a one-job matrix — the
   smoke path is unchanged. The bundle is uploaded as the `fa-bundle`
   artifact so shards don't rebuild it.
2. **`bench` matrix** (`fromJSON(needs.setup.outputs.matrix)`,
   `fail-fast: false`, `max-parallel: 5`, `timeout-minutes: 180`): each
   shard downloads the bundle and runs its ~10 tasks with repeated
   `-t <id>` flags, `--n-concurrent 1` (sequential per shard keeps the
   10 × ~11 min ≈ 110 min timeout math valid and holds concurrent LLM load
   to `max-parallel`) and a **pinned `--run-id shard-N`** — tb writes
   `tb-runs/<run-id>/results.json`, so pinned ids keep the merge
   collision-free (default run ids are timestamps; two shards starting the
   same second would overwrite each other). Per-shard artifact
   `tb-runs-shard-N` + informational summary upload with `if: always()`,
   so a timed-out shard still contributes partial results.
3. **`merge`** (`needs: [setup, bench]`, `if: always()`): downloads all
   `tb-runs-shard-*` artifacts with `merge-multiple`, uploads
   `tb-runs-merged`, and runs `summary.py` for the aggregate accuracy table
   plus the verdict.

Workflow-level `concurrency: group: bench, cancel-in-progress: false`
queues a second dispatch instead of stacking two multi-hour runs.

### Verdict semantics (changed deliberately)

`tb` exits 0 even with unresolved tasks; the old single job failed the step
on any unresolved task. That cannot survive real datasets — the first full
run scored 26/80 resolved and would be red forever, destroying the signal
the workflow guards. The verdict is now **run completeness only**: fail when
no `results.json` was produced or fewer than the expected task count was
attempted (lost/killed shard); unresolved/pending tasks are the model's
scoreboard, reported in the accuracy line and per-task table without
failing the step.

## Full-run evidence (run 34576017658, `tasks='*'`, `shards=8`)

All 9 jobs green, 80/80 tasks attempted, ≈3 h 25 min total, no timeout
cancellations. Failure classes over the 54 non-resolved (from artifacts):
14 clean test-fails + 13 `agent_timeout` (honest model results), 12
`parse_error` + 13 `test_timeout` (judge-phase apt stalls inside task
containers — panes end mid-`apt-get` at kB/s), 2 `unknown_agent_error`
(`docker compose build` failed for the two qemu task images). No
systematic fa-adapter failure.

## Lessons

- tb's `-t` is repeatable and each pattern is a `Path.glob` against the
  dataset dir — resolve shard membership with the same primitive
  (`tb datasets download --output-dir DIR` first), not by reimplementing
  fnmatch rules.
- Pin `--run-id` whenever results are consumed after the run; the default
  timestamp id collides across concurrent runs.
- Per-task token counters in `results.json` are 0 for the fa adapter —
  don't use them as a liveness signal; use `agent_started_at`/panes.
- A red CI job is a verdict, not a measurement: on datasets where the
  model cannot score 100%, accuracy must be reported, while only
  completeness can fail the build.
