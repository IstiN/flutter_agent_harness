import 'dart:io';

import 'package:test/test.dart';

/// Contract between the packaging script and the panel loader: the fa web
/// app bundle must live where `panel.js` actually resolves `app/index.html`
/// — relative to `panel/panel.html`, i.e. `browser_ext/panel/app/`. The
/// first cut bundled the app at the extension ROOT, the HEAD probe 404'd
/// and every build silently fell back to the basic panel.
void main() {
  final repoRoot = Directory.current.path;

  String read(String relative) =>
      File('$repoRoot/$relative').readAsStringSync();

  test('panel.js probes the panel-relative app bundle', () {
    final panel = read('browser_ext/panel/panel.js');
    expect(panel, contains("fetch('app/index.html'"));
    // The redirect (via the injectable __faRedirect seam) targets the
    // same panel-relative path.
    expect(panel, contains("'app/index.html')"));
  });

  test('the packaging script bundles the app where the panel probes it', () {
    final script = read('scripts/build_browser_ext.sh');
    expect(
      script,
      contains('--base-href=/panel/app/'),
      reason:
          'absolute asset URLs must resolve under chrome-extension://<id>'
          '/panel/app/',
    );
    expect(
      script,
      contains('browser_ext/panel/app'),
      reason: 'the bundle target the panel can actually see',
    );
    // A root-level copy would be dead weight the panel never loads.
    expect(
      script,
      isNot(contains('cp -R flutter_app/build/web/. browser_ext/app/')),
    );
    // The zip needs no separate root entry: panel/app rides in panel/.
    expect(script, isNot(contains(r'runtime="$runtime app"')));
  });

  // Issue #291 — Chrome Web Store rejects the zip when the staged panel
  // app still carries its Flutter PWA manifest ("More than one manifest
  // found in package"). The packaging script must strip it from the
  // STAGED copy only and guard the produced zip (behavioral coverage of
  // both lives in package_shape_guard_test.dart; this pins the wiring).
  test('packaging strips the PWA manifest from the staged app only (#291)', () {
    final script = read('scripts/build_browser_ext.sh');
    expect(
      script,
      contains('ext_package_guard.py strip browser_ext/panel/app'),
      reason: 'the staged bundle copy is stripped after it lands',
    );
    // Sources untouched: the strip never targets flutter_app/ — the
    // standalone web app / pages deploy keeps its PWA manifest.
    expect(script, isNot(contains('strip flutter_app')));
  });

  test(
    'packaging guards the zip shape — single manifest, hard fail (#291)',
    () {
      final script = read('scripts/build_browser_ext.sh');
      expect(
        script,
        contains('ext_package_guard.py check build/fa-extension.zip'),
        reason:
            'the CWS single-manifest rule must assert on the real '
            'artifact every build (with or without the bundled app)',
      );
      // The guard is a hard failure wired BEFORE the unpacked copy is
      // extracted (fail fast — a rejected zip must not ship as the
      // load-unpacked dir either).
      expect(
        script.indexOf('ext_package_guard.py check'),
        lessThan(script.indexOf('build/fa-extension/ (unpacked')),
      );
    },
  );
}
