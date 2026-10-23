// gh-1814 — the macOS desktop DMG lane (build-macos.yml) ADOPTS the SwiftPM
// lane. History: gh-180 pinned the release legs to PURE CocoaPods via
// FLUTTER_SWIFT_PACKAGE_MANAGER=0 because Flutter 3.47's best-effort,
// silent FlutterGeneratedPluginSwiftPackage floor bump
// (xcodebuild -showBuildSettings inside updateMinimumDeployment) skipped on
// the first Xcode 27 run and a 14.0-floored SwiftPM product died inside the
// 12.0-floored generated package. Upstream then REMOVED the disable knob
// between 3.47.4 and 3.47.7 (flutter/flutter#193978): on the pinned-3.47.7
// runners the --config-only pass adds SwiftPM integration no matter what
// (runs 39991663029 / 40022900373 — the latter AFTER the #1812 residue
// clean), and the gh-180 gate — which FORBADE any SwiftPM state — became
// the failure itself. The #1813 escape hatch (pin 3.47.4, the last
// flag-honoring patch) is operationally dead: the runners' ~60kB/s link
// cannot fetch that SDK (run 40034163885). Owner ruling (gh-1814): the
// minimum macOS version may be raised — adopt the SPM lane.
//
// Floor audit (gh-1814 step 1): the original gh-180 sub-14.0 target was the
// generated FlutterGeneratedPluginSwiftPackage at its 12.0 tool default
// (flutter_tools darwin.dart: macos => Version(12, 0, null)) with the
// silent bump skipped. On 3.47.7 the bump WORKS — the failing runs' gate
// diagnostic reported `generated floor: 14.0` — so every floor in the lane
// is already ≥ 14.0 and NO floor file needs raising:
//
//   - flutter_app/macos/Runner.xcodeproj/project.pbxproj — 3×14.0
//     (Runner Debug/Release/Profile; pinned by
//     test/build_macos_spm_lane_guard_test.dart AC3);
//   - flutter_app/macos/Podfile — platform :osx, '14.0' (the pods half of
//     the hybrid lane: the vendored flutter_inappwebview_macos keeps its
//     Package.swift deleted — gh-1798 — so it rides CocoaPods, pinned in
//     Podfile.lock at the podspec's 14.0 floor);
//   - the generated package floor — the tool raises it to the app's
//     MACOSX_DEPLOYMENT_TARGET via updateMinimumDeployment; the gate
//     asserts the bump landed (≥ APP_MIN) so a silent skip can never
//     resurrect the gh-180 Xcode error.
//
// This suite pins the rewritten REG gate
// (scripts/assert_macos_min_platform.sh) that ASSERTS the SPM lane. It
// runs in the Build macOS release step AFTER `flutter build macos
// --config-only` (which drives the tool's real SPM/pods config pass
// without compiling) and asserts, in order:
//
//   AC0  the script is present, +x, shebang'd, and does not advertise the
//        dead disable knob (no FLUTTER_SWIFT_PACKAGE_MANAGER=0
//        remediation — upstream removed it in 3.47.7, flutter/flutter#193978);
//   AC1  a post-config SPM tree PASSES: pbxproj marker + generated package
//        at the app floor, every product floor ≤ the app min (the gh-1814
//        happy path on 3.47.7);
//   AC2  a tree with NO SwiftPM state FAILS — the lane decision is
//        "SPM expected"; its absence means the migration did not run
//        (tool behavior changed) and must fail loud, not silently mean
//        the old pods lane;
//   AC3  a sub-app-min GENERATED floor fails (the tool's silent bump
//        skipped — the literal gh-180 killer);
//   AC4  the floor scan covers EVERY package manifest under the generated
//        tree — a product floor above the app min in a later manifest is
//        caught too (a single-item scan can pass while multi-item logic
//        is broken);
//   AC5  the vendored plugin's Package.swift (if it ever reappears) is
//        floored AT the app min — sub-floor fails ("raise it"), above-app
//        fails ("exceeds the app min"); its mere PRESENCE is no longer a
//        violation;
//   AC6  a half-migrated tree fails: pbxproj marker without the generated
//        package, or the generated package without the marker;
//   AC7  app-floor drift still fails: any MACOSX_DEPLOYMENT_TARGET ≠ 14.0
//        in the pbxproj, or a Podfile platform ≠ 14.0;
//   AC8  a missing pbxproj/Podfile fails gracefully (no false green);
//   AC9  the committed floors PASS once the tool's migration state is
//        materialized on top (asserted against HEAD, not the live tree —
//        a local SwiftPM-enabled build migrates the checkout in place).
import 'dart:io';

import 'package:test/test.dart';

const scriptPath = 'scripts/assert_macos_min_platform.sh';
const appMin = '14.0';

/// A minimal Runner.xcodeproj shape the gate accepts: exactly the Runner
/// target's three configs (Debug/Release/Profile) carry the floor.
String pbxprojWith(String deploymentTargetLine) =>
    '''
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
  final pbxprojFile = File(
    '${dir.path}/flutter_app/macos/Runner.xcodeproj/project.pbxproj',
  )..createSync(recursive: true);
  pbxprojFile.writeAsStringSync(pbxproj);
  File('${dir.path}/flutter_app/macos/Podfile')
    ..createSync()
    ..writeAsStringSync(podfile);
  // The vendored plugin rides the CocoaPods half of the hybrid lane: its
  // SwiftPM manifest stays deleted (gh-1798; pinned by
  // test/inappwebview_macos_pods_lane_test.dart AC1).
  Directory(
    '${dir.path}/vendor/flutter_inappwebview_macos/macos/flutter_inappwebview_macos',
  ).createSync(recursive: true);
  return dir;
}

/// Materialize the SwiftPM state `flutter build macos --config-only`
/// generates on 3.47.7: the FlutterGeneratedPluginSwiftPackage marker in
/// the pbxproj plus the ephemeral generated package tree.
void addSpmState(
  Directory tree, {
  String? generatedFloor = appMin,
  List<String> productFloors = const [],
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
  if (generatedFloor != null) {
    final pkgs = '${tree.path}/flutter_app/macos/Flutter/ephemeral/Packages';
    final generated = File(
      '$pkgs/FlutterGeneratedPluginSwiftPackage/Package.swift',
    )..createSync(recursive: true);
    generated.writeAsStringSync(
      'let package = Package(\n  platforms: [.macOS("$generatedFloor")],\n)\n',
    );
  }
  for (var i = 0; i < productFloors.length; i++) {
    final plugin = File(
      '${tree.path}/flutter_app/macos/Flutter/ephemeral/Packages'
      '/.packages/plugin_$i/Package.swift',
    )..createSync(recursive: true);
    plugin.writeAsStringSync(
      'let package = Package(\n  platforms: [.macOS("${productFloors[i]}")],\n)\n',
    );
  }
}

void writeVendoredPackageSwift(Directory tree, String floor) {
  final vendored = File(
    '${tree.path}/vendor/flutter_inappwebview_macos/macos/'
    'flutter_inappwebview_macos/Package.swift',
  )..createSync();
  vendored.writeAsStringSync(
    'let package = Package(\n  platforms: [.macOS("$floor")],\n)\n',
  );
}

ProcessResult runGate(Directory tree, {String min = appMin}) {
  return Process.runSync('bash', [
    File(scriptPath).absolute.path,
    min,
    tree.path,
  ], workingDirectory: tree.path);
}

void main() {
  test('AC0a — gate script exists and is executable', () {
    final script = File(scriptPath);
    expect(script.existsSync(), isTrue, reason: '$scriptPath must exist');
    // Executable bit: the workflow invokes it directly from the build step.
    final mode = FileStat.statSync(scriptPath).mode;
    expect(
      mode & 0x49,
      isNot(0),
      reason: '$scriptPath must be +x (0o111 exec bits)',
    );
    final content = script.readAsStringSync();
    expect(content.startsWith('#!'), isTrue, reason: 'shebang required');
  });

  test('AC0b — the gate never advertises the DEAD SwiftPM disable knob; '
      'the real env override is FLUTTER_SWIFT_PACKAGE_MANAGER and no '
      '28-char FLUTER_ misspelling may re-enter the tree', () {
    // flutter_tools consulted exactly one environment override for the
    // SwiftPM feature — FLUTTER_SWIFT_PACKAGE_MANAGER (29 chars;
    // packages/flutter_tools/lib/src/features.dart, environmentOverride).
    // Flutter 3.47.7 removed the knob entirely (flutter/flutter#193978):
    // a "=0" remediation is now a no-op instruction, and a 28-char FLUTER_
    // spelling (missing a T) never was anything but a no-op. These files
    // are what gets copied on the failure path, so neither may re-enter.
    // Built by surgery, not a literal: this file is scanned too.
    final misspelled = 'FLUTTER_SWIFT_PACKAGE_MANAGER'.replaceFirst(
      'FLUTTER',
      'FLUTER',
    );
    const documented = [
      'scripts/assert_macos_min_platform.sh',
      'test/macos_min_platform_gate_test.dart',
      'test/build_macos_spm_lane_guard_test.dart',
    ];
    for (final path in documented) {
      expect(
        File(path).readAsStringSync().contains(misspelled),
        isFalse,
        reason:
            '$path spells the SwiftPM env override "$misspelled" '
            '(28 chars, missing a T) — the tool read '
            'FLUTTER_SWIFT_PACKAGE_MANAGER (29 chars); the misspelled '
            'name was always a no-op pin',
      );
    }
    final script = File(scriptPath).readAsStringSync();
    expect(
      script.contains('FLUTTER_SWIFT_PACKAGE_MANAGER=0'),
      isFalse,
      reason:
          'the gate must not remediate with FLUTTER_SWIFT_PACKAGE_MANAGER=0 '
          '— Flutter 3.47.7 removed the disable knob '
          '(flutter/flutter#193978); instructing an operator to set it '
          'would send them chasing a no-op (gh-1814: the SPM lane is '
          'adopted, not suppressed)',
    );
  });

  test('AC1 — a post-config SPM tree with all floors at/below the app min '
      'PASSES (the gh-1814 happy path on 3.47.7)', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(
      tree,
      generatedFloor: '14.0',
      // Sub-app-min product floors are FINE on the SPM lane: a product
      // requiring ≤ 14.0 builds inside a 14.0-floored package consumed by
      // a 14.0-floored app target.
      productFloors: ['10.15', '12.3'],
    );
    final r = runGate(tree);
    expect(
      r.exitCode,
      0,
      reason:
          'SPM state is the adopted lane — expected floor-clean state must '
          'pass. stdout: ${r.stdout}\nstderr: ${r.stderr}',
    );
    expect(r.stdout, contains('OK'));
  });

  test('AC1b — SPM state with ONLY the generated package (no product '
      'manifests) passes', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: '14.0');
    final r = runGate(tree);
    expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
    expect(r.stdout, contains('OK'));
  });

  test('AC2 — a tree with NO SwiftPM state after the config pass FAILS: '
      'the lane decision is SPM-expected, absence is loud', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    final r = runGate(tree);
    expect(
      r.exitCode,
      1,
      reason:
          'the build-macos lane adopted SwiftPM (gh-1814): if the '
          '--config-only pass produced no SwiftPM state, the migration did '
          'not run (tool behavior changed) — that must fail loud, never '
          'silently pass as the retired pods-only lane',
    );
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('Swift Package Manager'));
    expect(out, contains('gh-1814'));
  });

  test('AC3 — generated floor below the app min fails (the tool\'s silent '
      'bump skipped — the literal gh-180 killer)', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: '12.0', productFloors: ['14.0']);
    final r = runGate(tree);
    expect(r.exitCode, 1);
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('12.0'));
    expect(out, contains('14.0'));
    // The gh-180 error shape this prevents: a package product requiring a
    // floor above the target's.
    expect(out, contains('minimum platform version'));
  });

  test('AC4 — floor scan catches a product above the app min in a LATER '
      'manifest (multi-item)', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(
      tree,
      generatedFloor: '14.0',
      // first two fine, violation third — a single-item scan would pass
      productFloors: ['10.15', '12.3', '15.0'],
    );
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('15.0'));
  });

  test('AC5a — vendored Package.swift at the app floor is no longer a '
      'violation (presence is fine on the SPM lane)', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: '14.0');
    writeVendoredPackageSwift(tree, '14.0');
    final r = runGate(tree);
    expect(
      r.exitCode,
      0,
      reason:
          'gh-1814 adopts the SPM lane: a correctly-floored vendored '
          'manifest must not fail the gate. stdout: ${r.stdout}\n'
          'stderr: ${r.stderr}',
    );
  });

  test('AC5b — vendored Package.swift below the app min fails with the '
      'raise-the-floor remediation', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: '14.0');
    writeVendoredPackageSwift(tree, '12.0');
    final r = runGate(tree);
    expect(r.exitCode, 1);
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('12.0'));
    expect(out, contains('14.0'));
  });

  test('AC5c — vendored Package.swift above the app min fails', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: '14.0');
    writeVendoredPackageSwift(tree, '15.0');
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('15.0'));
  });

  test('AC6a — pbxproj marker without the generated package fails '
      '(half-migrated tree)', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: null); // marker only, no ephemeral tree
    final r = runGate(tree);
    expect(r.exitCode, 1);
    final out = '${r.stdout}${r.stderr}';
    expect(out, contains('ephemeral'));
  });

  test('AC6b — generated package without the pbxproj marker fails '
      '(half-migrated tree)', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: '14.0', markerInPbxproj: false);
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('FlutterGeneratedPluginSwiftPackage'));
  });

  test('AC7a — MACOSX_DEPLOYMENT_TARGET drift below the app floor fails', () {
    final tree = makeTree(pbxproj: pbxprojWith('13.0;'), podfile: cleanPodfile);
    addSpmState(tree, generatedFloor: '14.0');
    expect(runGate(tree).exitCode, 1);
  });

  test('AC7b — Podfile platform drift fails', () {
    final tree = makeTree(
      pbxproj: pbxprojWith('14.0;'),
      podfile: "platform :osx, '10.15'\n",
    );
    addSpmState(tree, generatedFloor: '14.0');
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('Podfile'));
  });

  test('AC8 — missing pbxproj fails gracefully', () {
    final tree = makeTree(pbxproj: '', podfile: cleanPodfile);
    File(
      '${tree.path}/flutter_app/macos/Runner.xcodeproj/project.pbxproj',
    ).deleteSync();
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('project.pbxproj'));
  });

  test('AC8b — missing Podfile fails gracefully', () {
    final tree = makeTree(pbxproj: pbxprojWith('14.0;'), podfile: '');
    File('${tree.path}/flutter_app/macos/Podfile').deleteSync();
    final r = runGate(tree);
    expect(r.exitCode, 1);
    expect('${r.stdout}${r.stderr}', contains('Podfile'));
  });

  test('AC9 — the committed floors PASS the gate once the tool\'s SPM '
      'migration state is materialized on top (asserted against HEAD, not '
      'the live working tree)', () {
    // A local SwiftPM-enabled flutter build migrates the checkout IN PLACE
    // (the pbxproj gains the FlutterGeneratedPluginSwiftPackage marker and
    // the gitignored Flutter/ephemeral/Packages tree appears) without
    // changing what SHIPS. So the gate inputs are materialized from the
    // COMMITTED state (git show HEAD:) into a temp repo root, plus the
    // exact SPM state the tool's --config-only pass generates on 3.47.7
    // (marker + generated package at the app floor) — host-state
    // independent, identical on Linux CI and on a migrated macOS checkout.
    // The gate is a POST-CONFIG gate: it asserts the state the config pass
    // must produce, so the test produces it explicitly.
    String headFile(String relPath) {
      final r = Process.runSync('git', ['show', 'HEAD:$relPath']);
      expect(
        r.exitCode,
        0,
        reason: 'git show HEAD:$relPath failed: ${r.stderr}',
      );
      return r.stdout as String;
    }

    const pbxprojRel = 'flutter_app/macos/Runner.xcodeproj/project.pbxproj';
    const podfileRel = 'flutter_app/macos/Podfile';
    const vendoredRel =
        'vendor/flutter_inappwebview_macos/macos/'
        'flutter_inappwebview_macos/Package.swift';

    final tree = Directory.systemTemp.createTempSync('fah_min_platform_head');
    addTearDown(() => tree.deleteSync(recursive: true));
    File('${tree.path}/$pbxprojRel')
      ..createSync(recursive: true)
      ..writeAsStringSync(headFile(pbxprojRel));
    File('${tree.path}/$podfileRel')
      ..createSync(recursive: true)
      ..writeAsStringSync(headFile(podfileRel));
    // The vendored SwiftPM manifest stays deleted on the hybrid lane
    // (gh-1798); materialize it only if HEAD regressed to tracking it, so
    // a committed re-opt-in still gets its floor audited here.
    // flutter_app/macos/Flutter/ephemeral/ is gitignored — never in HEAD —
    // so its absence in the temp root IS the committed state.
    final vendoredInHead = Process.runSync('git', [
      'cat-file',
      '-e',
      'HEAD:$vendoredRel',
    ]);
    if (vendoredInHead.exitCode == 0) {
      final content = headFile(vendoredRel);
      File('${tree.path}/$vendoredRel')
        ..createSync(recursive: true)
        ..writeAsStringSync(content);
      // If HEAD re-adds the manifest, its floor must parse so AC9 can
      // assert it at the app min via the same materialized-SPM-state run
      // below (the gate audits it).
      expect(content, contains('.macOS'));
    }

    // The tool-generated post-config state on 3.47.7 (the bump works —
    // failing-run diagnostics reported `generated floor: 14.0`).
    addSpmState(tree, generatedFloor: appMin);

    final r = runGate(tree);
    expect(r.exitCode, 0, reason: 'stdout: ${r.stdout}\nstderr: ${r.stderr}');
  });
}
