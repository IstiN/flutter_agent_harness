/// Flutter native bindings for the wasm_run library.
///
/// This library contains the dynamic libraries for native platforms that
/// implement the wasm_run interface.
/// It also works on Flutter web by using wasm_run's provided browser
/// runtime bindings.
library wasm_run_flutter;

import 'dart:ffi' if (dart.library.html) 'wasm_run_flutter_stub.dart' as ffi;
import 'dart:io' if (dart.library.html) 'wasm_run_flutter_stub.dart' as io;

import 'package:flutter/services.dart' show rootBundle;
import 'package:wasm_run/wasm_run.dart';

export 'package:wasm_run/wasm_run.dart';

/// Registers the native bindings for the WasmRun plugin.
class WasmRunFlutterNative {
  /// Registers the native bindings for the WasmRun plugin.
  /// For more information, see: [WasmRunLibrary.setUp].
  static void registerWith() {
    // iOS cannot spawn processes or download dynamic libraries; use the
    // statically linked library bundled by wasm_run_flutter instead.
    if (io.Platform.isIOS) {
      try {
        WasmRunLibrary.set(ffi.DynamicLibrary.executable());
      } catch (_) {
        // The static library is not linked; WASM features will be unavailable.
      }
      return;
    }
    WasmRunLibrary.setUp(
      override: false,
      isFlutter: true,
      loadAsset: rootBundle.load,
    );
  }
}
