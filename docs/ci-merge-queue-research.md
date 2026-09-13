# GitHub merge queue — research memo (issue #283, AC5)

Date: 2026-09-13. Author: CI wave-3 workstream. **Research only — no settings changed;
enabling is the owner's decision.**

## Why this is on the table

Branch protection on `main` is in strict mode ("branches must be up to date before
merging"). Every merge to `main` invalidates the green of every other open PR,
forcing a serial update-branch → full-CI-re-run cycle. On 2026-09-13, **7 approved
PRs waited through serial re-runs** (measured, see issue #283). With CI at 10–18 min
wall-clock, the last PR in the line waits hours despite being green all along.

GitHub merge queue replaces the strict "up to date" requirement: PRs enter a queue;
GitHub builds a temporary merge branch (`main` + the queued PRs), runs the required
checks on **the merge result**, and fast-forwards `main` only when green.

## Safety: a strengthening, not a trade (the invariant)

Today a PR goes green on its **head commit**; the actual merge result is never
tested before landing (with strict mode the head *is* main+PR only if the branch is
literally up to date at merge time — which the update-branch storm approximates but
the merge machine / admin bypass can skip).

The merge queue runs the required checks on the head of the temporary merge branch —
**the code exactly as it will land on main**. That is strictly stronger than PR-head
green: the invariant "code NEVER reaches main without green tests AND a successful
compile" is enforced on the merge result itself, closing the semantic-conflict hole
(two PRs individually green, broken together). Every speed argument below is
secondary to this.

## Interaction with the 3 required checks

Current branch protection (read 2026-09-13 via API):

- Required checks: `JS engine integration (quickjs-ng)`, `Binaries smoke gate`,
  `Quality gate`.
- `enforcement_level: non_admins` (admins can bypass — unchanged by the queue).
- Strict "up to date" mode: ON (per issue #283; the full protection endpoint is
  admin-only, so this was not re-verified by API).

With a merge queue:

1. **Same 3 required checks.** The queue does not add, remove, or rename required
   checks. `Quality gate` remains the aggregate that all fa_ui/core shards fan into —
   sharding (this card) is invisible to branch protection.
2. **Workflows must trigger on `merge_group`.** GitHub runs checks on the queue's
   temporary branch via the `merge_group` event (`types: [checks_requested]`). Any
   workflow whose checks are required MUST add:
   `on: merge_group:` — otherwise the queue waits forever and evicts PRs as
   "checks did not report". This means a one-line trigger addition to `ci.yml` (and
   to whichever workflows own the other two required checks). This is an additive,
   no-op-unless-enabled change — safe to land before the owner flips the setting.
3. **Path filters.** Our `changes` job treats any non-`pull_request` event as "full
   gate" (all four path groups true). A `merge_group` run therefore always runs the
   FULL gate — including the fa_ui shards and goldens-adjacent lanes — regardless of
   what the queued PRs touched. That is the safe direction (the merge result must be
   fully green) and costs runner time on docs-only PRs that PR-head CI skipped.
   With this card landed, a full gate is ≤ 10 min wall-clock, so the cost is small.
4. **Skipped checks count as success** in the queue exactly as on PRs, so the
   skip-tolerant `Quality gate` aggregate keeps its current semantics.

## Batching semantics

- **Solo mode** (group size 1): each PR is merged onto the latest `main` (+ PRs ahead
  of it), checked, landed. One full CI run per merge. Predictable; a flaky or red
  merge result evicts only the offending PR, the rest of the queue re-forms behind
  it.
- **Grouped mode** (`max_group_size` > 1, with `min_group_size` /
  `wait_time` knobs): several PRs are checked together as one merge result —
  amortizes CI across a landing wave. If the group fails, GitHub removes the
  offending PR (it isolates by re-queuing subsets) and the remainder re-runs.
  Trade: fewer CI runs, but a red group costs one full run plus re-runs, and
  attribution of the failure takes a bisect cycle.

Given our measured flakiness is low and PR arrival is bursty (owner batches), the
default conservative choice is **solo or max_group_size ≈ 2–3**; grouping beyond
that buys little while CI is ≤ 10 min.

## Runner-minute cost

The repo is **public** — GitHub-hosted `ubuntu-latest` minutes are **free**, so the
cost is wall-clock latency and concurrency-slot contention, not money.

Strict mode today, N PRs in a landing wave: each merge invalidates the rest →
N + (N−1) + … + 1 ≈ **N²/2 full CI runs** worst case (measured N=7 on 2026-09-13 →
up to ~28 runs of 16–18 min each, serialized by human update-branch clicks).

Merge queue, all green: **N runs** (one per merge result), no human in the loop.
With grouping of g: ≈ N/g runs when green. Even adding eviction re-runs, the queue
is O(N), never O(N²).

## What must change in-repo if the owner enables it (not in this card)

1. `ci.yml`: add `merge_group:` to the `on:` block (one line). The `changes`
   classifier already treats it as full-gate; the concurrency group
   (`ci-${{ github.ref }}`) keys off the queue branch ref — no collision with PR
   runs, and `cancel-in-progress` stays PR-only.
2. Workflows owning the other two required checks (`JS engine integration
   (quickjs-ng)`, `Binaries smoke gate`): same `merge_group:` trigger addition.
3. `watchdog` (degraded-runner retrigger) pushes an empty commit to the PR branch —
   it must stay gated to `pull_request` events; on `merge_group` there is no PR
   branch to push to. Gate it explicitly when adding the trigger.
4. `auto-update-prs.yml` (the current strict-mode coping mechanism) becomes
   unnecessary for queued repos; keep or retire as a separate decision.

## Rollback plan

Disabling is a single branch-protection toggle ("Require merge queue" off), instant,
with no workflow revert needed — the `merge_group:` trigger lines are inert when no
queue exists. Strict "up to date" can be re-enabled at the same time if desired.
Nothing in this card (fa_ui sharding) interacts with the queue beyond the trigger
line, so wave-3 speed work is safe regardless of the decision.

## Recommendation

**Enable the merge queue** on `main` (solo mode, or max_group_size 2–3) after
landing the three `merge_group:` trigger additions listed above, and relax strict
"up to date" at that moment. Rationale, in invariant-first order:

1. **Stronger safety**: required checks run on the merge result — the exact code
   that lands — closing the semantic-conflict hole PR-head green cannot see.
2. **Same required set**: the 3 required checks are untouched; `Quality gate` stays
   the single aggregate; sharding never samples coverage.
3. **Kills the O(N²) re-run storm**: 7 queued PRs ≈ 7 CI runs instead of up to ~28,
   with zero human update-branch round-trips; public-repo runner minutes are free,
   so the win is pure wall-clock.
4. **Cheap, reversible**: one settings toggle to enable, one to roll back.

Do NOT enable before the `merge_group:` triggers land — required checks that never
report would wedge the queue.
