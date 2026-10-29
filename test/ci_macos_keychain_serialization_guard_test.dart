// gh-1852 / gh-1865 — why the build-macos matrix no longer needs
// serialization, and why it must never regain per-job keychains.
//
// HISTORY: the two build-macos matrix legs used to create their own
// per-arch keychains (build-arm64.keychain / build-x86_64.keychain) and
// publish them through the PER-USER GLOBAL keychain search list.
// `security list-keychains -d user -s` REPLACES the whole list, so
// concurrent legs evicted each other (gh-1852, run 40117288269: x86_64
// evicted arm64's keychain 67 s after import; gh-1866, run
// 40165498619: the cross-workflow variant — the TestFlight iOS job on
// another fa-m5 registration of the SAME host evicted it 75 s after
// import). The first fix serialized the matrix with
// `strategy.max-parallel: 1`; the second made the writes additive; the
// gh-1865 endgame (run 40455401630, owner decision 2026-10-28) retired
// per-job keychains ENTIRELY in favor of the persistent host keychain
// managed by scripts/ci-sign.
//
// With no keychain lifecycle and no search-list writes left in the
// workflow, the legs are race-free BY CONSTRUCTION and the matrix runs
// PARALLEL again — which is the whole point of the pool (#359):
//
//   AC1  build-macos matrix is NOT serialized by keychain necessity:
//        max-parallel is absent or >= 2.
//   AC2  audit: NO multi-leg matrix job in ANY workflow contains keychain
//        lifecycle writes — the gh-1852 class of "a matrix fan-out times
//        a keychain mutation" must stay structurally impossible.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';

String read(String path) => File(path).readAsStringSync();

YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// Executable (comment-stripped) script text of every step in the job.
String executableScriptOf(YamlMap job) {
  final steps = job['steps'] as YamlList? ?? YamlList();
  return steps
      .whereType<YamlMap>()
      .map((s) => s['run']?.toString() ?? '')
      .map(_stripComments)
      .join('\n');
}

String _stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

/// True when the job's rendered step scripts touch keychain lifecycle or
/// the user-global keychain state — the operations that made matrix
/// fan-outs dangerous back when legs carried per-job keychains.
final _keychainMutation = RegExp(
  r'security\s+(create-keychain|delete-keychain|'
  r'list-keychains\s+-d\s+user\s+-s|default-keychain)',
);

void main() {
  test('AC1 — build-macos matrix runs parallel (no keychain-driven '
      'max-parallel: 1) (gh-1852 retired by ci-sign)', () {
    final job = jobsOf(workflowPath)['build-macos'] as YamlMap;
    final strategy = job['strategy'] as YamlMap?;
    final maxParallel = strategy?['max-parallel'];
    if (maxParallel is int) {
      expect(
        maxParallel,
        greaterThanOrEqualTo(2),
        reason:
            'build-macos matrix is serialized (max-parallel: '
            '$maxParallel) but the gh-1852 reason is retired: legs no '
            'longer create keychains or write the search list — they '
            'sign via ci-sign against the persistent host keychain. '
            'Serialization here is pure lost throughput (#359). If a '
            'NEW race justifies re-serializing, the reason must be '
            'documented in this test, not inherited from the retired '
            'per-job-keychain era.',
      );
    }
  });

  test('AC2 — audit: no multi-leg matrix job mutates keychain state '
      '(gh-1852 class)', () {
    final offenders = <String>[];
    for (final wf in Directory(
      '.github/workflows',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.yml'))) {
      final jobs = loadYaml(read(wf.path))['jobs'] as YamlMap? ?? YamlMap();
      jobs.forEach((name, job) {
        if (job is! YamlMap) return;
        final strategy = job['strategy'];
        final script = executableScriptOf(job);
        if (strategy != null && _keychainMutation.hasMatch(script)) {
          offenders.add('${wf.path}:$name');
        }
      });
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'a multi-leg matrix job still performs keychain lifecycle or '
          'user-global keychain writes: $offenders. Matrix fan-outs '
          'amplify every keychain race on the shared fa-m5 host/user '
          '(gh-1852: intra-matrix eviction; gh-1866: cross-workflow '
          'eviction; gh-1865: same-subject identity ambiguity). Signing '
          'legs route through ci-sign against the persistent host '
          'keychain instead.',
    );
  });
}
