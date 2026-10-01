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
// the download retry budget must FIT the step cap with correct
// arithmetic (attempts = loop items; curl's own --retry would MULTIPLY
// into it and restart+truncate rather than resume — curl ≥7.x/8.x
// ignores -C - for its internal retries, so retries must live in the
// bash loop, and each attempt must RESUME the partial zip via -C - so
// slow links make forward progress). Static lint over the workflow YAML,
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
  expect(
    hits,
    hasLength(1),
    reason:
        '$workflowPath must keep exactly one '
        '"$stepName" step — the lint below guards that step',
  );
  return hits.single;
}

/// The download retry loop of the step: `for attempt in …` / `done` with
/// the curl invocation and inter-attempt sleep inside.
class DownloadLoop {
  DownloadLoop({
    required this.header,
    required this.body,
    required this.attempts,
    required this.curl,
    required this.sleepSeconds,
  });

  /// One curl invocation, backslash continuations joined.
  final String curl;
  final String header;
  final String body;
  final int attempts;
  final int sleepSeconds;

  static DownloadLoop parse(String runText) {
    final lines = runText.split('\n');
    final headerIndex = lines.indexWhere(
      (l) => RegExp(r'^\s*for\s+\w+\s+in\s+').hasMatch(l),
    );
    if (headerIndex < 0) {
      fail(
        'no `for attempt in …` download loop in the "$stepName" step — '
        'retries must live in an explicit bash loop whose budget the lint '
        'can check (gh-1149)',
      );
    }
    final doneIndex = lines.indexWhere((l) => l.trim() == 'done', headerIndex);
    expect(
      doneIndex,
      greaterThan(headerIndex),
      reason: 'unterminated for loop in the "$stepName" step',
    );
    final header = lines[headerIndex];
    final bodyLines = lines.sublist(headerIndex + 1, doneIndex);
    final items = RegExp(r'in\s+([^#]+)').firstMatch(header)!.group(1)!.trim();
    final attempts = items
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && int.tryParse(w) != null)
        .length;
    expect(
      attempts,
      greaterThanOrEqualTo(1),
      reason: 'download loop `for … in $items` yields no attempts',
    );

    final curlStart = bodyLines.indexWhere(
      (l) => RegExp(r'^\s*(if\s+)?curl\s').hasMatch(l),
    );
    if (curlStart < 0) fail('no curl invocation inside the download loop');
    final cmd = <String>[bodyLines[curlStart]];
    var j = curlStart;
    while (cmd.last.trimRight().endsWith(r'\') && j < bodyLines.length - 1) {
      j++;
      cmd.add(bodyLines[j]);
    }
    final curl = cmd.map((l) => l.replaceAll(r'\', '').trim()).join(' ');

    final sleep = bodyLines
        .map(RegExp(r'^\s*sleep\s+(\d+)').firstMatch)
        .whereType<RegExpMatch>()
        .map((m) => int.parse(m.group(1)!))
        .toList(growable: false);
    return DownloadLoop(
      header: header,
      body: bodyLines.join('\n'),
      attempts: attempts,
      curl: curl,
      sleepSeconds: sleep.isEmpty ? 0 : sleep.first,
    );
  }

  int? intFlag(String flag) {
    final m = RegExp('$flag (\\d+)').firstMatch(curl);
    return m == null ? null : int.parse(m.group(1)!);
  }
}

void main() {
  group('build-macos.yml WasmRun restore step budget (gh-1149)', () {
    test('download retry budget fits inside the step timeout-minutes cap', () {
      final step = restoreStep();
      final timeoutMinutes = step['timeout-minutes'] as int?;
      expect(
        timeoutMinutes,
        isNotNull,
        reason:
            'the step must carry an explicit timeout — it is the cap '
            'the download budget is sized against',
      );

      final loop = DownloadLoop.parse(step['run'] as String);
      final maxTime = loop.intFlag(r'--max-time');
      expect(
        maxTime,
        isNotNull,
        reason: 'curl must pin --max-time explicitly (per-attempt cap)',
      );
      expect(
        loop.intFlag(r'--retry'),
        isNull,
        reason:
            'curl --retry must NOT be combined with the bash loop: --retry N '
            'adds N MORE attempts (an off-by-one that produced gh-1149\'s 975s '
            'worst case) and its internal retries restart+truncate instead of '
            'resuming. The loop owns retries — exactly one retry layer.',
      );

      // Worst case: every loop attempt burns its full --max-time, plus the
      // inter-attempt sleeps. 3 × 240s + 2 × 5s = 730s, leaving ~170s of
      // the 900s cap for connect + unzip + slack.
      final worstCaseSeconds =
          loop.attempts * maxTime! + (loop.attempts - 1) * loop.sleepSeconds;
      const reserveSeconds = 60; // one connect timeout + unzip + slack
      final budgetSeconds = timeoutMinutes! * 60;
      expect(
        worstCaseSeconds + reserveSeconds,
        lessThanOrEqualTo(budgetSeconds),
        reason:
            'download worst case $worstCaseSeconds s (${loop.attempts} '
            'attempts × ${maxTime}s + sleeps) + $reserveSeconds s '
            'connect/unzip reserve must fit the ${timeoutMinutes}m step cap '
            '($budgetSeconds s) — gh-1149 timed out at 15m because '
            'curl --retry 3 × --max-time 240s = 4 attempts = 975s > 900s',
      );
    });

    test('each download attempt resumes the partial zip (-C -)', () {
      final loop = DownloadLoop.parse(restoreStep()['run'] as String);
      final resumable = RegExp(
        r'(^|\s)-C\s+-($|\s)|--continue-at\s+-($|\s)',
      ).hasMatch(loop.curl);
      expect(
        resumable,
        isTrue,
        reason:
            'each attempt must RESUME the partial zip from its byte offset '
            '(GitHub release assets serve Range requests). Without -C - every '
            '--max-time-capped attempt restarts from byte 0: at the observed '
            '~300 KB/s the 92.7 MB asset needs ~309 s, which no 240 s attempt '
            'can deliver — the download could never succeed regardless of the '
            'retry count (gh-1149)',
      );
    });

    test(
      'the download starts from a fresh /tmp zip (deterministic -C - seed)',
      () {
        final run = restoreStep()['run'] as String;
        final loopStart = run.indexOf(
          RegExp(r'^\s*for\s+\w+\s+in\s+', multiLine: true),
        );
        expect(loopStart, greaterThan(0));
        final beforeLoop = run.substring(0, loopStart);
        expect(
          beforeLoop,
          contains('rm -f /tmp/WasmRun.xcframework.zip'),
          reason:
              'a stale /tmp zip from a previous run must never seed -C - '
              'with an unknown byte offset — rm -f it before the loop so only '
              'THIS step\'s own partial bytes are resumed',
        );
      },
    );
  });
}
