// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/relay/relay_probe.dart' show kFaBuildHost;

/// gh-1630 (I3/I4) — per-build engine asset URLs for [WebInterpreters].
///
/// The plain web build (fa1.dev) and the Office taskpane load pyodide /
/// quickjs / sql.js from public CDNs — remote code is fine there and keeps
/// the app bundle small. The EXTENSION package (`--dart-define=FA_HOST=
/// extension`, set by scripts/build_browser_ext.sh) must carry no remote
/// code (CWS Blue Argon) and its CSP forbids remote scripts anyway — the
/// same engines ship inside the package under `vendor/interpreters/`
/// (fetched and sha-verified from browser_ext/vendor.lock.json by
/// scripts/fetch_vendor_assets.sh), so the extension build compiles ONLY
/// the package-relative paths. The CDN constants below are tree-shaken
/// out of the compiled extension bundle (dart2js drops the unreachable
/// const branch of [interpreterAssets]); the packaging guard asserts the
/// compiled artifact stays free of remote markers (gh-1630 AC1/AC7).
///
/// `kFaBuildHost` is compile-time truth, exactly like the Office host
/// flag (office_boot_web.dart): the deployed bundle ALWAYS carries the
/// define, so no runtime probing is needed.

/// True only in the extension build (FA_HOST=extension).
const kFaExtBuild = kFaBuildHost == 'extension';

/// Immutable asset-location set for the three run_script interpreters.
class InterpreterAssets {
  const InterpreterAssets({
    required this.quickJsScript,
    required this.pyodideScript,
    required this.pyodideIndex,
    required this.sqlJsScript,
    required this.sqlJsDist,
  });

  /// quickjs-emscripten's `index.global.js` (defines `window.__fahQjs*`).
  final String quickJsScript;

  /// pyodide's `pyodide.js` bootstrap script.
  final String pyodideScript;

  /// pyodide indexURL — the directory holding pyodide.asm.wasm,
  /// python_stdlib.zip and pyodide-lock.json. ALWAYS passed explicitly to
  /// `loadPyodide`: a wrong base must fail loudly naming the missing
  /// asset, not silently fall back to a remote default (gh-1630 E2).
  final String pyodideIndex;

  /// sql.js' `sql-wasm.js` bootstrap script.
  final String sqlJsScript;

  /// sql.js dist base — the directory holding sql-wasm.wasm, passed to
  /// `initSqlJs({ locateFile })` so the wasm resolves beside the script.
  final String sqlJsDist;
}

/// Package-relative (extension) build: the engines live in the zip under
/// vendor/interpreters/ next to sw/ and panel/ — see
/// scripts/fetch_vendor_assets.sh (the paths mirror vendor.lock.json).
const extInterpreterAssets = InterpreterAssets(
  quickJsScript: '../../vendor/interpreters/index.global.js',
  pyodideScript: '../../vendor/interpreters/pyodide.js',
  pyodideIndex: '../../vendor/interpreters/',
  sqlJsScript: '../../vendor/interpreters/sql-wasm.js',
  sqlJsDist: '../../vendor/interpreters/',
);

/// Hosted web / Office taskpane builds: public CDNs (unchanged behavior —
/// tree-shaken out of the extension bundle).
const cdnInterpreterAssets = InterpreterAssets(
  quickJsScript:
      'https://cdn.jsdelivr.net/npm/quickjs-emscripten@0.31.0/dist/index.global.js',
  pyodideScript: 'https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js',
  pyodideIndex: 'https://cdn.jsdelivr.net/pyodide/v0.26.4/full/',
  sqlJsScript: 'https://cdn.jsdelivr.net/npm/sql.js@1.14.1/dist/sql-wasm.js',
  sqlJsDist: 'https://cdn.jsdelivr.net/npm/sql.js@1.14.1/dist/',
);

/// The asset set for THIS build (const-folded at dart2js time: in the
/// extension build the CDN branch is unreachable and its constants are
/// dropped from the emitted bundle).
InterpreterAssets interpreterAssets() =>
    kFaExtBuild ? extInterpreterAssets : cdnInterpreterAssets;
