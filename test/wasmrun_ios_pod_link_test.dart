// gh-2106 (v1.0.707 ci-red): the Runner link resolves CocoaPods-generated
// `-l"wasm_run_dart"` ONLY through LIBRARY_SEARCH_PATHS'
// ${PODS_XCFRAMEWORKS_BUILD_DIR}/wasm_run_flutter — the
// XCFrameworkIntermediates copy that the wasm_run_flutter pod's
// "[CP] Copy XCFrameworks" phase rsyncs at BUILD time. On the self-hosted
// fa-m5-2 runner that copy stopped landing after a cancelled run poisoned
// the per-project DerivedData build database (outside the repo, invisible
// to the workspace `git clean -ffdx`, per-checkout-path → per-runner), and
// every build leg died at link with `Library 'wasm_run_dart' not found`
// while the identical tree stayed green on fa-m5-1 and GitHub-hosted macOS.
//
// The Podfile post_install hook already rewrites OTHER_LDFLAGS[sdk=…] to
// force_load the exact restored slices; the same loop must also pin
// LIBRARY_SEARCH_PATHS[sdk=iphoneos*]/[sdk=iphonesimulator*] at the vendored
// slice DIRS so the `-l` lookup resolves the restored archive directly and
// never depends on the intermediates copy. Static lint over the Podfile +
// the committed pbxproj, same style as wasmrun_macos_pod_link_test.dart.
import 'dart:io';

import 'package:test/test.dart';

const podfilePath = 'flutter_app/ios/Podfile';
const pbxprojPath = 'flutter_app/ios/Runner.xcodeproj/project.pbxproj';
const xcframeworkSetting =
    r"$(SRCROOT)/../../vendor/wasm_run_flutter/ios/Frameworks/WasmRun.xcframework";

void main() {
  group('iOS Runner link does not depend on the XCFrameworkIntermediates copy', () {
    test(
      'post_install injects the vendored slice dirs into LIBRARY_SEARCH_PATHS[sdk=…]',
      () {
        final podfile = File(podfilePath).readAsStringSync();
        // The xcframework root constant the force_load flags already use —
        // the LIBRARY_SEARCH_PATHS injection must reuse the SAME path root,
        // not restate a divergent copy of it.
        expect(
          podfile.contains(
            "xcframework = '$xcframeworkSetting'",
          ),
          isTrue,
          reason:
              '$podfilePath must keep the xcframework = constant pointing at '
              'the vendored WasmRun.xcframework under vendor/ — it anchors '
              'both the -Wl,-force_load slices and the LIBRARY_SEARCH_PATHS '
              'injection (gh-2106).',
        );

        // Slice DIR constants: the -l lookup needs the DIRECTORY that holds
        // libwasm_run_dart.a, not the archive path itself.
        expect(
          RegExp(
            r'device_slice_dir = "#\{xcframework\}/ios-arm64"',
          ).hasMatch(podfile),
          isTrue,
          reason:
              '$podfilePath must define device_slice_dir as the vendored '
              'xcframework ios-arm64 slice dir so '
              '-l"wasm_run_dart" resolves against the restored archive even '
              'when the pod target\'s "[CP] Copy XCFrameworks" phase is '
              'skipped (gh-2106: the phase\'s declared output '
              'WasmRun.framework never matches the bare .a slice, and a '
              'poisoned DerivedData build database on a self-hosted runner '
              'leaves the copy undone — link dies with '
              '"Library \'wasm_run_dart\' not found").',
        );
        expect(
          RegExp(
            r'simulator_slice_dir = "#\{xcframework\}/ios-arm64_x86_64-simulator"',
          ).hasMatch(podfile),
          isTrue,
          reason:
              '$podfilePath must define simulator_slice_dir as the '
              'ios-arm64_x86_64-simulator slice dir — the simulator '
              'variant of the -l lookup must not fall back to the device '
              'slice or the intermediates copy (gh-2106).',
        );

        // The injection loop: same sdk-keyed mapping shape as the
        // OTHER_LDFLAGS loop, writing the sdk-qualified LIBRARY_SEARCH_PATHS.
        expect(
          RegExp(
            r"'iphoneos\*' => device_slice_dir, 'iphonesimulator\*' => simulator_slice_dir",
          ).hasMatch(podfile),
          isTrue,
          reason:
              '$podfilePath must map the slice dirs per SDK family '
              "(iphoneos* → ios-arm64, iphonesimulator* → "
              'ios-arm64_x86_64-simulator) exactly like the existing '
              'OTHER_LDFLAGS loop — a single unqualified path list would '
              'let a device build resolve -l"wasm_run_dart" against the '
              'simulator slice (gh-2106).',
        );
        expect(
          podfile.contains('key = "LIBRARY_SEARCH_PATHS[sdk=#{sdk}]"') &&
              RegExp(
                r'config\.build_settings\[key\] = \[',
              ).hasMatch(podfile),
          isTrue,
          reason:
              '\$podfilePath post_install must WRITE '
              "LIBRARY_SEARCH_PATHS[sdk=#{sdk}] on the Runner target's "
              'build configurations — that is the setting ld consults for '
              'the CocoaPods-generated -l"wasm_run_dart" flag; without it '
              'the lookup rides solely on the '
              '${r'$'}{PODS_XCFRAMEWORKS_BUILD_DIR}/wasm_run_flutter '
              'intermediates copy, the copy gh-2106 showed can vanish on a '
              'self-hosted runner.',
        );

        // Search order: the vendored slice must come BEFORE $(inherited) so
        // a stale intermediates copy can never satisfy the -l lookup with
        // different bytes than the -Wl,-force_load loaded.
        final injection = RegExp(
          r'key = "LIBRARY_SEARCH_PATHS\[sdk=#\{sdk\}\]"[\s\S]{0,400}?'
          r'config\.build_settings\[key\] = \[\s*'
          r'(\w+),\s*'
          r"'\$\(inherited\)'",
        ).firstMatch(podfile);
        expect(
          injection,
          isNotNull,
          reason:
              '\$podfilePath must assemble the injected LIBRARY_SEARCH_PATHS '
              "as [slice_dir, '\$(inherited)', …] — the vendored slice dir "
              'must precede \$(inherited) so ld resolves -l"wasm_run_dart" '
              'against the same archive the -Wl,-force_load loads, never '
              'against a stale/partial XCFrameworkIntermediates copy '
              '(gh-2106).',
        );
        if (injection != null) {
          expect(
            injection.group(1),
            'slice_dir',
            reason:
                'The LIBRARY_SEARCH_PATHS entry must be the per-SDK '
                'slice_dir loop variable, not a hard-coded slice — the '
                'loop pairs iphoneos* with the device slice and '
                'iphonesimulator* with the simulator slice (gh-2106).',
          );
        }

        // Idempotent re-runs: pod install rewrites these settings on every
        // install, so the hook must drop previously injected entries before
        // re-adding them (no duplicated slice dirs accumulating in the
        // pbxproj across pod installs).
        expect(
          RegExp(
            r"reject!\s*\{\s*\|p\|\s*p\.include\?\('WasmRun\.xcframework'\)\s*\}",
          ).hasMatch(podfile),
          isTrue,
          reason:
              '$podfilePath must reject previously injected '
              'WasmRun.xcframework entries from LIBRARY_SEARCH_PATHS before '
              're-adding the slice dir — pod install runs on every build '
              'and a non-idempotent injection would grow the pbxproj on '
              'every run (gh-2106).',
        );
      },
    );

    test(
      'committed pbxproj carries the injected LIBRARY_SEARCH_PATHS settings',
      () {
        final pbxproj = File(pbxprojPath).readAsStringSync();
        // The repo commits the pod-install-processed Runner project (the
        // pod-sync contract — scripts/check_lockfiles.sh). The committed
        // pbxproj must already contain the settings post_install writes;
        // otherwise every CI pod install would dirty the tree again.
        for (final sdk in const ['iphoneos*', 'iphonesimulator*']) {
          final needle = '"LIBRARY_SEARCH_PATHS[sdk=$sdk]" = (';
          expect(
            pbxproj.contains(needle),
            isTrue,
            reason:
                '$pbxprojPath is missing "$needle" — run '
                '`cd flutter_app/ios && pod install` and commit the '
                'regenerated project so the committed tree stays '
                'pod-install-stable (gh-2106).',
          );
        }
        expect(
          pbxproj.split('vendor/wasm_run_flutter/ios/Frameworks/WasmRun.xcframework/ios-arm64"').length,
          greaterThan(3),
          reason:
              '$pbxprojPath must reference the restored device slice dir in '
              'its LIBRARY_SEARCH_PATHS lists (3 configurations × '
              'iphoneos* entries); fewer means the committed project '
              'predates the gh-2106 Podfile injection.',
        );
      },
    );

    test('load side is unchanged: force_load stays pinned to the same slices',
        () {
      final podfile = File(podfilePath).readAsStringSync();
      // The -l fix resolves the name; the force_load + exported_symbol
      // machinery is what actually loads/keeps the FFI surface. Guard both
      // so a future edit cannot trade one for the other.
      expect(
        RegExp(r'-Wl,-force_load,#\{slice\}').hasMatch(podfile),
        isTrue,
        reason:
            '$podfilePath must keep appending -Wl,-force_load,#{slice} per '
            'SDK — the dlsym-resolved wasm_run FFI symbols only reach the '
            'binary via force_load (gh-2106 keeps the existing mechanism; '
            'LIBRARY_SEARCH_PATHS only fixes the -l name resolution).',
      );
      expect(
        RegExp(r"'iphoneos\*' => device_slice, 'iphonesimulator\*' => simulator_slice")
            .hasMatch(podfile),
        isTrue,
        reason:
            '$podfilePath must keep the OTHER_LDFLAGS loop mapping '
            'iphoneos* → device_slice and iphonesimulator* → '
            'simulator_slice (the archive FILE paths, distinct from the '
            'gh-2106 slice DIR mapping).',
      );
    });
  });
}
