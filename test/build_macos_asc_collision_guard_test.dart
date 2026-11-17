// gh-2246 — ASC collision guard for the macOS desktop app legs
// (build-macos.yml). Live failure chain on v1.0.740 (2026-11-17):
//
//   run 44048482993 attempt 1 (BUILD_NUMBER=github.run_number=194):
//     gh-180 min-platform flake — known, unrelated.
//   rerun of the same run: altool -19232 "bundle version must be higher
//     than the previously uploaded version '194'" — a rerun REUSES
//     github.run_number, so the same CFBundleVersion is re-uploaded.
//   fresh dispatch 44077946369 (BUILD_NUMBER=195): the arm64 TestFlight
//     submit died at post_beta_app_review_submissions with "Another build
//     is in review. Another build in the same train" — ASC-side external
//     state. Because the artifact uploads were ordered AFTER the submit,
//     the already-built DMG/ZIP never became workflow artifacts, and the
//     aggregate release attach (needs: build-macos) never ran: v1.0.740
//     shipped with NO fa-macos-*-mac.zip / .dmg / latest-mac.yml at all.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of build_macos_spm_lane_guard_test.dart):
//
//   AC1  BUILD_NUMBER is unique per ARCH and per ATTEMPT: the expression
//        must derive from github.run_number AND github.run_attempt AND
//        distinguish matrix.arch — a bare `${{ github.run_number }}` is
//        the collision (both matrix legs share it; reruns reuse it).
//   AC2  In the build-macos job, the artifact banking steps (Upload
//        TestFlight PKG artifact, Upload macOS artifacts) run BEFORE the
//        Submit PKG to TestFlight step — an ASC-side wall (review race,
//        altool validation) must never forfeit already-built binaries.
//   AC3  The Submit PKG to TestFlight step carries continue-on-error: true
//        and an id — distribution is external ASC state; the leg must
//        stay green so the aggregate attach runs with banked artifacts.
//   AC4  A follow-up step reports the submit outcome loudly
//        (steps.<id>.outcome == 'failure' → ::warning annotation) so the
//        skip is visible in the run UI and the daily watchers.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const jobName = 'build-macos';
const submitStepName = 'Submit PKG to TestFlight';
const pkgArtifactStepName = 'Upload TestFlight PKG artifact';
const macArtifactStepName = 'Upload macOS artifacts';

String read(String path) => File(path).readAsStringSync();

MapEntry<String, Map<dynamic, dynamic>> stepOf(
  List<dynamic> steps,
  String name,
) {
  final matches = steps
      .whereType<Map>()
      .where((s) => (s['name'] ?? '') == name)
      .map((s) => Map.castFrom<dynamic, dynamic, dynamic, dynamic>(s))
      .toList();
  if (matches.length != 1) {
    throw StateError(
      'expected exactly one "$name" step, found ${matches.length}',
    );
  }
  return MapEntry(name, matches.first);
}

int stepIndex(List<dynamic> steps, String name) {
  final idx = steps.indexWhere((s) => s is Map && (s['name'] ?? '') == name);
  if (idx < 0) {
    throw StateError('step "$name" not found');
  }
  return idx;
}

void main() {
  final doc = loadYaml(read(workflowPath)) as Map;
  final job = (doc['jobs'] as Map)[jobName];
  final steps = (job as Map)['steps'] as List;

  test(
    'AC1: BUILD_NUMBER is per-arch + per-attempt, never bare run_number',
    () {
      final buildStep = stepOf(
        steps,
        'Build macOS release (\${{ matrix.arch }})',
      );
      final env = (buildStep.value)['env'] as Map;
      final buildNumber = env['BUILD_NUMBER'];
      expect(
        buildNumber,
        isA<String>(),
        reason: 'BUILD_NUMBER must stay an env var',
      );
      final expr = buildNumber as String;
      expect(
        expr,
        contains('github.run_number'),
        reason: 'monotonic growth across dispatches',
      );
      expect(
        expr,
        contains('github.run_attempt'),
        reason:
            'gh-2246: reruns reuse run_number — the attempt term is what '
            'makes re-uploads legal (altool -19232 fix)',
      );
      expect(
        expr,
        contains('matrix.arch'),
        reason: 'gh-2246: sibling arch legs must not race one ASC build',
      );
      expect(
        expr,
        isNot(equals(r'${{ github.run_number }}')),
        reason: 'the bare form IS the collision',
      );
    },
  );

  test('AC2: artifact banking precedes the TestFlight submit', () {
    final submitIdx = stepIndex(steps, submitStepName);
    expect(
      stepIndex(steps, pkgArtifactStepName),
      lessThan(submitIdx),
      reason: 'the PKG artifact must be banked before the ASC wall can hit',
    );
    expect(
      stepIndex(steps, macArtifactStepName),
      lessThan(submitIdx),
      reason: 'DMG/ZIP/manifest must be banked before the ASC wall can hit',
    );
  });

  test('AC3: the submit step is non-fatal and addressable', () {
    final submitStep = stepOf(steps, submitStepName);
    expect(
      (submitStep.value)['continue-on-error'],
      isTrue,
      reason:
          'distribution is external ASC state; artifacts are already '
          'banked (AC2) and the aggregate attach needs this leg green',
    );
    expect(
      (submitStep.value)['id'],
      isA<String>(),
      reason: 'the outcome-report step (AC4) addresses this step by id',
    );
  });

  test('AC4: a follow-up step reports a failed submit loudly', () {
    final submitStep = stepOf(steps, submitStepName);
    final id = (submitStep.value)['id'] as String;
    final reportIdx = steps.indexWhere(
      (s) =>
          s is Map && (s['name'] ?? '').contains('TestFlight submit outcome'),
    );
    expect(
      reportIdx,
      greaterThan(stepIndex(steps, submitStepName)),
      reason: 'the outcome report must follow the submit',
    );
    final report = steps[reportIdx] as Map;
    final run = report['run'] as String? ?? '';
    expect(
      report['if'].toString(),
      contains('steps.$id.outcome'),
      reason: 'fires exactly on the non-fatal failure',
    );
    expect(
      run,
      contains('::warning'),
      reason: 'visible in the run UI, not a silent skip',
    );
  });
}
