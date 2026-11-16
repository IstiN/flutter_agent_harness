import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'package:test/test.dart';

/// Contract tests for the cooperative drain stop
/// (`qjs_request_drain_stop` / `qjs_clear_drain_stop` /
/// `qjs_drain_stop_requested`, added to native/quickjs_bridge.c for the
/// js_widget_runtime shutdown-crash fix, surfaced through
/// [QuickjsRuntime.requestDrainStop]).
///
/// Why this exists: a QuickJS worker isolate processes commands
/// sequentially, so a shutdown signal cannot be observed while a
/// pending-job drain runs — and a drain can execute up to 100k promise
/// reactions, each entering a host-callback FI trampoline. At Dart VM
/// teardown those trampolines FATAL ("GetFfiCallbackMetadata called after
/// shutdown") before the isolate has finished exiting — SIGABRT on the
/// worker thread (js_widget_runtime crash report 2026-11-03). The bridge
/// therefore lets the host arm a process-global flag that makes BOTH
/// `qjs_execute_pending_jobs` loops return early, leaving the remaining
/// jobs pending (a later close() frees them): execution stops within one
/// job of the host's dispose starting. The flag must go through the same
/// library instance the drains run in — hence the instance-level Dart
/// API these tests use rather than raw `DynamicLibrary` lookups (native
/// assets and dynamic loads produce separate copies of the atomic).

/// Self-re-enqueueing chain: one `tick()` host call per reaction, chain
/// length [limit]. The eval's auto-drain (`drainMicrotasks`) runs up to
/// 100000 reactions, so [limit] must exceed 100000 for reactions to
/// survive the eval into the explicit drains under test.
String _chainJs(int limit) =>
    '''
var __ticks = 0;
function __step() {
  __ticks++;
  tick();
  if (__ticks < $limit) { Promise.resolve().then(__step); }
}
__step();
''';

void main() {
  tearDown(() {
    // The flag is process-global: never leak an armed stop into the rest
    // of the suite (later tests would silently stop draining).
    QuickjsRuntime().clearDrainStop();
  });

  test('flag round-trips and defaults to clear', () {
    final rt = QuickjsRuntime();
    expect(rt.drainStopRequested, isFalse);
    rt.requestDrainStop();
    expect(rt.drainStopRequested, isTrue);
    rt.clearDrainStop();
    expect(rt.drainStopRequested, isFalse);
  });

  test('executePendingJobs stops at the flag and leaves jobs pending', () {
    final rt = QuickjsRuntime();
    var ticks = 0;
    rt.registerHostFunction('tick', (_) {
      ticks++;
      return null;
    });
    addTearDown(rt.close);

    rt.eval(_chainJs(150000), filename: '<drain_stop>');
    // The eval's auto-drain ran its capped first pass (100000 reactions);
    // the remaining 50000 are still pending on the runtime's job list.
    expect(ticks, 100001); // +1: __step() itself runs synchronously in eval

    rt.requestDrainStop();
    final drained = rt.executePendingJobs();
    // The C loop checks the flag before every job and returns immediately:
    // no host trampoline runs while the stop is armed, and the remaining
    // reactions stay pending (a later close() frees them).
    expect(drained, 0);
    expect(ticks, 100001);

    rt.clearDrainStop();
    rt.executePendingJobs();
    // Released: the whole chain drains.
    expect(ticks, 150000);
  });

  test('capped drain honours the flag too (eval auto-drain lane)', () {
    final rt = QuickjsRuntime();
    var ticks = 0;
    rt.registerHostFunction('tick', (_) {
      ticks++;
      return null;
    });
    addTearDown(rt.close);

    rt.requestDrainStop();
    rt.eval(_chainJs(500), filename: '<drain_stop_capped>');
    // eval's auto-drain and the explicit capped drain both go through the
    // capped C loop — which must honour the flag. Only the synchronous
    // first __step() (inside JS_Eval itself) may have ticked; NO queued
    // reaction may run.
    expect(
      rt.drainMicrotasks(maxJobs: 100),
      0,
      reason:
          'flag set — the capped C loop must return without executing any job',
    );
    expect(
      ticks,
      1,
      reason:
          'only the synchronous __step() (which runs '
          'inside JS_Eval, before any drain) may call the host fn; no '
          'promise reaction may run while the drain stop is armed',
    );
    expect(rt.drainStopRequested, isTrue);

    rt.clearDrainStop();
    rt.executePendingJobs();
    expect(ticks, 500);
  });

  test('bytes-lane dispatch is gated by the drain stop identically', () {
    final rt = QuickjsRuntime();
    if (!rt.hasBytesFn) {
      rt.close();
      markTestSkipped('bridge build has no bytes lane');
      return;
    }
    var calls = 0;
    rt.registerHostBytesFn('probe', (_, __) => calls++);
    addTearDown(rt.close);

    rt.requestDrainStop();
    rt.eval('''
var __n = 0;
function __step() {
  __n++;
  probe('x', new Uint8Array([__n]));
  if (__n < 100) { Promise.resolve().then(__step); }
}
__step();
''', filename: '<drain_stop_bytes>');
    // Only the synchronous first __step() (inside JS_Eval) dispatches;
    // every queued reaction is gated by the flag.
    expect(
      calls,
      1,
      reason:
          'the synchronous __step() runs inside '
          'JS_Eval itself and is not gated; queued reactions must be',
    );
    rt.clearDrainStop();
    rt.executePendingJobs();
    expect(calls, 100);
  });
}
