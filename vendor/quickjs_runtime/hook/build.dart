// Build hook for quickjs_runtime: compiles the vendored QuickJS 2024-01-13
// C sources and quickjs_bridge.c into a bundled CodeAsset so Flutter apps
// (iOS, Android, macOS, Linux, Windows) and `dart run` / `dart test` work
// out of the box without running `tool/build_quickjs.sh` manually.
//
// ----------------------------------------------------------------------------
// Vendored fork delta vs hosted quickjs_runtime 0.4.2 (flutter_agent_harness
// PR #1785 rework — see test/quickjs_runtime_vendor_pin_test.dart):
//
// 1. Android: do NOT link pthread. bionic ships pthread inside libc and the
//    NDK sysroot has had no libpthread since r18 — the unconditional
//    `-lpthread` fails the link for every ABI:
//      ld.lld: error: unable to find library -lpthread
//    (Build Android APK CI leg, NDK 27/28, armv7+arm64+x64).
//
// 2. Windows: return before the CBuilder. The QuickJS 2024-01-13 sources are
//    not MSVC-clean — C11 `<stdatomic.h>`/`__ATOMIC_ACQUIRE` (undeclared on
//    MSVC), POSIX `sys/time.h` (C1083), GNU packed-attribute macros (C2061) —
//    so upstream 0.4.2 dies in flutter_assemble.vcxproj:
//      quickjs.h(672): error C2440: 'type cast': cannot convert from
//      'JSValue' to 'JSValue'
//    js_widget_runtime falls back to its flutter_js backend when the native
//    asset is absent (`QuickjsFfi.isAvailable` == false), which is exactly
//    the pre-0.4.0 Windows behavior — skipping the build restores it instead
//    of failing the whole app build (Lockfile smoke windows leg).
//
// Everything else (sources, defines, flags, iOS/macOS embedding flags,
// 16 KB page-size alignment, optimization) is byte-identical to upstream
// 0.4.2. Re-vendor on the next upstream publish that fixes both.
// ----------------------------------------------------------------------------

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const String _assetName = 'src/quickjs_ffi.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final os = input.config.code.targetOS;
    // Windows: skip the Native Assets build — the QuickJS 2024-01-13 sources
    // are not MSVC-clean (see the fork delta above); consumers fall back to
    // their non-native-assets backend when the asset is absent.
    if (os == OS.windows) return;
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
      includes: const ['native/quickjs'],
      defines: const {
        '_GNU_SOURCE': null,
        'CONFIG_VERSION': '"2024-01-13"',
      },
      flags: [
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
        // Android: pthread lives in bionic's libc — there is no libpthread
        // in the NDK sysroot (removed with r18), and `-lpthread` fails the
        // link on every ABI.
        OS.android => const ['m', 'dl'],
        // NOT const: the `if (os == …)` arm is a runtime condition and a
        // const collection would fail the hook kernel compile with
        // "Not a constant expression" (the Native Assets runner compiles
        // this file with `dart compile kernel`).
        _ => ['m', 'pthread', if (os == OS.linux) 'dl'],
      },
      optimizationLevel: OptimizationLevel.o2,
    );
    await builder.run(input: input, output: output);
  });
}
