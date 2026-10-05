// Issue #1280 — the CLI arch matrix must gate merges and every produced
// binary must boot:
//
// v1.0.512 shipped without fa-linux-arm64/-linux-x64/windows + SHA256SUMS.
// Chain: a flaky PTY boot timeout reds the arm integration leg on the
// release run -> quality-gate red -> the release `binaries` matrix skips
// (ci.yml gates it on `needs.quality-gate.result == 'success'`). The
// never-again gap that made this a merge-gate blind spot: PR validation
// runs are dispatched by Machine SM as `workflow_dispatch` on the PR head,
// but binaries-pr/binaries-smoke-gate gated themselves on
// `github.event_name == 'pull_request'` — the required "Binaries smoke
// gate" context went green-by-skip on every real validation run, so a
// broken arch build could never block a merge. And the release `binaries`
// job uploaded assets without ever booting them (NG2).
//
// Structural lint over .github/workflows/ci.yml (same style as
// dispatch_watch_test.dart / release_hygiene_test.dart).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// The full CLI binary target inventory (NG1): every supported target the
/// release ships must exist as a matrix leg in BOTH the merge-gate matrix
/// and the release matrix.
const expectedArchLegs = {
  'windows-x64',
  'macos-arm64',
  'macos-x64',
  'linux-x64',
  'linux-arm64',
};

Set<String> matrixLegs(YamlMap job) {
  final include = (job['strategy'] as YamlMap)['matrix'] as YamlMap;
  return (include['include'] as YamlList)
      .map((e) => '${(e as YamlMap)['os']}-${(e as YamlMap)['arch']}')
      .toSet();
}

int _stepIndex(YamlMap job, String stepName) =>
    (job['steps'] as YamlList).indexWhere(
      (s) => (s as YamlMap)['name'] == stepName,
    );

void main() {
  final ci = jobsOf('.github/workflows/ci.yml');

  group('NG1 — the arch matrix gates the merge (#1280)', () {
    test('binaries-pr also fires on the SM validation dispatch event', () {
      final cond = (ci['binaries-pr'] as YamlMap)['if'].toString();
      expect(cond, contains("github.event_name == 'pull_request'"));
      expect(
        cond,
        contains("github.event_name == 'workflow_dispatch'"),
        reason:
            'SM-dispatched PR validations are workflow_dispatch — a '
            'pull_request-only gate skipped the required "Binaries smoke '
            'gate" context green on every real validation run '
            '(v1.0.512 starvation class)',
      );
    });

    test(
      'binaries-smoke-gate aggregates the same events (no green-by-skip)',
      () {
        final cond = (ci['binaries-smoke-gate'] as YamlMap)['if'].toString();
        expect(cond, contains("github.event_name == 'workflow_dispatch'"));
      },
    );

    test('binaries-pr carries the full 5-leg arch inventory', () {
      expect(matrixLegs(ci['binaries-pr'] as YamlMap), expectedArchLegs);
    });

    test('linux/arm64 builds on the native arm runner (no cross-compile)', () {
      // `dart build cli` cannot cross-compile linux_arm64 (ci.yml matrix
      // comment) — the leg must stay pinned to ubuntu-24.04-arm.
      final include =
          ((ci['binaries-pr'] as YamlMap)['strategy'] as YamlMap)['matrix']
              as YamlMap;
      final arm = (include['include'] as YamlList)
          .map((e) => e as YamlMap)
          .firstWhere((e) => '${e['os']}-${e['arch']}' == 'linux-arm64');
      expect(arm['runner'], 'ubuntu-24.04-arm');
    });
  });

  group('NG2 — release binaries boot before they ship (#1280)', () {
    test('release binaries matrix carries the full 5-leg arch inventory', () {
      expect(matrixLegs(ci['binaries'] as YamlMap), expectedArchLegs);
    });

    test(
      'release binaries job boots the binary (fa --help) before archiving',
      () {
        final job = ci['binaries'] as YamlMap;
        const smokeName = 'Smoke — the binary runs (fa --help)';
        final smoke = _stepIndex(job, smokeName);
        final archive = _stepIndex(job, 'Archive bundle');
        final upload = _stepIndex(job, 'Upload archive to GitHub Release');
        expect(
          smoke,
          greaterThanOrEqualTo(0),
          reason: 'release assets must be boot-smoked (NG2)',
        );
        expect(
          smoke,
          lessThan(archive),
          reason: 'a dead binary fails before archiving',
        );
        expect(
          smoke,
          lessThan(upload),
          reason: 'a dead binary fails before upload',
        );
        final run =
            ((job['steps'] as YamlList)[smoke] as YamlMap)['run'].toString();
        expect(run, contains('--help'));
        expect(run, contains('exit 1'));
      },
    );
  });

  group('merge-gate lockstep (#1280 never-again)', () {
    test(
      'machine-sm still stamps Binaries smoke gate as a required context',
      () {
        final sm = read('.github/workflows/machine-sm.yml');
        expect(
          sm,
          contains('"Binaries smoke gate"'),
          reason:
              'the arch gate only blocks merges while the SM-required context '
              'keeps the exact aggregate job name',
        );
      },
    );
  });
}
