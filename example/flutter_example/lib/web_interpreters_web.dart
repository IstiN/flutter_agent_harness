// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:typed_data';

import 'sandbox_pip.dart';

/// Result of running a snippet in a browser-hosted interpreter.
typedef InterpreterResult = ({bool available, String stdout, String stderr});

/// Result of running SQL statements in the browser-hosted sql.js engine.
/// [dbBytes] carries the exported database back to the caller so it can be
/// persisted (sql.js keeps the database in memory only).
typedef SqliteRunResult = ({
  bool available,
  String stdout,
  String stderr,
  Uint8List? dbBytes,
});

/// Result of a `pip` run through the browser-hosted micropip.
typedef PipInterpreterResult = ({
  bool available,
  String stdout,
  String stderr,
  int exitCode,
});

@JS('__fahQjsRun')
external JSPromise _fahQjsRun(String code);

@JS('__fahPyRun')
external JSPromise _fahPyRun(String code);

@JS('__fahPyPip')
external JSPromise _fahPyPip(String code);

@JS('__fahSqlRun')
external JSPromise _fahSqlRun(String payloadJson);

/// Browser-hosted Python (pyodide) and JavaScript (quickjs-emscripten)
/// interpreters for the web sandbox.
///
/// Both engines are loaded from public CDNs on first use and cached on
/// `window`; nothing is bundled into the app. quickjs-emscripten is the same
/// QuickJS engine that runs as WASM on iOS/Android; pyodide is CPython
/// compiled to WebAssembly for the browser.
class WebInterpreters {
  static const _quickJsCdn =
      'https://cdn.jsdelivr.net/npm/quickjs-emscripten@0.31.0/dist/index.global.js';
  static const _pyodideCdn =
      'https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js';
  static const _sqlJsCdn =
      'https://cdn.jsdelivr.net/npm/sql.js@1.14.1/dist/sql-wasm.js';
  static const _sqlJsDistBase =
      'https://cdn.jsdelivr.net/npm/sql.js@1.14.1/dist/';

  static Future<void>? _quickJsLoading;
  static Future<void>? _pyodideLoading;
  static Future<void>? _sqlJsLoading;

  static Future<void> _ensureScript(String id, String url) {
    if (html.document.getElementById(id) != null) {
      return Future.value();
    }
    final completer = Completer<void>();
    final script = html.ScriptElement()
      ..id = id
      ..src = url
      ..type = 'text/javascript';
    script.onLoad.first.then((_) {
      if (!completer.isCompleted) completer.complete();
    });
    script.onError.first.then((_) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('failed to load $url'));
      }
    });
    html.document.head!.append(script);
    return completer.future;
  }

  static void _injectHelperScript(String id, String code) {
    if (html.document.getElementById(id) != null) return;
    final script = html.ScriptElement()
      ..id = id
      ..type = 'text/javascript'
      ..text = code;
    html.document.head!.append(script);
  }

  static Future<void> _ensureQuickJs() {
    return _quickJsLoading ??= _ensureScript(
      'fah-quickjs-cdn',
      _quickJsCdn,
    ).then((_) => _injectHelperScript('fah-quickjs-runner', _qjsRunnerSource));
  }

  static Future<void> _ensurePyodide() {
    return _pyodideLoading ??= _ensureScript(
      'fah-pyodide-cdn',
      _pyodideCdn,
    ).then((_) => _injectHelperScript('fah-pyodide-runner', _pyRunnerSource));
  }

  static Future<void> _ensureSqlJs() {
    return _sqlJsLoading ??= _ensureScript('fah-sqljs-cdn', _sqlJsCdn).then(
      (_) => _injectHelperScript(
        'fah-sqljs-runner',
        _sqlRunnerSource.replaceAll('__SQLJS_DIST_BASE__', _sqlJsDistBase),
      ),
    );
  }

  /// Installs `window.__fahQjsRun(code)`, a stdout-capturing QuickJS runner
  /// that reuses one engine instance.
  static const _qjsRunnerSource = r'''
window.__fahQjsRun = function(code) {
  if (!window.__fahQjsPromise) {
    var g = window.QJS || window.quickjs || window;
    window.__fahQjsPromise = g.getQuickJS();
  }
  return window.__fahQjsPromise.then(function(qjs) {
    if (!window.__fahQjsCtx) {
      var ctx = qjs.newContext ? qjs.newContext() : qjs;
      window.__fahQjsCtx = ctx;
      window.__fahQjsOut = [];
      window.__fahQjsPrint = ctx.newFunction('__fahQjsPrint', function() {
        var parts = [];
        for (var i = 0; i < arguments.length; i++) {
          var v = arguments[i];
          if (v && typeof v === 'object') {
            try { v = ctx.dump(v); } catch (e) {}
          }
          parts.push(String(v));
        }
        window.__fahQjsOut.push(parts.join(' '));
      });
      ctx.setProp(ctx.global, '__fahQjsPrint', window.__fahQjsPrint);
    }
    var ctx = window.__fahQjsCtx;
    window.__fahQjsOut = [];
    var error = null;
    try {
      var result = ctx.evalCode(
        'var console = { log: function() { __fahQjsPrint.apply(null, arguments); },' +
        ' error: function() { __fahQjsPrint.apply(null, arguments); },' +
        ' warn: function() { __fahQjsPrint.apply(null, arguments); } };\n' + code
      );
      if (result && result.error) {
        var dumped = ctx.dump(result.error);
        if (dumped && typeof dumped === 'object') {
          error = String(dumped.name || 'Error') + ': ' +
            String(dumped.message || dumped) +
            (dumped.stack ? '\n' + dumped.stack : '');
        } else {
          error = String(dumped);
        }
        if (result.error.dispose) result.error.dispose();
      }
      if (result && result.value && result.value.dispose) result.value.dispose();
    } catch (e) {
      error = String((e && e.stack) || e);
    }
    return JSON.stringify({ stdout: window.__fahQjsOut.join('\n'), error: error });
  });
};
''';

  /// Installs `window.__fahPyRun(code)`, a stdout/stderr-capturing pyodide
  /// runner that reuses one interpreter instance, and
  /// `window.__fahPyPip(code)`, the micropip-backed `pip` runner (loads the
  /// micropip package from the pyodide CDN, then runs [code] with
  /// `runPythonAsync` so snippets can use top-level `await`).
  static const _pyRunnerSource = r'''
window.__fahPyRun = function(code) {
  if (!window.__fahPyPromise) {
    window.__fahPyPromise = loadPyodide();
  }
  return window.__fahPyPromise.then(function(py) {
    var out = [];
    var err = [];
    py.setStdout({ batched: function(s) { out.push(s); } });
    py.setStderr({ batched: function(s) { err.push(s); } });
    var error = null;
    try {
      py.runPython(code);
    } catch (e) {
      error = String((e && e.message) || e);
    }
    return JSON.stringify({ stdout: out.join('\n'), stderr: err.join('\n'), error: error });
  });
};
window.__fahPyPip = function(code) {
  if (!window.__fahPyPromise) {
    window.__fahPyPromise = loadPyodide();
  }
  return window.__fahPyPromise.then(function(py) {
    return py.loadPackage('micropip').then(function() {
      var out = [];
      var err = [];
      py.setStdout({ batched: function(s) { out.push(s); } });
      py.setStderr({ batched: function(s) { err.push(s); } });
      return py.runPythonAsync(code).then(function() {
        return JSON.stringify({ stdout: out.join('\n'), stderr: err.join('\n'), error: null });
      }, function(e) {
        return JSON.stringify({ stdout: out.join('\n'), stderr: err.join('\n'), error: String((e && e.message) || e) });
      });
    }, function(e) {
      return JSON.stringify({ stdout: '', stderr: '', error: 'failed to load micropip: ' + String((e && e.message) || e) });
    });
  });
};
''';

  /// Installs `window.__fahSqlRun(payloadJson)`, a sql.js runner that loads
  /// the database from base64 bytes, executes all statements, and returns
  /// the rows (`|`-separated, like the sqlite3 CLI list mode) plus the
  /// re-exported database bytes so the caller can persist them.
  static const _sqlRunnerSource = r'''
window.__fahSqlRun = function(payloadJson) {
  var payload = JSON.parse(payloadJson);
  if (!window.__fahSqlPromise) {
    window.__fahSqlPromise = initSqlJs({
      locateFile: function(file) { return '__SQLJS_DIST_BASE__' + file; }
    });
  }
  return window.__fahSqlPromise.then(function(SQL) {
    var db = null;
    var error = null;
    var out = [];
    var exported = null;
    try {
      if (payload.dbBase64) {
        var bin = atob(payload.dbBase64);
        var bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        db = new SQL.Database(bytes);
      } else {
        db = new SQL.Database();
      }
      var results = db.exec(payload.sql);
      for (var r = 0; r < results.length; r++) {
        var res = results[r];
        for (var v = 0; v < res.values.length; v++) {
          out.push(res.values[v].map(function(x) {
            if (x === null || x === undefined) return '';
            if (x instanceof Uint8Array) return '[blob ' + x.length + ' bytes]';
            return String(x);
          }).join('|'));
        }
      }
    } catch (e) {
      error = String((e && e.message) || e);
    }
    if (db) {
      // Export even after an error: statements before the failing one were
      // applied, matching the sqlite3 CLI.
      try {
        var data = db.export();
        var chunks = [];
        for (var i = 0; i < data.length; i += 0x8000) {
          chunks.push(String.fromCharCode.apply(null, data.subarray(i, i + 0x8000)));
        }
        exported = btoa(chunks.join(''));
      } catch (exportError) {}
      try { db.close(); } catch (closeError) {}
    }
    return JSON.stringify({ stdout: out.join('\n'), error: error, dbBase64: exported });
  });
};
''';

  static Future<Map<String, dynamic>> _parse(JSPromise promise) async {
    final result = await promise.toDart;
    final json = (result as JSString).toDart;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  /// Runs QuickJS [code] (console.log/error/warn captured into stdout).
  static Future<InterpreterResult> runQjs(String code) async {
    try {
      await _ensureQuickJs();
      final result = await _parse(_fahQjsRun(code));
      final error = result['error'] as String?;
      return (
        available: true,
        stdout: (result['stdout'] as String?) ?? '',
        stderr: error ?? '',
      );
    } catch (e) {
      return (available: false, stdout: '', stderr: '$e');
    }
  }

  /// Runs Python [code] (print/tracebacks captured).
  static Future<InterpreterResult> runPython(String code) async {
    try {
      await _ensurePyodide();
      final result = await _parse(_fahPyRun(code));
      final error = result['error'] as String?;
      final stderr = (result['stderr'] as String?) ?? '';
      return (
        available: true,
        stdout: (result['stdout'] as String?) ?? '',
        stderr: error != null ? '$stderr$error' : stderr,
      );
    } catch (e) {
      return (available: false, stdout: '', stderr: '$e');
    }
  }

  /// Runs `pip` [args] through pyodide's micropip. Usage errors are
  /// short-circuited in pure Dart before pyodide (and the CDN) is touched;
  /// real subcommands load pyodide lazily inside the runner closure.
  static Future<PipInterpreterResult> runPip(List<String> args) async {
    try {
      final result = await runMicropipPip(args, (code) async {
        await _ensurePyodide();
        final r = await _parse(_fahPyPip(code));
        return (
          stdout: (r['stdout'] as String?) ?? '',
          stderr: (r['stderr'] as String?) ?? '',
          error: r['error'] as String?,
        );
      });
      return (
        available: true,
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
      );
    } catch (e) {
      return (available: false, stdout: '', stderr: '$e', exitCode: 127);
    }
  }

  /// QuickJS version string, or null when the engine cannot load.
  static Future<String?> qjsVersion() async {
    final result = await runQjs(
      'console.log(JSON.stringify({ engine: "quickjs" }))',
    );
    return result.available ? 'quickjs-ng (emscripten)' : null;
  }

  /// Python version string, or null when the engine cannot load.
  static Future<String?> pythonVersion() async {
    final result = await runPython('import sys; print(sys.version)');
    return result.available ? result.stdout.trim() : null;
  }

  /// Runs [sql] against [dbBytes] (or a fresh in-memory database when null)
  /// via sql.js. Rows are returned `|`-separated like the sqlite3 CLI list
  /// mode; the re-exported database bytes come back in [SqliteRunResult].
  static Future<SqliteRunResult> runSqlite(
    String sql,
    Uint8List? dbBytes,
  ) async {
    try {
      await _ensureSqlJs();
      final payload = jsonEncode({
        'sql': sql,
        if (dbBytes != null) 'dbBase64': base64Encode(dbBytes),
      });
      final result = await _parse(_fahSqlRun(payload));
      final error = result['error'] as String?;
      final exported = result['dbBase64'] as String?;
      return (
        available: true,
        stdout: (result['stdout'] as String?) ?? '',
        stderr: error ?? '',
        dbBytes: exported != null ? base64Decode(exported) : null,
      );
    } catch (e) {
      return (available: false, stdout: '', stderr: '$e', dbBytes: null);
    }
  }

  /// SQLite version string, or null when the engine cannot load.
  static Future<String?> sqliteVersion() async {
    final result = await runSqlite('select sqlite_version();', null);
    if (!result.available || result.stderr.isNotEmpty) return null;
    return result.stdout.trim();
  }
}
