// gh-2314 — the release-gate `Build iOS (debug, unsigned)` leg red'd twice
// in a row (runs 4435156578 and its watchdog retrigger 44360029870, tag
// v1.0.748) on the SAME step: "Restore vendored WasmRun iOS framework".
// The step single-shot-curls the pinned 92.7 MB upstream asset
// (curl --retry 3 --max-time 600) under a 15-min step cap inside a 30-min
// job — on the [self-hosted, macos-m5] box, whose link to github release
// assets delivered 21.8 KB/s (killed at 6%) and then 16.3 KB/s (killed at
// 5%) across the two reds. At that rate the asset needs 74–101 min of
// wire time; the step can never converge. The SAME box fetched the SAME
// asset at 6.4 MB/s fourteen hours earlier (testflight run 44243620979),
// i.e. a contention-window class — and the release path's iOS leg
// (build-mobile.yml, gh-1149 → gh-1759 → gh-2197/gh-2233) already carries
// the designed remedy: cache → local copy → resume-capable digest-gated
// loop under a 60-min step cap in a 90-min job. That hardening never
// reached the ci.yml step (its stale comment even claims "GitHub-hosted
// PR legs always take the pinned upstream fallback" — the job has ridden
// [self-hosted, macos-m5] since gh-1005), so the release gate stays red
// through every slow-link window and the gh-2290 watchdog correctly
// refuses to retrigger it (a step `failure` is a real failure, not a
// timeout-kill).
//
// Static workflow-shape lint (the wasmrun_restore_budget_test.dart /
// ci_cube_kernel_ceiling_guard_test.dart pattern). Pins the back-port:
//  AC1  an actions/cache step for the immutable framework precedes the
//       restore step (a hit skips the wire entirely, mid-window too);
//  AC2  the restore step carries an explicit step ceiling and the loop's
//       worst case fits it with correct arithmetic (gh-1149);
//  AC3  the loop's total transfer budget covers the asset at the WORST
//       measured sustained throttle (16 KB/s — the 44360029870 window):
//       attempts × max-time × floor ≥ 97,238,501 bytes;
//  AC4  exactly one retry layer: the bash loop owns retries, curl's
//       --retry must NOT multiply into it, each attempt RESUMES the
//       partial (-C -), --fail gates HTTP errors into the loop, and a
//       successful attempt breaks out (gh-1149's HTTP-416 lesson);
//  AC5  the job ceiling exceeds the step ceiling with the healthy
//       pub-get/pods/build tail covered (gh-2070 doctrine: the ceiling
//       must not kill a converged-but-slow window);
//  AC6  the self-hosted local-copy preference (LOCAL_SRC) is checked
//       before the download branch — parity with build-mobile.yml's
//       step on the same box family.
// Out of scope here (already guarded): the $RUNNER_TEMP zip path, the
// --fail flag, the size+sha256-before-unzip order and the split failure
// messages (test/wasmrun_restore_temp_race_test.dart), the DerivedData
// wipe (test/ci_build_ios_derivedata_wipe_guard_test.dart), the prewarm
// wiring (test/ci_sqlite3_prewarm_guard_test.dart), and the macos-m5
// pool pin (test/workflow_selfhosted_legs_test.dart).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/ci.yml';
const jobId = 'build-ios';
const restoreStepName = 'Restore vendored WasmRun iOS framework';
const cacheStepName = 'Cache vendored WasmRun iOS framework';

const assetDigest =
    'aca903d732202bcdf9c8d19fbb8a795c3c930762419f852a5ee228468c548a98';
const assetBytes = 97238501;

/// The worst sustained throttle measured on the fa-m5 box for this asset:
/// run 44360029870's window held 15.9–16.5 KB/s across its full 5-minute
/// progress-line span (run 4435156578 measured 21.3–21.8 KB/s earlier the
/// same day). The loop budget must converge even at this floor.
const observedFloorBytesPerSecond = 16000;

/// connect + unzip + bookkeeping reserve, same convention as
/// wasmrun_restore_budget_test.dart's worst-case arithmetic.
const reserveSeconds = 60;

/// Healthy pub-get/pods/prewarm/build tail the job must still fit after a
/// fully-banked download (observed healthy job walls: 15m58s–16m17s).
const jobTailReserveMinutes = 20;

String read(String path) => File(path).readAsStringSync();

YamlMap job() =>
    ((loadYaml(read(workflowPath)) as YamlMap)['jobs'] as YamlMap)[jobId]
        as YamlMap;

List<YamlMap> steps() =>
    (job()['steps'] as YamlList).whereType<YamlMap>().toList();

YamlMap stepByName(String name) {
  final hits = steps().where((s) => s['name'] == name).toList(growable: false);
  expect(
    hits,
    hasLength(1),
    reason: '$workflowPath:$jobId must keep exactly one "$name" step',
  );
  return hits.single;
}

/// The download loop of the restore step, parsed well enough to do
/// budget arithmetic: `for attempt in …` header, its curl invocation
/// (backslash continuations joined), its inter-attempt sleep.
class DownloadLoop {
  DownloadLoop({
    required this.header,
    required this.curl,
    required this.attempts,
    required this.sleepSeconds,
  });

  final String header;
  final String curl;
  final int attempts;
  final int sleepSeconds;

  static DownloadLoop parse(String runText, String label) {
    final lines = runText.split('\n');
    final headerIndex = lines.indexWhere(
      (l) => RegExp(r'^\s*for\s+\w+\s+in\s+').hasMatch(l),
    );
    if (headerIndex < 0) {
      fail(
        'no `for attempt in …` download loop in "$label" — retries must '
        'live in an explicit bash loop whose budget the lint can check '
        '(gh-1149); gh-2314 red\'d twice on a single-shot curl that '
        'cannot survive a slow-link window',
      );
    }
    final doneIndex = lines.indexWhere((l) => l.trim() == 'done', headerIndex);
    expect(
      doneIndex,
      greaterThan(headerIndex),
      reason: 'unterminated for loop in "$label"',
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
      curl: curl,
      attempts: attempts,
      sleepSeconds: sleep.isEmpty ? 0 : sleep.first,
    );
  }

  int? intFlag(String flag) {
    final m = RegExp('$flag (\\d+)').firstMatch(curl);
    return m == null ? null : int.parse(m.group(1)!);
  }
}

void main() {
  group('gh-2314 — build-ios WasmRun restore survives a slow-link window', () {
    test('AC1: the immutable framework is actions/cache-backed first', () {
      final stepsList = steps();
      final cacheIndex = stepsList.indexWhere(
        (s) => s['name'] == cacheStepName,
      );
      final restoreIndex = stepsList.indexWhere(
        (s) => s['name'] == restoreStepName,
      );
      expect(
        cacheIndex,
        greaterThanOrEqualTo(0),
        reason:
            '$workflowPath:$jobId lost its "$cacheStepName" step — the '
            'asset is immutable (pinned digest), so a cache hit skips the '
            '97 MB wire transfer entirely, mid-window included '
            '(build-macos.yml release-leg precedent; the same job already '
            'caches CocoaPods the same way)',
      );
      expect(
        restoreIndex,
        greaterThan(cacheIndex),
        reason: 'the cache restore must precede the download fallback',
      );
      final cache = stepsList[cacheIndex];
      expect(
        (cache['uses'] as String).startsWith('actions/cache@'),
        isTrue,
        reason: 'the cache step must use the pinned actions/cache',
      );
      final with_ = cache['with'] as YamlMap;
      expect(
        with_['path'],
        'vendor/wasm_run_flutter/ios/Frameworks/WasmRun.xcframework',
        reason: 'the cache must cover exactly the framework directory',
      );
      expect(
        with_['key'],
        contains('wasmrun-xcframework-ios'),
        reason:
            'an iOS-specific key — the repo-global cache namespace already '
            'carries build-macos.yml\'s wasmrun-xcframework-v0.1.0 entry '
            'for a DIFFERENT path, and same-key-different-path saves '
            'conflict',
      );
    });

    test('AC2+AC3: the loop budget fits the step cap AND converges at the '
        '16 KB/s measured floor', () {
      final step = stepByName(restoreStepName);
      final timeoutMinutes = step['timeout-minutes'];
      expect(
        timeoutMinutes,
        isA<int>(),
        reason:
            'the step must carry an explicit timeout — it is the cap the '
            'download budget is sized against',
      );

      final loop = DownloadLoop.parse(
        step['run'] as String,
        '$workflowPath:$jobId "$restoreStepName"',
      );
      final maxTime = loop.intFlag(r'--max-time');
      expect(
        maxTime,
        isNotNull,
        reason: 'curl must pin --max-time explicitly (per-attempt cap)',
      );

      // gh-1149 arithmetic: every attempt may burn its full --max-time,
      // plus the inter-attempt sleeps, plus a connect/unzip reserve.
      final worstCaseSeconds =
          loop.attempts * maxTime! + (loop.attempts - 1) * loop.sleepSeconds;
      final budgetSeconds = (timeoutMinutes as int) * 60;
      expect(
        worstCaseSeconds + reserveSeconds,
        lessThanOrEqualTo(budgetSeconds),
        reason:
            'download worst case $worstCaseSeconds s (${loop.attempts} '
            'attempts × ${maxTime}s + sleeps) + $reserveSeconds s reserve '
            'must fit the ${timeoutMinutes}m step cap ($budgetSeconds s) — '
            'gh-2314 red\'d twice because 600s of single-shot wire time '
            'sat under a 900s step cap while the asset needed '
            '74–101 min at the measured 16–22 KB/s',
      );

      // The gh-2197 budget (10 × 300s = 3000s) still under-covers its own
      // measured 22 KB/s floor (66 MB < 92.7 MB); size THIS loop to the
      // observed floor so one job can converge even at 16 KB/s.
      final floorBytes = loop.attempts * maxTime * observedFloorBytesPerSecond;
      expect(
        floorBytes,
        greaterThanOrEqualTo(assetBytes),
        reason:
            '${loop.attempts} attempts × ${maxTime}s covers only '
            '${floorBytes ~/ 1024 ~/ 1024} MB at the measured '
            '$observedFloorBytesPerSecond B/s floor — the '
            '$assetBytes-byte asset must be bankable inside ONE job '
            '(the retrigger run red\'d on the same step because the '
            'single-shot budget could never converge)',
      );
      expect(
        loop.curl,
        contains('-C -'),
        reason:
            'each attempt must RESUME the partial zip from its byte '
            'offset (Range requests) — without -C - a throttled attempt '
            'restarts from zero and the budget can never converge '
            '(gh-1759: `Resuming transfer from byte position …` is what '
            'made slow links make forward progress)',
      );
    });

    test('AC4: exactly one retry layer, --fail gated, break on success', () {
      final loop = DownloadLoop.parse(
        stepByName(restoreStepName)['run'] as String,
        '$workflowPath:$jobId "$restoreStepName"',
      );
      expect(
        loop.intFlag(r'--retry'),
        isNull,
        reason:
            'curl --retry must NOT be combined with the bash loop: --retry N '
            'adds N MORE attempts (gh-1149\'s 975s off-by-one) and its '
            'internal retries restart+truncate instead of resuming. The '
            'loop owns retries — exactly one retry layer.',
      );
      expect(
        loop.curl,
        contains('--fail'),
        reason:
            'without --fail curl exits 0 on HTTP 404/5xx and OVERWRITES the '
            'accumulated partial with the error page — destroying exactly '
            'the progress the loop exists to keep (gh-1759)',
      );
      expect(
        loop.curl,
        contains('--connect-timeout'),
        reason: 'a dead endpoint must fail fast into the next attempt',
      );
      expect(
        loop.header.contains('...') || loop.attempts >= 2,
        isTrue,
        reason: 'the loop must actually carry more than one attempt',
      );
      final runText = stepByName(restoreStepName)['run'] as String;
      expect(
        runText,
        contains('break'),
        reason:
            'a successful attempt must exit the loop — the next -C - '
            'attempt against a complete file gets HTTP 416 and reads '
            'success as failure (gh-1149 review)',
      );
    });

    test('AC5: the job ceiling clears the step ceiling plus a healthy tail',
        () {
      final jobTimeout = job()['timeout-minutes'];
      expect(jobTimeout, isA<int>(), reason: 'the job must keep a ceiling');
      final stepTimeout = stepByName(restoreStepName)['timeout-minutes'];
      expect(
        stepTimeout,
        isA<int>(),
        reason: 'AC2 pins the step ceiling; the job ceiling is sized to it',
      );
      expect(
        jobTimeout as int,
        greaterThanOrEqualTo((stepTimeout as int) + jobTailReserveMinutes),
        reason:
            'a converged-but-slow download (up to the full step cap) plus '
            'the healthy pub-get/pods/build tail ($jobTailReserveMinutes '
            'min reserve; observed healthy walls ≈ 16 min) must still fit '
            'the job — the gh-2070 doctrine: a ceiling sized to the '
            'healthy wall turns one contention window into a release-kill',
      );
    });

    test('AC6: local-copy preference precedes the download branch '
        '(release-path parity)', () {
      final runText = stepByName(restoreStepName)['run'] as String;
      final localIndex = runText.indexOf('[ -d "\$LOCAL_SRC" ]');
      final loopIndex = runText.indexOf(RegExp(r'^\s*for\s+\w+\s+in\s+',
          multiLine: true));
      expect(
        localIndex,
        greaterThanOrEqualTo(0),
        reason:
            '$workflowPath:$jobId must prefer the self-hosted local copy '
            '(LOCAL_SRC) like build-mobile.yml\'s step does — parity on '
            'the same box family (the copy is usually absent on fa-m5 per '
            'gh-2197, but the preference is live surface on dev-box legs '
            'and keeps the two iOS legs structurally identical)',
      );
      expect(
        localIndex,
        lessThan(loopIndex),
        reason: 'the local copy must be consulted before any download',
      );
      expect(
        runText,
        contains('vendor/wasm_run_flutter/ios/Frameworks'),
        reason: 'the local copy and the download land in the vendored '
            'ios Frameworks directory the podspec links',
      );
    });

    test('the digest gate still pins the immutable asset', () {
      final runText = stepByName(restoreStepName)['run'] as String;
      expect(
        runText,
        contains('ASSET_BYTES=$assetBytes'),
        reason: 'the pinned byte size distinguishes truncated from wrong',
      );
      expect(
        runText,
        contains('ASSET_DIGEST="$assetDigest"'),
        reason: 'the pinned sha256 keeps unverified bytes out of the build',
      );
    });
  });
}
