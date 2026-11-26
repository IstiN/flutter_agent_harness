// gh-2436 — the v1.0.782 class: a CANCELLED/FAILED `binaries` stage must
// leave a RERUNNABLE release train, not an unreachable publish point.
//
// Run 45830131519 (v1.0.782): the self-hosted fa-m5-3 runner hung 45 min
// inside the checkout `git fetch`, the `binaries` job's 45m timeout
// cancelled the macos-x64 leg, and `release-provenance` — the SOLE publish
// point (signed SHA256SUMS + `--draft=false --latest` flip) — SKIPPED on
// its `needs.binaries.result == 'success'` gate. Consequences:
//   - the draft release rotted (missing fa-macos-x64 + provenance) until
//     the 24h sweeper or a manual FULL rerun,
//   - `rerun --failed` — the documented recovery vehicle — could NOT
//     resurrect the skipped job, so the red tag + stale vpinned marker
//     needed a ~2h full rerun (re-running the already-green quality gate),
//   - the fail-closed `Advance vpinned marker` job (always(), v1.0.483)
//     surfaced as the ticket-visible red: E_PIN_PROVENANCE_MISSING.
// This is the exact trap v1.0.483 already fixed for install-pin-bump: a
// job that SKIPS is invisible to `rerun --failed`; a job that RUNS AND
// FAILS LOUD is the recovery vessel. release-provenance never got the
// same treatment.
//
// Safe because provenance's own body already fails closed in the right
// order: the gh-1832 required-assets gate runs BEFORE "Build and sign
// SHA256SUMS" and BEFORE the `--draft=false --latest` publish flip — a
// cancelled binaries leg makes provenance fail loud on the missing asset
// and the draft stays a draft (gh-1899 rerunnable-vessel convention).
//
// Static workflow-shape asserts (the ci_red_report / ci_2408 pattern):
//   AC1  release-provenance runs whenever the train reached the binaries
//        stage (`needs.binaries.result != 'skipped'`) — success,
//        failure AND cancelled; the `== 'success'` form is banned.
//   AC2  the skip arm stays: a `binaries` SKIP (failed quality gate /
//        non-release refs) still skips provenance — nothing was built,
//        nothing to sign.
//   AC3  the run-level `!cancelled()` and the tag/release event gates
//        are preserved (no widening beyond the binaries-result arm).
//   AC4  downstream consumers stay coherent with a FAILED provenance:
//        release-asset-smoke still requires success, train-draft-guard's
//        script deletes only on `skipped` (a failed provenance keeps the
//        draft as the rerun vessel), install-pin-bump stays always().
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

void main() {
  final jobs = jobsOf('.github/workflows/ci.yml');
  final provenanceIf = (jobs['release-provenance'] as YamlMap)['if'].toString();

  group('AC1 — release-provenance is rerunnable, never unreachable', () {
    test('runs on a cancelled/failed binaries stage (!= skipped)', () {
      expect(
        provenanceIf,
        contains("needs.binaries.result != 'skipped'"),
        reason:
            'release-provenance must gate on needs.binaries.result != '
            "'skipped' — with == 'success' a cancelled binaries leg "
            '(gh-2436: fa-m5-3 checkout hang hit the 45m timeout, run '
            '45830131519) SKIPS the sole publish point, and `gh run rerun '
            "--failed` never resurrects skipped jobs: the red tag and the "
            'stale vpinned marker then need a ~2h FULL rerun instead of a '
            'rerun --failed recovery.',
      );
    });

    test('the == success form is gone', () {
      expect(
        provenanceIf,
        isNot(contains("needs.binaries.result == 'success'")),
        reason:
            "needs.binaries.result == 'success' is the gh-2436 trap — it "
            'makes the publish point unreachable exactly when the binaries '
            'stage fails or is cancelled, the one state where a loud, '
            'rerunnable failure is needed.',
      );
    });

    test('the if still keys on the binaries result (dedupe-twin intent)', () {
      // ci_release_dedupe_guard_test pins "release-provenance signs what
      // binaries attached" — the if must keep mentioning the binaries
      // result so the deduped release twin keeps its signing leg.
      expect(provenanceIf, contains('needs.binaries.result'));
    });
  });

  group('AC2 — the skip arm survives (gate-failed / non-release refs)', () {
    test('provenance still skips when binaries itself skipped', () {
      expect(
        provenanceIf,
        contains("!cancelled() && needs.binaries.result != 'skipped'"),
        reason:
            'the != skipped arm must stay ANDed with the skip-aware gate: '
            "binaries SKIPS when the quality gate failed or on non-release "
            'refs — nothing was built, nothing to sign, and the '
            'train-draft-guard/sweeper own the (nonexistent) draft '
            'hygiene for that state. Widening past that would sign '
            'releases a red gate never built.',
      );
    });
  });

  group('AC3 — no widening beyond the binaries-result arm', () {
    test('run-level cancel still skips provenance', () {
      expect(
        provenanceIf,
        contains('!cancelled()'),
        reason:
            'a user/workflow-level cancellation must still skip the '
            'publish point — only the binaries-stage outcome widened.',
      );
    });

    test('the tag/release event gates are preserved', () {
      expect(
        provenanceIf,
        contains("startsWith(github.ref, 'refs/tags/v')"),
        reason: 'PR/dispatch runs must never sign or publish releases.',
      );
      expect(
        provenanceIf,
        contains("github.event_name == 'release'"),
        reason:
            'release-provenance stays reachable on the release twin '
            '(gh-1625) and on `release: published` events.',
      );
    });
  });

  group('AC4 — downstream consumers stay coherent with a FAILED publish '
      'point', () {
    test('release-asset-smoke still requires a SUCCESSFUL provenance', () {
      final smokeIf = (jobs['release-asset-smoke'] as YamlMap)['if'].toString();
      expect(
        smokeIf,
        contains("needs.release-provenance.result == 'success'"),
        reason:
            'the post-publish smoke probes release URLs — it must only run '
            'after provenance actually signed and flipped the release.',
      );
    });

    test('train-draft-guard deletes only on a SKIPPED publish point', () {
      final script = read('scripts/release_train_draft_guard.sh');
      expect(
        script,
        contains('if [ "\$result" != "skipped" ]'),
        reason:
            'the guard must treat a FAILED/CANCELLED provenance as '
            'rerunnable and keep the staged draft as the rerun --failed '
            'recovery vessel (gh-1899) — with AC1 in place a cancelled '
            'binaries stage now yields a FAILED (not skipped) provenance, '
            'so the draft must survive for exactly that recovery.',
      );
    });

    test('install-pin-bump keeps its always() rerunnable arming', () {
      final pinIf = (jobs['install-pin-bump'] as YamlMap)['if'].toString();
      expect(
        pinIf,
        contains('always()'),
        reason:
            'the v1.0.483 contract: the marker advance must RUN (and fail '
            'loud) even on a red upstream, so rerun --failed reaches it '
            'once the train recovers.',
      );
    });
  });

  group('guard stays meaningful', () {
    test('release-provenance and the gh-1832 gate order still exist', () {
      final prov = jobs['release-provenance'] as YamlMap;
      final stepNames = (prov['steps'] as YamlList)
          .map((s) => (s as YamlMap)['name']?.toString() ?? '')
          .toList();
      expect(
        stepNames,
        contains('Assert required release assets (gh-1832 gate)'),
      );
      final gateIdx = stepNames.indexOf(
        'Assert required release assets (gh-1832 gate)',
      );
      final flipIdx = stepNames.indexWhere(
        (n) => n.startsWith('Upload provenance assets'),
      );
      expect(
        gateIdx,
        lessThan(flipIdx),
        reason:
            'the whole AC1 widening is safe ONLY because the gh-1832 gate '
            'fails BEFORE the sign/publish flip — if the step order '
            'changes, revisit this guard before trusting a FAILED '
            'provenance as "loud but safe".',
      );
    });
  });
}
