// gh-1831 — the web sandbox FS loader must probe the helper surface
// `web/fs_store.js` actually ships.
//
// `IdbFsSnapshotStore._ensureScript` used to probe
// `window._fahFsGetAllDefined`, a global fs_store.js has NEVER defined: the
// probe read `undefined` on every call, the loader re-injected the (already
// loaded!) script and then still concluded "fs_store.js is not loaded" and
// threw — so every save/remove on every web host failed with
// `[fah] sandbox persist failed (changes NOT saved)` while the helper sat
// right there in the page (the deployed fa1.dev serves the file with 200).
// The fix probes the functions the helper defines
// (`__fahFsGetAll`/`__fahFsSet`/`__fahFsRemove`) via `window.hasProperty`.
//
// Deliberately static asserts over the committed sources (the
// jsr_host_call_pin_guard_test.dart pattern) so the guard runs on the bare
// ubuntu shards without a browser: the Dart probe and the JS helper must
// stay in sync, and the never-defined-global probe must stay gone.
import 'dart:io';

import 'package:test/test.dart';

/// The flutter_app root, located by walking up from the cwd (under
/// `flutter test` the cwd is flutter_app) — the android_icon_test.dart
/// convention; Platform.script points into .dart_tool and is not stable.
String get _appRoot {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/ios').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate the flutter_app root from ${Directory.current}');
    }
    dir = parent;
  }
}

String get dartGate => '$_appRoot/lib/sandbox/fs_persistence_web.dart';
String get helperJs => '$_appRoot/web/fs_store.js';
String get indexHtml => '$_appRoot/web/index.html';

void main() {
  /// Masks `//`/`///` comments and `/* */` blocks so the guard asserts
  /// over CODE: the historical note in `_helperDefined`'s doc comment is
  /// allowed to name the dead global, the probe itself is not.
  String code(String source) {
    final withoutBlocks = source.replaceAll(
      RegExp(r'/\*.*?\*/', dotAll: true),
      '',
    );
    return withoutBlocks
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'(?<!:)//.*$'), ''))
        .join('\n');
  }

  test('the loader no longer probes the never-defined _fahFsGetAllDefined',
      () {
    final source = code(File(dartGate).readAsStringSync());
    expect(
      source,
      isNot(contains('_fahFsGetAllDefined')),
      reason:
          'window._fahFsGetAllDefined does not exist (fs_store.js never '
          'defined it) — probing it always reports "not loaded" and kills '
          'every web sandbox save (gh-1831). Probe the __fahFs* functions '
          'the helper actually defines instead.',
    );
  });

  test('the Dart gate probes exactly the helper surface fs_store.js defines',
      () {
    final source = code(File(dartGate).readAsStringSync());
    final probed = RegExp(
      r"hasProperty\('(__fahFs\w+)'\.toJS\)",
    ).allMatches(source).map((m) => m.group(1)!).toSet();

    expect(
      probed,
      isNotEmpty,
      reason: 'the gate must probe the __fahFs* helper surface '
          '(window.hasProperty) — that is the only contract fs_store.js '
          'ships',
    );

    final js = File(helperJs).readAsStringSync();
    for (final name in probed) {
      expect(
        js,
        contains('window.$name = function'),
        reason:
            'fs_persistence_web.dart gates on window.$name but '
            '$helperJs does not define it — a drifted helper makes the '
            'loader throw "fs_store.js is not loaded" on every web host '
            '(the gh-1831 outage)',
      );
    }
  });

  test('the helper defines the full surface the store calls', () {
    final source = File(dartGate).readAsStringSync();
    final js = File(helperJs).readAsStringSync();
    // Every __fahFs* external binding in the Dart file must exist in the
    // helper — the @JS('__fahFsXxx') names are the store's actual calls.
    final bound = RegExp(
      r"@JS\('(__fahFs\w+)'\)",
    ).allMatches(source).map((m) => m.group(1)!).toSet();
    expect(
      bound,
      containsAll(['__fahFsGetAll', '__fahFsSet', '__fahFsRemove']),
      reason: 'the store calls load/save/remove — the surface check must '
          'cover exactly these',
    );
    for (final name in bound) {
      expect(js, contains('window.$name = function'));
    }
  });

  test('the shipped index.html still includes the fs_store.js script tag',
      () {
    final html = File(indexHtml).readAsStringSync();
    expect(
      html,
      contains('<script src="fs_store.js"></script>'),
      reason: 'the on-demand injection is a FALLBACK for stale bundles '
          '(issue #470); a healthy deploy ships the tag',
    );
  });
}
