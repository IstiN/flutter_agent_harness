// Per-connection client state and the serialized write pump.
//
// Port of the Go relay.go `client` + writePump. Dart is single-isolate,
// so the pump is a microtask/async drain over an in-memory outbox; the
// io transport's sendText awaits the OS-level flush, which gives the
// queued-bytes cap the same backpressure semantics as the Go original.

import 'dart:async';
import 'dart:convert';

import 'connection.dart';

/// Per-client outbound byte cap; overflow drops the connection (slow
/// consumer shedding — the Go hub's maxQueuedBytes).
const maxQueuedBytes = 4 << 20;

/// One queued outbound frame.
final class _OutFrame {
  const _OutFrame(this.text, {this.fatal = false, this.onWritten});

  final String text;

  /// Fatal frames (hello rejects) close the connection once written.
  final bool fatal;

  /// Completed after a fatal frame was written and the close issued.
  final Completer<void>? onWritten;
}

/// How the connection authenticated at the upgrade (port of authKind).
enum DapAuthKind {
  /// Bearer matched the master secret (enrollment-capable).
  master,

  /// Bearer matched an issued client secret (bound to [boundName]).
  agent,
}

/// One live client connection: identity fields plus the write pump.
final class ClientSession {
  ClientSession({
    required this.connection,
    required this.authKind,
    this.boundName = '',
    this.maxQueued = maxQueuedBytes,
  });

  final DapConnection connection;
  final DapAuthKind authKind;

  /// [DapAuthKind.agent] only: the name the issued secret is bound to.
  final String boundName;

  /// Test-tunable queued-bytes cap.
  final int maxQueued;

  // Authenticated identity (set by the hub on welcome).
  bool authed = false;
  String agentId = '';
  String pubkey = '';
  String x25519 = '';
  String name = '';

  final List<_OutFrame> _outbox = [];
  var _queuedBytes = 0;
  var _pumping = false;
  var _closed = false;

  /// Queued-but-unflushed outbound bytes (test introspection).
  int get queuedBytes => _queuedBytes;

  /// Whether this session can still accept frames.
  bool get isClosed => _closed || !connection.isOpen;

  /// Queues [frame] for the pump; false when the session is gone or the
  /// queued-bytes cap is crossed (the connection is shed in that case).
  /// A [fatal] frame closes the connection after it is written.
  bool sendFrame(Map<String, Object?> frame, {bool fatal = false}) {
    final text = jsonEncode(frame);
    if (isClosed) return false;
    if (_queuedBytes + text.length > maxQueued) {
      unawaited(close());
      return false;
    }
    _queuedBytes += text.length;
    _outbox.add(_OutFrame(text, fatal: fatal));
    _pump();
    return true;
  }

  /// Queues a fatal error frame and completes once it was written and
  /// the close issued (the Go `reject` ordering guarantee).
  Future<void> reject(Map<String, Object?> frame) {
    final text = jsonEncode(frame);
    final done = Completer<void>();
    if (isClosed) {
      done.complete();
      return done.future;
    }
    _queuedBytes += text.length;
    _outbox.add(_OutFrame(text, fatal: true, onWritten: done));
    _pump();
    return done.future;
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    while (_outbox.isNotEmpty) {
      final frame = _outbox.first;
      if (isClosed) {
        _discardAll();
        break;
      }
      try {
        await connection.sendText(frame.text);
      } on Object {
        _closed = true;
        _discardAll();
        break;
      }
      _outbox.removeAt(0);
      _queuedBytes -= frame.text.length;
      if (frame.fatal) {
        await close();
        frame.onWritten?.complete();
        break;
      }
    }
    _pumping = false;
  }

  void _discardAll() {
    for (final frame in _outbox) {
      frame.onWritten?.complete();
    }
    _outbox.clear();
    // queuedBytes intentionally keeps its last accounting value: it is
    // the outstanding-at-drop figure the Go test asserts against.
  }

  /// Terminates the connection; idempotent.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await connection.close();
  }
}
