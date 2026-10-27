# quickjs_runtime

A pure-Dart QuickJS JavaScript runtime on `dart:ffi` with **synchronous
host callbacks**. No Flutter, no Flutter SDK — `dart pub get && dart test`
is all you need.

- Vendored QuickJS **2024-01-13** sources
- A C bridge (`native/quickjs_bridge.c`) with JSON-based marshaling: JS
  arguments are stringified to JSON in C, passed to a synchronous Dart
  callback (`NativeCallable`), and the JSON result is parsed back into a
  JS value
- One flat C ABI: `qjs_create_runtime`, `qjs_eval`, `qjs_register_host_fn`, …

## Build

```sh
tool/build_quickjs.sh   # produces native/quickjs/libquickjs_bridge.so (gcc)
```

A fresh checkout (including a pub-cache download) has **no** `.so` — run
the build once after `pub add`. pub packages cannot ship binaries, so
consumers wire this into their own build (Makefile / CI step).

The library is looked up via the `JSR_QUICKJS_LIB` env var, inside this
package's checkout, or in `<cwd>/native/quickjs/` — in that order.

## Usage

```dart
import 'package:quickjs_runtime/quickjs_runtime.dart';

final rt = QuickjsRuntime();
rt.registerHostFunction('add', (argsJson) {
  final args = jsonDecode(argsJson) as List;
  return jsonEncode(args[0] + args[1]);
});
print(rt.eval('add(2, 3)')); // 5
rt.executePendingJobs();     // drain promise reactions
rt.close();
```

## Parallel engines (`runAsync`)

`AsyncEnginePool` adds engine-level parallelism while keeping the
scripting surface synchronous: `runAsync(fn, args)` returns a `Job`
whose `wait()` blocks the calling engine (no promises, no event loop).

```dart
// Top-level (static) — it crosses the isolate spawn boundary.
Future<void> workerMain(AsyncWorkerLink link) async {
  final runtime = QuickjsRuntime();          // consumer wiring here
  try {
    while (true) {
      final request = await link.next();
      if (request == null) return;           // shutdown
      link.complete(runAsyncJobOnRuntime(runtime,
          jobId: request.jobId,
          fnSource: request.fnSource,
          argsJson: request.argsJson));
    }
  } finally {
    runtime.close();
  }
}

final pool = AsyncEnginePool(workers: 4, workerMain: workerMain);
await pool.boot();                           // from main(), event loop alive
pool.attachMainRuntime(rt);                  // adds runAsync/AsyncJob globals
```

```js
// in JS
var job = runAsync(function (x) { return expensive(x); }, [arg]);
var result = job.wait();
var all = runAsync.all([job1, job2, job3]).wait();
```

Boot the pool from `main()` **before** any JS evaluates —
`Isolate.spawn` cannot progress while the isolate is blocked inside an
FFI callback. No timeouts: a dispatched function that never returns
blocks its caller forever, like any infinite script loop.

VM-only (`dart:ffi`): never import from a web-reachable path.

## Node/js compat layer (opt-in)

The bare runtime is a clean-room ES2020 — no `console`, `process`,
`setTimeout`. `installNodeCompat` adds the idioms scripts habitually
reach for, and turns the unsupported ones into self-documenting errors
instead of bare `ReferenceError`s:

```dart
installNodeCompat(rt, NodeCompatConfig(
  env: platformEnv,          // process.env snapshot
  cwd: () => dir,            // process.cwd() / path.resolve base
  randomBytes: secureRandom, // crypto.getRandomValues
  consoleSink: (level, msg) => myLog(level, msg),
));
```

```js
global === globalThis;                 // true
path.join('a', 'b');                   // 'a/b'
process.env.HOME;                      // from the snapshot
require('assert').equal(2 + 2, 4);
new TextEncoder().encode('hi');        // Uint8Array
btoa('hello');                         // 'aGVsbG8='
structuredClone(v);                    // JSON fidelity
Buffer.from('hi', 'utf8').toString('base64'); // 'aGk='
new URL('?b=2', 'http://h/a?x=1').href;       // 'http://h/a?b=2'
console.time('x'); console.timeEnd('x');      // 'x: 0.123ms'
var EventEmitter = require('events');
setTimeout(f, 10);                     // registers; fires when the host
                                       // drains timers (see below)
```

**Buffer** is a real `Uint8Array` subclass with the Node encodings
(`utf8`/`utf16le`/`latin1`/`ascii`/`hex`/`base64`/`base64url`),
`from`/`alloc`/`allocUnsafe`/`concat`/`byteLength`/`isBuffer`/`compare`,
instance `toString`/`write`/`fill`/`copy`/`equals`/`indexOf`/`slice`/
`toJSON` and the LE/BE `read*`/`write*` primitives over a `DataView`.

**URL / URLSearchParams** implement the commonly scripted WHATWG subset:
special-scheme default ports, relative resolution, live `searchParams`
binding, `origin`, `canParse`/`parse`, form-urlencoded codec.

**`fetch`** becomes real when the embedding provides an HTTP transport
(`NodeCompatConfig.httpFetch`): Node-shaped `fetch(input, init)` with
`Headers` (case-insensitive) and `Response` (`ok`, `status`, `headers`,
one-shot `text()`/`json()`/`arrayBuffer()`/`bytes()` with the
`bodyUsed` guard). Body accessors return plain values — await-compatible,
documented. Network failures throw `TypeError: fetch failed` with the
transport message in `error.cause`; `init.signal` is accepted and
ignored. Without the hook the self-documenting stub stays.

**console** gains `time`/`timeEnd`/`timeLog`, `count`/`countReset`,
`group`/`groupEnd`, `table`, `dir`, `trace`; `util.inspect` renders
Node-style. **process** gains `argv`, `pid`, `execPath`, `hrtime`
(+`.bigint()`), `uptime`, `memoryUsage`, `stdout`/`stderr` writes,
`on('exit')` listeners; `__filename`/`__dirname` follow
`NodeCompatConfig.scriptPath` (or `NodeCompatHandle.setScriptPath`).
**Intl** constructors are typeof-safe call-time stubs (no ICU in
QuickJS). Default text codecs are real UTF-8; hooks remain for override.

Builtin modules via `require`: `path`, `assert`, `util`, `os`, `url`,
`buffer`, `events`. Consumers can register more
(`installNodeCompatModule(rt, 'fs', factory)`) and a pre-existing
`require` loader stays reachable as the fallback.

### Timers, microtasks and `events` (host-driven, no event loop)

Promise reactions drain automatically after every `QuickjsRuntime.eval`
(Node/GraalJS parity — `.then` chains, `queueMicrotask`,
`util.promisify` just work; the drain is capped so a self-re-enqueueing
chain cannot hang the host, and `QuickjsRuntime(autoDrainMicrotasks:
false)` restores manual draining via `drainMicrotasks()`).

Timers (`setTimeout`/`setInterval`/`setImmediate` + `clear*`) are real
but **host-driven** — there is no background loop to fire them. The
embedding drains at its chosen checkpoints:

```dart
final compat = installNodeCompat(rt, NodeCompatConfig(
  timerDrain: TimerDrainMode.block, // ready (default) | none
  sleep: (d) => myBlockingSleep(d), // default: C-bridge qjs_sleep_ms
));
rt.eval('setTimeout(function () { step(2); }, 50);');
final stats = compat.drainTimers(); // runs due timers + microtasks
```

- `TimerDrainMode.ready` (default): one pass — what is due now runs,
  future timers stay queued. Safe on UI isolates.
- `TimerDrainMode.block`: loops, blocking the thread (via `sleep`)
  until the earliest ref'd timer is due, the queue empties, or a guard
  raises (`maxTimerCallbacks` per pass — the `setInterval(fn, 0)` storm
  guard; `maxTimerDrainWallClock`). Unref'd timers never hold the
  drain. For CLI embeddings where "setTimeout as sleep" must behave
  like Node.
- Ordering matches Node for the common cases: sync code always runs
  before any timer, immediates run before due timeouts, equal dues in
  registration order. Timer callbacks never interrupt a running script
  — they run between drain passes.

**`events`** is 1:1: Node's `EventEmitter` is synchronous, so
`require('events')` needs no loop at all (`on`/`once`/`prepend*`/
`off`/`removeAllListeners`/`emit`/`listenerCount`/`eventNames`/
`setMaxListeners`, `error` with no listener throws, max-listeners
warning via `console.warn`).

**Known deviations vs Node** (all documented, all deterministic):
timer callbacks run only between host checkpoints — a `setInterval`
tick never interrupts script code; `process.nextTick` maps onto the
microtask queue (interleaves in promise order instead of running
before promise reactions); body accessors and timer handles expose
plain values/no-op `ref` for immediates; no `AbortSignal`, no streams,
no workers — those need real concurrency (`runAsync` covers engines).


## Testing

```sh
tool/build_quickjs.sh
dart test
```
