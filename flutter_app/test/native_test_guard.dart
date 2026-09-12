// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Host-capability guard for the JS-engine-backed test suites (issue #184).
///
/// The `js_app_*` / `js_theme` / `dynamic_*` tests boot real JS engines via
/// `FlutterJsWidgetEngineBackend` → flutter_js `getJavascriptRuntime()`,
/// which dlopens a native library: the QuickJS bridge on Linux/Windows
/// (`libquickjs_c_bridge_plugin.so` / `quickjs_c_bridge.dll`) and the
/// JavaScriptCore framework on macOS/iOS. On hosts where that library is
/// absent (a bare ubuntu CI runner has no `libquickjs_c_bridge_plugin.so`)
/// every one of those tests crashes inside `dart:ffi` — a hard error, not a
/// failure a `skip:` inside the test could catch.
///
/// [quickJsBridgeAvailable] probes the exact load path the engine takes
/// (mirroring flutter_js `quickjs/ffi.dart` + `javascriptcore/binding/
/// jsc_ffi.dart`) ONCE per test isolate, so suites can mark engine-dependent
/// tests `skip: quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable`
/// while pure-Dart tests in the same file keep running everywhere.
library;

import 'dart:ffi';
import 'dart:io';

/// Skip reason attached to engine-dependent tests on hosts without the
/// native JS bridge — printed by the test runner next to every skipped
/// test (issue #184, AC5).
const String kQuickJsBridgeUnavailable =
    'requires the flutter_js native JS engine (QuickJS '
    'libquickjs_c_bridge_plugin.so / quickjs_c_bridge.dll, or the '
    'JavaScriptCore framework) — not loadable on this host (issue #184)';

/// Whether the JS engine backend the suites boot can load its native
/// library on THIS host. Resolved once at first reference; the result never
/// changes mid-run.
///
/// `FAH_SIMULATE_MISSING_BRIDGE=1` forces `false` so the skip path itself
/// (reason strings in the runner output) can be exercised on a
/// bridge-capable host.
final bool quickJsBridgeAvailable =
    Platform.environment['FAH_SIMULATE_MISSING_BRIDGE'] == '1'
    ? false
    : _probeNativeJsEngine();

bool _probeNativeJsEngine() {
  try {
    if (Platform.isMacOS || Platform.isIOS) {
      // flutter_js `getJavascriptRuntime()` picks JavascriptCoreRuntime on
      // Apple desktops/devices; jsc_ffi.dart dlopens the system framework
      // with this exact fallback chain.
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
    // resolves `jsNewRuntime` from the bridge library. Under `flutter test`
    // (FLUTTER_TEST=true) flutter_js quickjs/ffi.dart uses this exact
    // lookup chain.
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
