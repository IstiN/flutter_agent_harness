# Memory churn: measuring, budgeting, and regressing (issue #1850)

Allocation churn and retention are tracked with [`crap4dart memory`]
(≥ 0.19.0 — on the Flutter engine it measures through the VM Service
allocation profile; `churnNewMb` is intentionally `null` there and
`allocatedMb` is the cross-engine metric).

## The two metrics

| metric | dart engine (`dart test`) | flutter engine (`flutter test`) |
|---|---|---|
| `churnNewMb` | reclaimed new-gen volume (GC log) | **null by design** (the VM GC stream has no new-gen reclaimed counter) |
| `allocatedMb` | falls back to `churnNewMb` | exact allocated bytes per window (VM allocation profile) |
| `oldGrowthMb` | signed old-space delta summed over GCs — **includes promotion smear**: short-lived garbage that got promoted and was only reclaimed by a later full GC counts as "growth" | same |

`oldGrowthMb` over a whole file therefore reads high; before declaring a
leak, measure the settled live set (below).

## Nightly report (issue #1850 AC5)

`.github/workflows/nightly.yml` runs the `memory-churn` job every night:

- **core** — the whole `test/` suite on the dart engine. Badge budget:
  **35,000 MB total churn** (the #1850 AC4 target; the 2026-10-25
  baseline was 56,393 MB, cut by #1872 provider-export crypto and #1873
  trajectory).
- **app** — the #1850-named Flutter suites on the flutter engine
  (allocated-volume basis). Badge budget starts at **3,000 MB** for the
  subset. The whole app suite does not fit a hosted job (every test is a
  fresh flutter_tester), so the subset is the standing proxy.
- Artifacts: `memory-churn-report` (both JSONs + badges), 90-day
  retention. A red leg files the deduped `nightly-red` issue like the
  other nightly legs.

A PR that changes allocation behavior quotes before/after from the
**targeted files** (never a whole-suite re-run — the core pass is slow by
design).

## Before/after workflow

```bash
# BEFORE (on the base revision), targeted at the files you touch:
crap4dart memory --format json --top 20 <test/files...> > before.json
# Flutter engine files: same command; the tool auto-detects flutter from
# pubspec.yaml and rides `flutter test --verbose -j1` (files run twice).

# AFTER (on your branch), the exact same command:
crap4dart memory --format json --top 20 <test/files...> > after.json

# Diff what matters:
jq -r '.tests[] | [.allocatedMb, .oldGrowthMb, .label] | @tsv' before.json > /tmp/b
jq -r '.tests[] | [.allocatedMb, .oldGrowthMb, .label] | @tsv' after.json  > /tmp/a
diff /tmp/b /tmp/a
```

Quote both totals (`totalAllocatedMb`) and the per-test rows for the named
files in the PR.

### Machine pinning

Numbers are only comparable on the same machine class and SDK. The CI
legs pin the Flutter SDK (`3.47.4`) for exactly this reason; locally, use
the same SDK across before/after and expect ±10 % run-to-run noise.

## Settled retention (is a growth number a leak?)

`oldGrowthMb` is not a leak verdict. To measure what a suite truly
RETAINS, force a full GC at suite end and read the per-class live set:

1. Append one line inside the suite's `main()`:
   `tearDownAll(() => settleMemoryProbe('my_suite'));`
   (helper: `flutter_app/test/memory_probe.dart`; it is inert unless the
   VM service is on).
2. Run with the VM service enabled:

   ```bash
   cd flutter_app
   flutter test --start-paused test/my_suite_test.dart &   # prints the URI, then waits
   # resume it with any one-shot VM service client, e.g. the driver used
   # by crap4dart; the probe then writes ../.bench/settled_my_suite.json
   ```

3. `totalLiveBytes` is the truth: framework baseline (~105 MB per
   flutter_tester process on 3.47.4 macOS-arm64) + the code model of
   everything the file imports + the suite's own live data.

Measurements recorded for the #1850 offenders (2026-10-25, macOS-arm64,
Flutter 3.47.4): an empty suite settles at ~105 MB; the six named app
suites settle at 259–397 MB **and a one-test bisect of a suite equals the
full suite's settled set** — i.e. nothing accumulates *across* tests.
Cross-test "growth" in the GC stream is promotion smear + per-process
one-time cost, not retention.
