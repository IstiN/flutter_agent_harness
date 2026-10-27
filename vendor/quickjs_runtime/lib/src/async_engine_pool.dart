/// Pre-spawned engine-worker pool for parallel JavaScript execution over
/// synchronous host callbacks.
///
/// One `QuickjsRuntime` evaluates scripts one at a time on its owning
/// isolate; while a host function runs, that isolate's event loop is
/// frozen. This pool adds *engine-level* parallelism: it owns N worker
/// isolates, each running dispatched functions on engines the consumer
/// wires inside its own [AsyncWorkerMain]. The scripting surface stays
/// synchronous — `runAsync(fn, args)` returns a `Job` whose `wait()`
/// blocks the calling engine until the worker answers.
///
/// The pool owns the transport and lifecycle: worker spawning, handshake,
/// the dispatch/wait mailbox protocol, FIFO backpressure, fire-and-forget
/// envelope caching, and dead-worker completion. The consumer owns the
/// worker body — what "an engine" means for it (runtime creation, host
/// functions, per-worker resources, teardown).
///
/// Boot discipline (same as any FFI-hosting isolate setup): [AsyncEnginePool.boot]
/// spawns the worker isolates and handshakes their inbox ports and MUST run
/// while the main event loop is alive (e.g. from `main()` before any JS
/// evaluates). `Isolate.spawn` cannot make progress while the spawning
/// isolate is blocked inside an FFI callback.
///
/// Mechanism:
/// - [AsyncEnginePool.dispatch] is normally called from JS on the main
///   engine — i.e. from inside a blocked FFI callback. `SendPort.send` is
///   a native non-blocking call, so it works there.
/// - [AsyncEnginePool.wait] parks the calling OS thread on a
///   `Mailbox.take()` (native pthread condvar — no event loop needed)
///   until the worker puts the job envelope. The worker isolate keeps
///   running on another VM thread while the main engine is blocked.
///
/// Backpressure: there are exactly `workers` engines. Dispatch claims an
/// idle worker; when all workers are busy it blocks (FIFO) on the oldest
/// busy worker's completion — jobs queue by dispatch order.
///
/// There are no timeouts: a dispatched function that never returns blocks
/// its caller forever, exactly like a main-script infinite loop would.
///
/// Failure paths: the worker body answers every dispatched job (`ok:false`
/// + error text on any failure — `runAsyncJobOnRuntime` captures JS
/// evaluation errors, and wrapping the body's execution in try/catch covers
/// host/executor errors); a worker isolate that exits is marked dead by an
/// exit listener and its undispatched jobs are completed with an error
/// envelope. Residual gap: a `wait()` already parked on a dead worker's
/// mailbox still blocks.
///
/// Fire-and-forget jobs are legal: completed envelopes nobody waited for
/// are cached and served if [AsyncEnginePool.wait] comes later, and
/// [AsyncEnginePool.dispose] asks the workers to exit (they finish any
/// in-flight job first).
///
/// Example:
/// ```dart
/// // Top-level (or static) — an entry point must cross the isolate spawn.
/// Future<void> workerMain(AsyncWorkerLink link) async {
///   final runtime = myWiredRuntimeFor(link.workerId); // consumer setup
///   try {
///     while (true) {
///       final request = await link.next();
///       if (request == null) return; // shutdown
///       link.complete(runAsyncJobOnRuntime(runtime,
///           jobId: request.jobId,
///           fnSource: request.fnSource,
///           argsJson: request.argsJson));
///     }
///   } finally {
///     runtime.close(); // consumer teardown
///   }
/// }
///
/// final pool = AsyncEnginePool(workers: 4, workerMain: workerMain);
/// await pool.boot();                       // from main(), event loop alive
/// pool.attachMainRuntime(mainRuntime);     // runAsync/AsyncJob globals
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:native_synchronization/mailbox.dart';
import 'package:native_synchronization/sendable.dart';

import 'quickjs_runtime.dart';

/// Completion envelope for one dispatched job.
class AsyncJobEnvelope {
  /// Creates an envelope.
  const AsyncJobEnvelope({
    required this.jobId,
    required this.ok,
    this.resultJson,
    this.error,
  });

  /// Parses an envelope from its worker JSON shape.
  factory AsyncJobEnvelope.fromJson(Map<String, dynamic> json) {
    return AsyncJobEnvelope(
      jobId: json['jobId'] as int,
      ok: json['ok'] as bool,
      resultJson: json['resultJson'] as String?,
      error: json['error'] as String?,
    );
  }

  /// Pool-assigned job id.
  final int jobId;

  /// Whether the function ran to completion without throwing.
  final bool ok;

  /// JSON-encoded return value of the dispatched function.
  final String? resultJson;

  /// Error text when [ok] is false.
  final String? error;

  /// The decoded return value (raw string if it was not valid JSON).
  Object? get decodedResult {
    final raw = resultJson;
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  /// JSON transport shape (worker → pool).
  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'ok': ok,
        'resultJson': resultJson,
        'error': error,
      };
}

/// One dispatched job as seen by the worker side.
class AsyncJobRequest {
  /// Creates a request.
  const AsyncJobRequest({
    required this.jobId,
    required this.workerId,
    required this.fnSource,
    required this.argsJson,
    this.context = const {},
  });

  /// Pool-assigned job id.
  final int jobId;

  /// Id of the worker isolate executing this job.
  final int workerId;

  /// Source text of the (closure-free) dispatched function.
  final String fnSource;

  /// JSON-encoded argument array for the function.
  final String argsJson;

  /// Consumer-opaque snapshot captured at dispatch time by
  /// [AsyncDispatchContext] (e.g. config, overrides, directories).
  final Map<String, dynamic> context;
}

/// Called synchronously at dispatch time on the submitting (main) isolate;
/// its return value travels to the worker as [AsyncJobRequest.context].
typedef AsyncDispatchContext = Map<String, dynamic> Function();

/// Worker-side job runner: runs one dispatched function on this worker's
/// engines and returns the completion envelope.
///
/// Simple consumers wrap [runAsyncJobOnRuntime]; anything thrown here is
/// turned into an `ok:false` envelope by the link loop.
typedef AsyncJobExecutor = Map<String, dynamic> Function(
  AsyncJobRequest request,
);

/// The worker's view of the pool's mailbox protocol.
abstract class AsyncWorkerLink {
  /// Id of this worker (stable across jobs).
  int get workerId;

  /// Awaits the next dispatched job, or `null` after a shutdown request.
  Future<AsyncJobRequest?> next();

  /// Answers the pool for the job the worker took from [next].
  ///
  /// Every dispatched job must be answered exactly once, or a blocked
  /// [AsyncEnginePool.wait] never wakes. `AsyncJobRunner`-style callers
  /// that funnel execution through [AsyncJobExecutor] get this for free.
  void complete(AsyncJobEnvelope envelope);
}

/// Entry point of one worker isolate.
///
/// MUST be a top-level or static function: it is used as the
/// `Isolate.spawn` entry and therefore cannot capture instance state.
/// Consumer setup (engines, resources) reads plain data from
/// [AsyncJobRequest.context] instead.
typedef AsyncWorkerMain = Future<void> Function(AsyncWorkerLink link);

/// Lifecycle state of one worker (main-side view).
enum _WorkerState { booting, idle, busy, dead }

/// Parsed `runAsync(fn, args)` host-call arguments.
/// The worker-shutdown control message on the spawn inbox.
const String _shutdownMessage = 'shutdown';

class _DispatchArgs {
  const _DispatchArgs({this.fnSource, this.argsJson, this.error});

  /// JS function source; null when validation failed.
  final String? fnSource;

  /// JSON-encoded args; null when validation failed.
  final String? argsJson;

  /// Validation message for the `__jsError` sentinel.
  final String? error;
}

class _Worker {
  _Worker({
    required this.id,
    required this.isolate,
    required this.sendPort,
    required this.doneBox,
  });

  final int id;
  final Isolate isolate;
  final SendPort sendPort;
  final Mailbox doneBox;
  _WorkerState state = _WorkerState.booting;
}

class _PendingJob {
  _PendingJob({required this.workerId});

  final int workerId;
}

/// Spawn message for a worker isolate.
class _WorkerInit {
  _WorkerInit({
    required this.workerId,
    required this.handshake,
    required this.doneBox,
  });

  final int workerId;
  final SendPort handshake;
  final Sendable<Mailbox> doneBox;
}

/// Pool of engine-worker isolates serving dispatched functions.
///
/// Consumers create private pools and must call [dispose] in teardown so
/// the isolates exit and the test runner ends.
class AsyncEnginePool {
  /// Creates a pool that [boot]s [workers] engine isolates running
  /// [workerMain].
  ///
  /// Exactly one of [workerMain] / [executor] must be provided: a
  /// [workerMain] pool hands each worker to the consumer's loop; an
  /// [executor] pool uses the default one-engine-per-job loop.
  AsyncEnginePool({
    AsyncWorkerMain? workerMain,
    this.workers = defaultWorkerCount,
    AsyncDispatchContext? dispatchContext,
    AsyncJobExecutor? executor,
  })  : assert(
          (workerMain == null) != (executor == null),
          'provide exactly one of workerMain / executor',
        ),
        _workerMain = workerMain,
        _dispatchContext = dispatchContext,
        _executor = executor;

  /// Default worker count.
  static const int defaultWorkerCount = 4;

  static final Uint8List _readyMessage = utf8.encode('ready');

  /// Number of engine isolates this pool boots.
  final int workers;

  final AsyncWorkerMain? _workerMain;
  final AsyncDispatchContext? _dispatchContext;
  final AsyncJobExecutor? _executor;

  final _workers = <_Worker>[];
  final _jobs = <int, _PendingJob>{};
  final _completed = <int, AsyncJobEnvelope>{};
  ReceivePort? _exitPort;
  Future<void>? _booting;
  bool _booted = false;
  int _nextJobId = 0;

  /// Whether [dispatch] is usable.
  bool get ready => _booted;

  /// Boots the worker isolates; idempotent (later calls return the first
  /// boot's future). Must run while the event loop is alive.
  Future<void> boot() => _booting ??= _boot();

  Future<void> _boot() async {
    final exitPort = ReceivePort()..listen(_onWorkerExit);
    _exitPort = exitPort;
    for (var i = 0; i < workers; i++) {
      final handshake = ReceivePort();
      final doneBox = Mailbox();
      final init = _WorkerInit(
        workerId: i,
        handshake: handshake.sendPort,
        doneBox: doneBox.asSendable,
      );
      final isolate =
          await Isolate.spawn(_isolateEntry, (init, _workerMain, _executor));
      isolate.addOnExitListener(exitPort.sendPort, response: i);
      final port = await handshake.first as SendPort;
      handshake.close();
      _workers.add(
        _Worker(id: i, isolate: isolate, sendPort: port, doneBox: doneBox),
      );
    }
    _booted = true;
  }

  /// Wires the `runAsync` scripting surface onto a main engine: registers
  /// the `__jsrDispatchHost` / `__jsrWaitHost` host functions and evaluates
  /// [asyncJobPrelude] (the `runAsync` / `AsyncJob` globals).
  ///
  /// Per-dispatch context is captured through [AsyncDispatchContext] —
  /// set either at construction (pool-wide default) or per main runtime
  /// via [dispatchContext]. The runtime-attached provider wins when both
  /// are set: a shared pool serves many main engines whose dispatch
  /// context differs per engine (script directory, job params, …).
  ///
  /// The provider runs synchronously on the submitting isolate inside the
  /// `runAsync` host call; its return value must be SendPort-safe (plain
  /// JSON-ish maps/lists/scalars) because it crosses to the worker
  /// isolate in the job payload.
  ///
  /// When the pool is not booted, `runAsync(...)` throws a clear JS error
  /// on first use (dispatch sentinel) instead of failing the engine
  /// wiring.
  void attachMainRuntime(QuickjsRuntime runtime,
      {AsyncDispatchContext? dispatchContext}) {
    runtime.registerHostFunction('__jsrDispatchHost', (argsJson) {
      return _dispatchHost(argsJson, context: dispatchContext);
    });
    runtime.registerHostFunction('__jsrWaitHost', (argsJson) {
      return _waitHost(argsJson);
    });
    runtime.eval(asyncJobPrelude, filename: '<async_prelude>');
  }

  /// Dispatches one job to a worker and returns its id.
  ///
  /// Blocks while every worker is busy (FIFO backpressure — see the
  /// library docs) or while the first worker finishes booting.
  int dispatch({
    required String fnSource,
    required String argsJson,
    Map<String, dynamic>? context,
  }) {
    if (!_booted) {
      throw StateError('JS worker pool is not booted');
    }
    final worker = _acquireWorker();
    final jobId = _nextJobId++;
    _jobs[jobId] = _PendingJob(workerId: worker.id);
    worker.sendPort.send(
      jsonEncode({
        'jobId': jobId,
        'fnSource': fnSource,
        'argsJson': argsJson,
        'context': context ??
            (_dispatchContext != null
                ? _dispatchContext()
                : const <String, dynamic>{}),
      }),
    );
    return jobId;
  }

  /// Waits for [jobId] and returns its envelope (blocking).
  ///
  /// Serving from cache makes a late `wait()` on an already-completed
  /// fire-and-forget job work. Waiting twice for the same job throws.
  AsyncJobEnvelope wait(int jobId) {
    final cached = _completed.remove(jobId);
    if (cached != null) {
      _jobs.remove(jobId);
      return cached;
    }
    final pending = _jobs[jobId];
    if (pending == null) {
      throw StateError('Unknown or already-waited async job id $jobId');
    }
    final worker = _workerById(pending.workerId);
    while (true) {
      final envelope = _takeEnvelope(worker);
      if (envelope.jobId == jobId) {
        _jobs.remove(jobId);
        return envelope;
      }
      _completed[envelope.jobId] = envelope;
    }
  }

  /// Asks every worker to exit (in-flight jobs finish first) and resets the
  /// pool; a fresh [boot] revives it.
  void dispose() {
    for (final worker in _workers) {
      if (worker.state != _WorkerState.dead) {
        worker.sendPort.send(_shutdownMessage);
      }
    }
    _workers.clear();
    _jobs.clear();
    _completed.clear();
    _exitPort?.close();
    _exitPort = null;
    _booted = false;
    _booting = null;
  }

  /// Kills a worker isolate outright (dead-worker test hook).
  ///
  /// `Isolate.beforeNextEvent` lets the worker unwind — its own `finally`
  /// blocks run, so consumer-held per-worker resources are released by the
  /// worker itself.
  void killWorkerForTest(int workerId) {
    _workerById(workerId).isolate.kill(priority: Isolate.beforeNextEvent);
  }

  /// `__jsrDispatchHost` implementation: parses the JS call, captures the
  /// dispatch context, dispatches, and answers with the JSON job id — or a
  /// `{'__jsError': …}` sentinel the prelude rethrows.
  String _dispatchHost(String argsJson, {AsyncDispatchContext? context}) {
    try {
      final parsed = _parseDispatchArgs(argsJson);
      final error = parsed.error;
      if (error != null) return jsonEncode({'__jsError': error});
      final jobId = dispatch(
        fnSource: parsed.fnSource!,
        argsJson: parsed.argsJson!,
        context: context?.call(),
      );
      return jsonEncode(jobId);
    } catch (e) {
      return jsonEncode({'__jsError': 'runAsync dispatch failed: $e'});
    }
  }

  /// Validates the JS-side `runAsync(fn, args)` arguments.
  ///
  /// Returns the fn source plus JSON-encoded args, or an `error` message
  /// shaped like the JS-side TypeError the prelude surfaces.
  _DispatchArgs _parseDispatchArgs(String argsJson) {
    final args = jsonDecode(argsJson);
    if (args is! List || args.length < 2 || args[0] is! String) {
      return _DispatchArgs(
        error: 'runAsync expects (function, args) — '
            'got ${args is List ? args.length : 'non-array'} arguments',
      );
    }
    final second = args[1];
    return _DispatchArgs(
      fnSource: args[0] as String,
      argsJson: second is String ? second : jsonEncode(second),
    );
  }

  /// `__jsrWaitHost` implementation: blocks on the pool until [argsJson]'s
  /// job completes, then answers with the JS envelope JSON — or a
  /// `{'__jsError': …}` sentinel.
  String _waitHost(String argsJson) {
    try {
      final id = jsonDecode(argsJson);
      if (id is! int) {
        return jsonEncode({'__jsError': 'AsyncJob.wait expects a job id'});
      }
      final envelope = wait(id);
      return jsonEncode({
        'ok': envelope.ok,
        'result': envelope.decodedResult,
        'error': envelope.error,
      });
    } catch (e) {
      return jsonEncode({'__jsError': 'AsyncJob.wait failed: $e'});
    }
  }

  /// Claims a worker for [dispatch], draining completed jobs as needed.
  _Worker _acquireWorker() {
    if (_workers.isEmpty) {
      throw StateError('JS worker pool has no workers');
    }
    for (final worker in _workers) {
      _settleWorker(worker);
      if (worker.state == _WorkerState.idle) return _claim(worker);
    }
    // Saturated: block on the oldest busy worker's completion (FIFO).
    final busy = _workers.where((w) => w.state == _WorkerState.busy).toList();
    if (busy.isEmpty) {
      throw StateError('JS worker pool has no live workers');
    }
    final envelope = _takeEnvelope(busy.first);
    _completed[envelope.jobId] = envelope;
    return _claim(busy.first);
  }

  void _settleWorker(_Worker worker) {
    if (worker.state == _WorkerState.booting) {
      final message = utf8.decode(worker.doneBox.take());
      if (message != 'ready') {
        throw StateError('Unexpected worker message: $message');
      }
      worker.state = _WorkerState.idle;
    }
  }

  AsyncJobEnvelope _takeEnvelope(_Worker worker) {
    final raw = utf8.decode(worker.doneBox.take());
    final envelope = AsyncJobEnvelope.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    worker.state = _WorkerState.idle;
    return envelope;
  }

  _Worker _claim(_Worker worker) {
    worker.state = _WorkerState.busy;
    return worker;
  }

  _Worker _workerById(int id) => _workers.firstWhere((w) => w.id == id);

  /// Exit listener: marks the worker dead and completes its undispatched
  /// jobs with an error envelope (delivered when the event loop can run).
  void _onWorkerExit(dynamic message) {
    if (message is! int || _exitPort == null) return;
    final worker = _workerById(message);
    worker.state = _WorkerState.dead;
    _jobs.removeWhere((jobId, job) {
      if (job.workerId != worker.id) return false;
      _completed[jobId] = AsyncJobEnvelope(
        jobId: jobId,
        ok: false,
        error: 'JS worker ${worker.id} exited unexpectedly',
      );
      return true;
    });
  }

  /// Spawn entry: hops through the package-static trampoline so the
  /// consumer's top-level [AsyncWorkerMain] reference can cross the spawn
  /// boundary inside the plain-data message.
  static Future<void> _isolateEntry(
    (_WorkerInit, AsyncWorkerMain?, AsyncJobExecutor?) message,
  ) {
    final (init, workerMain, executor) = message;
    return _workerLoop(init, workerMain, executor);
  }

  /// The pool-provided worker loop: handshake, ready, then the consumer's
  /// [AsyncWorkerMain] (or, when only an [AsyncJobExecutor] was given, the
  /// default runtime-per-job loop below).
  static Future<void> _workerLoop(
    _WorkerInit init,
    AsyncWorkerMain? workerMain,
    AsyncJobExecutor? executor,
  ) async {
    final inbox = ReceivePort();
    final doneBox = init.doneBox.materialize();
    init.handshake.send(inbox.sendPort);
    doneBox.put(_readyMessage);
    if (executor != null) {
      await _executorLoop(inbox, init.workerId, doneBox, executor);
      return;
    }
    await workerMain!(_PoolWorkerLink(inbox, init.workerId, doneBox));
  }

  /// Default worker loop for executor-only pools: one engine per job,
  /// built and owned by [AsyncJobExecutor].
  static Future<void> _executorLoop(
    ReceivePort inbox,
    int workerId,
    Mailbox doneBox,
    AsyncJobExecutor executor,
  ) async {
    await for (final message in inbox) {
      if (message == _shutdownMessage) return;
      final request = jsonDecode(message as String) as Map<String, dynamic>;
      final jobId = request['jobId'] as int;
      final jobRequest = AsyncJobRequest(
        jobId: jobId,
        workerId: workerId,
        fnSource: request['fnSource'] as String,
        argsJson: request['argsJson'] as String,
        context:
            (request['context'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
      Map<String, dynamic> envelope;
      try {
        envelope = executor(jobRequest);
      } catch (e) {
        envelope = AsyncJobEnvelope(
          jobId: jobId,
          ok: false,
          error: e.toString(),
        ).toJson();
      }
      doneBox.put(utf8.encode(jsonEncode(envelope)));
    }
  }
}

/// [AsyncWorkerLink] implementation talking to the pool's main side.
class _PoolWorkerLink implements AsyncWorkerLink {
  _PoolWorkerLink(this._inbox, this._workerId, this._doneBox);

  final ReceivePort _inbox;
  final int _workerId;
  final Mailbox _doneBox;
  StreamIterator<dynamic>? _iterator;

  @override
  int get workerId => _workerId;

  @override
  Future<AsyncJobRequest?> next() async {
    // ReceivePort is single-subscription — one StreamIterator serves all
    // jobs; a closed inbox (moveNext false) counts as shutdown.
    final iterator = _iterator ??= StreamIterator<dynamic>(_inbox);
    if (!await iterator.moveNext()) return null;
    final message = iterator.current;
    if (message == _shutdownMessage) return null;
    final request = jsonDecode(message as String) as Map<String, dynamic>;
    return AsyncJobRequest(
      jobId: request['jobId'] as int,
      workerId: _workerId,
      fnSource: request['fnSource'] as String,
      argsJson: request['argsJson'] as String,
      context:
          (request['context'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }

  @override
  void complete(AsyncJobEnvelope envelope) {
    _doneBox.put(utf8.encode(jsonEncode(envelope.toJson())));
  }
}

/// Runs one dispatched function on [runtime] using the pool's calling
/// convention and returns its completion envelope.
///
/// The runtime must already carry the consumer's host functions; this
/// helper evaluates the [asyncWorkerBootstrap] (`__jsrCall`), materializes
/// the (closure-free) function, calls it with the parsed args, and encodes
/// the result. JS evaluation failures become `ok:false` envelopes.
Map<String, dynamic> runAsyncJobOnRuntime(
  QuickjsRuntime runtime, {
  required int jobId,
  required String fnSource,
  required String argsJson,
  String bootstrapFilename = '<jsr_worker_bootstrap>',
  String jobFilename = '<jsr_job>',
}) {
  runtime.eval(asyncWorkerBootstrap, filename: bootstrapFilename);
  final errors = <String?>[];
  final result = runtime.eval(
    '__jsrCall(${jsonEncode(fnSource)}, ${jsonEncode(argsJson)})',
    filename: jobFilename,
    errMsg: errors,
  );
  return AsyncJobEnvelope(
    jobId: jobId,
    ok: errors.isEmpty,
    resultJson: result,
    error: errors.isEmpty ? null : errors.first,
  ).toJson();
}

/// Main-engine bootstrap: `runAsync` / `AsyncJob` / `runAsync.all`.
///
/// Host functions underneath (registered by [AsyncEnginePool.attachMainRuntime]):
/// - `__jsrDispatchHost(fnSource, argsJson)` → JSON job id, or a
///   `{'__jsError': …}` sentinel (rethrown as a real JS `Error`).
/// - `__jsrWaitHost(jobId)` → JSON envelope `{'ok', 'result', 'error'}` —
///   blocks the calling engine until the worker answers.
const String asyncJobPrelude = '''
(function() {
    // Host results arrive as real JS values (the C bridge runs
    // JS_ParseJSON on them) — no JSON.parse here, only sentinel checks.
    function Job(id) {
        this.id = id;
    }
    Job.prototype.wait = function() {
        var env = __jsrWaitHost(this.id);
        if (env && env.__jsError !== undefined) {
            throw new Error(env.__jsError);
        }
        if (!env || !env.ok) {
            throw new Error('runAsync job ' + this.id + ' failed: ' +
                (env && env.error ? env.error : 'no result'));
        }
        return env.result;
    };
    function runAsync(fn, args) {
        if (typeof fn !== 'function') {
            throw new Error('runAsync expects a function as its first argument');
        }
        var argsJson = JSON.stringify(args === undefined ? null : args);
        var jobId = __jsrDispatchHost(fn.toString(), argsJson);
        if (jobId && jobId.__jsError !== undefined) {
            throw new Error(jobId.__jsError);
        }
        return new Job(jobId);
    }
    runAsync.all = function(jobs) {
        if (!Array.isArray(jobs)) {
            throw new Error('runAsync.all expects an array of jobs');
        }
        return {
            wait: function() {
                return jobs.map(function(job) { return job.wait(); });
            }
        };
    };
    globalThis.runAsync = runAsync;
    globalThis.AsyncJob = Job;
})();
''';

/// Worker-engine bootstrap: materializes and runs one dispatched function.
const String asyncWorkerBootstrap = '''
(function() {
    globalThis.__jsrCall = function(fnSource, argsJson) {
        var fn = eval('(' + fnSource + ')');
        if (typeof fn !== 'function') {
            throw new Error('runAsync: dispatched value is not a function');
        }
        return fn(JSON.parse(argsJson));
    };
})();
''';
