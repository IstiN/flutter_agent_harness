import 'dart:convert';

import 'package:quickjs_runtime/quickjs_runtime.dart';
import 'package:test/test.dart';

/// Top-level worker main with a warm per-worker engine (state persists
/// across jobs on the same worker). Counts jobs in `globalThis.__jobs`.
Future<void> warmWorkerMain(AsyncWorkerLink link) async {
  final runtime = QuickjsRuntime();
  try {
    while (true) {
      final request = await link.next();
      if (request == null) return;
      runtime.eval('globalThis.__jobs = (globalThis.__jobs || 0) + 1');
      link.complete(
        AsyncJobEnvelope.fromJson(
          runAsyncJobOnRuntime(
            runtime,
            jobId: request.jobId,
            fnSource: request.fnSource,
            argsJson: request.argsJson,
          ),
        ),
      );
    }
  } finally {
    runtime.close();
  }
}

/// Executor-style worker: one fresh engine per job running the dispatched
/// function (with the dispatch context exposed as `__ctx`).
Map<String, dynamic> echoExecutor(AsyncJobRequest request) {
  final runtime = QuickjsRuntime();
  try {
    runtime.setGlobal('__ctx', request.context);
    return runAsyncJobOnRuntime(
      runtime,
      jobId: request.jobId,
      fnSource: request.fnSource,
      argsJson: request.argsJson,
    );
  } finally {
    runtime.close();
  }
}

/// Warm worker that echoes the dispatch context it received: the
/// dispatched function reads it as `globalThis.__ctx`.
Future<void> contextEchoWorkerMain(AsyncWorkerLink link) async {
  final runtime = QuickjsRuntime();
  try {
    while (true) {
      final request = await link.next();
      if (request == null) return;
      runtime.setGlobal('__ctx', request.context);
      link.complete(
        AsyncJobEnvelope.fromJson(
          runAsyncJobOnRuntime(
            runtime,
            jobId: request.jobId,
            fnSource: request.fnSource,
            argsJson: request.argsJson,
          ),
        ),
      );
    }
  } finally {
    runtime.close();
  }
}

void main() {
  group('per-runtime dispatch context (attachMainRuntime)', () {
    late AsyncEnginePool pool;
    late QuickjsRuntime main;

    setUp(() async {
      pool = AsyncEnginePool(
        workers: 1,
        workerMain: contextEchoWorkerMain,
        dispatchContext: () => {'source': 'pool'},
      );
      await pool.boot();
      main = QuickjsRuntime();
      pool.attachMainRuntime(
        main,
        dispatchContext: () => {'source': 'runtime', 'at': 'dispatch'},
      );
    });

    tearDown(() {
      main.close();
      pool.dispose();
    });

    test('runtime-attached provider reaches the worker through runAsync', () {
      final result = main.eval(
        "runAsync(function () { return globalThis.__ctx; }, null).wait()",
      );
      final ctx = jsonDecode(result!) as Map<String, dynamic>;
      expect(ctx['source'], 'runtime');
      expect(ctx['at'], 'dispatch');
    });

    test('pool-level provider is the default when the runtime has none', () {
      final other = QuickjsRuntime();
      pool.attachMainRuntime(other);
      try {
        final result = other.eval(
          "runAsync(function () { return globalThis.__ctx; }, null).wait()",
        );
        final ctx = jsonDecode(result!) as Map<String, dynamic>;
        expect(ctx['source'], 'pool');
      } finally {
        other.close();
      }
    });

    test('explicit dispatch context still wins over providers', () {
      final id = pool.dispatch(
        fnSource: 'function () { return globalThis.__ctx; }',
        argsJson: 'null',
        context: {'source': 'explicit'},
      );
      expect(pool.wait(id).decodedResult, {'source': 'explicit'});
    });
  });

  group('executor-style pool', () {
    late AsyncEnginePool pool;

    setUp(() async {
      pool = AsyncEnginePool(workers: 2, executor: echoExecutor);
      await pool.boot();
    });

    tearDown(() => pool.dispose());

    test('dispatch + wait returns the function result', () {
      final id = pool.dispatch(
        fnSource: 'function (x) { return x * 2; }',
        argsJson: '21',
      );
      final envelope = pool.wait(id);
      expect(envelope.ok, isTrue);
      expect(envelope.decodedResult, 42);
    });

    test('dispatch context travels to the worker', () {
      final id = pool.dispatch(
        fnSource: 'function () { return __ctx; }',
        argsJson: 'null',
        context: {'who': 'main', 'n': 7},
      );
      final envelope = pool.wait(id);
      expect(envelope.ok, isTrue);
      expect(envelope.decodedResult, {'who': 'main', 'n': 7});
    });

    test('fire-and-forget jobs are served by a later wait', () {
      final forgotten = pool.dispatch(
        fnSource: 'function () { return "forgotten"; }',
        argsJson: 'null',
      );
      // Waiting on ANOTHER job drains the worker's mailbox and caches the
      // first envelope — the late wait() below must be served from cache.
      final other = pool.dispatch(
        fnSource: 'function () { return 1; }',
        argsJson: 'null',
      );
      pool.wait(other);
      expect(pool.wait(forgotten).decodedResult, 'forgotten');
    });

    test('waiting twice for the same job throws', () {
      final id = pool.dispatch(
        fnSource: 'function () { return 1; }',
        argsJson: 'null',
      );
      pool.wait(id);
      expect(() => pool.wait(id), throwsStateError);
    });

    test('dispatch without boot throws a StateError', () {
      final cold = AsyncEnginePool(workers: 1, executor: echoExecutor);
      expect(
        () => cold.dispatch(fnSource: 'function(){}', argsJson: 'null'),
        throwsStateError,
      );
    });
  });

  group('workerMain pool (warm engines)', () {
    late AsyncEnginePool pool;
    late QuickjsRuntime main;

    setUp(() async {
      pool = AsyncEnginePool(workers: 1, workerMain: warmWorkerMain);
      await pool.boot();
      main = QuickjsRuntime();
      pool.attachMainRuntime(main);
    });

    tearDown(() {
      main.close();
      pool.dispose();
    });

    test('runAsync end-to-end over the attached main runtime', () {
      final result = main.eval(
        'runAsync(function (x) { return x * 2; }, [21]).wait()',
      );
      expect(result, '42');
    });

    test('worker state persists across jobs (warm engine reuse)', () {
      final src = 'function () { return globalThis.__jobs || 0; }';
      final first = pool.dispatch(fnSource: src, argsJson: 'null');
      final second = pool.dispatch(fnSource: src, argsJson: 'null');
      expect(pool.wait(first).decodedResult, 1);
      expect(pool.wait(second).decodedResult, 2);
    });

    test('runAsync.all waits every job', () {
      final result = main.eval('''
        runAsync.all([
          runAsync(function () { return 1; }, null),
          runAsync(function () { return 2; }, null)
        ]).wait()
      ''');
      expect(jsonDecode(result!), [1, 2]);
    });

    test('runAsync validates its arguments through the sentinel', () {
      final errors = <String?>[];
      main.eval('runAsync(42, null)', errMsg: errors);
      expect(errors.first, contains('runAsync expects a function'));
    });

    test('failed job surfaces as a JS error from wait()', () {
      final errors = <String?>[];
      main.eval(
        'runAsync(function () { throw new Error("nope"); }, null).wait()',
        errMsg: errors,
      );
      expect(errors.first, contains('nope'));
    });
  });

  group('backpressure and lifecycle', () {
    test('saturated dispatch queues FIFO by dispatch order', () async {
      final pool = AsyncEnginePool(workers: 1, executor: echoExecutor);
      await pool.boot();
      // workers=1: dispatches 2 and 3 block until the worker finishes the
      // previous job, so wait order proves FIFO backpressure.
      final ids = [0, 1, 2]
          .map((i) => pool.dispatch(
                fnSource: 'function () { return $i; }',
                argsJson: 'null',
              ))
          .toList();
      final results = [for (final id in ids) pool.wait(id).decodedResult];
      expect(results, [0, 1, 2]);
      pool.dispose();
    });

    test('dead worker completes its unwaited job with an error envelope',
        () async {
      final pool = AsyncEnginePool(workers: 2, executor: echoExecutor);
      await pool.boot();
      final id = pool.dispatch(
        fnSource: 'function () { return 1; }',
        argsJson: 'null',
      );
      pool.killWorkerForTest(0);
      // Let the exit listener deliver the error completion.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final envelope = pool.wait(id);
      expect(envelope.ok, isFalse);
      expect(envelope.error, contains('exited unexpectedly'));
      pool.dispose();
    });

    test('all workers dead: dispatch surfaces a clear error', () async {
      final pool = AsyncEnginePool(workers: 1, executor: echoExecutor);
      await pool.boot();
      pool.killWorkerForTest(0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        () => pool.dispatch(
          fnSource: 'function () { return 1; }',
          argsJson: 'null',
        ),
        throwsStateError,
      );
      pool.dispose();
    });

    test('dispose lets worker mains unwind and the pool reboot', () async {
      final pool = AsyncEnginePool(workers: 1, workerMain: warmWorkerMain);
      await pool.boot();
      pool.dispose();
      await pool.boot();
      final id = pool.dispatch(
        fnSource: 'function () { return "revived"; }',
        argsJson: 'null',
      );
      expect(pool.wait(id).decodedResult, 'revived');
      pool.dispose();
    });
  });
}
