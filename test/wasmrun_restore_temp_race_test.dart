// gh-2233 — the daily-publish `testflight` leg failed in
// "Build iOS IPA — Restore vendored WasmRun iOS framework" (leg run
// 44023345849): curl reported a COMPLETE 92.7 MB transfer (100%), yet
// unzip rejected the archive mid-file (invalid compressed data to inflate
// libwasm_run_dart.a, bad CRC 49791ab5 (should be 0b87d612), file #6/#7
// bad zipfile offsets at ~74 MB).
//
// Root cause: the four WasmRun restore steps that download the pinned
// upstream asset as a fallback (build-mobile.yml build-ios, ci.yml
// build-ios + build-macos, nightly.yml build-release Apple targets) all
// curl into the FIXED shared path /tmp/WasmRun.xcframework.zip. The
// macos-m5 pool is ONE physical box hosting multiple concurrent runner
// processes (fa-m5-1/2/3 — the gh-2134 comment in ci.yml; this exact
// shared-state class is why build-macos.yml's step went per-arch in the
// gh-1149 review and why bench-harbor moved its outputs to $RUNNER_TEMP —
// workflow_selfhosted_legs_test.dart AC2). Overlapping downloads open the
// same file with O_TRUNC and interleave two transfers into one path:
// every curl still exits 0 with its full byte count, but the file on disk
// is a patchwork of the two payloads — unzip then fails mid-archive
// exactly as the failing leg's log shows. The same steps also lacked
// --fail and the pinned size+sha256 gate the gh-1759 build-macos.yml step
// carries (unzip CRC32 proves internal consistency only — a truncated or
// wrong-content file must never unzip into the build tree as success).
//
// Static workflow-shape lint (the wasmrun_restore_budget_test.dart /
// workflow_selfhosted_legs_test.dart pattern). build-macos.yml's RELEASE
// step is intentionally out of scope — its per-arch persisted /tmp partial
// + digest gate is the deliberate gh-1759 design already guarded by
// wasmrun_restore_budget_test.dart.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const assetDigest =
    'aca903d732202bcdf9c8d19fbb8a795c3c930762419f852a5ee228468c548a98';
const assetBytes = 97238501;

/// The guarded (step name, workflow, job) tuples — every WasmRun restore
/// step that takes the upstream-download fallback and had NOT been
/// hardened by gh-1759.
const guardedSteps = <(String, String, String)>[
  (
    'Restore vendored WasmRun iOS framework',
    '.github/workflows/build-mobile.yml',
    'build-ios',
  ),
  (
    'Restore vendored WasmRun iOS framework',
    '.github/workflows/ci.yml',
    'build-ios',
  ),
  (
    'Restore vendored WasmRun macOS framework',
    '.github/workflows/ci.yml',
    'build-macos',
  ),
  (
    'Restore vendored WasmRun framework (Apple targets)',
    '.github/workflows/nightly.yml',
    'build-release',
  ),
];

String read(String path) => File(path).readAsStringSync();

/// The `run` script of the named step in the named job, and a one-line
/// description for assertion messages.
(String, String) stepRun(String workflowPath, String job, String stepName) {
  final workflow = loadYaml(read(workflowPath)) as YamlMap;
  final jobs = workflow['jobs'] as YamlMap;
  expect(
    jobs.containsKey(job),
    isTrue,
    reason:
        '$workflowPath lost its $job job — the lint below guards its '
        '"$stepName" step',
  );
  final steps = (jobs[job] as YamlMap)['steps'] as YamlList;
  final hits = steps
      .whereType<YamlMap>()
      .where((s) => s['name'] == stepName)
      .toList(growable: false);
  expect(
    hits,
    hasLength(1),
    reason:
        '$workflowPath:$job must keep exactly one "$stepName" step — '
        'the lint below guards that step',
  );
  final label = '$workflowPath:$job "$stepName"';
  return (hits.single['run'] as String, label);
}

/// The single curl invocation of the step, backslash continuations joined.
String curlOf(String run, String label) {
  final lines = run.split('\n');
  final starts = lines.indexWhere(
    (l) => RegExp(r'^\s*(if\s+)?curl\s').hasMatch(l),
  );
  expect(
    starts,
    greaterThanOrEqualTo(0),
    reason: '$label has no curl invocation',
  );
  final cmd = <String>[lines[starts]];
  var j = starts;
  while (cmd.last.trimRight().endsWith(r'\') && j < lines.length - 1) {
    j++;
    cmd.add(lines[j]);
  }
  return cmd.map((l) => l.replaceAll(r'\', '').trim()).join(' ');
}

void main() {
  group('WasmRun restore steps: no shared /tmp zip race (gh-2233)', () {
    for (final (stepName, workflowPath, job) in guardedSteps) {
      test(
        '$workflowPath:$job "$stepName" downloads to a job-private path',
        () {
          final (run, label) = stepRun(workflowPath, job, stepName);
          expect(
            run,
            contains(r'$RUNNER_TEMP/WasmRun.xcframework.zip'),
            reason:
                '$label must download to \$RUNNER_TEMP (job-private, emptied '
                'per job). The fixed /tmp/WasmRun.xcframework.zip path is '
                'shared by every WasmRun-downloading leg on the ONE fa-m5 box '
                'that hosts multiple concurrent runner processes (gh-2134) — '
                'two overlapping downloads O_TRUNC and interleave two '
                'transfers into one file; run 44023345849 unzipped exactly '
                'such a patchwork (bad CRC at file #6) though curl itself '
                'reported 100% (gh-2233)',
          );
          expect(
            run.contains('/tmp/WasmRun.xcframework.zip'),
            isFalse,
            reason:
                '$label must not touch the arch-less shared '
                '/tmp/WasmRun.xcframework.zip path anywhere — it is the '
                'shared-race path (gh-2233; same posture as the per-arch '
                'gh-1759 build-macos.yml zip path)',
          );
        },
      );

      test('$workflowPath:$job "$stepName" curls with --fail', () {
        final (run, label) = stepRun(workflowPath, job, stepName);
        expect(
          curlOf(run, label),
          contains('--fail'),
          reason:
              '$label: without --fail curl exits 0 on HTTP 404/5xx and '
              'writes the error page into the zip — unzip then fails with a '
              'misleading "not a zip" error instead of an explicit download '
              'failure (gh-1149 review, gh-1759)',
        );
      });

      test('$workflowPath:$job "$stepName" pins size+sha256 before unzip', () {
        final (run, label) = stepRun(workflowPath, job, stepName);
        expect(
          run,
          contains('ASSET_BYTES=$assetBytes'),
          reason:
              '$label must pin the asset byte size ($assetBytes — the '
              'immutable wasm_run-v0.1.0 asset build-macos.yml already '
              'pins): a truncated download would otherwise unzip as success '
              '(gh-2233)',
        );
        expect(
          run,
          contains('ASSET_DIGEST="$assetDigest"'),
          reason:
              '$label must pin the asset sha256 (unzip CRC32 proves '
              'internal consistency only — a wrong-content-but-valid zip '
              'would pass unzip; gh-1759 posture, gh-2233)',
        );
        expect(
          run.contains('shasum -a 256 -c -'),
          isTrue,
          reason:
              '$label must digest-check the downloaded zip before '
              'unzipping it',
        );
        final digestIndex = run.indexOf('shasum -a 256 -c -');
        final unzipIndex = run.indexOf(RegExp(r'unzip\s+-q'));
        expect(
          unzipIndex,
          greaterThan(digestIndex),
          reason:
              '$label must unzip ONLY after the size+sha256 gate — '
              'never unzipping unverified bytes',
        );
      });
      test(
        '$workflowPath:$job "$stepName" splits its integrity-gate errors '
        'by failure mode (gh-2233 review NIT)',
        () {
          final (run, label) = stepRun(workflowPath, job, stepName);
          expect(
            run.contains('bytes (expected \$ASSET_BYTES)'),
            isTrue,
            reason:
                '$label must print a SIZE-MISMATCH message naming the '
                'actual vs expected byte counts ("is N bytes (expected M '
                'bytes)") — the conflated single message "failed its '
                'integrity gate (N / M bytes or sha256 mismatch)" forces '
                'the reader to notice two EQUAL numbers to infer a sha256 '
                'mismatch (gh-2233 review NIT)',
          );
          expect(
            run.contains('failed its pinned sha256'),
            isTrue,
            reason:
                '$label must print a DISTINCT digest-mismatch message — a '
                'future red leg that passes the size check but fails the '
                'sha256 gate must be diagnosable from the error line alone '
                '(gh-2233 review NIT)',
          );
          expect(
            run.contains('bytes or sha256 mismatch'),
            isFalse,
            reason:
                '$label must not keep the conflated "bytes or sha256 '
                'mismatch" message that makes the reader compare two '
                'printed numbers to tell the failure modes apart '
                '(gh-2233 review NIT)',
          );
          final sizeIndex = run.indexOf('bytes (expected \$ASSET_BYTES)');
          final digestIndex = run.indexOf('failed its pinned sha256');
          expect(
            sizeIndex,
            lessThan(digestIndex),
            reason:
                '$label must check the cheap byte-size mode before the '
                'digest mode in its gate (gh-2233 review NIT shape)',
          );
        },
      );
    }
  });
}
