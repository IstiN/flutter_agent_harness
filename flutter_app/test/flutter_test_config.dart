import 'dart:async';

import 'package:js_widget_runtime/src/runtime/js_widget_engine_flutter_js.dart';

/// Global test setup: the engine's native-release grace (15s in production,
/// crash-proofing for use-after-free) must not leak pending timers into test
/// teardowns — every engine-disposing test would trip the binding's
/// no-pending-timers invariant. The grace itself is covered by the runtime
/// package's own tests.
Future<void> testExecutable(FutureOr<void> Function() main) async {
  FlutterJsWidgetEngineBackend.nativeReleaseGrace = Duration.zero;
  await main();
}
