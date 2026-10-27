// gh-1798 — the daily-publish cli leg (build-macos.yml, run 39905803673)
// failed on both arches with:
//
//   error: The package product 'flutter-inappwebview-macos-product'
//   requires minimum platform version 14.0 for the macOS platform, but
//   this target supports 12.0 (in target 'FlutterGeneratedPluginSwiftPackage')
//
// Flutter 3.47 generates FlutterGeneratedPluginSwiftPackage at the macOS
// 12.0 floor and raises it to the app's 14.0 only when a silent
// `xcodebuild -showBuildSettings` read succeeds (failures are swallowed at
// trace level). The ONLY macOS plugin whose SwiftPM product needs > 12.0 is
// the vendored flutter_inappwebview_macos (Package.swift floor 14.0, raised
// from upstream 10.14 in gh-1235) — every other SPM-riding macOS plugin
// declares ≤ 10.15. When the bump skips, Xcode hard-fails the whole build.
//
// Static vendor-pin asserts (the wasmrun_macos_pod_link_test.dart /
// quickjs_runtime_vendor_pin_test.dart pattern):
//
//   AC1  the vendored plugin must NOT expose a SwiftPM Package.swift — a
//        plugin rides SPM purely because that file exists, so removing it
//        moves the plugin to the CocoaPods lane and the 14.0 product out
//        of the 12.0-floored generated package for good;
//   AC2  the CocoaPods lane must stay wired: the podspec keeps the 14.0
//        floor (the @available(macOS 10.15) presentationAnchor fix from
//        gh-1235) and flutter_app/macos/Podfile.lock keeps the pod pin;
//   AC3  flutter_app/pubspec.yaml keeps the dependency_overrides mapping
//        onto the vendored directory.
import 'dart:io';

import 'package:test/test.dart';

const vendorDir = 'vendor/flutter_inappwebview_macos';
const packageSwiftPath =
    '$vendorDir/macos/flutter_inappwebview_macos/Package.swift';
const podspecPath = '$vendorDir/macos/flutter_inappwebview_macos.podspec';
const macosPodfileLockPath = 'flutter_app/macos/Podfile.lock';
const appPubspecPath = 'flutter_app/pubspec.yaml';

void main() {
  test('AC1 — vendored flutter_inappwebview_macos ships no SwiftPM manifest '
      '(gh-1798)', () {
    expect(
      File(packageSwiftPath).existsSync(),
      isFalse,
      reason:
          '$packageSwiftPath must not exist: the flutter tool treats its '
          'mere presence as SwiftPM opt-in and publishes the 14.0-floored '
          'flutter-inappwebview-macos product into '
          'FlutterGeneratedPluginSwiftPackage, which Flutter 3.47 generates '
          'at the macOS 12.0 floor. The tool raises that floor only when a '
          'silent `xcodebuild -showBuildSettings` read succeeds, and when '
          'the read fails the leg dies with "requires minimum platform '
          'version 14.0 ... this target supports 12.0" (gh-1798, first '
          'Xcode 27 run). The CocoaPods lane (podspec, Podfile.lock pin) '
          'builds the same sources at the app\'s 14.0 floor with no '
          'dependency on the fragile bump.',
    );
  });

  test('AC2 — the CocoaPods lane stays wired (podspec floor + lock pin)', () {
    final podspec = File(podspecPath).readAsStringSync();
    expect(
      podspec.contains("s.platform = :osx, '14.0'"),
      isTrue,
      reason:
          '$podspecPath must keep the 14.0 floor — the plugin\'s '
          '@available(macOS 10.15, *) presentationAnchor conformance does '
          'not compile below it (gh-1235), and the pod builds at the '
          'Podfile platform instead of the app deployment target.',
    );

    final lock = File(macosPodfileLockPath).readAsStringSync();
    expect(
      lock.contains('  - flutter_inappwebview_macos (0.0.1):'),
      isTrue,
      reason:
          '$macosPodfileLockPath must keep the flutter_inappwebview_macos '
          'pod pinned (podspec s.version) — moving the plugin out of SPM '
          'only works because the CocoaPods lane is already installed and '
          'the check_lockfiles.sh pod-sync gate enforces the pin.',
    );
  });

  test('AC3 — pubspec dependency_overrides keeps the vendored mapping', () {
    final pubspec = File(appPubspecPath).readAsStringSync();
    final overrideBlock = RegExp(
      r'flutter_inappwebview_macos:\n\s+path: \.\./vendor/flutter_inappwebview_macos',
    ).hasMatch(pubspec);
    expect(
      overrideBlock,
      isTrue,
      reason:
          '$appPubspecPath dependency_overrides must keep '
          'flutter_inappwebview_macos mapped onto $vendorDir — the pin is '
          'what routes the plugin into the vendored, pods-lane-only copy.',
    );
  });
}
