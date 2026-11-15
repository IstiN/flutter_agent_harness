// #2132 — the shipped non-sandboxed macOS app is pinned end to end:
//
//   AC3 (golden)  ReleaseNoSandbox.entitlements declares EXACTLY the
//                 shipped trio {cs.allow-jit, network.client,
//                 network.server} — app-sandbox absent, and the stale
//                 personal-information / healthkit / homekit claims
//                 absent (they are sandbox-scoped or iOS-only and poison
//                 profile-free Developer ID notarization). The Debug twin
//                 matches. The pipeline half of AC3 (assertion over the
//                 SIGNED binary) lives in build_macos_nosandbox.sh and is
//                 pinned by the script-order test below.
//   AC6 (REG)     the sandboxed dev configs stay untouched: Release and
//                 Debug entitlements keep app-sandbox + the shared app
//                 group, and the pbxproj keeps their pins.
//   Wiring        ReleaseNoSandbox.entitlements is REFERENCED by the Xcode
//                 project — a real `ReleaseNoSandbox` build configuration
//                 (cloned from Release) pins it for project, Runner and
//                 Flutter Assemble targets.
//   Leg shape     the workflow notarizes + staples the no-sandbox DMG with
//                 the same signed-path gating and graceful-skip semantics
//                 as the sandboxed "Notarize DMG" step, and the prune runs
//                 INSIDE the script BEFORE the re-sign (pruning a signed
//                 bundle breaks the seal — the shipped-tree order).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const workflowPath = '.github/workflows/build-macos.yml';
const scriptPath = 'flutter_app/scripts/build_macos_nosandbox.sh';
const pbxprojPath = 'flutter_app/macos/Runner.xcodeproj/project.pbxproj';
const runnerDir = 'flutter_app/macos/Runner';

const shippedKeys = [
  'com.apple.security.cs.allow-jit',
  'com.apple.security.network.client',
  'com.apple.security.network.server',
];
const forbiddenKeys = [
  'com.apple.security.app-sandbox',
  'personal-information',
  'healthkit',
  'homekit',
];

String read(String path) => File(path).readAsStringSync();

/// Top-level entitlement keys of a plist entitlements file, extracted the
/// text way: every `<key>…</key>` that sits at dict depth (the files are
/// flat — no nested dicts but the app-groups array, whose entries are
/// `<string>` elements, never `<key>`). XML comments are stripped first —
/// a future comment containing a literal `<key>…</key>` must not pollute
/// the count (review 5876405113, digest 3).
List<String> entitlementKeys(String text) {
  final withoutComments = text.replaceAll(
    RegExp('<!--.*?-->', dotAll: true),
    '',
  );
  final keys = <String>[];
  final pattern = RegExp(r'<key>([^<]+)</key>');
  for (final match in pattern.allMatches(withoutComments)) {
    keys.add(match.group(1)!);
  }
  return keys;
}

void expectPlistShape(String text, String path) {
  expect(text.startsWith('<?xml'), isTrue, reason: '$path must be XML plist');
  expect(text, contains('<plist version="1.0">'), reason: path);
  expect(text, contains('<dict>'), reason: path);
}

YamlMap _buildMacosJob() {
  final jobs = (loadYaml(read(workflowPath)) as YamlMap)['jobs'] as YamlMap;
  return jobs['build-macos'] as YamlMap;
}

YamlMap? _step(YamlMap job, String name) {
  for (final s in (job['steps'] as YamlList).whereType<YamlMap>()) {
    if (s['name']?.toString() == name) return s;
  }
  return null;
}

void main() {
  test(
    'AC3 — ReleaseNoSandbox.entitlements is exactly the shipped trio (golden)',
    () {
      final text = read('$runnerDir/ReleaseNoSandbox.entitlements');
      expectPlistShape(text, 'ReleaseNoSandbox.entitlements');
      final keys = entitlementKeys(text);
      for (final key in shippedKeys) {
        expect(
          keys,
          contains(key),
          reason:
              'the shipped no-sandbox app needs $key '
              '(hardened-runtime JIT for the Flutter engine, host-shell '
              'network surfaces)',
        );
      }
      expect(
        keys.length,
        shippedKeys.length,
        reason:
            'the shipped set must be EXACTLY the trio — found $keys '
            '(#2132: stale claims poison notarization)',
      );
      for (final bad in forbiddenKeys) {
        expect(
          keys.where((k) => k.contains(bad)),
          isEmpty,
          reason: '$bad must not be declared by the shipped no-sandbox app',
        );
      }
    },
  );

  test('AC3 — the DebugNoSandbox twin matches the shipped set', () {
    final text = read('$runnerDir/DebugNoSandbox.entitlements');
    expectPlistShape(text, 'DebugNoSandbox.entitlements');
    final keys = entitlementKeys(text);
    expect(keys, shippedKeys);
    for (final bad in forbiddenKeys) {
      expect(keys.where((k) => k.contains(bad)), isEmpty);
    }
  });

  test('AC6 — sandboxed dev entitlements stay untouched (REG)', () {
    final release = entitlementKeys(read('$runnerDir/Release.entitlements'));
    expect(
      release,
      contains('com.apple.security.app-sandbox'),
      reason: 'the sandboxed Release config is dev/store-future — keep it',
    );
    expect(
      release,
      contains('com.apple.security.application-groups'),
      reason: 'the shared App Group (CLI <-> app sessions) rides Release',
    );
    final debug = entitlementKeys(read('$runnerDir/Debug.entitlements'));
    expect(debug, contains('com.apple.security.app-sandbox'));
  });

  test('Wiring — the pbxproj references ReleaseNoSandbox.entitlements', () {
    final pbx = read(pbxprojPath);
    expect(
      pbx,
      contains(
        'CODE_SIGN_ENTITLEMENTS = Runner/ReleaseNoSandbox.entitlements;',
      ),
      reason:
          'the entitlements file must be wired into a real build '
          'configuration — an orphaned file is what #2132 is about',
    );
    // The cloned Release configuration exists for project, Runner and
    // Flutter Assemble targets (xcodebuild -configuration ReleaseNoSandbox
    // resolves all three; the backend maps the name to release mode).
    expect(
      RegExp('name = ReleaseNoSandbox;').allMatches(pbx).length,
      3,
      reason: 'project + Runner + Flutter Assemble need the configuration',
    );
    // The sandboxed pins stay (AC6): exactly one Release pin, Debug and
    // DebugProfile intact.
    expect(
      RegExp(
        'CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;',
      ).allMatches(pbx).length,
      1,
    );
    expect(
      pbx,
      contains('CODE_SIGN_ENTITLEMENTS = Runner/Debug.entitlements;'),
    );
    expect(
      pbx,
      contains('CODE_SIGN_ENTITLEMENTS = Runner/DebugProfile.entitlements;'),
    );
    // The entitlements file is a project file reference (group member).
    expect(
      pbx,
      contains('ReleaseNoSandbox.entitlements */ = {isa = PBXFileReference;'),
    );
  });

  test(
    'Leg shape — the no-sandbox DMG is notarized + stapled like the sandboxed one',
    () {
      final job = _buildMacosJob();
      final steps = (job['steps'] as YamlList).map((s) {
        return s is YamlMap ? s['name']?.toString() : null;
      }).toList();

      final buildIdx = steps.indexOf('Build and package no-sandbox release');
      final notarizeIdx = steps.indexOf('Notarize no-sandbox DMG');
      final uploadIdx = steps.indexOf('Upload no-sandbox macOS artifacts');
      expect(buildIdx, greaterThan(-1));
      expect(
        notarizeIdx,
        greaterThan(-1),
        reason:
            'the no-sandbox DMG must be notarized — an unstapled DMG is a '
            'Gatekeeper block for every user (#2132 AC2)',
      );
      expect(
        notarizeIdx,
        greaterThan(buildIdx),
        reason: 'notarization needs the packaged DMG',
      );
      expect(
        uploadIdx,
        greaterThan(notarizeIdx),
        reason: 'the artifact upload must carry the stapled DMG',
      );

      final notarize = _step(job, 'Notarize no-sandbox DMG')!;
      expect(
        notarize['if']?.toString(),
        "steps.signing.outputs.signed == 'true'",
        reason: 'mirror the sandboxed leg: notarize only on the signed path',
      );
      final run = notarize['run']?.toString() ?? '';
      // Optional secrets degrade gracefully — byte-shape of the sandboxed
      // step's skip guard (a run without notarization secrets must stay
      // green and loud, never red the release leg).
      expect(run, contains(r'-z "$MACOS_NOTARIZE_APPLE_ID"'));
      expect(run, contains('exit 0'));
      expect(
        run,
        contains('xcrun notarytool submit "flutter_app/\$DMG_NAME"'),
        reason: 'the no-sandbox DMG is staged in flutter_app/',
      );
      expect(run, contains('--wait'));
      expect(run, contains('xcrun stapler staple'));
    },
  );

  test('Consume — the leg builds the ReleaseNoSandbox configuration '
      '(review 5876405113: the wired config is the BUILT config)', () {
    final script = read(scriptPath);
    final configOnly = script.indexOf('flutter build macos --config-only');
    final gate = script.indexOf('scripts/assert_macos_min_platform.sh 14.0');
    final consume = script.indexOf('-configuration ReleaseNoSandbox');
    expect(
      configOnly,
      greaterThan(-1),
      reason:
          'the leg runs the same tool config pass as the sandboxed leg '
          '(SPM migration + pod install) — the xcodebuild below consumes '
          'its Generated.xcconfig + integrated Pods',
    );
    expect(
      gate,
      greaterThan(configOnly),
      reason:
          'the gh-1814 gate must see the post-config state before '
          'any compile minute is spent (sandboxed-leg AC2 doctrine)',
    );
    expect(
      consume,
      greaterThan(gate),
      reason:
          'the real compile must invoke xcodebuild with '
          '-configuration ReleaseNoSandbox — a configuration CI never '
          'builds cannot be gated by CI (review 5876405113 gating '
          'issue: the config was consumed by no build path)',
    );
    expect(
      script,
      contains('APP="build/macos/Build/Products/ReleaseNoSandbox/Fa.app"'),
      reason:
          'the shipped app is the ReleaseNoSandbox product, not the '
          'mode-mapped Release one',
    );
  });

  test(
    'Seal order — prune runs inside the script BEFORE the re-sign (and not in the workflow step)',
    () {
      final script = read(scriptPath);
      final build = script.indexOf('-configuration ReleaseNoSandbox');
      final prune = script.indexOf('prune_flutter_assets.sh');
      final resign = script.indexOf('codesign --force');
      expect(build, greaterThan(-1));
      expect(
        prune,
        greaterThan(build),
        reason: 'the prune needs the built app',
      );
      expect(
        resign,
        greaterThan(prune),
        reason:
            'pruning a SIGNED bundle breaks the seal (missing sealed '
            'resource) — the re-sign must cover the shipped tree (#2132)',
      );

      // AC3 pipeline half: the script ASSERTS the signed entitlement set.
      final assertBlock = script.indexOf('AC3 pipeline assertion');
      expect(assertBlock, greaterThan(resign));
      expect(script, contains('codesign -d --entitlements :-'));
      expect(
        script,
        contains(
          "for BAD in app-sandbox personal-information healthkit homekit; do",
        ),
      );
      expect(script, contains("grep -q 'cs.allow-jit'"));

      final job = _buildMacosJob();
      final run =
          _step(
            job,
            'Build and package no-sandbox release',
          )!['run']?.toString() ??
          '';
      expect(
        run.contains('bash ../scripts/prune_flutter_assets.sh'),
        isFalse,
        reason:
            'the prune is single-owned by the script (before the re-sign) '
            '— a workflow-level prune would re-introduce the broken-seal '
            'order',
      );
    },
  );
}
