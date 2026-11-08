// gh-2070 — the Cube kernel live (macOS) budget survives a degraded-box
// window on the single self-hosted runner.
//
// CI run 42511425580 (tag v1.0.695, 2026-11-08) red'd the release: the
// `Cube kernel live (macOS)` job was killed by its own job-level
// `timeout-minutes: 10` while its FIRST step — a plain github.com
// `actions/checkout` — was still running. The checkout stalled 9m32s
// against a 1–3 s baseline (8 observed runs on the same box: full-job
// walls 68–114 s, e.g. run 42496815925 checkout = 5 s), and the ceiling
// cancelled the job mid-step: conclusion `cancelled`, later steps
// skipped. `Quality gate` followed (`platform_red` — cube-kernel-live is
// a platform leg, #1368: anything not success/skipped is red), the
// release train skipped, and `Advance vpinned marker` refused loudly by
// design (pin_release.sh does not move the marker without the signed
// provenance the skipped train never published). The fa-m5 pool is ONE
// host under ONE user account hosting fa-m5 / fa-m5-2 / fa-m5-3 —
// cross-workflow contention windows on that box are documented
// (gh-2013: "each build crawls ~10x its solo time"); a 10-min ceiling
// sized to the healthy wall turns one such window into a release-kill.
// Red tag runs are release-flow failures, triaged and fixed
// structurally — never quarantined as flakes (AGENTS.md, gh-1537 note;
// same class as gh-1778's test-core budget).
//
// Deliberately YAML-level asserts (the ci_core_shard_timeout_guard_test.dart
// static pattern):
//  AC1  `cube-kernel-live` declares a job-level `timeout-minutes` >= 30 —
//       headroom over the gh-2070 stall (9m32s checkout + the rest of the
//       healthy ~2 min job ≈ 12 min worst observed) with ~20 min of slack,
//       in line with the sibling hosted-macos build leg (build-ios: 30).
//       A genuinely wedged box is still killed loudly, just not during a
//       transient contention window.
//  AC2  the leg stays routed to the shared `macos-m5` pool — the budget
//       raise must never arrive packaged with a reroute off the one
//       genuinely macOS-only gate runner (the release_hygiene gh-1005 pin,
//       re-asserted here so this file's contract is self-contained).
//  AC3  no step inside the job declares its own shorter `timeout-minutes`
//       — a step-level cap would silently reintroduce a gh-2070-magnitude
//       kill under the job ceiling (today no step has one; keep it that
//       way or raise the ceiling argument again in the open).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const ci = '.github/workflows/ci.yml';
const cubeJobId = 'cube-kernel-live';

/// The gh-2070 worst observed stall: checkout ran 9m32s (572 s) without
/// completing before the 10-min ceiling cancelled the job (run
/// 42511425580).
const observedStallSeconds = 572;

/// Healthy full-job walls on the same box (8 runs, 2026-11-08): 68–114 s.
const healthyWallSeconds = 114;

/// The new job budget — clears the gh-2070 stall with ~20 min of slack
/// and sits at the sibling hosted-macos build leg class (build-ios: 30).
const minJobTimeoutMinutes = 30;

int? jobTimeout(YamlMap job) {
  final v = job['timeout-minutes'];
  return v is int ? v : (v is String ? int.tryParse(v) : null);
}

YamlMap cubeJob() {
  final root = loadYaml(read(ci)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  final job = jobs[cubeJobId];
  if (job is! YamlMap) throw StateError('job $cubeJobId missing from $ci');
  return job;
}

List<YamlMap> cubeSteps() =>
    (cubeJob()['steps'] as YamlList).whereType<YamlMap>().toList();

void main() {
  group('gh-2070 — cube-kernel-live budget survives a degraded-box window',
      () {
    final job = cubeJob();
    final steps = cubeSteps();

    test('AC1: the job budget clears the gh-2070 stall with slack', () {
      final timeout = jobTimeout(job);
      expect(
        timeout,
        isNotNull,
        reason:
            'cube-kernel-live must keep a job-level timeout — it is the '
            'backstop that kills a genuinely hung leg loudly',
      );
      expect(
        timeout,
        greaterThanOrEqualTo(minJobTimeoutMinutes),
        reason:
            'cube-kernel-live timeout-minutes is $timeout — the leg needs '
            '~$healthyWallSeconds s healthy, but the gh-2070 checkout '
            'stalled $observedStallSeconds s and the 10-min ceiling '
            'cancelled it mid-step (run 42511425580, v1.0.695), redding '
            'the release through the platform-leg verdict; the budget '
            'must clear that stall with slack, matching the sibling '
            'hosted-macos leg (build-ios: 30 min)',
      );
    });

    test('AC2: the leg stays routed to the shared macos-m5 pool', () {
      final runsOn = job['runs-on'].toString();
      expect(
        runsOn,
        contains('macos-m5'),
        reason:
            'cube-kernel-live keeps the genuinely macOS-only gate on the '
            'macos-m5 pool (gh-1005) — the gh-2070 budget raise must not '
            'come packaged with a reroute (found: $runsOn)',
      );
    });

    test('AC3: no step caps its own runtime below the job ceiling', () {
      for (final step in steps) {
        expect(
          step.containsKey('timeout-minutes'),
          isFalse,
          reason:
              'step "${step['name'] ?? step['uses']}" declares its own '
              'timeout-minutes — a step-level cap silently reintroduces a '
              'gh-2070-magnitude kill under the job ceiling; the job-level '
              'budget is the only stall bound this leg should carry',
        );
      }
    });
  });
}
