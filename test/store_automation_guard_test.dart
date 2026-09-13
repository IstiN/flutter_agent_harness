// Issue #239 grep-guards (AC1/AC2/AC6 + Track 2 statics): a future refactor
// must not silently drop external TestFlight distribution, the Beta App
// Review info, export compliance, or the App Store submission guardrails.
//
// Deliberately text-level asserts over the Fastfile and workflows (the
// issue's "static assert in CI: grep-guard test"): they pin contract
// strings the fastlane lanes and Apple-facing automation depend on, plus a
// YAML parse of every touched workflow.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

void expectCount(String label, String haystack, Pattern pattern, int expected) {
  expect(
    pattern.allMatches(haystack).length,
    expected,
    reason: '$label — expected $expected occurrence(s)',
  );
}

void main() {
  final fastfile = read('flutter_app/fastlane/Fastfile');
  final iosPlist = read('flutter_app/ios/Runner/Info.plist');
  final macPlist = read('flutter_app/macos/Runner/Info.plist');
  final buildMobile = read('.github/workflows/build-mobile.yml');
  final buildMacos = read('.github/workflows/build-macos.yml');
  final daily = read('.github/workflows/daily-publish.yml');
  final releaseAppstore = read('.github/workflows/release-appstore.yml');

  group('AC1 — submit_only lanes distribute externally', () {
    test('both lanes render distribute_external: true', () {
      expectCount('distribute_external: true', fastfile, 'distribute_external: true', 2);
    });

    test('both lanes pass the configured group', () {
      expectCount('groups: [group]', fastfile, 'groups: [group]', 2);
    });

    test('both lanes wait for processing (pilot silently skips distribution otherwise)', () {
      expectCount(
        'skip_waiting_for_build_processing: false',
        fastfile,
        'skip_waiting_for_build_processing: false',
        2,
      );
    });

    test('missing TESTFLIGHT_EXTERNAL_GROUP fails loudly at lane start', () {
      expect(
        fastfile,
        contains('require_env!("TESTFLIGHT_EXTERNAL_GROUP"'),
        reason: 'lane-start guard for the group variable',
      );
    });

    test('workflows pass the repo variables through', () {
      for (final wf in [buildMobile, buildMacos]) {
        expect(wf, contains(r'TESTFLIGHT_EXTERNAL_GROUP: ${{ vars.TESTFLIGHT_EXTERNAL_GROUP }}'));
      }
    });

    test('external distribution supplies a changelog (pilot raises without one)', () {
      expectCount('changelog: testflight_changelog', fastfile, 'changelog: testflight_changelog', 2);
    });

    test('distribution is verified against ASC after upload (AC4)', () {
      expectCount(
        'verify_external_distribution!',
        fastfile,
        'verify_external_distribution!',
        3, // 2 lane calls + 1 definition
      );
    });
  });

  group('AC2 — beta review info + export compliance (both platforms)', () {
    test('lanes supply beta_app_review_info and the feedback email', () {
      expectCount('beta_app_review_info: review_info', fastfile, 'beta_app_review_info: review_info', 2);
      expectCount('beta_app_feedback_email: feedback_email', fastfile, 'beta_app_feedback_email: feedback_email', 2);
    });

    test('export compliance off in both lanes', () {
      expectCount('uses_non_exempt_encryption: false', fastfile, 'uses_non_exempt_encryption: false', 2);
    });

    test('export compliance off in both plists', () {
      for (final plist in [iosPlist, macPlist]) {
        final key = plist.indexOf('<key>ITSAppUsesNonExemptEncryption</key>');
        expect(key, isNonNegative, reason: 'ITSAppUsesNonExemptEncryption must stay in the plist');
        expect(
          plist.substring(key),
          contains('<false/>'),
          reason: 'ITSAppUsesNonExemptEncryption must be false (no per-build compliance prompt)',
        );
      }
    });
  });

  group('Track 2 — release-appstore.yml', () {
    test('dispatch contract: version + platforms + confirm', () {
      expect(releaseAppstore, contains('workflow_dispatch:'));
      for (final input in ['version:', 'platforms:', 'confirm:']) {
        expect(releaseAppstore, contains(input));
      }
      expect(releaseAppstore, contains('inputs.confirm'), reason: 'fat-finger guard');
    });

    test('both platform jobs gate on the platforms input', () {
      expect(releaseAppstore, contains("inputs.platforms == 'ios' || inputs.platforms == 'both'"));
      expect(releaseAppstore, contains("inputs.platforms == 'macos' || inputs.platforms == 'both'"));
    });

    test('both submit_for_review lanes submit for review', () {
      expectCount('submit_for_review: true', fastfile, 'submit_for_review: true', 2);
    });

    test('automatic release stays a one-line config (E5), not hardcoded', () {
      expect(fastfile, contains('ENV.fetch("APP_STORE_AUTOMATIC_RELEASE", "false")'));
    });

    test('pre-flight module + AC3 matrix tests exist', () {
      final preflight = read('flutter_app/fastlane/appstore_preflight.rb');
      expect(preflight, contains('SUBMITTED_STATES'));
      expect(preflight, contains('WAITING_FOR_REVIEW'));
      final rubyTest = read('flutter_app/fastlane/test/appstore_preflight_test.rb');
      for (final scenario in [
        'confirm mismatch',
        'still processing',
        'green no-op',
        'fail before mutation',
        'latest PROCESSED build',
      ]) {
        expect(rubyTest, contains(scenario), reason: 'AC3 matrix case missing');
      }
    });
  });

  group('workflow YAML parses', () {
    test('all touched workflows are valid YAML', () {
      for (final source in [buildMobile, buildMacos, daily, releaseAppstore]) {
        loadYaml(source);
      }
    });
  });

  group('AC6 — regression guard (existing channels unchanged)', () {
    test('metadata lanes never submit for review', () {
      expectCount('submit_for_review: false', fastfile, 'submit_for_review: false', 4);
    });

    test('daily testflight leg keeps Android excluded', () {
      expect(daily, contains('-f android_content=none -f ios_content=all'));
    });

    test('daily cron unchanged', () {
      expect(daily, contains("cron: '17 5 * * *'"));
    });

    test('notarized DMG leg intact', () {
      expect(buildMacos, contains('Notarize DMG'));
    });
  });
}
