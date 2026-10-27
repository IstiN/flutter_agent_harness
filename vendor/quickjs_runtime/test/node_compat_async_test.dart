// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'package:test/test.dart';

/// Shared engine wiring for the async node-compat surface: microtask drain,
/// host-driven timers, `events`, `util.promisify`/`callbackify`.
/// Evaluates an expression whose completion value is a string, decoding
/// the single layer of JSON that [QuickjsRuntime.eval] adds.
String jsStr(QuickjsRuntime rt, String code) =>
    jsonDecode(rt.eval(code)!) as String;

void main() {
  group('microtask queue', () {
    late QuickjsRuntime rt;
    setUp(() {
      rt = QuickjsRuntime();
      installNodeCompat(rt);
    });
    tearDown(() => rt.close());

    test('promise reactions run automatically after eval (Node parity)', () {
      rt.eval('var x = 0; Promise.resolve().then(function () { x = 42; });');
      expect(rt.eval('x'), '42');
    });

    test('chained microtasks settle within one eval drain', () {
      rt.eval('''
var log = [];
Promise.resolve().then(function () {
  log.push('a');
  Promise.resolve().then(function () { log.push('b'); });
});
''');
      expect(jsStr(rt, 'JSON.stringify(log)'), '["a","b"]');
    });

    test('drainMicrotasks caps a self-re-enqueueing chain', () {
      // Own runtime: the spin chain never empties the job queue (each job
      // re-enqueues itself), so it must not share the group's runtime —
      // leftover spin jobs would starve later tests' microtasks.
      final rt2 = QuickjsRuntime();
      try {
        rt2.eval('''
globalThis.__n = 0;
globalThis.__spin = function () { __n++; Promise.resolve().then(__spin); };
__spin();
''');
        final first = rt2.drainMicrotasks(maxJobs: 100);
        expect(first, lessThanOrEqualTo(100));
        final n = int.parse(rt2.eval('__n')!);
        expect(n, greaterThan(0));
        expect(n, lessThan(100200));
      } finally {
        rt2.close();
      }
    });

    test('autoDrainMicrotasks=false restores strict manual draining', () {
      final rt2 = QuickjsRuntime(autoDrainMicrotasks: false);
      try {
        rt2.eval('var x = 0; Promise.resolve().then(function () { x = 7; });');
        expect(rt2.eval('x'), '0');
        rt2.drainMicrotasks();
        expect(rt2.eval('x'), '7');
      } finally {
        rt2.close();
      }
    });

    test('queueMicrotask and process.nextTick run real callbacks', () {
      rt.eval('''
var log = [];
queueMicrotask(function () { log.push('qm'); });
process.nextTick(function () { log.push('tick'); });
''');
      expect(jsStr(rt, 'JSON.stringify(log)'), '["qm","tick"]');
    });
  });

  group('timers: ready mode (default)', () {
    late QuickjsRuntime rt;
    late NodeCompatHandle compat;
    setUp(() {
      rt = QuickjsRuntime();
      compat = installNodeCompat(rt);
    });
    tearDown(() => rt.close());

    test('sync code first, immediates before timeouts, equal dues in order',
        () {
      rt.eval('''
var log = [];
setTimeout(function () { log.push('t1'); }, 0);
setTimeout(function () { log.push('t2'); }, 0);
setTimeout(function () { log.push('t3'); }, 0);
setImmediate(function () { log.push('immediate'); });
log.push('sync');
''');
      final stats = compat.drainTimers();
      expect(stats.ran, 4);
      expect(
        jsStr(rt, 'JSON.stringify(log)'),
        '["sync","immediate","t1","t2","t3"]',
      );
      expect(stats.pending, 0);
    });

    test('clearTimeout cancels; callback receives extra args', () {
      rt.eval('''
var log = [];
var t = setTimeout(function (a, b) { log.push(a + b); }, 0, 3, 4);
clearTimeout(t);
setTimeout(function () { log.push('still here'); }, 0);
''');
      final stats = compat.drainTimers();
      expect(stats.ran, 1);
      expect(jsStr(rt, 'JSON.stringify(log)'), '["still here"]');
    });

    test('intervals repeat until cleared', () {
      rt.eval('''
var n = 0;
globalThis.__iv = setInterval(function () {
  n++;
  if (n >= 3) clearInterval(__iv);
}, 0);
''');
      final stats = compat.drainTimers();
      expect(stats.ran, 3);
      expect(rt.eval('n'), '3');
      expect(stats.pending, 0);
    });

    test('handle surface: unref/ref/hasRef/refresh exist', () {
      rt.eval('''
var t = setTimeout(function () {}, 10);
globalThis.__shape = [typeof t.unref, typeof t.ref, typeof t.hasRef,
    typeof t.refresh];
t.unref();
globalThis.__refState = t.hasRef();
t.refresh();
''');
      expect(jsStr(rt, 'JSON.stringify(__shape)'),
          '["function","function","function","function"]');
      expect(rt.eval('__refState'), 'false');
    });

    test('ready mode leaves future timers queued without sleeping', () {
      rt.eval(
          'var log = []; setTimeout(function () { log.push("x"); }, 5000);');
      final stats = compat.drainTimers();
      expect(stats.ran, 0);
      expect(stats.pending, 1);
      expect(jsStr(rt, 'JSON.stringify(log)'), '[]');
    });
  });

  group('timers: block mode (injectable clock + sleep)', () {
    late QuickjsRuntime rt;
    late NodeCompatHandle compat;
    final sleeps = <double>[];
    var clockMs = 1000.0;

    setUp(() {
      sleeps.clear();
      clockMs = 1000.0;
      rt = QuickjsRuntime();
      compat = installNodeCompat(
        rt,
        NodeCompatConfig(
          timerDrain: TimerDrainMode.block,
          clock: () => clockMs,
          sleep: (d) {
            sleeps.add(d.inMilliseconds.toDouble());
            clockMs += d.inMilliseconds; // fake wall clock advance
          },
        ),
      );
    });
    tearDown(() => rt.close());

    test('waits (via sleep) for a future timer and unblocks', () {
      rt.eval('var hit = false; setTimeout(function () { hit = true; }, 50);');
      final stats = compat.drainTimers();
      expect(stats.ran, 1);
      expect(rt.eval('hit'), 'true');
      expect(sleeps, isNotEmpty);
      expect(sleeps.first, 50);
    });

    test('setTimeout-as-sleep chains terminate', () {
      rt.eval('''
var log = [];
function step(i) {
  log.push(i);
  if (i < 3) setTimeout(function () { step(i + 1); }, 10);
}
setTimeout(function () { step(1); }, 10);
''');
      compat.drainTimers();
      expect(jsStr(rt, 'JSON.stringify(log)'), '[1,2,3]');
    });

    test("unref'd timers do not hold the drain", () {
      rt.eval('''
var log = [];
setTimeout(function () { log.push('ghost'); }, 5000).unref();
setTimeout(function () { log.push('now'); }, 0);
''');
      final stats = compat.drainTimers();
      expect(stats.ran, 1);
      expect(jsStr(rt, 'JSON.stringify(log)'), '["now"]');
      expect(stats.pending, 1); // ghost stays queued, unreferenced
      expect(sleeps, isEmpty); // never waited on the 5s ghost
    });

    test('setInterval storm raises the maxTimerCallbacks guard', () {
      rt.eval('globalThis.__storm = setInterval(function () {}, 0);');
      expect(
        compat.drainTimers,
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('maxTimerCallbacks'),
        )),
      );
    });

    test('wall-clock deadline raises with pending timers', () {
      rt.eval('setTimeout(function () {}, 60000);');
      expect(
        () => compat.drainTimers(deadline: const Duration(milliseconds: 5)),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('maxTimerDrainWallClock'),
        )),
      );
    });
  });

  group('events', () {
    late QuickjsRuntime rt;
    setUp(() {
      rt = QuickjsRuntime();
      installNodeCompat(rt);
    });
    tearDown(() => rt.close());

    test('require("events") has the Node shape', () {
      expect(jsStr(rt, 'typeof require("events")'), 'function');
      expect(jsStr(rt, 'typeof require("events").EventEmitter'), 'function');
      expect(rt.eval('require("events").defaultMaxListeners'), '10');
    });

    test('on/emit/once/prepend/off/listenerCount/eventNames', () {
      rt.eval('''
var EventEmitter = require('events');
var ee = new EventEmitter();
var log = [];
function h1(v) { log.push('h1:' + v); }
ee.on('x', h1);
ee.once('x', function (v) { log.push('once:' + v); });
ee.prependListener('x', function (v) { log.push('pre:' + v); });
ee.emit('x', 1);
ee.emit('x', 2);
globalThis.__count = ee.listenerCount('x');
ee.off('x', h1);
globalThis.__names = ee.eventNames();
''');
      expect(
        jsStr(rt, 'JSON.stringify(log)'),
        '["pre:1","h1:1","once:1","pre:2","h1:2"]',
      );
      expect(rt.eval('__count'), '2');
      expect(jsStr(rt, 'JSON.stringify(__names)'), '["x"]');
    });

    test("emit('error') without listeners throws (Node semantics)", () {
      rt.eval('var ee = new (require("events"))();');
      final errors = <String?>[];
      rt.eval("ee.emit('error', new Error('boom'))", errMsg: errors);
      expect(errors.first, isNotNull);
      expect(errors.first!, contains('boom'));
    });

    test('emit returns false when nobody listens', () {
      rt.eval('var ee = new (require("events"))();');
      expect(rt.eval("ee.emit('nothing-here')"), 'false');
    });

    test('setMaxListeners warns via console', () {
      final warns = <String>[];
      final rt2 = QuickjsRuntime();
      try {
        installNodeCompat(
          rt2,
          NodeCompatConfig(consoleSink: (level, message) {
            if (level == 'warn') warns.add(message);
          }),
        );
        rt2.eval('''
var ee = new (require('events'))();
ee.setMaxListeners(1);
ee.on('x', function () {});
ee.on('x', function () {});
''');
        expect(warns, isNotEmpty);
        expect(warns.first, contains('MaxListenersExceededWarning'));
      } finally {
        rt2.close();
      }
    });
  });

  group('util.promisify / callbackify', () {
    late QuickjsRuntime rt;
    late NodeCompatHandle compat;
    setUp(() {
      rt = QuickjsRuntime();
      compat = installNodeCompat(rt);
    });
    tearDown(() => rt.close());

    test('promisify resolves: timer fires, then reaction runs', () {
      rt.eval('''
var setTimeoutP = util.promisify(function (ms, cb) {
  setTimeout(function () { cb(null, 'done'); }, ms);
});
globalThis.__out = null;
setTimeoutP(0).then(function (v) { __out = v; });
''');
      compat.drainTimers(); // timer callback queues a reaction
      rt.drainMicrotasks(); // reaction resolves __out
      expect(jsStr(rt, '__out'), 'done');
    });

    test('promisify rejects on err', () {
      rt.eval('''
var failP = util.promisify(function (cb) { cb(new Error('nope')); });
globalThis.__msg = null;
failP().catch(function (e) { __msg = e.message; });
''');
      expect(jsStr(rt, '__msg'), 'nope');
    });

    test('promisify is idempotent', () {
      expect(
        rt.eval(
          'var f = function (cb) { cb(null, 1); };'
          'var p = util.promisify(f);'
          'util.promisify(p) === p;',
        ),
        'true',
      );
    });

    test('callbackify converts promise fns', () {
      rt.eval('''
var cbStyle = util.callbackify(function (v) {
  return Promise.resolve(v * 2);
});
globalThis.__res = null;
cbStyle(21, function (err, value) { __res = err === null && value === 42; });
''');
      expect(rt.eval('__res'), 'true');
    });

    test('callbackify surfaces rejections as err', () {
      rt.eval('''
var cbFail = util.callbackify(function () {
  return Promise.reject(new Error('bad'));
});
globalThis.__err = null;
cbFail(function (err, value) { __err = err ? err.message : null; });
''');
      expect(jsStr(rt, '__err'), 'bad');
    });
  });
}
