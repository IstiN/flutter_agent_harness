/*
 * msvc_compat.h — compatibility shims so the vendored QuickJS 2024-01-13
 * C sources and quickjs_bridge.c compile with the MSVC C toolchain
 * (cl.exe) that native_toolchain_c selects on Windows.
 *
 * Force-included on Windows only (see forcedIncludes in hook/build.dart).
 * Everything below is guarded by _MSC_VER, so clang/GCC builds (including
 * macOS/iOS/Android/Linux and clang-cl) see zero difference.
 *
 * Covers:
 *  - GNU __attribute__ (empty expansion; MSVC has no equivalent)
 *  - alloca (MSVC spells it _alloca, declared in <malloc.h>)
 *  - strdup (MSVC C headers expose only the conforming _strdup)
 *  - isnan/isfinite (mapped to _isnan/_finite when the UCRT math macros
 *    are not provided)
 *  - GCC atomic builtins used by quickjs_bridge.c, mapped onto the
 *    _Interlocked* intrinsics (<intrin.h>); on x86/x64 these are full
 *    barriers, which is stronger than the required acquire/release
 *  - <intrin.h> itself, used by the guarded _MSC_VER branches in
 *    cutils.h (clz/ctz) and quickjs.c (stack pointer probe)
 *
 * Note: sys/time.h is provided by the sibling shim sys/time.h, which
 * quickjs.c picks up because this directory is added to the MSVC include
 * path (hook/build.dart).
 */
#ifndef QUICKJS_MSVC_COMPAT_H
#define QUICKJS_MSVC_COMPAT_H

#ifdef _MSC_VER

/* 1. GNU attributes: expand to nothing. Must come before any vendored
   header is parsed (this file is force-included first). */
#ifndef __attribute__
#define __attribute__(x)
#endif
/* GCC also accepts the single-trailing-underscore spelling
   (quickjs.c uses __attribute((unused)) on dump_token). */
#ifndef __attribute
#define __attribute(x)
#endif

/* 2. intrinsics: _BitScanReverse / _BitScanForward (cutils.h),
   _AddressOfReturnAddress (quickjs.c), _Interlocked* (below). */
/* clang-cl in MSVC-emulation mode accepts __forceinline; plain clang
   (e.g. simulating _MSC_VER on a non-Windows host) does not. */
#if defined(__clang__) && !defined(__forceinline)
#define __forceinline inline
#endif
#include <intrin.h>

/* 3. alloca: MSVC declares _alloca in <malloc.h> and does not provide
   <alloca.h>. Needed by quickjs.c and libregexp.c. */
#include <malloc.h>
#ifndef alloca
#define alloca _alloca
#endif

/* 4. strdup: POSIX name not declared by the MSVC C headers (only the
   underscore-prefixed conforming name). Needed by quickjs_bridge.c. */
#ifndef strdup
#define strdup _strdup
#endif

/* 5. C99 math classification macros: the UCRT declares them in recent
   toolsets, so only fill in when absent. Needed by quickjs.c. */
#ifndef isnan
#define isnan(x) _isnan((double)(x))
#endif
#ifndef isfinite
#define isfinite(x) _finite((double)(x))
#endif

/* 6. GCC atomic builtins used by quickjs_bridge.c for process-global
   callback-table registration. The _Interlocked intrinsics are full
   memory barriers on x86/x64, which satisfies (and exceeds) the
   acquire/release ordering the bridge requires. */
static __forceinline int qjs_atomic_load_acquire(volatile int *p)
{
    return (int)_InterlockedCompareExchange((volatile long *)p, 0, 0);
}

static __forceinline int qjs_atomic_fetch_add_int(volatile int *p, int delta)
{
    return (int)_InterlockedExchangeAdd((volatile long *)p, (long)delta);
}

#define __atomic_load_n(ptr, order) \
    qjs_atomic_load_acquire((volatile int *)(ptr))
#define __sync_fetch_and_add(ptr, delta) \
    qjs_atomic_fetch_add_int((volatile int *)(ptr), (int)(delta))

/* 7. ssize_t: POSIX signed size type not provided by MSVC. */
#include <stdint.h>
#ifndef _SSIZE_T_DEFINED
#define _SSIZE_T_DEFINED
typedef intptr_t ssize_t;
#endif

#endif /* _MSC_VER */
#endif /* QUICKJS_MSVC_COMPAT_H */
