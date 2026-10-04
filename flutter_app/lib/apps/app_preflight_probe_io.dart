// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IO variant of the [jsEngineBootable] probe (selected by the
/// conditional export in `app_preflight.dart`; never compiled for web —
/// dart:ffi has no web target). Mirrors the flutter_js native load path
/// the same way `test/native_test_guard.dart` does for the test suites:
/// QuickJS bridge on Linux/Windows/Android, JavaScriptCore framework on
/// Apple platforms.
library;

import 'dart:ffi';
import 'dart:io';

/// Whether the JS engine the smoke probe boots can load its native bridge
/// on THIS host. Resolved once at first reference; never changes mid-run.
final bool jsEngineBootable = _probeNativeJsEngine();

bool _probeNativeJsEngine() {
  try {
    if (Platform.isMacOS || Platform.isIOS) {
      // flutter_js picks JavascriptCoreRuntime on Apple desktops/devices;
      // jsc_ffi.dart dlopens the system framework with this fallback chain.
      DynamicLibrary lib;
      try {
        lib = DynamicLibrary.open('JavaScriptCore.framework/JavaScriptCore');
      } on ArgumentError {
        lib = DynamicLibrary.open(
          '/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore',
        );
      }
      // The engine cannot evaluate without this entry point.
      lib.lookup<NativeFunction<Void Function()>>('JSEvaluateScript');
      return true;
    }
    // Everywhere else the engine is QuickJsRuntime2, whose constructor
    // resolves `jsNewRuntime` from the bridge library.
    final lib = Platform.isWindows
        ? DynamicLibrary.open('quickjs_c_bridge.dll')
        : Platform.isAndroid
        ? DynamicLibrary.open('libfastdev_quickjs_runtime.so')
        : DynamicLibrary.open(
            Platform.environment['LIBQUICKJSC_TEST_PATH'] ??
                'libquickjs_c_bridge_plugin.so',
          );
    lib.lookup<NativeFunction<Void Function()>>('jsNewRuntime');
    return true;
  } on Object {
    return false;
  }
}
