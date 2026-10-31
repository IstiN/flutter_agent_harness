// gh-1852 / gh-1865 / gh-2013 — why the build-macos matrix is serialized
// (twice over, for two different reasons), and why it must never regain
// per-job keychains.
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
// gh-2013 (run 41172095157, 2026-10-31): the parallel matrix is retired
// AGAIN — for a reason that has nothing to do with keychains. The fa-m5
// pool is ONE host under ONE user account hosting the fa-m5 / fa-m5-2 /
// fa-m5-3 runner registrations (the retired gh-1852 comment block said it
// verbatim). With the matrix parallel, the daily run places THREE heavy
// Xcode/Flutter builds on that single Mac at once: both build-macos
// release legs (150m job ceilings) plus the TestFlight leg's Build iOS
// IPA gym (90m ceiling, dispatched concurrently by #359). Each build
// crawls ~10x its solo time — the green 10-27 baseline built Fa.app in
// 12m39s; run 41172095157 streamed its last compile line at +14m and then
// sat silent for 2h14m until the 150m ceiling killed BOTH arch legs, and
// the concurrent gym independently blew its own 90m ceiling. No repo
// change explains it: flutter_app/pubspec.yaml + flutter_app/macos/ are
// byte-identical between the last green tree and the first slow one.
//
//   AC1  build-macos matrix IS serialized: max-parallel: 1 — the two
//        release legs must never share the host with each other. The
//        daily-publish cli leg budget (#351) documents exactly this shape
//        ("arm64 + x86_64 SERIALIZE on the single self-hosted runner").
//        A future parallel restoration must first prove the host can fit
//        2× build-macos + build-mobile iOS inside every job ceiling.
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
  test('AC1 — build-macos matrix is serialized (max-parallel: 1, '
      'host-saturation, gh-2013)', () {
    final job = jobsOf(workflowPath)['build-macos'] as YamlMap;
    final strategy = job['strategy'] as YamlMap?;
    final maxParallel = strategy?['max-parallel'];
    expect(maxParallel, 1,
        reason:
            'build-macos matrix is not serialized (max-parallel: '
            '$maxParallel) — the two release legs run CONCURRENTLY on the '
            'fa-m5 pool, which is ONE host under ONE user account '
            '(fa-m5 / fa-m5-2 / fa-m5-3 registrations). Together with the '
            'concurrent TestFlight iOS gym that is three ceiling-bounded '
            'Xcode/Flutter builds on one Mac: each build crawls ~10x its '
            'solo time (green 10-27 baseline: Fa.app built in 12m39s; run '
            '41172095157: 2h14m of build silence, both legs killed by the '
            '150m ceiling, gh-2013). Serialize the matrix, or first prove '
            'the host fits 2× build-macos + build-mobile iOS inside every '
            'job ceiling.');
  });

  test('AC2 — audit: no multi-leg matrix job mutates keychain state '
      '(gh-1852 class)', () {
    final offenders = <String>[];
    for (final wf in Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))) {
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
    expect(offenders, isEmpty,
        reason:
            'a multi-leg matrix job still performs keychain lifecycle or '
            'user-global keychain writes: $offenders. Matrix fan-outs '
            'amplify every keychain race on the shared fa-m5 host/user '
            '(gh-1852: intra-matrix eviction; gh-1866: cross-workflow '
            'eviction; gh-1865: same-subject identity ambiguity). Signing '
            'legs route through ci-sign against the persistent host '
            'keychain instead.');
  });
}
