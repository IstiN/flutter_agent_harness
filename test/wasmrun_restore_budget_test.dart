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
// gh-1759 (2026-10-21): the gh-1149 budget met a slow-link day. The same
// link that did ~300KB/s on 10-20 delivered 40–108KB/s on 10-21 (both
// arch jobs, cold cache — the wasmrun-xcframework-v0.1.0 entry saved on
// 10-20 was LRU-evicted by the repo's daily cache churn within ~37h).
// Resume itself worked (`** Resuming transfer from byte position …` in
// the logs; the shrinking `out of N` totals match the prior attempts'
// byte counts), but 3 × 240s of wire time banked only 29.5MB (x86_64) /
// 73% (arm64) of the 97,238,501-byte asset — and the pre-loop
// `rm -f "$ZIP"` threw each run's partial away, so no slow-link day
// ever made durable progress and the leg could not self-heal.
//
// These tests pin the invariants the step's comments promise, updated
// for the gh-1759 design:
// - the download retry budget fits the (now 20-min) step cap with
//   correct arithmetic (attempts = loop items; curl's own --retry would
//   MULTIPLY into it and restart+truncate rather than resume — retries
//   live in the bash loop, and each attempt RESUMES the partial zip via
//   -C - so slow links make forward progress);
// - the partial zip is PER-ARCH (one self-hosted runner, two matrix
//   archs — the shared arch-less /tmp path races) and now PERSISTS
//   across runs: no wipe before the loop, a pre-loop digest gate skips
//   the download when the persisted zip is already complete, an
//   incomplete download KEEPS the partial (the next daily run resumes
//   it), and only a wrong-content download is purged (self-heal);
// - --fail (HTTP errors must engage the loop, not land an error page
//   in the zip), the load-bearing `break` on success, and the pinned
//   sha256 + byte size of the asset (unzip CRC32 proves internal
//   consistency only). Static lint over the workflow YAML, same style
//   as release_hygiene_test.dart / dispatch_watch_test.dart.
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
  group('build-macos.yml WasmRun restore step budget (gh-1149, gh-1759)', () {
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
      expect(
        loop.body,
        contains('break'),
        reason:
            'a successful attempt must exit the loop — without break, the next '
            '-C - attempt hits HTTP 416 on the already-complete file, curl '
            'exits 33, and the loop reads success as failure (gh-1149 review)',
      );

      // Worst case: every loop attempt burns its full --max-time, plus the
      // inter-attempt sleeps. gh-1759 raised this from gh-1149's
      // 3 × 240s + 2 × 5s = 730s to 4 × 240s + 3 × 5s = 975s — at the
      // 10-21-measured ~95KB/s the old budget banked only ~71% of the
      // 97,238,501-byte asset, the new one ~93% with cross-run resume
      // covering the tail.
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
            '(GitHub release assets serve Range requests — proven by the '
            'gh-1759 logs: `** Resuming transfer from byte position '
            '45468197`). Without -C - every --max-time-capped attempt '
            'restarts from byte 0: at the observed 40–108KB/s no 240s '
            'attempt can deliver the 92.7MB asset — the download could '
            'never succeed regardless of the retry count (gh-1149, '
            're-confirmed by gh-1759)',
      );
    });

    test('the partial zip is PER-ARCH and PERSISTS across runs '
        '(deterministic -C - seed, no cross-arch race, gh-1759)', () {
      final run = restoreStep()['run'] as String;
      final loopStart = run.indexOf(
        RegExp(r'^\s*for\s+\w+\s+in\s+', multiLine: true),
      );
      expect(loopStart, greaterThan(0));
      final beforeLoop = run.substring(0, loopStart);
      expect(
        beforeLoop,
        contains(r'ZIP="/tmp/WasmRun.xcframework-${{ matrix.arch }}.zip"'),
        reason:
            'the partial zip must be PER-ARCH: both matrix archs run on ONE '
            'self-hosted runner and have raced shared runner state before '
            '(the shared build.keychain — see the per-arch keychain comment '
            'in this file). A shared arch-less /tmp zip lets one job\'s '
            'cleanup unlink the other\'s in-flight partial, then both curls '
            'interleave bytes into one path (gh-1149 review)',
      );
      expect(
        beforeLoop,
        isNot(contains(r'rm -f "$ZIP"')),
        reason:
            'the partial must NOT be wiped before the loop (gh-1759): the '
            'pre-gh-1759 `rm -f` threw away every finished-but-failed run\'s '
            'bytes, so a slow-link day restarted from byte 0 every daily run '
            'and the leg could never self-heal. -C - is exactly what makes a '
            'persisted partial safe to resume; the pinned sha256 gate below '
            'keeps a stale or wrong-content zip from ever being unzipped',
      );
      expect(
        beforeLoop,
        contains(r'echo "$ASSET_DIGEST  $ZIP" | shasum -a 256 -c -'),
        reason:
            'before the loop the step must digest-check an existing zip: a '
            'complete, digest-valid persisted zip skips the download (the '
            'cache entry gets LRU-evicted — saved 10-20 06:02Z, gone by '
            '10-21 19:03Z) AND avoids the HTTP-416 trap of a -C - attempt '
            'against an already-complete file (gh-1759)',
      );
      expect(
        run.contains('/tmp/WasmRun.xcframework.zip'),
        isFalse,
        reason:
            'the arch-less /tmp/WasmRun.xcframework.zip path must not come '
            'back anywhere in the step — it is the shared-race path '
            '(gh-1149 review)',
      );
    });

    test('curl fails on HTTP errors (--fail) so the retry loop owns them', () {
      final loop = DownloadLoop.parse(restoreStep()['run'] as String);
      expect(
        loop.curl,
        contains('--fail'),
        reason:
            'without --fail curl exits 0 on HTTP 404/5xx and writes the error '
            'page into the zip: the loop then never retries, and unzip fails '
            'with a misleading "not a zip" error instead of the loop\'s '
            'explicit "download failed after N attempts" (gh-1149 review)',
      );
    });

    test('the downloaded zip is verified against a pinned sha256 + byte '
        'size, incomplete downloads keep the partial, wrong content is '
        'purged (gh-1759)', () {
      final run = restoreStep()['run'] as String;
      // Real digest + size of the pinned asset (wasm_run-v0.1.0 tag,
      // 97238501 bytes), from the release download.
      const digest =
          'aca903d732202bcdf9c8d19fbb8a795c3c930762419f852a5ee228468c548a98';
      const size = 97238501;
      expect(
        run,
        contains('ASSET_DIGEST="$digest"'),
        reason:
            'unzip CRC32 only proves the zip is INTERNALLY consistent — a '
            'wrong-content-but-valid-zip (asset re-uploaded under the same '
            'tag, intercepted payload) would pass unzip and be cached forever '
            'under wasmrun-xcframework-v0.1.0. Pin the digest like the '
            'litertlm download in this same file does (gh-1149 review)',
      );
      expect(
        run,
        contains('ASSET_BYTES=$size'),
        reason:
            'the pinned byte size is what tells a TRUNCATED download (keep '
            'the partial — the next daily run resumes it, the whole point of '
            'gh-1759) apart from a complete-but-wrong one (purge it — a '
            'wrong-content zip must never unzip into the permanent cache)',
      );
      final doneIndex = run.lastIndexOf(RegExp(r'^\s*done$', multiLine: true));
      final checkIndex = run.lastIndexOf('shasum -a 256 -c -');
      final unzipIndex = run.indexOf(r'unzip -q "$ZIP"');
      expect(doneIndex, greaterThan(0));
      expect(checkIndex, greaterThan(doneIndex));
      expect(unzipIndex, greaterThan(checkIndex));

      final keepIndex = run.indexOf('keeping the partial');
      expect(
        keepIndex,
        greaterThan(doneIndex),
        reason:
            'an INCOMPLETE download (size < ASSET_BYTES) must keep the '
            'partial and exit non-zero — the next run resumes from its byte '
            'offset. Purging here would re-create the gh-1759 treadmill '
            '(every slow-link daily run restarting from byte 0)',
      );
      final purgeIndex = run.indexOf(r'rm -f "$ZIP"');
      expect(
        purgeIndex,
        greaterThan(doneIndex),
        reason:
            'the ONLY allowed rm -f of the partial is the self-heal purge '
            'AFTER the loop: a zip that is complete-but-wrong (digest or '
            'size mismatch on full bytes) would otherwise fail the same way '
            'on every future run — purge it so the next run restarts clean',
      );
      // The incomplete branch must NOT purge: keep and exit 1.
      final incompleteBranch = run.substring(
        keepIndex,
        run.indexOf('exit 1', keepIndex),
      );
      expect(
        incompleteBranch.contains('rm -f'),
        isFalse,
        reason:
            'the incomplete-download branch exits 1 while KEEPING the '
            'partial — it must not delete the bytes the next run resumes',
      );
    });
  });
}
