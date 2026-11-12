// gh-2125 — the daily-publish TestFlight leg failed in the "Build iOS IPA"
// step (run 43160591145) 12 minutes into the archive with the classic
// corrupted-shared-state trio:
//
//   unable to read PCH file .../Runner-primary-Bridging-header.pch:
//     'No such file or directory'
//   cannot open constant extraction protocol list input file
//     .../Runner_const_extract_protocols.json
//   accessing build database .../XCBuildData/build.db: disk I/O error
//
// Every failing path lived in the DEFAULT per-user Xcode DerivedData
// (`~/Library/Developer/Xcode/DerivedData/Runner-<path-hash>`): the gym
// archive passed no `-derivedDataPath`, so xcodebuild fell back to the
// shared per-user root on the persistent self-hosted Mac — a directory
// NOTHING in the pipeline ever cleans (the lane's `flutter clean` touches
// only `flutter_app/build/`; gym's `clean: true` cleans through the very
// build database that corrupted). The SAME tree archived green the two
// days before (runs of 11-10 / 11-11), so this was runner state, not code.
// The Mac also serves up to three runner registrations concurrently
// (gh-2026), sharing that per-user root — plus the date-based
// `~/Library/Developer/Xcode/Archives/<date>` default archivePath.
//
// Static workflow-shape asserts (the "workflow-shape test never-again"
// pattern of workflow_ios_archive_observability_test.dart):
//
//   AC1  the build_only lane pins a workspace-local derived data path
//        (fresh by construction — the checkout is wiped and re-cloned
//        every run, gh-160), never the shared per-user root.
//   AC2  the lane removes that path before the archive (hand-run lanes
//        skip `flutter clean`).
//   AC3  the xcarchive is pinned workspace-local too — never the shared
//        per-user date directory (two registrations archiving on the
//        same day collide on the same `fa.xcarchive` path).
//   AC4  the shared per-user DerivedData root is never PURGED from the
//        repo — a sibling registration's archive may be live inside it
//        (the isolation fix must not regress into a clobbering fix).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

List<YamlMap> stepsOf(String workflowPath, String job) =>
    (((loadYaml(read(workflowPath))['jobs'] as YamlMap)[job] as YamlMap)
                ['steps'] as YamlList)
            .whereType<YamlMap>()
            .toList();

void main() {
  const fastfile = 'flutter_app/fastlane/Fastfile';
  const mobile = '.github/workflows/build-mobile.yml';

  group('AC1 — the archive builds into a workspace-local derived data path',
      () {
    test('build_app pins derived_data_path under the workspace build dir',
        () {
      final source = read(fastfile);
      final buildApp = source.indexOf('build_app(');
      expect(buildApp, greaterThan(-1), reason: 'build_app must exist');
      final options = source.substring(
        buildApp,
        source.indexOf("\n    end", buildApp),
      );
      expect(
        options,
        contains('derived_data_path: derived_data,'),
        reason:
            'gym ran with NO -derivedDataPath, so the archive used the '
            'shared per-user ~/Library/Developer/Xcode/DerivedData root — '
            'never cleaned, concurrently written by sibling registrations, '
            'and it corrupted mid-archive (gh-2125: missing PCH + missing '
            'Runner_const_extract_protocols.json + build.db disk I/O '
            'error). The lane must pin a per-run path.',
      );
      final ddDecl =
          RegExp(r'derived_data = File\.expand_path\("\.\./build/ios/[^"]+", __dir__\)');
      expect(
        ddDecl.hasMatch(source),
        isTrue,
        reason:
            'the pinned path must resolve under flutter_app/build/ios/ — '
            'inside the workspace, which the gh-160 checkout wipes and '
            're-clones every run, so the directory starts clean by '
            'construction (gh-2125)',
      );
    });
  });

  group('AC2 — the pinned path is removed before the archive', () {
    test('rm_rf of the derived data path precedes build_app', () {
      final source = read(fastfile);
      final rmIdx = source.indexOf('FileUtils.rm_rf(derived_data)');
      final buildApp = source.indexOf('build_app(');
      expect(
        rmIdx,
        greaterThan(-1),
        reason:
            'a hand-run lane skips the workflow\'s flutter clean — the '
            'lane itself must remove the pinned path before archiving '
            '(gh-2125)',
      );
      expect(
        rmIdx,
        lessThan(buildApp),
        reason:
            'the removal must happen BEFORE build_app, not after it '
            '(gh-2125)',
      );
    });
  });

  group('AC3 — the xcarchive is workspace-local too', () {
    test('build_app pins archive_path next to the derived data path', () {
      final source = read(fastfile);
      final buildApp = source.indexOf('build_app(');
      final options = source.substring(
        buildApp,
        source.indexOf("\n    end", buildApp),
      );
      expect(
        options,
        contains('archive_path:'),
        reason:
            'gym\'s default archivePath is the shared per-user '
            '~/Library/Developer/Xcode/Archives/<date>/ dir — two '
            'registrations archiving on the same day write the SAME '
            'fa.xcarchive path (gh-2125). Pin it workspace-local.',
      );
      expect(
        options.contains('/Library/Developer/Xcode/Archives'),
        isFalse,
        reason:
            'the archive must never land in the shared per-user Archives '
            'date directory (gh-2125)',
      );
    });
  });

  group('AC4 — the shared per-user root is isolated, never purged', () {
    test('the Fastfile never deletes ~/Library/Developer/Xcode/DerivedData',
        () {
      final source = read(fastfile);
      expect(
        RegExp(
                r'(rm_rf|rm -rf|FileUtils\.remove_dir)[^\n]*~/Library/Developer/Xcode/DerivedData',
                multiLine: true)
            .hasMatch(source),
        isFalse,
        reason:
            'the shared per-user DerivedData root may hold a LIVE archive '
            'from a sibling registration (three registrations build '
            'concurrently on this Mac, gh-2026) — blanket-purging it from '
            'the repo would clobber a running build. Isolate (pin a '
            'workspace-local path), never clobber (gh-2125).',
      );
    });

    test('build-ios has no step that blanket-purges the shared DerivedData',
        () {
      final steps = stepsOf(mobile, 'build-ios');
      final purgers = steps
          .map((s) => s['run']?.toString() ?? '')
          .where((script) => RegExp(
                  r'rm\s+-rf[^|\n;]*~/Library/Developer/Xcode/DerivedData')
              .hasMatch(script))
          .toList();
      expect(
        purgers,
        isEmpty,
        reason:
            'a workflow-level rm -rf of the shared per-user DerivedData '
            'root races the sibling registrations\' concurrent archives '
            '(gh-2026/gh-2125). The fix is workspace-local isolation in '
            'the lane, not a shared-root purge step.',
      );
    });
  });
}
