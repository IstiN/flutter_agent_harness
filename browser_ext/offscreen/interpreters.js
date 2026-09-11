// run_script interpreter host (offscreen document side).
//
// Vendored runtimes (browser_ext/vendor/interpreters/, downloaded by
// scripts/vendor_interpreters.sh — extension CSP forbids remote scripts):
//   - quickjs-emscripten@0.31.0 dist/index.global.js (the SYNC wasm
//     embedded as a base64 data URL; exposes the API incl.
//     newQuickJSAsyncWASMModuleFromVariant/newAsyncRuntime);
//   - vendor/interpreters/asyncify/ — the ASYNC quickjs variant
//     (@jitl/quickjs-wasmfile-release-asyncify): emscripten-module
//     (.browser.mjs + .wasm) + ffi.mjs with its bare npm import rewritten
//     onto ffi-types-shim.mjs by the vendor script. The async (asyncify)
//     runtime is what lets host functions return PROMISES — that is how
//     `fetch` gets into scripts;
//   - pyodide v0.26.4 (pyodide.js + pyodide.asm.js + pyodide.asm.wasm +
//     python_stdlib.zip + pyodide-lock.json, exposes loadPyodide).
// All load LAZILY on first use of the language (pyodide is heavy).
//
// NETWORK: this offscreen document runs on the extension origin, which
// holds <all_urls> host permissions — fetch() from here is CORS-free
// (unlike any web page). Both interpreters expose that:
//   - javascript: global `fetch(url, {method, headers, body})` — await
//     it; resolves to {status, headers, body} (body as text, 30s
//     timeout);
//   - python: `await fetch(url, method="GET", headers=None, body=None)`
//     (same dict; top-level await works — the runner is runPythonAsync)
//     plus pyodide's own pyfetch.
// Cookies are NOT sent (credentials omitted): scripts must pass explicit
// auth headers instead of riding the browser session.
//
// Protocol (answered by the SW's run_script tool, see
// browser_ext/dart/src/run_script_tool.dart):
//   request  { __fahRunScript: true, language: 'python'|'javascript', code }
//   response { ok: true, stdout, stderr, error }  — script ran (error is
//            the script-level exception, null on success)
//            { ok: false, error }                  — transport/boot failure
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

  // Shared host fetch: 30s timeout, no credentials, headers flattened to
  // a plain object (a Headers instance does not survive the quickjs dump
  // nor pyodide's js->py conversion).
  function hostFetch(url, opts) {
    var ctrl = new AbortController();
    var timer = setTimeout(function () { ctrl.abort(); }, 30000);
    return fetch(url, {
      method: (opts && opts.method) || 'GET',
      headers: (opts && opts.headers) || undefined,
      body: (opts && opts.body) || undefined,
      signal: ctrl.signal,
      credentials: 'omit',
    })
      .then(function (res) {
        return res.text().then(function (body) {
          var headers = {};
          res.headers.forEach(function (v, k) { headers[k] = v; });
          return { status: res.status, headers: headers, body: body };
        });
      })
      .finally(function () { clearTimeout(timer); });
  }

  // -- QuickJS (asyncify runtime: host functions may return promises) ----

  var qjsPromise = null;
  var qjsCtx = null;
  var qjsRuntime = null;
  var qjsOut = [];

  function bootQuickJs() {
    if (!qjsPromise) {
      qjsPromise = ensureScript(VENDOR_BASE + 'index.global.js').then(
        function () {
          var g = window.QJS || window.quickjs || window;
          var absBase = new URL(VENDOR_BASE, location.href).href;
          var variant = {
            type: 'async',
            importFFI: function () {
              return import(absBase + 'asyncify/ffi.mjs').then(function (m) {
                return m.QuickJSAsyncFFI;
              });
            },
            importModuleLoader: function () {
              return import(
                absBase + 'asyncify/emscripten-module.browser.mjs'
              ).then(function (m) {
                return m.default;
              });
            },
          };
          return g
            .newQuickJSAsyncWASMModuleFromVariant(variant)
            .then(function (mod) {
              return g.newAsyncRuntime({ module: mod });
            });
        }
      );
    }
    return qjsPromise;
  }

  function newFetchFunction(ctx) {
    return ctx.newFunction('fetch', function (urlHandle, optsHandle) {
      var url = ctx.getString(urlHandle);
      var opts = null;
      if (optsHandle && ctx.typeof(optsHandle) === 'object') {
        opts = ctx.dump(optsHandle);
      }
      var promise = ctx.newPromise();
      hostFetch(url, opts).then(
        function (result) {
          var obj = ctx.newObject();
          ctx.setProp(obj, 'status', ctx.newNumber(result.status));
          ctx.setProp(obj, 'body', ctx.newString(result.body));
          var headers = ctx.newObject();
          for (var k in result.headers) {
            ctx.setProp(headers, k, ctx.newString(result.headers[k]));
          }
          ctx.setProp(obj, 'headers', headers);
          headers.dispose();
          promise.resolve(obj);
          obj.dispose();
        },
        function (err) {
          promise.reject(
            ctx.newError(String((err && err.message) || err))
          );
        }
      );
      // Drain the job queue once the host promise settles, so the
      // suspended script resumes inside evalCodeAsync.
      promise.settled.then(function () {
        qjsRuntime.executePendingJobs();
      });
      return promise.handle;
    });
  }

  function runJavaScript(code) {
    return bootQuickJs().then(function (runtime) {
      qjsRuntime = runtime;
      if (!qjsCtx) {
        qjsCtx = runtime.newContext();
        var printFn = qjsCtx.newFunction('__fahQjsPrint', function () {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) {
            parts.push(String(qjsCtx.dump(arguments[i])));
          }
          qjsOut.push(parts.join(' '));
        });
        qjsCtx.setProp(qjsCtx.global, '__fahQjsPrint', printFn);
        printFn.dispose();
        var fetchFn = newFetchFunction(qjsCtx);
        qjsCtx.setProp(qjsCtx.global, 'fetch', fetchFn);
        fetchFn.dispose();
        // console shim onto the print bridge.
        qjsCtx.evalCode(
          'var console = { log: __fahQjsPrint, info: __fahQjsPrint, ' +
            'warn: __fahQjsPrint, error: __fahQjsPrint };'
        );
      }
      qjsOut = [];
      var error = null;
      // Top-level `await` is module-only syntax in quickjs — wrap the
      // script in an async IIFE and await the resulting promise (that is
      // what makes `await fetch(...)` work anywhere in user code).
      var wrapped = '(async () => {\n' + code + '\n})()';
      return qjsCtx.evalCodeAsync(wrapped).then(function (result) {
        if (result.error) {
          return Promise.resolve(result);
        }
        // The IIFE returns a promise; resolvePromise drains the job
        // queue until it settles (fetch bridges resume it).
        var resolvedP = qjsCtx.resolvePromise(result.value);
        result.value.dispose();
        // Pump once ourselves: a script with NO awaits settles its IIFE
        // promise without any host promise, so the fetch bridge's
        // settled hook never fires and resolvePromise would wait for a
        // pump that never comes. Extra pumps are no-ops.
        qjsRuntime.executePendingJobs();
        setTimeout(function () {
          qjsRuntime.executePendingJobs();
        }, 0);
        return resolvedP;
      }).then(function (result) {
        if (result.error) {
          var dumped = qjsCtx.dump(result.error);
          result.error.dispose();
          error =
            typeof dumped === 'string'
              ? dumped
              : String(
                  (dumped && (dumped.name + ': ' + dumped.message)) ||
                    dumped
                );
        } else {
          result.value.dispose();
        }
        return {
          ok: true,
          stdout: qjsOut.join('\n'),
          stderr: '',
          error: error,
        };
      });
    });
  }

  // -- pyodide ---------------------------------------------------------------

  // Network preamble: a python-level `fetch` mirroring the JS bridge
  // (same result shape). Runs once after boot; user code runs with
  // runPythonAsync so top-level await works.
  var PY_PREAMBLE = [
    'from pyodide.http import pyfetch as _pyfetch',
    '',
    'async def fetch(url, method="GET", headers=None, body=None):',
    '    """CORS-free HTTP via the extension host.',
    '    Returns {\'status\', \'headers\', \'body\'} (body is text)."""',
    '    r = await _pyfetch(url, method=method, headers=headers or {}, body=body)',
    '    try:',
    '        hs = {k: r.headers.get(k) for k in r.headers.keys()}',
    '    except Exception:',
    '        hs = {}',
    '    return {"status": r.status, "headers": hs, "body": await r.string()}',
    '',
  ].join('\n');

  var pyPromise = null;

  function runPython(code) {
    if (!pyPromise) {
      pyPromise = ensureScript(VENDOR_BASE + 'pyodide.js')
        .then(function () {
          return loadPyodide({
            indexURL: new URL(VENDOR_BASE, location.href).href,
          });
        })
        .then(function (py) {
          return py.runPythonAsync(PY_PREAMBLE).then(function () {
            return py;
          });
        });
    }
    return pyPromise.then(function (py) {
      var out = [];
      var err = [];
      py.setStdout({ batched: function (s) { out.push(s); } });
      py.setStderr({ batched: function (s) { err.push(s); } });
      return py.runPythonAsync(code).then(
        function () {
          return {
            ok: true,
            stdout: out.join('\n'),
            stderr: err.join('\n'),
            error: null,
          };
        },
        function (e) {
          return {
            ok: true,
            stdout: out.join('\n'),
            stderr: err.join('\n'),
            error: String((e && e.message) || e),
          };
        }
      );
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
