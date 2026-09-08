// Transport abstraction for the DAP/1 hub core.
//
// The hub core is pure Dart: it never opens sockets. A [DapConnection]
// carries one client WebSocket (or an in-memory test pipe); the io entry
// point (`package:dap_hub/io.dart`) binds real dart:io WebSockets to it.

/// One client connection to the hub.
///
/// Inbound messages arrive on [messages] as [String] (text frames) or
/// [List]`<int>` (binary frames — the hub answers them with a `bad_frame`
/// error, per spec "text frames only"). The stream closing (done or
/// error) means the connection is gone.
abstract interface class DapConnection {
  /// Inbound frames. Completes when the connection dies.
  Stream<Object> get messages;

  /// Whether the connection can still accept outbound frames. Flips to
  /// false on close, write failure, or stream termination.
  bool get isOpen;

  /// Writes one text frame. Completes when the bytes are flushed to the
  /// underlying transport (OS socket buffer for the io binding), so a
  /// stalled peer applies real backpressure to the caller.
  Future<void> sendText(String text);

  /// Terminates the connection; idempotent.
  Future<void> close();
}
