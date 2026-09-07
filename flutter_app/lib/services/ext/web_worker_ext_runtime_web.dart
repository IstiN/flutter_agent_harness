// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web build of the web-worker extension engine (compiled only where
/// `dart.library.html` holds; see `web_worker_ext_runtime.dart`): one
/// `Worker` per extension, fed the post-message bootstrap + the extension
/// source as a single blob script, talking the `{'__ext__': msg}` envelope
/// protocol from `kExtTransportPostMessageJs`.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
// ignore: deprecated_member_use
import 'dart:html' as html;

/// Per-extension worker engine for web builds. The worker script is
/// `bootstrapJs` (post-message transport + shared core) followed by the
/// extension `mainJs` in a try/catch that reports top-level throws as
/// `{fatal}` messages.
final class WebWorkerExtRuntime implements JsrRuntime {
  @override
  String get engineId => 'web-worker';

  html.Worker? _worker;
  String? _objectUrl;
  ExtBridgeHandler? _bridges;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextInvokeId = 0;
  bool _disposed = false;

  /// Budget for the commit handshake in [start]; a worker that never
  /// finishes bootstrapping is terminated.
  static const Duration _startTimeout = Duration(seconds: 30);

  @override
  Future<void> start({
    required String bootstrapJs,
    required String mainJs,
    required ExtBridgeHandler bridges,
  }) async {
    if (_disposed) throw StateError('runtime disposed');
    _bridges = bridges;
    // One-shot script: workers cannot be evaluated into incrementally, so
    // bootstrap and main.js share the blob (deviation from the two-eval
    // adapter recipe — documented in the contract, section 7 note).
    final script =
        '$bootstrapJs\n;(function(){try{\n$mainJs\n}catch(e){'
        'postMessage({__ext__:{fatal:String(e && e.message || e)}});}})();\n';
    final html.Worker worker;
    try {
      final blob = html.Blob([script], 'text/javascript');
      final url = html.Url.createObjectUrl(blob);
      worker = html.Worker(url);
      _objectUrl = url; // revoke on dispose — the fetch may race a revoke
    } catch (error) {
      throw ExtEngineUnavailableException(
        'could not spawn extension worker: $error',
      );
    }
    _worker = worker;
    worker.onMessage.listen(_onWorkerEvent);
    worker.onError.listen((error) {
      // dart:html types this as Event; the payload carries `message`.
      final detail = (error as dynamic).message ?? error;
      _failAll('worker error: $detail');
    });
    // Contract section 4: start resolves only after __extCommit returned the
    // registration payload. Worker message events queue until the initial
    // script finishes evaluating, so posting before "ready" is safe.
    await invoke(ExtJsGlobals.commit, const [], timeout: _startTimeout);
  }

  @override
  Future<Object?> invoke(
    String fn,
    List<Object?> args, {
    Duration? timeout,
  }) async {
    if (_disposed) throw StateError('runtime disposed');
    final id = ++_nextInvokeId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _post({'invoke': id, 'fn': fn, 'args': args});
    try {
      return await completer.future.timeout(
        timeout ?? _startTimeout,
        onTimeout: () {
          // No interrupt for a wedged worker — terminate it (this engine
          // only; other extensions are separate workers).
          dispose();
          throw TimeoutException(
            'web extension worker did not answer $fn within $timeout',
            timeout,
          );
        },
      );
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final completer in List.of(_pending.values)) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('runtime disposed'));
      }
    }
    _pending.clear();
    try {
      _worker?.terminate();
    } catch (_) {}
    _worker = null;
    final url = _objectUrl;
    _objectUrl = null;
    if (url != null) {
      try {
        html.Url.revokeObjectUrl(url);
      } catch (_) {}
    }
  }

  /// Routes one worker message (dart:html hands plain Dart structures over
  /// for JSON-able payloads): `{fatal}`, `{invoke}` reply, or `{seq}` bridge
  /// request.
  void _onWorkerEvent(html.MessageEvent event) {
    final data = event.data;
    if (data is! Map) return;
    final message = data['__ext__'];
    if (message is! Map) return;
    if (message['fatal'] is String) {
      _failAll('extension fatal: ${message['fatal']}');
      return;
    }
    if (message.containsKey('invoke')) {
      final completer = _pending.remove(message['invoke']);
      if (completer == null || completer.isCompleted) return;
      if (message['ok'] == true) {
        completer.complete(message['value']);
      } else {
        completer.completeError(
          StateError('extension invoke failed: ${message['error']}'),
        );
      }
      return;
    }
    if (message['seq'] is int) {
      unawaited(
        _onBridgeRequest(
          message['seq'] as int,
          message['method'],
          message['args'],
        ),
      );
    }
  }

  Future<void> _onBridgeRequest(int seq, dynamic method, dynamic args) async {
    Object? value;
    var ok = true;
    String? error;
    try {
      value = await _bridges!(
        method is String ? method : '',
        args is Map
            ? Map<String, dynamic>.from(args)
            : const <String, dynamic>{},
      );
    } catch (caught) {
      ok = false;
      error = '$caught';
    }
    if (_disposed) return;
    _post(
      ok
          ? {'seq': seq, 'ok': true, 'value': value}
          : {'seq': seq, 'ok': false, 'error': error},
    );
  }

  void _post(Map<String, dynamic> message) {
    try {
      _worker?.postMessage({'__ext__': message});
    } catch (_) {}
  }

  void _failAll(String message) {
    for (final completer in List.of(_pending.values)) {
      if (!completer.isCompleted) {
        completer.completeError(ExtProtocolException(message));
      }
    }
    _pending.clear();
  }
}
