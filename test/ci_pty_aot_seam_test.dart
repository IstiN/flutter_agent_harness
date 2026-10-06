// gh-1300 red-run root cause (CI run 37446280743, head 9351028): the
// fa-aot-build job compiles the AOT bundle once per run and the 3 PTY/CLI
// shards download it — but artifact round-trips do NOT preserve the exec
// bit (actions/download-artifact README: "post-download the file is no
// longer guaranteed to be set as an executable"). The shard smoke
// (`test -x fa-local/bundle/bin/fah`) therefore failed silently ~20 ms in
// on EVERY shard → quality-gate red → the SM required contexts
// ("Quality gate", "JS engine integration (quickjs-ng)", "Binaries smoke
// gate") went red with it.
//
// Structural lint over the workflow YAML (same style as
// ci_binaries_arch_gate_test.dart / dispatch_watch_test.dart): the
// artifact→shard handoff must restore the exec bit BEFORE the smoke step
// and the FA_BIN export, and the smoke must stay fail-loud (a missing or
// dead binary fails the shard; it never silently falls back to JIT).
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    (loadYaml(read(workflowPath)) as YamlMap)['jobs'] as YamlMap;

List<YamlMap> stepsOf(YamlMap job) =>
    (job['steps'] as YamlList).cast<YamlMap>();

String runOf(YamlMap step) => (step['run'] ?? '').toString();

/// The download-artifact step in [job] that fetches [artifactName], or null.
YamlMap? downloadStepOf(YamlMap job, String artifactName) => stepsOf(job)
    .where(
      (s) =>
          (s['uses'] ?? '').toString().startsWith('actions/download-artifact@'),
    )
    .firstWhereOrNull(
      (s) =>
          ((s['with'] as YamlMap?)?['name'] ?? '').toString() == artifactName,
    );

extension FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in where(test)) {
      return e;
    }
    return null;
  }
}

int indexOfName(List<YamlMap> steps, String name) =>
    steps.indexWhere((s) => (s['name'] ?? '').toString() == name);

const bundleBin = 'fa-local/bundle/bin/fah';

void main() {
  final ci = jobsOf('.github/workflows/ci.yml');

  group('gh-1300 — the fa-aot-bin artifact survives the shard handoff', () {
    final ptyJob = ci['pty-integration-linux'] as YamlMap;

    test('the PTY/CLI shard leg downloads the once-per-run AOT artifact', () {
      final download = downloadStepOf(ptyJob, 'fa-aot-bin');
      expect(
        download,
        isNotNull,
        reason:
            'shards must consume the fa-aot-build artifact (the '
            'FA_BIN seam is the whole gh-1300 win)',
      );
    });

    test('the shard restores the exec bit after the download', () {
      // Artifact zips drop the exec bit (download-artifact README) —
      // run 37446280743: `test -x` failed ~20 ms in on every shard and
      // red-blocked the whole gate before a single test ran. The restore
      // must exist between the download and the smoke, and it must target
      // the exact binary the FA_BIN seam points at.
      final steps = stepsOf(ptyJob);
      final download = downloadStepOf(ptyJob, 'fa-aot-bin')!;
      final downloadIdx = steps.indexOf(download);
      final chmodIdx = steps.indexWhere(
        (s) => runOf(s).contains('chmod +x $bundleBin'),
      );
      expect(
        chmodIdx,
        greaterThan(downloadIdx),
        reason:
            'chmod +x must come after download-artifact — the zip '
            'round-trip drops the exec bit (run 37446280743)',
      );
      expect(
        chmodIdx,
        lessThan(steps.length - 1),
        reason: 'the restore must precede the consumers below',
      );
    });

    test('the smoke still fails loud, after the restore, before FA_BIN', () {
      final steps = stepsOf(ptyJob);
      final smokeIdx = indexOfName(
        steps,
        'Smoke the AOT binary (fail loud, never JIT-fallback)',
      );
      final chmodIdx = steps.indexWhere(
        (s) => runOf(s).contains('chmod +x $bundleBin'),
      );
      final testStepIdx = steps.indexWhere(
        (s) => ((s['env'] as YamlMap?)?['FA_BIN'] ?? '') != '',
      );
      expect(smokeIdx, greaterThanOrEqualTo(0), reason: 'smoke step present');
      expect(
        smokeIdx,
        greaterThan(chmodIdx),
        reason: 'the smoke must test the restored binary, not the zip state',
      );
      expect(
        testStepIdx,
        greaterThan(smokeIdx),
        reason:
            'FA_BIN is only exported once the binary proved alive — '
            'no silent JIT fallback (gh-1300 AC1 guard)',
      );
      final smokeRun = runOf(steps[smokeIdx]);
      expect(smokeRun, contains('test -x $bundleBin'));
      expect(smokeRun, contains('$bundleBin --version'));
    });
  });

  group(
    'gh-1300 — nightly keeps its in-job build (no artifact round-trip)',
    () {
      test(
        'the nightly PTY leg builds the bundle in-job and boots it before use',
        () {
          final nightly = jobsOf('.github/workflows/nightly.yml');
          final job = nightly['pty-integration'] as YamlMap;
          final steps = stepsOf(job);
          final buildIdx = steps.indexWhere(
            (s) => runOf(s).contains('dart build cli --target=bin/fah.dart'),
          );
          expect(buildIdx, greaterThanOrEqualTo(0));
          expect(
            downloadStepOf(job, 'fa-aot-bin'),
            isNull,
            reason:
                'the nightly runs one unsharded job — it builds in-job, '
                'so no zip round-trip can drop the exec bit there',
          );
          final buildRun = runOf(steps[buildIdx]);
          expect(buildRun, contains('test -x $bundleBin'));
          expect(buildRun, contains('$bundleBin --version'));
        },
      );
    },
  );
}
