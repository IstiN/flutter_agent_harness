// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Non-web stub of the web-worker extension engine: constructing it anywhere
/// but a web build is an unavailable engine, never a silent no-op.
library;

import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';

/// Web-worker [JsrRuntime] twin for non-web builds — every construction
/// throws.
final class WebWorkerExtRuntime implements JsrRuntime {
  /// Throws [ExtEngineUnavailableException]: the web extension engine needs a
  /// web build (IO/mobile builds use `FlutterJsExtRuntime` instead).
  WebWorkerExtRuntime() {
    throw ExtEngineUnavailableException(
      'web extension engine requires a web build',
    );
  }

  @override
  String get engineId => throw UnimplementedError('unavailable off web');

  @override
  Future<void> start({
    required String bootstrapJs,
    required String mainJs,
    required ExtBridgeHandler bridges,
  }) => throw UnimplementedError('unavailable off web');

  @override
  Future<Object?> invoke(String fn, List<Object?> args, {Duration? timeout}) =>
      throw UnimplementedError('unavailable off web');

  @override
  Future<void> dispose() => throw UnimplementedError('unavailable off web');
}
