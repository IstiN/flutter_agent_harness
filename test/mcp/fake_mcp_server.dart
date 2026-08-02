/// A fake MCP server for tests: an in-memory message-level [McpTransport]
/// pair plus a scriptable JSON-RPC peer.
///
/// The fake answers `initialize` automatically, serves a scripted tool list
/// and scripted `tools/call` results, logs every client request and
/// notification for assertions, and can simulate a crash or send
/// server-initiated requests. Mirrored after `test/lsp/fake_lsp_server.dart`
/// (message-level instead of byte-level: MCP transports deliver decoded
/// JSON-RPC messages).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The client-facing end of a [FakeMcpServer].
final class FakeMcpTransport implements McpTransport {
  // Synchronous controllers: a client send reaches the fake's listener
  // before the sending call returns, so tests assert deterministically.
  final _incoming = StreamController<Map<String, dynamic>>(sync: true);
  final _outgoing = StreamController<Map<String, dynamic>>(sync: true);
  final _closed = Completer<void>();

  @override
  Stream<Map<String, dynamic>> get messages => _incoming.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (!_outgoing.isClosed) _outgoing.add(message);
  }

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
    await _close();
  }

  Future<void> _close() async {
    await _incoming.close();
    await _outgoing.close();
  }
}

/// A scriptable fake MCP server over a [FakeMcpTransport].
final class FakeMcpServer {
  /// Creates a [FakeMcpServer] advertising [tools].
  FakeMcpServer({List<Map<String, dynamic>>? tools, this.serverInfo})
    : tools = tools ?? const [] {
    transport = FakeMcpTransport();
    _subscription = transport._outgoing.stream.listen(_dispatch);
  }

  /// The transport the client connects to.
  late final FakeMcpTransport transport;

  /// The tool list served by `tools/list` (MCP wire shape).
  List<Map<String, dynamic>> tools;

  /// The `serverInfo` answered to `initialize`.
  final Map<String, dynamic>? serverInfo;

  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// Client requests received (method + params), in order.
  final requests = <({String method, Object? params})>[];

  /// Client notifications received (method + params), in order.
  final notifications = <({String method, Object? params})>[];

  /// Client response envelopes (answers to server-initiated requests).
  final responses = <Map<String, dynamic>>[];

  /// Scripted handler for non-handshake requests (e.g. `tools/call`).
  /// Return a [FakeMcpError] to answer with a JSON-RPC error envelope.
  /// When null, `tools/list` serves [tools] and other requests get a
  /// default text result.
  Object? Function(String method, Object? params)? requestHandler;

  /// When false, client requests are logged but never answered (timeout
  /// and crash tests).
  bool autoRespond = true;

  /// How many times `initialize` was called.
  int initializeCount = 0;

  void _dispatch(Map<String, dynamic> message) {
    final method = message['method'];
    final id = message['id'];
    if (method is String && id != null) {
      _handleClientRequest(id, method, message['params']);
    } else if (method is String) {
      notifications.add((method: method, params: message['params']));
    } else if (id != null) {
      responses.add(message);
    }
  }

  void _handleClientRequest(Object id, String method, Object? params) {
    requests.add((method: method, params: params));
    if (!autoRespond) return;
    final Object? result;
    if (requestHandler != null) {
      result = requestHandler!(method, params);
    } else if (method == 'initialize') {
      initializeCount += 1;
      result = {
        'protocolVersion': mcpProtocolVersion,
        'capabilities': const <String, dynamic>{},
        if (serverInfo != null) 'serverInfo': serverInfo,
      };
    } else if (method == 'tools/list') {
      result = {'tools': tools};
    } else if (method == 'tools/call') {
      result = {
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
      };
    } else {
      result = null;
    }
    if (result is FakeMcpError) {
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': result.code, 'message': result.message},
      });
    } else {
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});
    }
  }

  void _send(Map<String, dynamic> message) {
    if (!transport._incoming.isClosed) transport._incoming.add(message);
  }

  /// Sends a raw server-initiated message (request or notification).
  void sendMessage(Map<String, dynamic> message) => _send(message);

  /// Simulates a server crash: both streams close.
  Future<void> simulateCrash() => transport.close();

  /// Tears the fake down.
  Future<void> dispose() async {
    await transport.close();
    await _subscription?.cancel();
  }
}

/// Return from [FakeMcpServer.requestHandler] to answer a request with a
/// JSON-RPC error envelope instead of a result.
final class FakeMcpError {
  /// Creates a [FakeMcpError].
  const FakeMcpError(this.message, {this.code = -32603});

  /// The error message.
  final String message;

  /// The JSON-RPC error code.
  final int code;
}

/// A [McpTransportFactory] that spawns [FakeMcpServer]s, recording each one
/// in [spawned]. [onSpawn] customizes a server before the client connects;
/// [failNext] makes the next spawn throw [McpServerUnavailableException].
final class FakeMcpServerFactory {
  /// The servers spawned so far, in order (one per connect attempt).
  final spawned = <FakeMcpServer>[];

  /// Customizes each spawned server (scripting) before it is returned.
  void Function(FakeMcpServer server)? onSpawn;

  /// When set, the next spawn throws this instead of connecting.
  Object? failNext;

  /// When set, EVERY spawn throws this (persistent startup failure).
  Object? failAlways;

  /// The factory callback.
  Future<McpTransport> call(McpServerConfig server, String cwd) async {
    final persistent = failAlways;
    if (persistent != null) throw persistent;
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    final fake = FakeMcpServer();
    onSpawn?.call(fake);
    spawned.add(fake);
    return fake.transport;
  }
}
