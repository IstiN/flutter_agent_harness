// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// PR #1298 rework (gh-1296): the build-ios failure classifier in ci.yml
/// must label failures by EVIDENCE in the log.
///
/// Review thread 1 caught a DEAD pattern in the CocoaPods alternative:
/// `error while running pod install` (lowercase, "while") — flutter_tools
/// never prints that string; the real tool-exit message is
/// `Error running pod install`
/// (flutter_tools/lib/src/macos/cocoapods.dart, throwToolExit). A generic
/// `pod install` failure whose log shows only the real message fell through
/// to the "Xcode/app layer" fallback, partially recreating the mislabeling
/// gh-1296 set out to fix (the old classifier grepped `pod install` in every
/// log — the string appears in EVERY flutter iOS build, green included).
///
/// Deliberately text/YAML-level asserts plus behavioral greps against
/// synthetic logs (the "static assert in CI" pattern of
/// nightly_desktop_leg_guard_test.dart / store_automation_guard_test.dart):
/// the classifier lives in a workflow `run:` block, so the test extracts
/// the actual `grep -qE` patterns from ci.yml and runs them — wording
/// drift in either the workflow or the pinned SDK messages reds here.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const ciYamlPath = '.github/workflows/ci.yml';

/// The two classifier greps, extracted verbatim from the build-ios step.
/// Each match is the ERE alternation between the quotes.
List<String> classifierPatterns() {
  final body = File(ciYamlPath).readAsStringSync();
  return [
    for (final m in RegExp("grep -qE (['\"])(.+?)\\1 /tmp/build-ios\\.log")
        .allMatches(body))
      m.group(2)!,
  ];
}

/// Feeds [log] through the extracted ci.yml patterns in workflow order
/// (native-assets first, CocoaPods second) and returns the labeled layer —
/// mirroring the if/elif in the build-ios step.
String classify(String log) {
  final patterns = classifierPatterns();
  expect(
    patterns.length,
    greaterThanOrEqualTo(2),
    reason: 'ci.yml build-ios classifier must keep its two grep -qE '
        'signatures (native-assets, then CocoaPods).',
  );
  final tmp = Directory.systemTemp.createTempSync('classifier-test');
  try {
    final logFile = File('${tmp.path}/build-ios.log')..writeAsStringSync(log);
    final run = Process.runSync(
      'bash',
      [
        '-c',
        'if grep -qE "\$1" "\$3"; then echo native-assets; '
            'elif grep -qE "\$2" "\$3"; then echo cocoapods; '
            'else echo xcode; fi',
        'classifier',
        patterns[0],
        patterns[1],
        logFile.path,
      ],
      stdoutEncoding: utf8,
    );
    return (run.stdout as String).trim();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

void main() {
  test('the dead CocoaPods pattern is gone from ci.yml', () {
    final body = File(ciYamlPath).readAsStringSync();
    expect(
      body.contains('error while running pod install'),
      isFalse,
      reason: '`error while running pod install` never matches — '
          'flutter_tools prints `Error running pod install` '
          '(throwToolExit, macos/cocoapods.dart). A case-sensitive grep '
          'for the "while" variant is dead code (PR #1298 review '
          'thread 1).',
    );
  });

  test('the CocoaPods classifier carries the real tool-exit message', () {
    expect(
      classifierPatterns().any((p) => p.contains('Error running pod install')),
      isTrue,
      reason: 'the generic pod-install failure signature must match the '
          'exact string flutter_tools throws: `Error running pod install` '
          '— case-sensitive, no "while" (PR #1298 review thread 1).',
    );
  });

  test('a log with only the real pod-install error classifies as cocoapods',
      () {
    expect(
      classify(
        'Encountered error while building for device.\n'
        'Error running pod install\n'
        'Error launching application\n',
      ),
      'cocoapods',
      reason: 'a generic `pod install` failure whose log shows only the '
          'real flutter_tools message must land in the CocoaPods layer, '
          'not fall through to the Xcode/app fallback.',
    );
  });

  test('the version-conflict and sandbox signatures still classify', () {
    expect(
      classify(
        '[!] CocoaPods could not find compatible versions for pod '
            '"flutter_gemma":\n',
      ),
      'cocoapods',
    );
    expect(
      classify(
        "[!] The sandbox is not in sync with the Podfile.lock. Run "
            "'pod install' or update your CocoaPods installation.\n",
      ),
      'cocoapods',
    );
    expect(
      classify('error: No podspec found for `Flutter` in `Flutter`\n'),
      'cocoapods',
    );
    expect(
      classify(
        '[!] Unable to satisfy the following requirements:\n'
            '- `Flutter` required by `Podfile`\n',
      ),
      'cocoapods',
    );
  });

  test('green-build pod-install noise does NOT classify as cocoapods', () {
    // The gh-1296 root cause: `Running pod install…` prints in EVERY
    // flutter iOS build log, success included. The classifier signatures
    // must not match build-progress lines.
    expect(
      classify(
        'Running pod install...\n'
            'Flutter installation finished\n'
            '4.4s\n'
            'Built build/app/iphoneos/iphone.app\n',
      ),
      'xcode',
      reason: 'a failure log that only contains normal pod-install '
          'progress lines has NO CocoaPods signature — it must stay '
          'unlabeled (xcode fallback) instead of being mislabeled.',
    );
  });

  test('native-assets signatures still win (checked first)', () {
    expect(
      classify(
        'Error running pod install\n' // decoy: cocoapods text present
            'Hash of downloaded file '
            'does not match the hash pinned in the manifest\n',
      ),
      'native-assets',
      reason: 'the native-assets grep runs BEFORE the CocoaPods grep — '
          'a hash-mismatch failure that also mentions pod install must '
          'still be labeled native-assets (the gh-1296 misdirection).',
    );
    expect(
      classify('build.dart returned with exit code 255\n'),
      'native-assets',
    );
  });
}
