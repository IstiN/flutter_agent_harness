# 0.4.2

- `hook/build.dart`: pass `-Wl,-z,max-page-size=16384` on Android (Google
  Play 16 KB page-size alignment gate) and `-headerpad_max_install_names` +
  `-install_name @rpath/libquickjs_bridge.dylib` on iOS/macOS (App Store
  Connect / TestFlight framework embedding and codesign reproducibility).

# 0.4.1

- Widen `code_assets` (`>=1.2.0 <3.0.0`) and `hooks` (`>=1.0.0 <3.0.0`)
  constraints so apps pinning `code_assets ^1.2.0` (e.g.
  `flutter_gemma_litertlm`) resolve cleanly without changing their lockfile.

# 0.4.0

- **Dart & Flutter Native Assets (`hook/build.dart`)**: `quickjs_runtime`
  now compiles `quickjs_bridge.c` and QuickJS 2024-01-13 automatically via
  `code_assets` + `native_toolchain_c` on iOS, Android, macOS, Linux, and
  Windows, binding symbols via `@DefaultAsset` and `@Native` FFI functions.
  Apps and `dart test` / `flutter test` no longer need manual
  `tool/build_quickjs.sh` runs or `dlopen` path lookups (while keeping
  `JSR_QUICKJS_LIB` and `DynamicLibrary.open(libraryPath)` as fallbacks).
- Added `QuickjsFfi.isAvailable` to probe whether the native asset or
  pre-built shared library is ready.

# 0.3.6

- **Bytes host functions**: `QuickjsRuntime.registerHostBytesFn(name, cb)` +
  `qjs_register_bytes_fn` in the C bridge — JS calls `name(typedArray)`,
  Dart receives a zero-copy `(name, Uint8List)` view with no JSON marshal,
  no base64, no string copies (the view is valid for the call's duration).
  Older native libraries degrade: `hasBytesFn` is false and the call
  returns false — callers fall back to the JSON/base64 path.
- Powering `jsr.hostCallBinary(name, typedArray)` in js_widget_runtime
  (per-frame bulk data: transforms, particles, audio levels).

# 0.3.4

## Added

- `AsyncEnginePool.attachMainRuntime` accepts a per-runtime
  `dispatchContext` provider: the `runAsync` dispatch path now captures
  context per main engine (overriding the pool-level default), so a
  shared pool can serve main engines whose dispatch context differs per
  engine (script directory, job params, ...). Explicit `dispatch(
  context: ...)` still wins over both providers. Consumer-opaque,
  must be SendPort-safe (plain JSON-ish values).

# 0.3.3

- Conformance fixture v2: byte-identical cross-runtime script with
  Buffer/URL/utilExtras/osProcess/events/fetchShapes/parallel sections
  plus a timer-protocol family (`actionTimers` + `drainTimers`).
- `util`: legacy Node predicates — `isArray`, `isString`, `isNumber`,
  `isBoolean`, `isNull`, `isUndefined`, `isFunction`.
- `util.inspect`: strings are now always single-quoted (Node semantics).
- `util.format`: extra string args inserted raw; non-strings inspected
  (previously everything was JSON.stringify-ed).

## 0.3.2

Fixes the native-library path join for **pub.dev (hosted) checkouts**:
the package_config fallback built
`<root>native/quickjs/libquickjs_bridge.so` without a separator when
`rootUri` has no trailing slash (hosted) — workers died with
`Failed to load dynamic library ...0.3.1native/...`. Also mirrors the
stringified-env shim into the async prelude (`require('os')`). No API
changes.

# 0.3.1

Restores the **sync `fetch`** and **timers / microtask auto-drain /
`require('events')`** features: their stacked PRs (#7, #8) were merged
out-of-band and their commits were not part of the `main` tree the
0.3.0 tarball was published from — the 0.3.0 section below documents
the intended surface, but only 0.3.1 actually ships it. Internally the
async surface now lives in its own prelude
(`node_compat_async.dart`); `require('events')`/`require('os')`
registration moved from the core builtin map into that prelude. No
other API or behavior changes.

# 0.3.0

- **Sync `fetch`** (opt-in): `NodeCompatConfig.httpFetch` hook + real
  `Headers`/`Response` (`text()`/`json()`/`arrayBuffer()`, `bodyUsed`,
  `ok`/`status`/`headers`); failures surface as
  `TypeError: fetch failed` with `cause`. Bodies are plain values, so
  `await res.text()` works through them; `AbortSignal` is not
  supported (documented deviation). Without the hook, `fetch` stays a
  self-documenting stub — the runtime remains I/O-clean.
- **Real timers + microtask auto-drain + events**: promise reactions,
  `queueMicrotask` and `process.nextTick` now actually run — the
  QuickJS pending-job queue is drained (capped) after every successful
  eval. `setTimeout`/`setInterval`/`setImmediate` + `clear*` are real,
  host-driven callbacks via `NodeCompatHandle.drainTimers()` in
  `ready` (default, UI-safe) / `block` (sleeps until the nearest
  reffed timer — CLI "setTimeout as sleep") / `none` modes, with
  `unref()`, a callback-count guard and a wall-clock budget.
  `require('events')` provides the full synchronous `EventEmitter`.
- **Node parity pack** (issue #3 follow-up): real `Buffer` (Uint8Array
  subclass, Node encodings + LE/BE accessors), `URL`/`URLSearchParams`
  (WHATWG subset verified against real Node), `console.time`/`table`/
  `group`/`count`/`dir`/`trace`, Node-style `util.inspect`, `os` +
  `url` + `buffer` builtin modules, `process.argv`/`pid`/`hrtime`/
  `uptime`/`memoryUsage`/`stdout`/`stderr`/`on('exit')`,
  `__filename`/`__dirname` (+ `NodeCompatHandle.setScriptPath`),
  typeof-safe `Intl` stubs. Default text codecs are now real UTF-8
  (dart:convert) — the latin-1 approximation is gone; `Buffer` removed
  from tier-2 stubs; `installNodeCompat` returns a
  `NodeCompatHandle`.

- Node/js compat layer (issue #3), opt-in via `installNodeCompat(rt, cfg)`:
  - **Tier 1 — real:** `global`, `console.*` (pluggable sink), `process`
    (env/platform/arch/version/exitCode/cwd/exit), `path` (posix subset),
    `assert` (node-like subset), `util` (subset), `TextEncoder`/
    `TextDecoder` (utf-8), `atob`/`btoa`, `performance.now()`,
    `crypto.randomUUID()`/`getRandomValues()`, `structuredClone`
    (JSON fidelity), `require()` builtin registry + consumer modules
    (`installNodeCompatModule`) + fallback to a pre-existing loader.
  - **Tier 2 — self-documenting stub:** `AbortController` —
    `typeof`-safe, throws the alternative on call (fetch has no signal
    support yet).
  - Host hooks: env, cwd, clock, secure random, utf-8/base64 codecs,
    console sink, exit notification. Without hooks, safe defaults.

# 0.2.0

- `AsyncEnginePool`: pre-spawned engine-worker isolates for parallel
  JavaScript execution over the synchronous host-callback bridge.
  Consumer owns the worker body (top-level `AsyncWorkerMain` with an
  `AsyncWorkerLink` next/complete protocol, or a simpler
  `AsyncJobExecutor` one-engine-per-job hook); the pool owns transport
  and lifecycle — dispatch/wait mailbox protocol (pthreads condvar via
  `native_synchronization`), FIFO backpressure, fire-and-forget envelope
  caching, dead-worker error completion.
- `runAsync(fn, args)` scripting surface: `AsyncEnginePool.attachMainRuntime`
  registers the `__jsrDispatchHost`/`__jsrWaitHost` host functions and
  the prelude exposing `runAsync`/`AsyncJob`/`runAsync.all` with a
  **blocking** `wait()`.
- `runAsyncJobOnRuntime`: runs one dispatched (closure-free) function on
  a consumer-wired runtime and returns its `AsyncJobEnvelope`.

# 0.1.0

- Initial release: QuickJS 2024-01-13 runtime on `dart:ffi` with
  synchronous host callbacks (`NativeCallable`).
- `QuickjsRuntime`: eval (JSON results), `registerHostFunction`,
  `setGlobal`, `executePendingJobs`, `close`.
- `QuickjsFfi`: flat C ABI bindings to `quickjs_bridge.c`
  (JSON marshaling).
- `tool/build_quickjs.sh` builds `libquickjs_bridge.so` (gcc); lookup via
  `JSR_QUICKJS_LIB`, `.dart_tool/package_config.json`, script dir, or cwd.
