// run_script interpreter host (offscreen document side).
//
// Vendored runtimes (browser_ext/vendor/interpreters/, downloaded by
// scripts/vendor_interpreters.sh — extension CSP forbids remote scripts):
//   - quickjs-emscripten@0.31.0 dist/index.global.js (wasm embedded as a
//     base64 data URL — one self-contained file, exposes getQuickJS);
//   - pyodide v0.26.4 (pyodide.js + pyodide.asm.js + pyodide.asm.wasm +
//     python_stdlib.zip + pyodide-lock.json, exposes loadPyodide).
// Both load LAZILY on first use of the language (pyodide is heavy).
//
// Protocol (answered by the SW's run_script tool, see
// browser_ext/dart/src/run_script_tool.dart):
//   request  { __fahRunScript: true, language: 'python'|'javascript', code }
//   response { ok: true, stdout, stderr, error }  — script ran (error is
//            the script-level exception, null on success)
//            { ok: false, error }                  — transport/boot failure
//
// The runner bodies mirror flutter_app/lib/sandbox/web_interpreters_web.dart
// (__fahQjsRun/__fahPyRun) so both surfaces behave identically.
'use strict';

(function () {
  var VENDOR_BASE = 'vendor/interpreters/';
  var scriptPromises = {};

  function ensureScript(src) {
    if (scriptPromises[src]) return scriptPromises[src];
    scriptPromises[src] = new Promise(function (resolve, reject) {
      var el = document.createElement('script');
      el.src = src;
      el.onload = function () { resolve(); };
      el.onerror = function () { reject(new Error('failed to load ' + src)); };
      document.head.appendChild(el);
    });
    return scriptPromises[src];
  }

  // -- QuickJS ---------------------------------------------------------------

  var qjsPromise = null;
  var qjsCtx = null;
  var qjsOut = [];

  function runJavaScript(code) {
    if (!qjsPromise) {
      qjsPromise = ensureScript(VENDOR_BASE + 'index.global.js').then(
        function () {
          var g = window.QJS || window.quickjs || window;
          return g.getQuickJS();
        }
      );
    }
    return qjsPromise.then(function (qjs) {
      if (!qjsCtx) {
        qjsCtx = qjs.newContext ? qjs.newContext() : qjs;
        qjsCtx.setProp(
          qjsCtx.global,
          '__fahQjsPrint',
          qjsCtx.newFunction('__fahQjsPrint', function () {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              var v = arguments[i];
              if (v && typeof v === 'object') {
                try { v = qjsCtx.dump(v); } catch (e) { /* opaque */ }
              }
              parts.push(String(v));
            }
            qjsOut.push(parts.join(' '));
          })
        );
      }
      qjsOut = [];
      var error = null;
      try {
        var result = qjsCtx.evalCode(
          'var console = { log: function() { __fahQjsPrint.apply(null, arguments); },' +
          ' error: function() { __fahQjsPrint.apply(null, arguments); },' +
          ' warn: function() { __fahQjsPrint.apply(null, arguments); } };\n' + code
        );
        if (result && result.error) {
          var dumped = qjsCtx.dump(result.error);
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
      return { ok: true, stdout: qjsOut.join('\n'), stderr: '', error: error };
    });
  }

  // -- pyodide ---------------------------------------------------------------

  var pyPromise = null;

  function runPython(code) {
    if (!pyPromise) {
      pyPromise = ensureScript(VENDOR_BASE + 'pyodide.js').then(function () {
        return loadPyodide({
          indexURL: new URL(VENDOR_BASE, location.href).href,
        });
      });
    }
    return pyPromise.then(function (py) {
      var out = [];
      var err = [];
      py.setStdout({ batched: function (s) { out.push(s); } });
      py.setStderr({ batched: function (s) { err.push(s); } });
      var error = null;
      try {
        py.runPython(code);
      } catch (e) {
        error = String((e && e.message) || e);
      }
      return {
        ok: true,
        stdout: out.join('\n'),
        stderr: err.join('\n'),
        error: error,
      };
    });
  }

  // -- message surface ---------------------------------------------------------

  chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
    if (!msg || msg.__fahRunScript !== true) return undefined;
    var language = String(msg.language || '');
    var code = String(msg.code || '');
    var run = language === 'python'
      ? runPython
      : language === 'javascript'
        ? runJavaScript
        : null;
    if (run == null) {
      sendResponse({ ok: false, error: 'unknown language: ' + language });
      return undefined;
    }
    run(code).then(
      function (reply) { sendResponse(reply); },
      function (e) {
        sendResponse({
          ok: false,
          error: String((e && e.message) || e),
        });
      }
    );
    return true; // async sendResponse
  });
})();
