# Leaderboard submission runbook (gh-1681)

How to take a `bench-harbor.yml` run from "results on the Harbor Hub" to
"a submittable terminal-bench leaderboard job". Community submissions are
currently closed for every terminal-bench version ("only submissions run
by the maintainers") — this is **readiness**: when a submission window
reopens (2.1 today; 3.0/4.0 later), the run produced by following this
page must already satisfy the submission rules.

Sources: `leaderboard/SUBMIT.md` + `core/hub.py` of the pinned dataset
repo (harbor-framework/terminal-bench-2-1 for the 2.1 family), harbor
0.23.0 (`harbor upload` packager, `harbor/models/trajectories` ATIF
schema), and the `submission: true` preflight in
`.github/workflows/bench-harbor.yml`.

## What the leaderboard reads

Everything comes from the Harbor Hub (`hub.harborframework.com`):

- `lb filter` takes **hub job links** — a run only exists for the
  leaderboard if every shard was uploaded (`harbor upload --public`,
  gated on the `HARBOR_API_KEY` repo secret).
- Leaderboard CI **re-derives every trial from the `source_jobs`** — a
  rerun-stitched matrix is not submittable. Trials must come from ONE
  run of the workflow.
- The static analysis requires every rewarded trial to have a hub
  `trajectory_path` in **ATIF format** — "agents that only upload custom
  logs fail here". The fa adapter exports
  `<trial>/agent/trajectory.json` per trial (`fa trajectory export
  --format atif`, gh-1681 Gap 2) and the per-shard **Preflight ATIF
  trajectories** step verifies presence before upload.
- An LLM `/judge` audit runs on all successful trials (reward-hacking
  check) — the finalize gate's verify-before-claim discipline is the
  mitigation; trajectories must be real, not padded.

## The dispatch (submission mode)

1. **Smoke first** (unchanged rule): `tasks=<family smoke>`,
   `attempts=1`, verify the ATIF gate reports `N/N trials carry an ATIF
   trajectory` and the uploaded smoke job shows `trajectory.json` per
   trial on the hub. This is the AC2 verification: a 1-task smoke run
   proves a rewarded trial's ATIF trajectory reaches the hub.
2. **Full run**: dispatch with `submission: true` and:
   - **no `tasks` filter** — full task coverage is required (the setup
     preflight fails otherwise);
   - `attempts >= 5` — at least 5 trials per task;
   - **no `agent-timeout`** — `timeout_multiplier` must stay 1.0 (no
     agent/verifier timeout overrides, no resource overrides);
   - a **pinned dataset**: the full `org/name@ref` id (the preflight
     rejects a bare name). The 2.x hub packages only carry `@latest`;
     when it is mutable like that, record the resolved content hash
     printed in each shard's `harbor datasets download` log into the
     submission metadata so the submission pins what actually ran.

The preflight runs in the setup job — a rule violation costs one setup
minute, never shard-hours of un-submittable results.

## Quota-window runner policy

**Errored trials count as reward 0 and are NOT excluded.** A
submission job must contain **zero infra-errored trials** — never burn
trials into a dead provider window:

- Provider quota windows (e.g. the Kimi coding plan's 5-hour windows)
  are handled **runner-side**: the runner waits between trials (the
  workflow's progress-watch kill + `n-concurrent: 1` keep every trial
  inside a live window); no trial is started into a dead window.
- This supersedes the closed #1674 **in the bench context**: fail-fast
  stays the default for local runs; the leaderboard-configured runner
  parks between trials instead of burning attempts.
- If a shard still ends with errored trials (exception classes in the
  summary's erored-trials breakdown), the run is not submittable —
  rerun the shard matrix fresh rather than stitching.

## Verifying readiness after the run

1. The job summary shows the **ATIF trajectories** block per shard
   (`N/N trials carry an ATIF trajectory`); with `submission: true` any
   miss fails the shard before upload.
2. Each shard's **Upload to Harbor Hub** step logs the uploaded job;
   open the hub job and confirm the trials are **publicly readable** and
   each carries a `trajectory.json`.
3. `result.json` metadata carries `atif_trajectory: present|missing`
   (folded by the adapter) so the ledger can be audited without the hub.

## Submitting (when a window reopens)

Per the dataset repo's `leaderboard/SUBMIT.md`:

1. `lb filter` — submit the hub job links from the run (one submission
   per agent + agent version + model + reasoning effort; the workflow's
   run label and `fa --version` identify the pair).
2. `lb metadata` — attach the run metadata (dataset id + resolved
   content hash for `@latest` families, model, agent version, date).
3. `lb open-prs` — open the submission PRs.
4. The `/judge` reward-hacking audit runs on all successful trials
   automatically.

## Failure modes and what to do

| Symptom | Meaning | Action |
|---|---|---|
| Preflight ATIF step warns `X/Y` in a normal run | a trial finished without a trajectory | check the shard log for the `[fa_agent] warning: ATIF trajectory export` line; rerun the shard |
| Submission-mode shard fails at the ATIF gate | un-submittable job caught before upload | fix, rerun the shard fresh (no stitching) |
| Setup preflight rejects the dispatch | a submission rule violated (coverage, attempts, timeout override, unpinned dataset) | re-dispatch with the rule satisfied |
| Hub upload step skipped | `HARBOR_API_KEY` secret absent | owner provisions the secret; artifacts still carry results |
