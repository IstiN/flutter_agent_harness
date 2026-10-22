/*
 * quickjs_bridge.c — thin C bridge exposing QuickJS to dart:ffi.
 *
 * JSON-based marshaling: JS args → JSON string → Dart callback →
 * JSON result string → JS value. Host callbacks are synchronous.
 *
 * Compile:
 *   gcc -shared -fPIC -O2 -D_GNU_SOURCE \
 *     -o libquickjs_bridge.so quickjs_bridge.c quickjs.c libregexp.c \
 *     libunicode.c cutils.c quickjs-libc.c libbf.c \
 *     -lm -ldl -lpthread
 */

#ifdef _WIN32
#include <windows.h> /* Sleep/DWORD (qjs_sleep_ms) */
#endif
#include "quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#define MAX_HOST_FNS 65536

/* Host callback: receives JSON args string, returns malloc'd JSON result
 * (or NULL for JS undefined). The bridge frees the returned string. */
typedef char* (*HostCallback)(const char* args_json);

static HostCallback g_callbacks[MAX_HOST_FNS];
/* Monotonic, never reset. Each runtime registers ~6 host functions; dart
 * test spawns parallel isolates that share this process-global table, so
 * indices must remain unique for the lifetime of the process. Allocation
 * is atomic to avoid a data race on concurrent registration. */
static int g_callback_count = 0;

/* ── Dispatch: the single C function all registered host fns call ──── */

static JSValue qjs_dispatch(JSContext* ctx, JSValueConst this_val,
                            int argc, JSValueConst* argv, int magic) {
    (void)this_val;
    /* Atomic load: parallel isolates register concurrently. The caller's
     * own registration completed earlier in program order, so the count
     * seen here is at least magic+1; the acquire load keeps it sound. */
    int count = __atomic_load_n(&g_callback_count, __ATOMIC_ACQUIRE);
    if (magic < 0 || magic >= count || !g_callbacks[magic]) {
        return JS_ThrowTypeError(ctx, "invalid host callback index %d", magic);
    }

    /* Marshal arguments to JSON: single arg → as-is, multiple → array,
     * none → empty object. */
    JSValue json_val;
    if (argc == 0) {
        json_val = JS_NewObject(ctx);
    } else if (argc == 1) {
        json_val = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    } else {
        JSValue arr = JS_NewArray(ctx);
        for (int i = 0; i < argc; i++) {
            JS_SetPropertyUint32(ctx, arr, i, JS_DupValue(ctx, argv[i]));
        }
        json_val = JS_JSONStringify(ctx, arr, JS_UNDEFINED, JS_UNDEFINED);
        JS_FreeValue(ctx, arr);
    }

    if (JS_IsException(json_val)) {
        JS_FreeValue(ctx, json_val);
        return JS_ThrowTypeError(ctx, "failed to marshal args to JSON");
    }

    const char* args_json = JS_ToCString(ctx, json_val);
    JS_FreeValue(ctx, json_val);
    if (args_json == NULL) {
        return JS_ThrowTypeError(ctx, "failed to convert JSON to string");
    }

    /* Synchronous host call */
    char* result_json = g_callbacks[magic](args_json);
    JS_FreeCString(ctx, args_json);

    if (result_json == NULL) {
        return JS_UNDEFINED;
    }

    JSValue result = JS_ParseJSON(ctx, result_json, strlen(result_json),
                                  "<host_result>");
    free(result_json);
    if (JS_IsException(result)) {
        JS_FreeValue(ctx, result);
        return JS_ThrowTypeError(ctx, "host callback returned invalid JSON");
    }
    return result;
}

/* ── Public API ────────────────────────────────────────────────────── */

JSRuntime* qjs_create_runtime(void) {
    return JS_NewRuntime();
}

JSContext* qjs_create_context(JSRuntime* rt) {
    return JS_NewContext(rt);
}

void qjs_destroy(JSRuntime* rt, JSContext* ctx) {
    if (ctx) JS_FreeContext(ctx);
    if (rt) JS_FreeRuntime(rt);
}

/* No-op retained for ABI compatibility. Indices are now monotonic and never
 * reset, so concurrent isolates sharing this process-global table do not
 * clobber each other's registrations. */
void qjs_reset_callbacks(void) {
    /* intentionally empty */
}

/* Register a host function as a global JS function.
 * Returns 0 on success, -1 on failure (too many fns or eval error). */
int qjs_register_host_fn(JSContext* ctx, const char* name,
                         HostCallback callback) {
    if (g_callback_count >= MAX_HOST_FNS) return -1;

    /* Atomic fetch-and-add: parallel isolates register concurrently. */
    int idx = __sync_fetch_and_add(&g_callback_count, 1);
    if (idx >= MAX_HOST_FNS) return -1;
    g_callbacks[idx] = callback;

    JSValue fn = JS_NewCFunction2(ctx, (JSCFunction*)qjs_dispatch, name, 0,
                                  JS_CFUNC_generic_magic, idx);
    if (JS_IsException(fn)) return -1;

    JSValue global = JS_GetGlobalObject(ctx);
    int rc = JS_SetPropertyStr(ctx, global, name, fn);
    JS_FreeValue(ctx, global);
    return (rc < 0) ? -1 : 0;
}

/* Evaluate JS code. Returns a malloc'd JSON string of the result
 * (caller frees). On exception returns NULL and sets *err_msg to a
 * malloc'd error string (caller frees; may be NULL if unavailable). */
char* qjs_eval(JSContext* ctx, const char* code, const char* filename,
               char** err_msg) {
    if (err_msg) *err_msg = NULL;

    JSValue val = JS_Eval(ctx, code, strlen(code),
                          filename ? filename : "<eval>",
                          JS_EVAL_TYPE_GLOBAL);

    if (JS_IsException(val)) {
        JSValue err = JS_GetException(ctx);
        const char* cstr = JS_ToCString(ctx, err);
        if (cstr && err_msg) {
            *err_msg = strdup(cstr);
        }
        if (cstr) JS_FreeCString(ctx, cstr);
        JS_FreeValue(ctx, err);
        JS_FreeValue(ctx, val);
        return NULL;
    }

    /* Serialize result to JSON; undefined → "null" for JSON compatibility. */
    JSValue json = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
    JS_FreeValue(ctx, val);

    if (JS_IsException(json)) {
        JS_FreeValue(ctx, json);
        if (err_msg) *err_msg = strdup("failed to serialize result to JSON");
        return NULL;
    }

    const char* cstr = JS_ToCString(ctx, json);
    JS_FreeValue(ctx, json);
    if (cstr == NULL) {
        if (err_msg) *err_msg = strdup("failed to convert JSON to string");
        return NULL;
    }

    char* result = strdup(cstr);
    JS_FreeCString(ctx, cstr);
    return result;
}

/* Execute pending jobs (promise reactions, async continuations). Drains the
 * queue until it is empty or a job throws. Returns the number of executed
 * jobs, or -1 if a job raised an exception (reported on stderr, cleared). */
int qjs_execute_pending_jobs(JSContext* ctx) {
    JSRuntime* rt = JS_GetRuntime(ctx);
    int executed = 0;
    for (;;) {
        JSContext* ctx1;
        int rc = JS_ExecutePendingJob(rt, &ctx1);
        if (rc == 0) break;
        if (rc < 0) {
            JSValue err = JS_GetException(ctx1);
            const char* msg = JS_ToCString(ctx1, err);
            fprintf(stderr, "[quickjs] pending job error: %s\n",
                    msg ? msg : "(unknown)");
            if (msg) JS_FreeCString(ctx1, msg);
            JS_FreeValue(ctx1, err);
            return -1;
        }
        executed++;
    }
    return executed;
}

/* Capped variant of qjs_execute_pending_jobs: stops after [max_jobs]
 * executed jobs so a self-re-enqueueing microtask chain cannot hang the
 * host thread. New symbol (the uncapped one keeps its original signature
 * so older Dart code against older builds stays ABI-safe). Returns the
 * number of executed jobs, or -1 if a job raised an exception (reported
 * on stderr, cleared). */
int qjs_execute_pending_jobs_capped(JSContext* ctx, int max_jobs) {
    JSRuntime* rt = JS_GetRuntime(ctx);
    int executed = 0;
    for (;;) {
        JSContext* ctx1;
        int rc = JS_ExecutePendingJob(rt, &ctx1);
        if (rc == 0) break;
        if (rc < 0) {
            JSValue err = JS_GetException(ctx1);
            const char* msg = JS_ToCString(ctx1, err);
            fprintf(stderr, "[quickjs] pending job error: %s\n",
                    msg ? msg : "(unknown)");
            if (msg) JS_FreeCString(ctx1, msg);
            JS_FreeValue(ctx1, err);
            return -1;
        }
        executed++;
        if (executed >= max_jobs) break;
    }
    return executed;
}

/* Blocks the calling thread for [ms] milliseconds. Used by the node-compat
 * timer pump in 'block' mode (setTimeout with a future due time). Returns
 * 0 on success. */
int qjs_sleep_ms(int ms) {
    if (ms <= 0) return 0;
#ifdef _WIN32
    Sleep((DWORD)ms);
#else
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {
        /* resume the remaining time after a signal */
    }
#endif
    return 0;
}

/* Set a global variable from a JSON string. Returns 0 on success. */
int qjs_set_global_json(JSContext* ctx, const char* name, const char* json) {
    JSValue val = JS_ParseJSON(ctx, json, strlen(json), "<global>");
    if (JS_IsException(val)) return -1;

    JSValue global = JS_GetGlobalObject(ctx);
    int rc = JS_SetPropertyStr(ctx, global, name, val);
    JS_FreeValue(ctx, global);
    return rc;
}

/* ── Bytes host functions ────────────────────────────────────────────
 * A dedicated lane for high-frequency bulk data (per-frame transforms,
 * particles, audio levels): JS passes a typed array, the bridge hands
 * Dart the raw (pointer, length) pair with NO JSON marshal, NO string
 * copies, NO base64. The data pointer is only valid for the duration
 * of the callback. */

typedef void (*BytesHostCallback)(const char* name, const uint8_t* data,
                                  size_t len);

static BytesHostCallback g_bytes_callbacks[MAX_HOST_FNS];
static int g_bytes_callback_count = 0;

static JSValue qjs_bytes_dispatch(JSContext* ctx, JSValueConst this_val,
                                  int argc, JSValueConst* argv, int magic) {
    (void)this_val;
    int count = __atomic_load_n(&g_bytes_callback_count, __ATOMIC_ACQUIRE);
    if (magic < 0 || magic >= count || !g_bytes_callbacks[magic]) {
        return JS_ThrowTypeError(ctx, "invalid bytes callback index %d", magic);
    }
    if (argc < 2 || !JS_IsString(argv[0])) {
        return JS_ThrowTypeError(ctx, "expected (name, typedArray)");
    }
    size_t offset = 0, length = 0;
    JSValue buf = JS_GetTypedArrayBuffer(ctx, argv[1], &offset, &length, NULL);
    if (JS_IsException(buf)) {
        return JS_ThrowTypeError(ctx, "second argument must be a typed array");
    }
    size_t absize = 0;
    uint8_t* ptr = JS_GetArrayBuffer(ctx, &absize, buf);
    JS_FreeValue(ctx, buf);
    if (!ptr) {
        return JS_ThrowTypeError(ctx, "typed array has no backing buffer");
    }
    if (offset > absize || length > absize - offset) {
        return JS_ThrowTypeError(ctx, "typed array range out of bounds");
    }
    const char* name = JS_ToCString(ctx, argv[0]);
    if (name == NULL) {
        return JS_ThrowTypeError(ctx, "failed to convert name");
    }
    g_bytes_callbacks[magic](name, ptr + offset, length);
    JS_FreeCString(ctx, name);
    return JS_UNDEFINED;
}

/* Register a bytes host function as a global JS function
 * name(typedArray). Returns 0 on success, -1 on failure. */
int qjs_register_bytes_fn(JSContext* ctx, const char* name,
                          BytesHostCallback callback) {
    if (g_bytes_callback_count >= MAX_HOST_FNS) return -1;
    int idx = __sync_fetch_and_add(&g_bytes_callback_count, 1);
    if (idx >= MAX_HOST_FNS) return -1;
    g_bytes_callbacks[idx] = callback;

    JSValue fn = JS_NewCFunction2(ctx, (JSCFunction*)qjs_bytes_dispatch, name,
                                  0, JS_CFUNC_generic_magic, idx);
    if (JS_IsException(fn)) return -1;

    JSValue global = JS_GetGlobalObject(ctx);
    int rc = JS_SetPropertyStr(ctx, global, name, fn);
    JS_FreeValue(ctx, global);
    return (rc < 0) ? -1 : 0;
}
