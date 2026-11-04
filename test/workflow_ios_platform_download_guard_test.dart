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
  final steps = ((loadYaml(read(workflowPath))['jobs'] as YamlMap)[job]
          as YamlMap)['steps'] as YamlList;
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
      final download = script.indexOf('-downloadPlatform');
      expect(gate, greaterThan(-1),
          reason: 'the step must check `xcodebuild -showsdks | grep '
              'iphoneos` before touching -downloadPlatform — an installed '
              'iphoneos SDK IS the step contract (gh-2054: the 27.1 SDK was '
              'already present and the step still downloaded)');
      expect(exit0, greaterThan(gate),
          reason: 'the SDK-present branch must EXIT before any download — '
              'the gate without an early exit still runs the unconditional '
              'download (gh-2054)');
      expect(download, greaterThan(exit0),
          reason: 'every -downloadPlatform call must sit AFTER the '
              'SDK-present early exit (gh-2054: run 417861470 downloaded '
              'with the SDK installed)');
    });

    test('AC2 — no hardcoded -buildVersion platform pin', () {
      expect(script.contains('-buildVersion'), isFalse,
          reason: 'a pinned -buildVersion force-downloads one frozen '
              'platform version forever; the 26.5 pin re-downloaded a '
              'multi-GB iOS 26.5 SIMULATOR runtime on an SDK-27.1 runner '
              'every single day and its transfer is what stalled for 77m '
              '(gh-2054). Unversioned -downloadPlatform iOS resolves the '
              'current platform and no-ops when current.');
    });

    test('AC3 — the download is bounded by a deadline watchdog', () {
      final download = script.indexOf('-downloadPlatform');
      expect(download, greaterThan(-1), reason: 'fallback download must exist');
      final background = script.indexOf('&\n', download);
      final deadline = script.indexOf('DEADLINE=');
      final killWatchdog = script.indexOf('kill -9');
      expect(background, greaterThan(download),
          reason: 'the download must run in background (& pid) so the step '
              'can police it (gh-2054: a foreground xcodebuild could not '
              'be interrupted by anything but the 90m job ceiling)');
      expect(deadline, greaterThan(-1),
          reason: 'a deadline must be computed so a stalled transfer is '
              'killed, not waited on (gh-2054: 77m35s of silence until the '
              'job ceiling cancelled the build)');
      expect(killWatchdog, greaterThan(deadline),
          reason: 'the watchdog must kill the stalled download (kill -9 '
              'backstop) — `|| true` guards exit codes, never duration '
              '(gh-2054)');
    });
  });
}
