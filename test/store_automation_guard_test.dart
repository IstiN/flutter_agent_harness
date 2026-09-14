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
  final storeMetadata = read('.github/workflows/store-metadata.yml');

  group('AC1 — submit_only lanes distribute externally', () {
    test('both lanes render distribute_external: true', () {
      expectCount(
        'distribute_external: true',
        fastfile,
        'distribute_external: true',
        2,
      );
    });

    test('both lanes pass the configured group', () {
      expectCount('groups: [group]', fastfile, 'groups: [group]', 2);
    });

    test(
      'both lanes wait for processing (pilot silently skips distribution otherwise)',
      () {
        expectCount(
          'skip_waiting_for_build_processing: false',
          fastfile,
          'skip_waiting_for_build_processing: false',
          2,
        );
      },
    );

    test('missing TESTFLIGHT_EXTERNAL_GROUP fails loudly at lane start', () {
      expect(
        fastfile,
        contains('require_env!("TESTFLIGHT_EXTERNAL_GROUP"'),
        reason: 'lane-start guard for the group variable',
      );
    });

    test('workflows pass the repo variables through', () {
      for (final wf in [buildMobile, buildMacos]) {
        expect(
          wf,
          contains(
            r'TESTFLIGHT_EXTERNAL_GROUP: ${{ vars.TESTFLIGHT_EXTERNAL_GROUP }}',
          ),
        );
      }
    });

    test(
      'external distribution supplies a changelog (pilot raises without one)',
      () {
        expectCount(
          'changelog: testflight_changelog',
          fastfile,
          'changelog: testflight_changelog',
          2,
        );
      },
    );

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
      expectCount(
        'beta_app_review_info: review_info',
        fastfile,
        'beta_app_review_info: review_info',
        2,
      );
      expectCount(
        'beta_app_feedback_email: feedback_email',
        fastfile,
        'beta_app_feedback_email: feedback_email',
        2,
      );
    });

    test('export compliance off in both lanes', () {
      expectCount(
        'uses_non_exempt_encryption: false',
        fastfile,
        'uses_non_exempt_encryption: false',
        2,
      );
    });

    test('export compliance off in both plists', () {
      for (final plist in [iosPlist, macPlist]) {
        final key = plist.indexOf('<key>ITSAppUsesNonExemptEncryption</key>');
        expect(
          key,
          isNonNegative,
          reason: 'ITSAppUsesNonExemptEncryption must stay in the plist',
        );
        expect(
          plist.substring(key),
          contains('<false/>'),
          reason:
              'ITSAppUsesNonExemptEncryption must be false (no per-build compliance prompt)',
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
      expect(
        releaseAppstore,
        contains('inputs.confirm'),
        reason: 'fat-finger guard',
      );
    });

    test('both platform jobs gate on the platforms input', () {
      expect(
        releaseAppstore,
        contains("inputs.platforms == 'ios' || inputs.platforms == 'both'"),
      );
      expect(
        releaseAppstore,
        contains("inputs.platforms == 'macos' || inputs.platforms == 'both'"),
      );
    });

    test('both submit_for_review lanes submit for review', () {
      expectCount(
        'submit_for_review: true',
        fastfile,
        'submit_for_review: true',
        2,
      );
    });

    test('automatic release stays a one-line config (E5), not hardcoded', () {
      expect(
        fastfile,
        contains('ENV.fetch("APP_STORE_AUTOMATIC_RELEASE", "false")'),
      );
    });

    test('pre-flight module + AC3 matrix tests exist', () {
      final preflight = read('flutter_app/fastlane/appstore_preflight.rb');
      expect(preflight, contains('SUBMITTED_STATES'));
      expect(preflight, contains('WAITING_FOR_REVIEW'));
      final rubyTest = read(
        'flutter_app/fastlane/test/appstore_preflight_test.rb',
      );
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

  group('Track 2 — store-metadata.yml android leg (#289)', () {
    test('fastlane android play_store lane uploads the listing via supply', () {
      expect(fastfile, contains('lane :play_store do'));
      expect(fastfile, contains('supply_listing_options'));
    });

    test(
      'android_content dispatch input offers the supply splits, none default',
      () {
        expect(storeMetadata, contains('android_content:'));
        expect(storeMetadata, contains("default: 'none'"));
        for (final option in ['metadata_only', 'images_only']) {
          expect(
            storeMetadata,
            contains(option),
            reason: 'supply content split missing',
          );
        }
      },
    );

    test('android job gates on android_content and wires the Play secret', () {
      expect(
        storeMetadata,
        contains("if: github.event.inputs.android_content != 'none'"),
      );
      expect(
        storeMetadata,
        contains(
          r'PLAY_STORE_SERVICE_ACCOUNT_JSON: ${{ secrets.PLAY_STORE_SERVICE_ACCOUNT_JSON }}',
        ),
      );
      expect(storeMetadata, contains('PLAY_TRACK: internal'));
    });

    test('dispatch maps android_content to PLAY_DEPLOY_* flags', () {
      expect(
        storeMetadata,
        contains(
          'export PLAY_DEPLOY_METADATA="true" PLAY_DEPLOY_IMAGES="false"',
        ),
      );
      expect(
        storeMetadata,
        contains(
          'export PLAY_DEPLOY_METADATA="false" PLAY_DEPLOY_IMAGES="true"',
        ),
      );
    });

    test('committed listing assets exist for both locales', () {
      for (final locale in ['en-US', 'ru-RU']) {
        for (final entry in [
          'title.txt',
          'short_description.txt',
          'full_description.txt',
          'images/icon.png',
          'images/featureGraphic.png',
        ]) {
          final path = 'flutter_app/fastlane/metadata/android/$locale/$entry';
          expect(
            File(path).existsSync(),
            isTrue,
            reason: 'supply expects a committed $path',
          );
        }
      }
    });
  });

  group('workflow YAML parses', () {
    test('all touched workflows are valid YAML', () {
      for (final source in [
        buildMobile,
        buildMacos,
        daily,
        releaseAppstore,
        storeMetadata,
      ]) {
        loadYaml(source);
      }
    });
  });

  group('AC6 — regression guard (existing channels unchanged)', () {
    test('metadata lanes never submit for review', () {
      expectCount(
        'submit_for_review: false',
        fastfile,
        'submit_for_review: false',
        4,
      );
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

  // #346: the daily play leg died in 4s with
  //   HTTP 422: Unexpected inputs provided: ["android_track"]
  // because build-mobile.yml consumed `inputs.android_track` without ever
  // declaring it under on.workflow_dispatch.inputs. Cross-check every
  // `-f key=value` a leg sends against the child workflow's declared
  // inputs so the whole class of bug is pinned, not just this instance.
  group('daily-publish dispatch contract (#346)', () {
    test('every -f input a leg sends is declared by the child workflow', () {
      final dailyYaml = loadYaml(daily) as Map;
      final sent = <String, Set<String>>{};
      for (final job in (dailyYaml['jobs'] as Map).values) {
        final steps = (job as Map)['steps'];
        if (steps is! Iterable) continue;
        for (final step in steps) {
          final run = (step as Map)['run'];
          // #343/#344 moved the legs from inline `gh workflow run` to the
          // shared `dispatch_and_watch.sh` wrapper — both spellings pass
          // the SAME `-f key=value` flags, so both are scanned (#351).
          if (run is! String ||
              (!run.contains('gh workflow run') &&
                  !run.contains('dispatch_and_watch.sh'))) {
            continue;
          }
          String? child;
          for (final line in run.split('\n')) {
            final m = RegExp(
              r'(?:gh workflow run|dispatch_and_watch\.sh) ([\w.-]+\.yml)',
            ).firstMatch(line);
            if (m != null) child = m.group(1);
            if (child == null) continue;
            for (final f in RegExp(r'-f (\w+)=').allMatches(line)) {
              sent.putIfAbsent(child, () => <String>{}).add(f.group(1)!);
            }
          }
        }
      }
      expect(
        sent,
        isNotEmpty,
        reason: 'dispatch scan found nothing — parser drifted',
      );
      sent.forEach((workflow, flags) {
        final childYaml = loadYaml(read('.github/workflows/$workflow')) as Map;
        final trigger =
            childYaml['on'] ?? childYaml[true]; // YAML 1.1 may key `on` as true
        final dispatch = trigger is Map ? trigger['workflow_dispatch'] : null;
        expect(
          dispatch,
          isA<Map>(),
          reason:
              '$workflow must declare a workflow_dispatch trigger — the daily legs dispatch it',
        );
        final inputs = dispatch is Map ? dispatch['inputs'] : null;
        expect(
          inputs,
          isA<Map>(),
          reason: '$workflow declares no workflow_dispatch inputs',
        );
        for (final flag in flags) {
          expect(
            (inputs as Map).containsKey(flag),
            isTrue,
            reason:
                '$workflow does not declare input `$flag` — gh workflow run fails instantly '
                'with HTTP 422 "Unexpected inputs provided" and the leg dies in seconds (#346)',
          );
        }
      });
    });

    test(
      'play leg is serialized after testflight — one build-mobile dispatch at a time (#343, #346)',
      () {
        final play = ((loadYaml(daily) as Map)['jobs'] as Map)['play'] as Map;
        // needs may be a scalar (`needs: plan`) or a list.
        final needs = play['needs'];
        final needsList = needs is List ? needs : [needs];
        expect(
          needsList.contains('testflight'),
          isTrue,
          reason:
              'both legs dispatch build-mobile.yml and each child derives '
              'the same next tag independently — concurrent dispatches would race '
              'on one release (duplicate drafts, asset clobbering) and strain the '
              '#343 title-correlation window. (#351: build-mobile\'s concurrency '
              'group is per-dispatch, so this serialization — not the group — is '
              'what guarantees one daily build-mobile child at a time)',
        );
        expect(
          play['if'],
          contains('!cancelled()'),
          reason:
              '!cancelled() keeps single-leg play dispatches runnable when the testflight leg skips',
        );
      },
    );
  });
}
