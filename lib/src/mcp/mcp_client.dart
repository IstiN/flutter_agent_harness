/// The MCP JSON-RPC client: a pure-Dart protocol layer over a
/// message-level [McpTransport] (same code shape as the LSP client in
/// `lib/src/lsp/lsp_client.dart`, reduced to the three MCP flows the agent
/// uses).
///
/// Covers the `initialize`/`notifications/initialized` handshake,
/// `tools/list` (cursor pagination followed), and `tools/call` with
/// per-request timeouts. Server-initiated requests get a `-32601`
/// method-not-found reply (the harness supports no client capabilities);
/// server notifications are ignored. A dead transport rejects every pending
/// request.
library;

import 'dart:async';

import 'mcp_transport.dart';

/// Client lifecycle state (mirrors `LspClientStatus`).
enum McpClientStatus {
  /// `initialize` handshake in flight.
  connecting,

  /// Handshake complete; requests may be sent.
  ready,

  /// The connection is dead (transport close or [McpClient.close]).
  closed,
}

/// Thrown when an MCP request fails: server error response, timeout, or a
/// dead connection.
final class McpRequestException implements Exception {
  /// Creates an [McpRequestException].
  const McpRequestException(this.message);

  /// Human-readable description.
  final String message;

  @override
  String toString() => message;
}

/// The MCP protocol revision the client advertises.
const mcpProtocolVersion = '2025-06-18';

/// The client identity advertised in `initialize`.
const mcpClientInfo = {'name': 'flutter-agent-harness', 'version': '0.1.0'};

/// One tool advertised by `tools/list`.
final class McpToolInfo {
  /// Creates an [McpToolInfo].
  const McpToolInfo({required this.name, this.description, this.inputSchema});

  /// The server-local tool name.
  final String name;

  /// The tool description, when the server provides one.
  final String? description;

  /// The JSON schema for the tool's arguments (passed through verbatim).
  final Map<String, dynamic>? inputSchema;
}

/// The result of the `initialize` handshake.
final class McpInitializeResult {
  /// Creates an [McpInitializeResult].
  const McpInitializeResult({this.serverName, this.serverVersion});

  /// The server's self-reported name.
  final String? serverName;

  /// The server's self-reported version.
  final String? serverVersion;
}

/// A live connection to one MCP server.
final class McpClient {
  /// Creates an [McpClient] over [transport]. The read loop starts
  /// immediately; call [initialize] before issuing tool requests.
  McpClient({
    required this.serverName,
    required this.transport,
    this.requestTimeout = const Duration(seconds: 60),
  }) {
    _subscription = transport.messages.listen(
      _dispatch,
      onError: (_) => _teardown('MCP connection error'),
      onDone: () => _teardown('MCP connection closed'),
    );
    unawaited(
      transport.closed.then(
        (_) => _teardown('MCP connection closed'),
        onError: (_) => _teardown('MCP connection closed'),
      ),
    );
  }

  /// The configured name of the server this client talks to.
  final String serverName;

  /// The message channel to the server.
  final McpTransport transport;

  /// Default timeout for requests without an explicit one.
  final Duration requestTimeout;

  final _pending = <Object, Completer<Object?>>{};
  StreamSubscription<Map<String, dynamic>>? _subscription;
  int _nextId = 0;

  /// Lifecycle state.
  McpClientStatus status = McpClientStatus.connecting;

  /// Completes when the connection dies, expectedly or not.
  Future<void> get closed => _closed.future;
  final _closed = Completer<void>();

  // -------------------------------------------------------------------------
  // Handshake
  // -------------------------------------------------------------------------

  /// Runs the `initialize`/`notifications/initialized` handshake. Throws
  /// [McpRequestException] on failure.
  Future<McpInitializeResult> initialize({Duration? timeout}) async {
    final result = await request('initialize', {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': const <String, dynamic>{},
      'clientInfo': mcpClientInfo,
    }, timeout: timeout ?? requestTimeout);
    if (result is! Map<String, dynamic>) {
      throw const McpRequestException('Failed to initialize MCP: no response');
    }
    status = McpClientStatus.ready;
    notify('notifications/initialized', const <String, dynamic>{});
    final serverInfo = result['serverInfo'];
    if (serverInfo is Map<String, dynamic>) {
      return McpInitializeResult(
        serverName: serverInfo['name'] as String?,
        serverVersion: serverInfo['version'] as String?,
      );
    }
    return const McpInitializeResult();
  }

  // -------------------------------------------------------------------------
  // Requests and notifications
  // -------------------------------------------------------------------------

  /// Sends a request and awaits its result. Throws [McpRequestException]
  /// on a server error response, on [timeout], or when the connection dies
  /// mid-flight.
  Future<Object?> request(String method, Object? params, {Duration? timeout}) {
    if (status == McpClientStatus.closed) {
      return Future.error(
        McpRequestException('MCP connection is closed ($method)'),
      );
    }
    final id = ++_nextId;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    unawaited(transport.send(_encode(id, method, params)));

    final effectiveTimeout = timeout ?? requestTimeout;
    Timer? timer;
    timer = Timer(effectiveTimeout, () {
      if (_pending.remove(id) != null) {
        completer.completeError(
          McpRequestException(
            'MCP request $method to server "$serverName" timed out after '
            '${effectiveTimeout.inMilliseconds}ms. The server may be hung; '
            'consider raising mcp.toolCallTimeoutMs.',
          ),
        );
      }
    });
    return completer.future.whenComplete(() => timer?.cancel());
  }

  Map<String, dynamic> _encode(Object id, String method, Object? params) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  };

  /// Sends a notification (no response expected).
  void notify(String method, Object? params) {
    if (status == McpClientStatus.closed) return;
    unawaited(
      transport.send({'jsonrpc': '2.0', 'method': method, 'params': params}),
    );
  }

  // -------------------------------------------------------------------------
  // Tools
  // -------------------------------------------------------------------------

  /// Lists the server's tools, following `nextCursor` pagination.
  Future<List<McpToolInfo>> listTools({Duration? timeout}) async {
    final tools = <McpToolInfo>[];
    String? cursor;
    do {
      final result = await request('tools/list', {
        'cursor': ?cursor,
      }, timeout: timeout);
      if (result is! Map<String, dynamic>) break;
      tools.addAll(_parseToolEntries(result['tools']));
      final next = result['nextCursor'];
      cursor = next is String && next.isNotEmpty ? next : null;
    } while (cursor != null);
    return tools;
  }

  List<McpToolInfo> _parseToolEntries(Object? list) {
    if (list is! List) return const [];
    return [
      for (final entry in list)
        if (entry is Map<String, dynamic> &&
            entry['name'] is String &&
            (entry['name'] as String).isNotEmpty)
          McpToolInfo(
            name: entry['name'] as String,
            description: entry['description'] as String?,
            inputSchema: entry['inputSchema'] is Map<String, dynamic>
                ? entry['inputSchema'] as Map<String, dynamic>
                : null,
          ),
    ];
  }

  /// Calls [tool] with [arguments]; the raw result map (`content`,
  /// `isError`, `structuredContent`, ...) is returned for the tool wrapper
  /// to interpret.
  Future<Map<String, dynamic>> callTool(
    String tool,
    Map<String, dynamic> arguments, {
    Duration? timeout,
  }) async {
    final result = await request('tools/call', {
      'name': tool,
      'arguments': arguments,
    }, timeout: timeout);
    if (result is Map<String, dynamic>) return result;
    return const {};
  }

  // -------------------------------------------------------------------------
  // Incoming message dispatch
  // -------------------------------------------------------------------------

  void _dispatch(Map<String, dynamic> message) {
    // A message carrying `method` is server-originated: a request when it
    // also has an `id`, a notification otherwise (LSP-client disambiguation:
    // server request ids live in their own id space).
    final method = message['method'];
    if (method is String) {
      final id = message['id'];
      if (id != null) {
        unawaited(
          transport.send({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'Method not found: $method'},
          }),
        );
      }
      return; // server notifications are ignored
    }
    final id = message['id'];
    if (id != null) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      final error = message['error'];
      if (error is Map<String, dynamic>) {
        pending.completeError(
          McpRequestException('MCP error: ${error['message']}'),
        );
      } else {
        pending.complete(message['result']);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  /// Rejects all pending requests and marks the client closed (idempotent).
  void _teardown(String reason) {
    if (status != McpClientStatus.closed) {
      status = McpClientStatus.closed;
      final error = McpRequestException(reason);
      for (final pending in _pending.values) {
        if (!pending.isCompleted) pending.completeError(error);
      }
      _pending.clear();
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  /// Closes the connection. Always safe to call.
  Future<void> close() async {
    _teardown('MCP client closed');
    await transport.close();
    await _subscription?.cancel();
  }
}
