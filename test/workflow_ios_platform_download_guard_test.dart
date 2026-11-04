// gh-2054 — the daily-publish testflight leg (child run 41778614770,
// 2026-11-04) died cancelled at "Build iOS IPA — Ensure iOS device SDK is
// available": the step ran TWO unconditional `xcodebuild -downloadPlatform`
// calls although the device SDK it ensures was ALREADY installed
// (`-showsdks` printed `iOS 27.1 -sdk iphoneos27.1` at 05:35:00Z). The
// second call pinned `-buildVersion 26.5` — a stale hardcode that
// force-downloads a multi-GB iOS 26.5 SIMULATOR runtime the SDK-27.1
// runner never needs — and the transfer stalled with zero output at
// 05:35:13Z. Nothing bounded it: `|| true` guards the step's exit code,
// not its duration. The step hung 77m35s until build-ios's own
// `timeout-minutes: 90` ceiling fired server-side (the #344 bound) and
// cancelled the whole job — no IPA, no submit, a lost TestFlight day.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of workflow_selfhosted_legs_test.dart /
// ci_cert_sha1_pin_guard_test.dart):
//
//   AC1  the step GATES the download on the SDK-missing condition — an
//        `iphoneos*` SDK in `-showsdks` is the step's contract ("Ensure
//        iOS device SDK is available"), so the gate + early exit must sit
//        BEFORE any `-downloadPlatform` line; an unconditional download
//        cannot return.
//   AC2  no hardcoded `-buildVersion` pin — pinned platform versions rot
//        exactly like this 26.5 pin did (the gh-1826 wildcard-pin lesson,
//        run 40066130883) and re-download dead runtimes every day.
//   AC3  the download is BOUNDED — run in background with a deadline
//        watchdog that kills a stalled transfer, so a hang can never eat
//        the 90-minute job budget again; the best-effort semantics
//        (download failure never reds the step) are preserved.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

/// Workflow YAML carries long incident comments that legitimately quote
/// the historical broken shape — the guard targets EXECUTABLE lines, so
/// strip shell `#` comments before matching.
String stripComments(String content) => content
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash == -1 ? line : line.substring(0, hash);
    })
    .join('\n');

/// The `run` script of the named step in the named job of the workflow.
String stepScriptOf(String workflowPath, String job, String stepName) {
  final steps =
      ((loadYaml(read(workflowPath))['jobs'] as YamlMap)[job]
              as YamlMap)['steps']
          as YamlList;
  return steps
      .whereType<YamlMap>()
      .firstWhere(
        (s) => (s['name']?.toString() ?? '') == stepName,
        orElse: () => throw StateError('step "$stepName" not found in $job'),
      )['run']
      .toString();
}

void main() {
  const mobile = '.github/workflows/build-mobile.yml';
  const step = 'Ensure iOS device SDK is available';
  final script = stripComments(stepScriptOf(mobile, 'build-ios', step));

  group('gh-2054 — build-ios SDK step cannot hang the job', () {
    test('AC1 — download is gated on the device SDK being MISSING', () {
      final gate = script.indexOf('if xcodebuild -showsdks | grep iphoneos');
      final exit0 = script.indexOf('exit 0');
      expect(
        gate,
        greaterThan(-1),
        reason:
            'the step must check `xcodebuild -showsdks | grep '
            'iphoneos` before touching -downloadPlatform — an installed '
            'iphoneos SDK IS the step contract (gh-2054: the 27.1 SDK was '
            'already present and the step still downloaded)',
      );
      expect(
        exit0,
        greaterThan(gate),
        reason:
            'the SDK-present branch must EXIT before any download — '
            'the gate without an early exit still runs the unconditional '
            'download (gh-2054)',
      );
      // every -downloadPlatform occurrence must sit AFTER the SDK-present
      // early exit (the review rework added a second, setsid-guarded
      // launch — the gate must dominate ALL of them, not just the first)
      for (final at in RegExp(
        '-downloadPlatform',
      ).allMatches(script).map((m) => m.start)) {
        expect(
          at,
          greaterThan(exit0),
          reason:
              'every -downloadPlatform call must sit AFTER the '
              'SDK-present early exit (gh-2054: run 41778614770 '
              'downloaded with the SDK installed)',
        );
      }
    });

    test('AC2 — no hardcoded -buildVersion platform pin', () {
      expect(
        script.contains('-buildVersion'),
        isFalse,
        reason:
            'a pinned -buildVersion force-downloads one frozen '
            'platform version forever; the 26.5 pin re-downloaded a '
            'multi-GB iOS 26.5 SIMULATOR runtime on an SDK-27.1 runner '
            'every single day and its transfer is what stalled for 77m '
            '(gh-2054). Unversioned -downloadPlatform iOS resolves the '
            'current platform and no-ops when current.',
      );
    });

    test('AC3 — the download is bounded by a deadline watchdog', () {
      final download = script.indexOf('-downloadPlatform');
      expect(download, greaterThan(-1), reason: 'fallback download must exist');
      final background = script.indexOf('&\n', download);
      final deadline = script.indexOf('DEADLINE=');
      final killWatchdog = script.indexOf('kill -9');
      expect(
        background,
        greaterThan(download),
        reason:
            'the download must run in background (& pid) so the step '
            'can police it (gh-2054: a foreground xcodebuild could not '
            'be interrupted by anything but the 90m job ceiling)',
      );
      expect(
        deadline,
        greaterThan(-1),
        reason:
            'a deadline must be computed so a stalled transfer is '
            'killed, not waited on (gh-2054: 77m35s of silence until the '
            'job ceiling cancelled the build)',
      );
      expect(
        killWatchdog,
        greaterThan(deadline),
        reason:
            'the watchdog must kill the stalled download (kill -9 '
            'backstop) — `|| true` guards exit codes, never duration '
            '(gh-2054)',
      );
      // gh-2054 review thread 1 (BLOCKING): the ceiling VALUE is part of
      // the contract. The first cut shipped DOWNLOAD_CEILING=120 — read
      // by `DEADLINE=$(( $(date +%s) + DOWNLOAD_CEILING ))` as 120
      // SECONDS (2 min) — while the same line's comment said `# 20m` and
      // the PR description promised a 20-minute ceiling twice. A healthy
      // multi-GB -downloadPlatform iOS transfer needs more than 2 min,
      // so on the only path reaching this code (SDK genuinely missing)
      // the watchdog killed LEGITIMATE downloads mid-transfer. Pin the
      // shipped constant AND a units sanity floor so the ceiling can
      // never silently shrink again (shape asserts could not catch it).
      final ceiling = RegExp(r'DOWNLOAD_CEILING=(\d+)').firstMatch(script);
      expect(
        ceiling,
        isNotNull,
        reason:
            'the watchdog deadline must come from a named '
            'DOWNLOAD_CEILING constant (gh-2054 review thread 1)',
      );
      final ceilingSeconds = int.parse(ceiling!.group(1)!);
      expect(
        ceilingSeconds,
        greaterThanOrEqualTo(600),
        reason:
            'DOWNLOAD_CEILING is EPOCH SECONDS — a value under 600 '
            '(10 min) kills legitimate multi-GB platform downloads '
            'mid-transfer; the documented ceiling is 20 minutes '
            '(gh-2054 review thread 1)',
      );
      expect(
        script.contains('DOWNLOAD_CEILING=1200'),
        isTrue,
        reason:
            'the shipped ceiling must stay the documented 20 '
            'minutes (1200 s ≪ the 90m build-ios job budget) — '
            'DOWNLOAD_CEILING=120 silently shrank it to 2 min and '
            'contradicted its own `# 20m` comment (gh-2054 review '
            'thread 1)',
      );
    });

    test('AC4 — the watchdog kills the whole transfer tree, not just the direct child', () {
      // gh-2054 review thread 2 (SUGGESTION, empirically verified): a
      // lone `kill $DL_PID` signals only the direct xcodebuild child —
      // the transfer's helper descendants survive detached, keep
      // consuming bandwidth/disk during the ~24-minute IPA archive and
      // can hold a runtime-install lock that misbehaves the NEXT daily
      // download. setsid gives the download its own process GROUP, and a
      // NEGATIVE pid to kill(1) signals the whole group; the direct-pid
      // kills stay as the fallback when setsid is unavailable.
      final setsidLaunch = script.indexOf(
        'setsid xcodebuild -downloadPlatform',
      );
      expect(
        setsidLaunch,
        greaterThan(-1),
        reason:
            'the download must be launched under setsid so DL_PID '
            'is a process-GROUP leader the watchdog can signal as a '
            'tree (gh-2054 review thread 2: grandchild helpers survived '
            'a lone kill)',
      );
      final groupTerm = script.indexOf('kill -- -"\$DL_PID"');
      final directTerm = script.indexOf('kill "\$DL_PID"');
      final groupKill = script.indexOf('kill -9 -- -"\$DL_PID"');
      final directKill = script.indexOf('kill -9 "\$DL_PID"');
      expect(
        groupTerm,
        greaterThan(-1),
        reason:
            'the watchdog must signal the process GROUP (negative '
            'pid) with TERM before escalating (gh-2054 review thread 2)',
      );
      expect(
        directTerm,
        greaterThan(groupTerm),
        reason:
            'the direct-pid TERM must follow the group TERM as the '
            'no-setsid fallback — without it a setsid-less runner never '
            'terminates the download at all',
      );
      expect(
        groupKill,
        greaterThan(groupTerm),
        reason:
            'the KILL backstop must target the GROUP too — hard '
            'kills cannot trap-and-forward to descendants '
            '(gh-2054 review thread 2)',
      );
      expect(
        directKill,
        greaterThan(groupKill),
        reason:
            'the direct-pid KILL must follow the group KILL so the '
            'watchdog stays effective even when setsid was unavailable',
      );
    });

    test('AC5 — the incident trail cites the real 11-digit leg run id (41778614770)', () {
      // gh-2054 review thread 3 (SUGGESTION): the incident run id was
      // spelled two ways — the workflow comment and the AC1 reason both
      // carried a truncated mangling of the leg run. The real id (the
      // cancelled testflight-leg build-mobile dispatch, 2026-11-04) is
      // 41778614770, the repo's established 11-digit format — one
      // `git grep 41778614770` must hit every reference.
      final mobileRaw = read(mobile);
      expect(
        mobileRaw.contains('run 41778614770'),
        isTrue,
        reason:
            'the workflow incident comment must cite the real leg '
            'run id 41778614770 (gh-2054 review thread 3)',
      );
      expect(
        mobileRaw.contains('417861470'),
        isFalse,
        reason:
            'the truncated 417861470 id must be gone from the '
            'workflow — a truncated id breaks `git grep 41…` '
            'greppability of the incident trail (gh-2054 review '
            'thread 3)',
      );
    });
  });
}
