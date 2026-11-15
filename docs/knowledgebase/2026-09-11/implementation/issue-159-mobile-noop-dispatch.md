# Issue #159 — `build-mobile.yml` content=none dispatch went red in the release job instead of a clean no-op

- **Issue:** https://github.com/IstiN/flutter_agent_harness/issues/159
- **PR:** https://github.com/IstiN/flutter_agent_harness/pull/162
- **Date:** 2026-09-11
- **Surface:** `.github/workflows/build-mobile.yml` (release-mobile job)

## Symptom

Manual/workflow_dispatch of `build-mobile.yml` with defaults
(`android_content=none`, `ios_content=none`) — nothing built, nothing to
ship — finished RED (run 34629859092): `release-mobile` ran and its
`ls -laR artifacts/` exited 2 on a directory that was never created. A
meaningless dispatch must end green-neutral; this flavor of red hides real
failures. The same red applied to `metadata_only`/`screenshots_only` on both
platforms (no binary → no artifact → same missing dir).

## Root cause

Three guards disagreed about who is responsible:

- the **job** `if` is skipped-ok — `always() && (build-android
  success|skipped) && (build-ios success|skipped)` — so with both builds
  skipped the job still *runs*;
- each **download-artifact** step is gated per-platform
  (`needs.build-ios.result == 'success'` etc.) — so with no build both
  downloads skip and `artifacts/` is never created;
- `List downloaded artifacts` (`ls -laR artifacts/`) and the release step
  were **unguarded** — `ls` on the missing dir is exit 2.

Skipping a build legitimately produces "skipped", not "success" — any
job that keys artifact *consumption* on plain `always()` must itself handle
the nothing-ran case.

## Fix (+15 lines, release-mobile only)

- New first step **Nothing to release**:
  `if: needs.build-android.result != 'success' && needs.build-ios.result != 'success'`
  — writes a `### Nothing to release` notice to `$GITHUB_STEP_SUMMARY`.
- The release-path steps (Checkout, List downloaded artifacts, Create or
  update GitHub Release) get
  `if: needs.build-android.result == 'success' || needs.build-ios.result == 'success'`.
  This also prevents an *empty* GitHub release being cut for an
  auto-incremented tag — worse than a red `ls`.
- Job-level `if`, per-platform download guards, the wasm_run FFI export
  hard-gates (`_wire_compile_wasm` …) and all other content modes are
  untouched: `app_only`/`all` and single-platform combos behave exactly as
  before; a **failed** build still skips the release job entirely.

Why step-level and not a job-level skip: a skipped job cannot write the
job-summary notice the issue asked for. The job stays green, runs one echo,
and every downstream step shows "Skipped" — the no-op is visible in the UI.

## Verification

1. **Failing-first scenario repro** (throwaway bash mirror of the job's
   gating, per-scenario temp cwd): old gating skipped/skipped → `ls: cannot
   access 'artifacts/'` exit 2; new gating → exit 0 + summary notice;
   success/skipped, skipped/success, success/success → release path
   unchanged (green); failure/* → job skipped (unchanged). Gotcha from the
   run: isolation matters — a leftover `artifacts/` dir from a previous
   scenario made the repro pass falsely until each case got its own temp
   cwd.
2. **actionlint 1.7.7**: clean (YAML + `needs.*` expression validation).
3. **Post-merge dispatch smoke** (run 34647696839, defaults): conclusion
   **success**; job step conclusions via API — `Nothing to release`
   success, Checkout/Downloads/`List downloaded artifacts`/`Create or update
   GitHub Release` all skipped. Exactly the designed no-op.

## Notes

`build-macos.yml` has its own release job with a similar shape; it is
dispatched with real content in practice and was not part of #159 — if a
bare dispatch ever needs to be routine there, the same three-guard audit
applies (download steps vs `always()` job vs unguarded consumers).
