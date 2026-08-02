/// The transport boundary for the MCP client: a message-level channel to a
/// running MCP server.
///
/// Unlike LSP (one byte-stream shape), MCP has two wire shapes — stdio
/// (newline-delimited JSON) and HTTP (POST per message) — so the transport
/// operates on decoded JSON-RPC messages instead of raw bytes. The stdio
/// framing glue ([McpStdioTransport]) is pure Dart over a [McpByteChannel];
/// the `dart:io` process channel lives in `io_mcp_transport.dart` and is
/// exported only from `lib/io.dart`. The HTTP transports
/// (`mcp_http_transport.dart`) are pure Dart over an injectable
/// `package:http` client, so they work on web hosts too.
library;

import 'dart:async';
import 'dart:convert';

import 'mcp_config.dart';
import 'mcp_framing.dart';

/// Thrown when an MCP server cannot be reached or spawned. The manager
/// converts this into the server's `failed` status — never a crash.
final class McpServerUnavailableException implements Exception {
  /// Creates an [McpServerUnavailableException].
  const McpServerUnavailableException(this.message, {this.cause});

  /// Human-readable description of the failure.
  final String message;

  /// The original error, when available.
  final Object? cause;

  @override
  String toString() => message;
}

/// A live message channel to an MCP server: JSON-RPC messages go out
/// through [send], decoded server messages arrive on [messages].
abstract interface class McpTransport {
  /// Decoded JSON-RPC messages from the server. The stream closing (normally
  /// or by error) means the connection is dead.
  Stream<Map<String, dynamic>> get messages;

  /// Sends one JSON-RPC message. For HTTP transports the returned future
  /// settles once the message was POSTed (transport-level failures are
  /// delivered as synthetic error responses on [messages] when the message
  /// was a request).
  Future<void> send(Map<String, dynamic> message);

  /// Completes when the connection dies, expectedly or not.
  Future<void> get closed;

  /// Closes the connection. Idempotent.
  Future<void> close();
}

/// Spawns/connects the transport for [server], running stdio processes in
/// [cwd]. Implementations must throw [McpServerUnavailableException] (not
/// return null) when the server cannot be started.
typedef McpTransportFactory =
    Future<McpTransport> Function(McpServerConfig server, String cwd);

/// The raw byte channel an [McpStdioTransport] frames: stdout bytes in,
/// stdin bytes out. The `dart:io` implementation wraps a spawned process;
/// tests substitute in-memory fakes.
abstract interface class McpByteChannel {
  /// Raw bytes from the server's stdout.
  Stream<List<int>> get messages;

  /// Writes raw (already framed) bytes to the server's stdin.
  void write(List<int> data);

  /// Completes with the server's exit code when the process ends.
  Future<int> get exitCode;

  /// Terminates the server process. Idempotent.
  void kill();
}

/// A stdio [McpTransport]: newline-delimited JSON-RPC over a
/// [McpByteChannel]. Malformed lines are skipped (a wrapper script's stdout
/// noise must not kill the reader); the process exiting closes the channel.
final class McpStdioTransport implements McpTransport {
  /// Creates an [McpStdioTransport] over [channel]. The read loop starts
  /// immediately.
  McpStdioTransport(this._channel) {
    _subscription = _channel.messages.listen(
      _onData,
      onError: (_) => _finish(),
      onDone: _finish,
    );
    unawaited(
      _channel.exitCode.then((_) => _finish(), onError: (_) => _finish()),
    );
  }

  final McpByteChannel _channel;
  final _framer = McpLineFramer();
  final _messages = StreamController<Map<String, dynamic>>();
  final _closed = Completer<void>();
  StreamSubscription<List<int>>? _subscription;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (_closed.isCompleted) return;
    try {
      _channel.write(McpLineFramer.encode(jsonEncode(message)));
    } on Object {
      // The process is gone; the exit watcher reports the failure.
    }
  }

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> close() async {
    _channel.kill();
    _finish();
  }

  void _onData(List<int> chunk) {
    _framer.push(chunk);
    for (final line in _framer.drain()) {
      final Object? message;
      try {
        message = jsonDecode(line);
      } on Object {
        continue; // non-protocol noise: skip, later lines still parse
      }
      if (message is Map<String, dynamic> && !_messages.isClosed) {
        _messages.add(message);
      }
    }
  }

  void _finish() {
    if (_closed.isCompleted) return;
    _closed.complete();
    unawaited(_subscription?.cancel());
    unawaited(_messages.close());
  }
}
