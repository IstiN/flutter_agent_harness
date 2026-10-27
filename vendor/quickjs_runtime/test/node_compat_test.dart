import 'dart:convert';

import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'package:test/test.dart';

/// Evaluates [code] and decodes the JSON result (raw string when not JSON).
Object? evalJson(QuickjsRuntime rt, String code) {
  final errors = <String?>[];
  final raw = rt.eval(code, errMsg: errors);
  if (errors.isNotEmpty) throw StateError(errors.first!);
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return raw;
  }
}

void main() {
  group('bare runtime stays clean without install', () {
    test('node globals are undefined', () {
      final rt = QuickjsRuntime();
      try {
        expect(evalJson(rt, 'typeof globalThis.process'), 'undefined');
        expect(evalJson(rt, 'typeof globalThis.console'), 'undefined');
        expect(evalJson(rt, 'typeof globalThis.Buffer'), 'undefined');
      } finally {
        rt.close();
      }
    });
  });

  group('tier 1: real implementations', () {
    late QuickjsRuntime rt;
    final logs = <String>[];

    setUp(() {
      logs.clear();
      rt = QuickjsRuntime();
      installNodeCompat(
        rt,
        NodeCompatConfig(
          env: {'HOME': '/root', 'DMTOOLS_X': '42'},
          platform: 'darwin',
          arch: 'arm64',
          cwd: () => '/work/dir',
          clock: () => 1234.5,
          consoleSink: (level, message) => logs.add('$level: $message'),
          randomUuid: () => 'uuid-1',
        ),
      );
    });

    tearDown(() => rt.close());

    test('global aliases globalThis', () {
      expect(rt.eval('global === globalThis'), 'true');
    });

    test('console routes to the sink with levels', () {
      rt.eval("console.log('hello', 42, {a: 1})");
      rt.eval("console.warn('careful')");
      // console now renders via util.inspect (Node style), not JSON
      expect(logs, ['log: hello 42 { a: 1 }', 'warn: careful']);
    });

    test('process exposes env, platform, arch, version, cwd', () {
      expect(evalJson(rt, 'process.env.HOME'), '/root');
      expect(evalJson(rt, 'process.env.DMTOOLS_X'), '42');
      expect(evalJson(rt, 'process.platform'), 'darwin');
      expect(evalJson(rt, 'process.arch'), 'arm64');
      expect(evalJson(rt, 'process.version'), contains('compat'));
      expect(evalJson(rt, 'process.cwd()'), '/work/dir');
      expect(evalJson(rt, 'typeof process.exitCode'), 'number');
    });

    test('process.exit throws ProcessExit and notifies the hook', () {
      var exitCode = -1;
      final rt2 = QuickjsRuntime();
      installNodeCompat(
        rt2,
        NodeCompatConfig(exitHook: (code) => exitCode = code),
      );
      final errors = <String?>[];
      rt2.eval('process.exit(7)', errMsg: errors);
      expect(errors.first, contains('ProcessExit: 7'));
      expect(exitCode, 7);
      rt2.close();
    });

    test('path posix subset', () {
      expect(evalJson(rt, "path.join('a', 'b', 'c.js')"), 'a/b/c.js');
      expect(evalJson(rt, "path.join('a/', './b/../c')"), 'a/c');
      expect(evalJson(rt, "path.resolve('x', '/abs', 'y')"), '/abs/y');
      expect(evalJson(rt, "path.resolve('relative')"), '/work/dir/relative');
      expect(evalJson(rt, "path.basename('/a/b/c.tar.gz')"), 'c.tar.gz');
      expect(evalJson(rt, "path.basename('c.js', '.js')"), 'c');
      expect(evalJson(rt, "path.dirname('/a/b/c')"), '/a/b');
      expect(evalJson(rt, "path.extname('file.tar.gz')"), '.gz');
      expect(evalJson(rt, "path.isAbsolute('/x')"), true);
      expect(evalJson(rt, "path.relative('/a/b', '/a/c/d')"), '../c/d');
      expect(evalJson(rt, 'path.sep'), '/');
    });

    test('assert subset', () {
      expect(
        evalJson(
            rt,
            "assert(1 === 1); assert.equal('a', 'a'); "
            "assert.deepEqual({x: [1]}, {x: [1]}); assert.ok(true); 'ok'"),
        'ok',
      );
      final errors = <String?>[];
      rt.eval("assert.equal(1, 2)", errMsg: errors);
      expect(errors.first, contains('AssertionError'));
      rt.eval(
          "assert.throws(function () { throw new Error('boom'); }, "
          "/boom/)",
          errMsg: errors);
      expect(
        evalJson(
            rt,
            'var threw = false; try { assert.match("abc", /z/) } '
            'catch (e) { threw = e.name } threw'),
        'AssertionError',
      );
    });

    test('util subset', () {
      expect(
        evalJson(rt, "util.format('%s=%d %j', 'a', 5, {b: 2})"),
        'a=5 {"b":2}',
      );
      expect(evalJson(rt, 'util.inspect({k: 1})'), '{ k: 1 }');
    });

    test('atob / btoa roundtrip', () {
      expect(evalJson(rt, "btoa('hello')"), 'aGVsbG8=');
      expect(evalJson(rt, "atob('aGVsbG8=')"), 'hello');
      expect(evalJson(rt, "atob(btoa('round trip'))"), 'round trip');
    });

    test('TextEncoder / TextDecoder roundtrip', () {
      final result = evalJson(rt, '''
        var enc = new TextEncoder();
        var bytes = enc.encode('hi');
        [bytes.length, bytes[0], new TextDecoder().decode(bytes)]
      ''');
      expect(result, [2, 104, 'hi']);
    });

    test('crypto.randomUUID + getRandomValues', () {
      expect(evalJson(rt, 'crypto.randomUUID()'), 'uuid-1');
      expect(
        evalJson(
            rt,
            'var a = new Uint8Array(4); crypto.getRandomValues(a); '
            'a.length'),
        4,
      );
    });

    test('performance.now uses the clock hook', () {
      expect(evalJson(rt, 'performance.now()'), 1234.5);
    });

    test('structuredClone is JSON-fidelity', () {
      expect(
        evalJson(
            rt,
            'var v = {a: [1, {b: "x"}]}; '
            'var c = structuredClone(v); c.a[1].b = "y"; '
            '[v.a[1].b, c.a[1].b]'),
        ['x', 'y'],
      );
    });

    test('require resolves builtin compat modules', () {
      expect(evalJson(rt, "require('path').sep"), '/');
      expect(
        evalJson(
            rt,
            "var assert = require('assert'); "
            "assert.deepEqual([1], [1]); 'ok'"),
        'ok',
      );
      expect(evalJson(rt, "require('util').inspect(5)"), '5');
    });

    test('require falls back to the pre-existing loader', () {
      rt.eval('globalThis.__preLoaded = {}; '
          'globalThis.require = function (name) { '
          '  return { from: "loader", name: name }; };');
      installNodeCompat(rt);
      expect(
        evalJson(rt, "require('my/local/module').from"),
        'loader',
      );
      // Builtins still win over the fallback.
      expect(evalJson(rt, "require('path').sep"), '/');
    });

    test('installNodeCompatModule registers consumer modules', () {
      installNodeCompat(rt);
      installNodeCompatModule(rt, 'fs', (name) {
        return '{"readFileSync": "host:${'file'}", "module": "$name"}';
      });
      expect(
        evalJson(rt, "require('fs').module"),
        'fs',
      );
      expect(evalJson(rt, "require('fs').readFileSync"), 'host:file');
    });
  });

  group('tier 2: self-documenting stubs', () {
    late QuickjsRuntime rt;

    setUp(() {
      rt = QuickjsRuntime();
      installNodeCompat(rt);
    });

    tearDown(() => rt.close());

    test('stubs are typeof-safe but throw the alternative on call', () {
      // Buffer graduated from tier-2 stub to a real Uint8Array subclass;
      // timers graduated from tier-2 stubs to a real sync-drain scheduler
      expect(evalJson(rt, 'typeof Buffer.from'), 'function');
      expect(evalJson(rt, 'typeof fetch'), 'function');
      expect(evalJson(rt, 'typeof setTimeout'), 'function');

      for (final expr in [
        'fetch(1)',
        "fetch('http://x')",
        'new AbortController()',
      ]) {
        final errors = <String?>[];
        rt.eval(expr, errMsg: errors);
        expect(errors.first, isNotNull, reason: expr);
        expect(errors.first!, contains('quickjs_runtime'), reason: expr);
      }
    });

    test('timer callbacks must be functions', () {
      for (final expr in [
        'setTimeout(1, 10)',
        'setInterval(1, 10)',
        'setImmediate(1)',
        'queueMicrotask(1)',
        'process.nextTick(1)',
      ]) {
        final errors = <String?>[];
        rt.eval(expr, errMsg: errors);
        expect(errors.first, isNotNull, reason: expr);
        expect(errors.first!, contains('must be a function'), reason: expr);
      }
    });

    test('clearTimeout / clearInterval are no-ops on junk', () {
      expect(evalJson(rt, 'clearTimeout(1); clearInterval(2); "ok"'), 'ok');
    });
  });
}
