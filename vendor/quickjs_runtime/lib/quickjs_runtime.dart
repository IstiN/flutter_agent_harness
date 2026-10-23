/// A pure-Dart QuickJS JavaScript runtime on `dart:ffi`.
///
/// Wraps the vendored QuickJS 2024-01-13 sources and a C bridge with
/// JSON-based marshaling: JS arguments are stringified to JSON in C, passed
/// to a synchronous Dart callback, and the JSON result string is parsed back
/// into a JS value.
///
/// Build the native library first:
///
/// ```sh
/// tool/build_quickjs.sh   # produces native/quickjs/libquickjs_bridge.so
/// ```
///
/// VM-only (`dart:ffi`); never import from a web-reachable path.
library;

export 'src/quickjs_ffi.dart';
export 'src/async_engine_pool.dart';
export 'src/node_compat.dart';
export 'src/node_compat_buffer.dart';
export 'src/node_compat_fetch.dart';
export 'src/node_compat_url.dart';
export 'src/quickjs_runtime.dart';
