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

const dartGate = 'flutter_app/lib/sandbox/fs_persistence_web.dart';
const helperJs = 'flutter_app/web/fs_store.js';
const indexHtml = 'flutter_app/web/index.html';

void main() {
  test('the loader no longer probes the never-defined _fahFsGetAllDefined',
      () {
    final source = File(dartGate).readAsStringSync();
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
    final source = File(dartGate).readAsStringSync();
    final probed = RegExp(
      r"hasProperty\('(__fahFs\w+)'\)",
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
