/*
 * sys/time.h — minimal shim for MSVC, which does not provide this header.
 *
 * quickjs.c includes <sys/time.h> unconditionally and uses gettimeofday()
 * for PRNG seeding (js_random_init) and Date.now (date_now). This shim is
 * only reachable on Windows: hook/build.dart prepends this directory to
 * the MSVC include path, and native/quickjs/msvc/msvc_compat.h is
 * force-included before every translation unit. The #error guard below
 * makes any accidental pickup by a clang/GCC build a hard failure.
 */
#ifndef QUICKJS_MSVC_SYS_TIME_H
#define QUICKJS_MSVC_SYS_TIME_H

#ifndef _MSC_VER
#error "native/quickjs/msvc/sys/time.h is an MSVC shim; do not include it in non-MSVC builds"
#endif

#include <time.h> /* struct timespec, timespec_get, TIME_UTC */

/*
 * struct timeval + gettimeofday().
 *
 * Implemented on top of C11 timespec_get(), which the UCRT backs with
 * the Windows system clock (sub-millisecond precision), so Date.now()
 * keeps millisecond resolution. The second gettimeofday() argument is
 * ignored, matching the call sites in quickjs.c which always pass NULL.
 *
 * _TIMEVAL_DEFINED is the include guard used by the Winsock headers for
 * their own struct timeval; honoring it keeps this shim conflict-free
 * if any translation unit pulls in winsock2.h.
 */
#ifndef _TIMEVAL_DEFINED
#define _TIMEVAL_DEFINED
struct timeval {
    long tv_sec;
    long tv_usec;
};
#endif

static __forceinline int gettimeofday(struct timeval *tv, void *tz)
{
    struct timespec ts;
    (void)tz;
    timespec_get(&ts, TIME_UTC);
    tv->tv_sec = (long)ts.tv_sec;
    tv->tv_usec = (long)(ts.tv_nsec / 1000);
    return 0;
}

#endif /* QUICKJS_MSVC_SYS_TIME_H */
