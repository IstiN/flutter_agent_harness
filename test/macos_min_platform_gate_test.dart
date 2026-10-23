// gh-180 — the macOS desktop DMG legs (build-macos.yml, run 39905803673,
// 2026-10-23, first run on the Xcode 27 runner) failed on BOTH arches with:
//
//   error: The package product 'flutter-inappwebview-macos-product'
//   requires minimum platform version 14.0 for the macOS platform, but
//   this target supports a lower version
//
// Flutter 3.47 ships Swift Package Manager enabled BY DEFAULT on stable
// (features.dart: swiftPackageManager enabledByDefault: true), migrates a
// fresh clone at build time, and generates FlutterGeneratedPluginSwiftPackage
// at the macOS 12.0 floor (darwin.dart: macos => Version(12, 0, null)). The
// tool raises that floor to the app's 14.0 ONLY via a best-effort, silent
// `xcodebuild -showBuildSettings` read (build_macos.dart →
// updateMinimumDeployment; "showBuildSettings is reported to occasionally
// timeout"). On the Xcode 27 first run the read skipped, and the vendored
// flutter_inappwebview_macos — which rode SwiftPM because its Package.swift
// existed (deleted afterwards by gh-1798) — published a 14.0-flored product
// into the 12.0-floored generated package. Xcode hard-failed the build.
//
// The lane decision (gh-180 fix): the macOS release legs build PURE
// CocoaPods. `FLUTER_SWIFT_PACKAGE_MANAGER=0` at the build-macos job level
// turns the feature off for every flutter invocation in the job
// (flutter_features_config.dart: the env override is read per invocation),
// the migration then skips cleanly ("The Swift Package Manager feature is
// off. Skipping..."), and every macOS plugin is already pinned in
// macos/Podfile.lock. The Podfile platform (:osx, '14.0') — not a silent
// tool bump — becomes the authority for the effective pod floors.
//
// This suite pins the REG gate script that turns that decision into a loud,
// build-time invariant (scripts/assert_macos_min_platform.sh), invoked in
// the Build macOS release step AFTER `flutter build macos --config-only`
// (which drives the real tool's SPM/pods config pass without compiling):
//
//   AC1  a clean pods-lane tree passes (exit 0);
//   AC2  any SwiftPM re-entry fails loud with the gh-180 remediation —
//        either the FlutterGeneratedPluginSwiftPackage marker in the
//        pbxproj (env pin lost / tool default flipped) or a plugin that
//        regained its Package.swift (SwiftPM opt-in signal);
//   AC3  the literal gh-180 violation shape (generated package floor
//        12.0 + plugin product floor 14.0) fails with the specific floor
//        message, not just the generic lane message;
//   AC4  the floor scan covers EVERY package manifest under the generated
//        tree — a violation in a later manifest is caught too (a
//        single-item scan can pass while multi-item logic is broken);
//   AC5  app-floor drift fails: any MACOSX_DEPLOYMENT_TARGET ≠ 14.0 in
//        the pbxproj, or a Podfile platform ≠ 14.0;
//   AC6  a missing pbxproj/Podfile fails gracefully (no false green).
import 'dart:io';

import 'package:test/test.dart';

const scriptPath = 'scripts/assert_macos_min_platform.sh';
const appMin = '14.0';

/// A minimal Runner.xcodeproj shape the gate accepts: exactly the Runner
/// target's three configs (Debug/Release/Profile) carry the floor.
String pbxprojWith(String deploymentTargetLine) => '''
\t\t33CC10F9 /* Debug */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = $deploymentTargetLine;
\t\t\t};
\t\t\tname = Debug;
\t\t};
\t\t33CC10FA /* Release */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = $deploymentTargetLine;
\t\t\t};
\t\t\tname = Release;
\t\t};
\t\t338D0CE9 /* Profile */ = {
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = $deploymentTargetLine;
\t\t\t};
\t\t\tname = Profile;
\t\t};
''';

const cleanPodfile = "platform :osx, '14.0'\n";

Directory makeTree({required String pbxproj, required String podfile}) {
  final dir = Directory.systemTemp.createTempSync('fah_min_platform_gate');
  addTearDown(() => dir.deleteSync(recursive: true));
  File(
    '${dir.path}/flutter_app/macos/Runner.xcodeproj/project.pbxproj',
  ).createSync(recursive: true)
    ..writeAsStringSync(pbxproj);
  File('${dir.path}/flutter_app/macos/Podfile')
    ..createSync()
    ..writeAsStringSync(podfile);
  // The vendored plugin's SwiftPM manifest is the opt-in signal; the pods
  // lane keeps it deleted (gh-1798 AC1).
  Directory(
    '${dir.path}/vendor/flutter_inappwebview_macos/macos/flutter_inappwebview_macos',
  ).createSync(recursive: true);
  return dir;
}

void addSpmState(
  Directory tree, {
  String? generatedFloor,
  List<String> pluginFloors = const [],
  bool markerInPbxproj = true,
}) {
  if (markerInPbxproj) {
    final pbx = File(
      '${tree.path}/flutter_app/macos/Runner.xcodeproj/project.pbxproj',
    );
    pbx.writeAsStringSync(
      '${pbx.readAsStringSync()}\t\t\tproductName = '
      'FlutterGeneratedPluginSwiftPackage;\n',
    );
  }
  final pkgs =
      '${tree.path}/flutter_app/macos/Flutter/ephemeral/Packages';
  if (generatedFloor != null) {
    File(
      '$pkgs/FlutterGeneratedPluginSwiftPackage/Package.swift',
    ).createSync(recursive: true)
      ..writeAsStringSync(
        'let package = Package(\n  platforms: [.macOS("$generatedFloor")],\n)\n',
      );
  }
  for (var i = 0; i < pluginFloors.length; i++) {
    File('$pkgs/.packages/plugin_$i/Package.swift').createSync(recursive: true)
      ..writeAsStringSync(
        'let package = Package(\n  platforms: [.macOS("${pluginFloors[i]}")],\n)\n',
      );
  }
}

ProcessResult runGate(Directory tree, {String min = appMin}) {
  return Process.runSync(
    'bash',
    [scriptPath, min, tree.path],
    workingDirectory: tree.path,
  );
}

void main() {
  test('gate script exists and is executable', () {
    final script = File(scriptPath);
    expect(script.existsSync(), isTrue, reason: '$scriptPath must exist');
    // Executable bit: the workflow invokes it directly from the build step.
    final mode = FileStat.statSync(scriptPath).mode;
    expect(mode & 0o111, isNot(0), reason: '$scriptPath must be +x');
    final content = script.readAsStringSync();
    expect(content.startsWith('#!'), isTrue, reason: 'shebang required');
  });

  test('AC1 — clean pods-lane tree passes', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: cleanPodfile,
    );
    final r = runGate(tree);
    expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
    expect(r.stdout, contains('OK'));
  });

  test('AC2a — FlutterGeneratedPluginSwiftPackage in pbxproj fails loud '
      'with the lane remediation', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: cleanPodfile,
    );
    addSpmState(tree); // marker only — floors would all be fine
    final r = runGate(tree);
    expect(r.exitCode, 1, reason: 'SPM re-entry must fail the gate');
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('FLUTTER_SWIFT_PACKAGE_MANAGER'));
    expect(out, contains('Podfile.lock'));
  });

  test('AC2b — a plugin that regained Package.swift fails loud', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: cleanPodfile,
    );
    // Package.swift mere presence is the SwiftPM opt-in signal (gh-1798).
    File(
      '${tree.path}/vendor/flutter_inappwebview_macos/macos/'
      'flutter_inappwebview_macos/Package.swift',
    ).createSync()
      ..writeAsStringSync('// .macOS("14.0")\n');
    final r = runGate(tree);
    expect(r.exitCode, 1);
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('Package.swift'));
    expect(out, contains('pods'));
  });

  test('AC3 — the literal gh-180 shape (generated 12.0 + product 14.0) '
      'fails with the floor message', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: cleanPodfile,
    );
    addSpmState(
      tree,
      generatedFloor: '12.0',
      pluginFloors: ['14.0'],
    );
    final r = runGate(tree);
    expect(r.exitCode, 1);
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('14.0'));
    expect(out, contains('12.0'));
    expect(out, contains('minimum platform version'));
  });

  test('AC4 — floor scan catches a violation in a LATER manifest '
      '(multi-item)', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: cleanPodfile,
    );
    addSpmState(
      tree,
      generatedFloor: '14.0',
      // first two fine, violation third — a single-item scan would pass
      pluginFloors: ['10.15', '12.3', '15.0'],
    );
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('15.0'));
  });

  test('AC4b — generated floor below app floor with all products under it '
      'is reported but not fatal (no false red)', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: cleanPodfile,
    );
    addSpmState(
      tree,
      generatedFloor: '12.0',
      pluginFloors: ['10.15', '11.0'],
    );
    final r = runGate(tree);
    expect(r.exitCode, 0, reason: 'products ≤ floor builds fine; warn only');
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('12.0'));
  });

  test('AC5a — MACOSX_DEPLOYMENT_TARGET drift below the app floor fails',
      () {
    final tree = makeTree(
      pbxproj: pbxprojWith('13.0;'),
      podfile: cleanPodfile,
    );
    expect(runGate(tree).exitCode, 1);
  });

  test('AC5b — Podfile platform drift fails', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: "platform :osx, '10.15'\n",
    );
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('Podfile'));
  });

  test('AC6 — missing pbxproj fails gracefully', () {
    final tree = makeTree(pbxproj: '', podfile: cleanPodfile);
    File(
      '${tree.path}/flutter_app/macos/Runner.xcodeproj/project.pbxproj',
    ).deleteSync();
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('project.pbxproj'));
  });

  test('AC6b — missing Podfile fails gracefully', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: '');
    File('${tree.path}/flutter_app/macos/Podfile').deleteSync();
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('Podfile'));
  });

  test('the committed tree passes the gate (real repo state)', () {
    // The gate's default repo-root resolution: run it with no root arg from
    // the repo root — the state this task ships must be green by default.
    final r = Process.runSync('bash', [scriptPath, appMin]);
    expect(
      r.exitCode,
      0,
      reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}',
    );
  });
}
