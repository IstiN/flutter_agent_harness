#!/usr/bin/env bash
# Builds the QuickJS FFI backend's shared library: native/quickjs/libquickjs_bridge.so
#
# Vendored QuickJS 2024-01-13 + the C bridge (native/quickjs_bridge.c) that the
# Dart FFI layer (lib/src/runtime/quickjs/) talks to. Run from anywhere; the
# output is placed next to the QuickJS sources, where quickjs_ffi.dart looks it
# up. Override CC to use a different compiler.
set -euo pipefail

cd "$(dirname "$0")/../native/quickjs"

CC="${CC:-gcc}"
UNAME_S="$(uname -s)"

# mingw-w64 (Git Bash / MSYS on Windows) has no libdl — dl* lives in
# kernel32 — and -ldl makes ld fail with "cannot find -ldl". Downstream
# consumers building the bridge on windows-latest runners currently work
# around this with an empty stub archive exposed via LIBRARY_PATH
# (dmtools-dart release-cli.yml); make the script itself Windows-honest
# instead. The .so output name is kept everywhere: the Dart FFI resolver
# hardcodes it and LoadLibrary ignores extensions.
DL_LIB="-ldl"
case "$UNAME_S" in
  MINGW* | MSYS* | CYGWIN*) DL_LIB="" ;;
esac

# Android (bionic) ships pthread inside libc and the NDK sysroot has had
# no libpthread since r18, so -lpthread fails the link there with
# "ld.lld: error: unable to find library -lpthread" — the Native Assets
# hook (../hook/build.dart) carries the same exclusion (PR #1785). Detect
# the two real NDK invocations: an *android* cross-compiler in CC (the
# NDK wrappers are named *-linux-android*-clang) or the ANDROID_NDK*
# environment variables pointing at an NDK.
PTHREAD_LIB="-lpthread"
case "$CC" in
  *android*) PTHREAD_LIB="" ;;
esac
if [ -n "${ANDROID_NDK:-}${ANDROID_NDK_HOME:-}${ANDROID_NDK_ROOT:-}" ]; then
  PTHREAD_LIB=""
fi

"$CC" -shared -fPIC -O2 -D_GNU_SOURCE \
  -DCONFIG_VERSION='"2024-01-13"' -I. \
  -o libquickjs_bridge.so ../quickjs_bridge.c \
  quickjs.c libregexp.c libunicode.c cutils.c quickjs-libc.c libbf.c \
  -lm $DL_LIB $PTHREAD_LIB

echo "built native/quickjs/libquickjs_bridge.so"
