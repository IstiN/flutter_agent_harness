/// Stub implementations for dart:ffi and dart:io on web platforms where
/// these libraries are not available.
library wasm_run_flutter_stub;

/// Stub for [dart:ffi] `DynamicLibrary`.
class DynamicLibrary {
  /// Stub for `DynamicLibrary.executable()`.
  static DynamicLibrary executable() => DynamicLibrary();
}

/// Stub for [dart:io] `Platform`.
class Platform {
  /// Stub for `Platform.isIOS`.
  static bool get isIOS => false;
}
