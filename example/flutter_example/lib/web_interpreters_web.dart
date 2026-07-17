// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';

/// Result of running a snippet in a browser-hosted interpreter.
typedef InterpreterResult = ({bool available, String stdout, String stderr});

@JS('__fahQjsRun')
external JSPromise _fahQjsRun(String code);

@JS('__fahPyRun')
external JSPromise _fahPyRun(String code);

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

  static Future<void>? _quickJsLoading;
  static Future<void>? _pyodideLoading;

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
  /// runner that reuses one interpreter instance.
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
}
