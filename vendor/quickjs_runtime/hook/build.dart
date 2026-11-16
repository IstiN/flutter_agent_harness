// Build hook for quickjs_runtime: compiles the vendored QuickJS 2024-01-13
// C sources and quickjs_bridge.c into a bundled CodeAsset so Flutter apps
// (iOS, Android, macOS, Linux, Windows) and `dart run` / `dart test` work
// out of the box without running `tool/build_quickjs.sh` manually.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const String _assetName = 'src/quickjs_ffi.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    final isWindows = os == OS.windows;
    final builder = CBuilder.library(
      name: 'quickjs_bridge',
      assetName: _assetName,
      sources: const [
        'native/quickjs_bridge.c',
        'native/quickjs/quickjs.c',
        'native/quickjs/libregexp.c',
        'native/quickjs/libunicode.c',
        'native/quickjs/cutils.c',
        'native/quickjs/libbf.c',
      ],
      // On Windows the MSVC toolchain (native_toolchain_c resolves cl.exe)
      // cannot compile the vendored GCC-oriented QuickJS sources as-is.
      // native/quickjs/msvc provides a forced-include compatibility shim
      // (sys/time.h, alloca, strdup, atomics, intrinsics) plus a shim
      // include dir that satisfies quickjs.c's <sys/time.h>. Other
      // platforms are untouched.
      includes: isWindows
          ? const ['native/quickjs/msvc', 'native/quickjs']
          : const ['native/quickjs'],
      forcedIncludes: isWindows
          ? const ['native/quickjs/msvc/msvc_compat.h']
          : const [],
      defines: const {'_GNU_SOURCE': null, 'CONFIG_VERSION': '"2024-01-13"'},
      flags: isWindows
          ? const []
          : [
              '-Wno-implicit-const-int-float-conversion',
              '-Wno-unused-parameter',
              '-Wno-sign-compare',
              if (os == OS.android) '-Wl,-z,max-page-size=16384',
              if (os == OS.iOS || os == OS.macOS) ...[
                '-headerpad_max_install_names',
                '-install_name',
                '@rpath/libquickjs_bridge.dylib',
              ],
            ],
      libraries: switch (os) {
        OS.windows => const [],
        // Android's bionic libc provides pthread entry points; the NDK has
        // no separate libpthread.so, so upstream's `-lpthread` cannot link.
        OS.android => const ['m', 'dl'],
        // Keep pthread on desktop platforms, and dl only where it exists.
        _ => ['m', 'pthread', if (os == OS.linux) 'dl'],
      },
      optimizationLevel: OptimizationLevel.o2,
    );
    await builder.run(input: input, output: output);
  });
}
