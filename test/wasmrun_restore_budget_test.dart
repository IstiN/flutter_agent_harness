// gh-1149: the daily-publish `cli` leg failed twice over in the
// "Restore vendored WasmRun macOS framework" step of build-macos.yml.
// The self-hosted runner downloads the pinned 92.7 MB upstream asset at
// ~300 KB/s (ETA 5:09 in the failed run's log), but every curl attempt
// was capped at --max-time 240 with NO resume flag, so no attempt could
// ever finish — and `--retry 3` means 3 retries ON TOP OF the initial
// attempt (4 attempts), whose worst case (4×240s + 3×5s = 975s) overran
// the step's own `timeout-minutes: 15` (900s). GitHub killed the step
// mid-attempt and the leg can never go green on a cold cache.
//
// These tests pin the invariant the step's comment already promises:
// the curl retry budget must FIT the step cap with correct arithmetic
// (attempts = retries + 1), and retries must RESUME the partial zip so
// slow links make forward progress. Static lint over the workflow YAML,
// same style as release_hygiene_test.dart / dispatch_watch_test.dart.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const stepName = 'Restore vendored WasmRun macOS framework';

String read(String path) => File(path).readAsStringSync();

YamlMap restoreStep() {
  final workflow = loadYaml(read(workflowPath)) as YamlMap;
  final job = workflow['jobs']['build-macos'] as YamlMap;
  final steps = job['steps'] as YamlList;
  final hits = steps
      .whereType<YamlMap>()
      .where((s) => s['name'] == stepName)
      .toList(growable: false);
  expect(hits, hasLength(1), reason: '$workflowPath must keep exactly one '
      '"$stepName" step — the lint below guards that step');
  return hits.single;
}

/// The curl invocation, backslash continuations joined.
String curlCommand(String runText) {
  final lines = runText.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!RegExp(r'^\s*curl\s').hasMatch(lines[i])) continue;
    final cmd = <String>[lines[i]];
    var j = i;
    while (cmd.last.trimRight().endsWith(r'\') && j < lines.length - 1) {
      j++;
      cmd.add(lines[j]);
    }
    return cmd.map((l) => l.replaceAll(r'\', '').trim()).join(' ');
  }
  fail('no curl invocation found in the "$stepName" step');
}

int? intFlag(String curl, String flag) {
  final m = RegExp('$flag (\\d+)').firstMatch(curl);
  return m == null ? null : int.parse(m.group(1)!);
}

void main() {
  group('build-macos.yml WasmRun restore step budget (gh-1149)', () {
    test('curl retry budget fits inside the step timeout-minutes cap', () {
      final step = restoreStep();
      final timeoutMinutes = step['timeout-minutes'] as int?;
      expect(timeoutMinutes, isNotNull,
          reason: 'the step must carry an explicit timeout — it is the cap '
              'the curl budget is sized against');

      final curl = curlCommand(step['run'] as String);
      final retries = intFlag(curl, r'--retry');
      final maxTime = intFlag(curl, r'--max-time');
      expect(retries, isNotNull, reason: 'curl must pin --retry explicitly');
      expect(maxTime, isNotNull, reason: 'curl must pin --max-time explicitly');

      // CORRECT arithmetic: --retry N = N retries on top of the initial
      // attempt, so attempts = N + 1. The old comment budgeted
      // "3 retries × 240s" and got 975s of worst case against a 900s cap.
      final attempts = retries! + 1;
      final retryDelay = intFlag(curl, r'--retry-delay') ?? 1; // curl default backoff floor
      final connectTimeout = intFlag(curl, r'--connect-timeout') ?? 30; // curl default 300s
      final worstCaseCurlSeconds =
          attempts * maxTime! + retries * retryDelay;
      // Reserve: one connect timeout + unzip of the 92.7 MB zip + slack.
      const reserveSeconds = 60;
      final budgetSeconds = timeoutMinutes! * 60;
      expect(
        worstCaseCurlSeconds + connectTimeout + reserveSeconds,
        lessThanOrEqualTo(budgetSeconds),
        reason: 'curl worst case $worstCaseCurlSeconds s ($attempts attempts '
            '× ${maxTime}s + $retries × ${retryDelay}s delays) + '
            '$connectTimeout s connect + $reserveSeconds s unzip reserve '
            'must fit the ${timeoutMinutes}m step cap ($budgetSeconds s) — '
            'gh-1149 timed out at 15m because 4 attempts × 240s + delays '
            'overran it',
      );
    });

    test('curl retries resume the partial download (-C -)', () {
      final curl = curlCommand(restoreStep()['run'] as String);
      final resumable = RegExp(r'(^|\s)-C\s+-($|\s)|--continue-at\s+-($|\s)')
          .hasMatch(curl);
      expect(resumable, isTrue, reason:
          'retries must RESUME the partial zip from its byte offset '
          '(GitHub release assets serve Range requests). Without -C - every '
          '--max-time-capped attempt restarts from byte 0: at the observed '
          '~300 KB/s the 92.7 MB asset needs ~309 s, which no 240 s attempt '
          'can deliver — the download could never succeed regardless of the '
          'retry count (gh-1149)');
    });

    test('the download starts from a fresh /tmp zip (deterministic -C - seed)',
        () {
      final run = restoreStep()['run'] as String;
      final curlIndex = run.indexOf(RegExp(r'^\s*curl\s', multiLine: true));
      expect(curlIndex, greaterThan(0));
      final beforeCurl = run.substring(0, curlIndex);
      expect(
        beforeCurl,
        contains('rm -f /tmp/WasmRun.xcframework.zip'),
        reason: 'a stale /tmp zip from a previous run must never seed -C - '
            'with an unknown byte offset — rm -f it before the download so '
            'only THIS step\'s own partial bytes are resumed',
      );
    });
  });
}
