// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit coverage for the per-build engine asset selection (gh-1630 I3/I4):
// hosted web builds resolve the interpreters from public CDNs, the
// extension build (FA_HOST=extension, set by scripts/build_browser_ext.sh)
// resolves the SAME engines from the package-local, sha-verified
// vendor/interpreters/ dir. The compile-time branch elimination itself is
// proven at the artifact level: test/browser_ext/cws_compliance_test.dart
// plus the packaging guard scan the compiled bundle for remote markers.
import 'package:fa/sandbox/web_interpreters_urls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('interpreter asset selection (gh-1630 I3/I4)', () {
    test('test/default builds are NOT the extension build', () {
      // This suite runs without --dart-define=FA_HOST=extension, so the
      // gate must resolve to the hosted-web branch here. (The extension
      // branch is asserted structurally below and empirically by the
      // packaging guard on the compiled bundle.)
      expect(kFaExtBuild, isFalse);
      final assets = interpreterAssets();
      expect(assets.quickJsScript, startsWith('https://cdn.jsdelivr.net/'));
      expect(assets.pyodideScript, startsWith('https://cdn.jsdelivr.net/'));
      expect(assets.pyodideIndex, startsWith('https://cdn.jsdelivr.net/'));
      expect(assets.sqlJsScript, startsWith('https://cdn.jsdelivr.net/'));
    });

    test('extension asset paths are package-relative and lock-shaped', () {
      // The paths must mirror browser_ext/vendor.lock.json's interpreters
      // layout (fetched by scripts/fetch_vendor_assets.sh) and stay
      // package-relative: sw/agent.js and the panel app both live two
      // levels below the extension root.
      const assets = extInterpreterAssets;
      for (final path in [
        assets.quickJsScript,
        assets.pyodideScript,
        assets.sqlJsScript,
      ]) {
        expect(path, startsWith('../../vendor/interpreters/'),
            reason: '$path must resolve into the package-local vendor dir');
        expect(path, isNot(contains('://')),
            reason: '$path must not be a remote URL');
      }
      // pyodide's indexURL is the DIRECTORY holding pyodide.asm.wasm and
      // python_stdlib.zip (E2: an explicit base, never a remote default).
      expect(assets.pyodideIndex, '../../vendor/interpreters/');
      expect(assets.sqlJsDist, '../../vendor/interpreters/');
    });

    test('the CDN set keeps the exact pre-gh-1630 URLs (no behavior drift '
        'on the hosted web app)', () {
      const assets = cdnInterpreterAssets;
      expect(
        assets.quickJsScript,
        'https://cdn.jsdelivr.net/npm/quickjs-emscripten@0.31.0/'
        'dist/index.global.js',
      );
      expect(assets.pyodideScript,
          'https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js');
      expect(assets.pyodideIndex,
          'https://cdn.jsdelivr.net/pyodide/v0.26.4/full/');
      expect(assets.sqlJsScript,
          'https://cdn.jsdelivr.net/npm/sql.js@1.14.1/dist/sql-wasm.js');
      expect(
          assets.sqlJsDist, 'https://cdn.jsdelivr.net/npm/sql.js@1.14.1/dist/');
    });
  });
}
