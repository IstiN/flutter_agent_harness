# 0.4.9

## Vendored fork (flutter_agent_harness, gh-2215 follow-up)

Tracks upstream quickjs_runtime 0.4.9, including its Windows MSVC shim,
isolate stack-top fix, and cooperative drain-stop bridge. Carries only these
local deltas, pinned by `test/quickjs_runtime_vendor_pin_test.dart`:

- **Android**: omit `-lpthread`; bionic provides pthread in libc and the NDK
  has no separate libpthread.so. Linux/desktop pthread linkage is unchanged.
- **CodeQL**: retain the three value-identical cast-before-multiply forms in
  `libbf.c` and `quickjs.c` (`q * q`, `digits_per_limb * radix_bits`, and
  `new_size * elem_size`). Inline CodeQL suppression comments are not honored
  by GitHub code scanning.
- No prebuilt `libquickjs_bridge.so` is vendored; Native Assets builds the C
  sources for each target. The old 0.4.2 Windows skip-build workaround is
  removed because upstream 0.4.9 ships the MSVC compatibility shim.

## Upstream

- **Fix the app-exit SIGABRT during pending-job drains**: `DLRT_GetFfiCallbackMetadata`
  FATALs once the Dart VM begins teardown (`IsolateCreationEnabled` goes false
  before `WaitForIsolateShutdown` returns), so an isolate-backend worker still
  draining up to 100k queued promise reactions — each entering an FFI
  trampoline through `qjs_bytes_dispatch` — aborts the process when the host
  closes while such a drain is in flight. The bridge now carries a
  process-global `g_drain_stop` atomic checked by BOTH
  `qjs_execute_pending_jobs*` loops per job: `qjs_request_drain_stop()` makes
  the drain return early (remaining jobs stay pending and are freed by
  `close()`), `qjs_clear_drain_stop()` resumes normal draining, and
  `qjs_drain_stop_requested()` reports the state. The Dart side binds the
  exports instance-consistently (`QuickjsFfi.hasDrainStop/requestDrainStop/
  clearDrainStop/drainStopRequested`) so pre-flag bridges degrade to no-ops
  instead of silently decoupling the flag. Verified by a dispose-mid-drain
  regression (js_widget_runtime `js_isolate_shutdown_drain_race_test.dart`,
  validated red without the flag) and this repo's `test/drain_stop_test.dart`
  (4 tests, all red against a pre-flag bridge).
# 0.4.8

- **Fix the ubuntu CI isolate flake (silent `undefined` evals)**: the Dart
  VM migrates an isolate to a different OS thread once it is not pinned
  inside an FFI call. QuickJS anchors its stack-overflow limit
  (`rt->stack_top - stack_size`) to the thread that created the runtime,
  so an eval running on a migrated thread compared its stack pointer
  against an unrelated address range and failed at parse time with a
  spurious `SyntaxError: stack overflow`. Rendering that error overflows
  again, so `JS_ToCString` returned NULL and the failure surfaced as a
  silent `undefined`/`null` eval result — the intermittent
  `async_engine_pool` / `cross_runtime_conformance` failures on
  ubuntu-latest. The bridge now calls `JS_UpdateStackTop` at every JS
  entry point (`qjs_eval`, `qjs_execute_pending_jobs[_capped]`), which
  Dart's one-runtime-per-isolate discipline makes race-free. Verified via
  CI instrumentation on the failing runner: the wedged exception reads
  `SyntaxError: stack overflow` at eval depth 0.

# 0.4.7

- **Windows (MSVC) link fix**:  called
   unconditionally, but the decimal support
  (, i.e. CONFIG_BIGNUM) is not compiled — MS linker fails
  with LNK2019 (macOS  silently tolerates the dangling reference in
  a dylib, which is why it went unnoticed). The call is now guarded by
  ;  is never TRUE on that path without it (the sole
  TRUE caller, , is itself guarded). Zero behavior change.

# 0.4.6

- **Windows (MSVC) build fix, part 4**: use -HUGE_VAL / HUGE_VAL instead of
  -1.0 / 0.0 and 1.0 / 0.0 in js_math_min_max (C2124). After 0.4.5 the MSVC
  compile reports exactly this one diagnostic.

# 0.4.5

- **Windows (MSVC) build fix, part 3**: neutralize the single-trailing-underscore
  GCC spelling  (used by upstream on ) in the
  shim, and use  instead of  under  (C2124).
  After 0.4.4 the full MSVC compile is down to these two diagnostics.

# 0.4.4

- **Windows (MSVC) build fix, part 2**: force `DIRECT_DISPATCH 0` for
  `_MSC_VER` (quickjs.c) — MSVC has no computed goto / labels-as-values,
  so `JS_CallInternal` uses the plain `switch` dispatch (same as the
  Emscripten build; identical semantics, slightly slower interpreter).
  Add `ssize_t` (`intptr_t`) to the MSVC shim (`msvc_compat.h`); MSVC has
  no POSIX `ssize_t`, which broke `JS_DumpMemoryUsage`.
- Verification upgraded from a plain-clang `_MSC_VER` simulation (which
  silently accepts GNU extensions such as labels-as-values) to
  **clang-cl `/Zs`** (MSVC driver mode from Homebrew LLVM) over all six
  translation units plus a standalone harness for the `sys/time.h` shim:
  0 errors.

# 0.4.3

- **Windows (MSVC) build fix**: `native_toolchain_c` resolves `cl.exe` on
  GitHub Actions `windows-latest`, which cannot compile the vendored
  GCC-oriented QuickJS 2024-01-13 sources directly. On Windows only, the
  build hook now force-includes `native/quickjs/msvc/msvc_compat.h`
  (`sys/time.h` + `gettimeofday` shim, `alloca`/`strdup`, GCC atomic
  builtins on `_Interlocked*` intrinsics, `isnan`/`isfinite`, GNU
  `__attribute__` neutralized) and prepends `native/quickjs/msvc` to the
  include path. The vendored sources gained `_MSC_VER`-guarded branches
  (compound-literal-free `JS_MKVAL`/`JS_MKPTR`/`JS_NAN` constructors,
  packed structs via `#pragma pack`, `clz`/`ctz` via `_BitScanReverse`,
  stack-pointer probe via `_AddressOfReturnAddress`); clang/GCC builds see
  zero changes. Tradeoff: on Windows, `Atomics.*`/`SharedArrayBuffer`
  futex-style waiting stays disabled (it requires pthreads), matching
  single-threaded QuickJS builds.

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
