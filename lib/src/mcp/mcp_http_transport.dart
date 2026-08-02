/// HTTP transports for remote MCP servers, pure Dart over an injectable
/// `package:http` client (web-safe — only stdio needs a process host).
///
/// - [McpStreamableHttpTransport] — the current streamable-HTTP transport:
///   every JSON-RPC message is a POST to the single endpoint with
///   `Accept: application/json, text/event-stream`; the server answers with
///   a JSON body, an SSE stream of `data:` frames, or a bare `202` (for
///   notifications). The `mcp-session-id` response header is captured and
///   replayed on later POSTs.
/// - [McpSseTransport] — the legacy HTTP+SSE transport: a long-lived GET
///   stream whose first `endpoint` event names the POST URL; server
///   messages arrive as `message` events on the GET stream.
///
/// Transport-level failures on a REQUEST (HTTP error status, network
/// exception) are delivered as a synthetic JSON-RPC error response so the
/// pending call rejects immediately instead of waiting out its timeout.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_config.dart';
import 'mcp_transport.dart';

/// One parsed SSE event: the `event` name (`message` when absent) and the
/// joined `data:` payload.
typedef SseEvent = ({String event, String data});

/// Incrementally parses a UTF-8 SSE byte stream into [SseEvent]s.
final class SseParser {
  final _buffer = StringBuffer();
  String _event = 'message';
  final _data = StringBuffer();

  /// Feeds [chunk]; returns every event completed by it.
  List<SseEvent> push(List<int> chunk) {
    _buffer.write(utf8.decode(chunk));
    final events = <SseEvent>[];
    while (true) {
      final newline = _buffer.toString().indexOf('\n');
      if (newline < 0) break;
      var line = _buffer.toString().substring(0, newline);
      final rest = _buffer.toString().substring(newline + 1);
      _buffer
        ..clear()
        ..write(rest);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final event = _consumeLine(line);
      if (event != null) events.add(event);
    }
    return events;
  }

  /// Handles one SSE line; returns a completed event on a blank line.
  SseEvent? _consumeLine(String line) {
    if (line.isEmpty) return _consumeBlankLine();
    if (line.startsWith(':')) return null; // comment / heartbeat
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _data
          ..write(value)
          ..write('\n');
      // id/retry are irrelevant to MCP framing.
    }
    return null;
  }

  SseEvent? _consumeBlankLine() {
    if (_data.isEmpty) {
      _event = 'message';
      return null;
    }
    var data = _data.toString();
    if (data.endsWith('\n')) data = data.substring(0, data.length - 1);
    final event = (event: _event, data: data);
    _event = 'message';
    _data.clear();
    return event;
  }
}

/// Shared base for the HTTP transports: the outgoing message stream,
/// synthetic error responses, and close bookkeeping.
abstract base class _McpHttpTransportBase implements McpTransport {
  _McpHttpTransportBase(http.Client? client)
    : _client = client ?? http.Client(),
      _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final _messages = StreamController<Map<String, dynamic>>();
  final _closed = Completer<void>();

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> close() async {
    if (_closed.isCompleted) return;
    _closed.complete();
    if (_ownsClient) _client.close();
    // Never awaited: StreamController.close()'s future only completes when a
    // listener consumes the done event — with no listener it hangs forever.
    unawaited(_messages.close());
  }

  /// Emits a decoded server message.
  void emit(Object? decoded) {
    if (decoded is Map<String, dynamic> && !_messages.isClosed) {
      _messages.add(decoded);
    }
  }

  /// Emits a synthetic JSON-RPC error response for the request [id] after a
  /// transport-level failure, so the pending call rejects promptly.
  void emitTransportError(Object? id, String message) {
    if (id == null) return;
    emit({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': -32603, 'message': message},
    });
  }

  /// Decodes SSE `data:` frames into messages.
  void emitSseData(String data) {
    try {
      emit(jsonDecode(data));
    } on Object {
      // Malformed frame: skip, later frames still parse.
    }
  }
}

/// The streamable-HTTP MCP transport (one endpoint, POST per message).
final class McpStreamableHttpTransport extends _McpHttpTransportBase {
  /// Creates a transport for [server]. [client] defaults to a fresh
  /// `package:http` client (owned and closed with the transport).
  McpStreamableHttpTransport(McpHttpServerConfig server, {http.Client? client})
    : _server = server,
      super(client);

  final McpHttpServerConfig _server;
  String? _sessionId;

  @override
  Future<void> send(Map<String, dynamic> message) async {
    if (_closed.isCompleted) return;
    final request = http.Request('POST', Uri.parse(_server.url));
    request.headers.addAll({
      ..._server.headers,
      'content-type': 'application/json',
      'accept': 'application/json, text/event-stream',
      'mcp-session-id': ?_sessionId,
    });
    request.body = jsonEncode(message);
    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } on Object catch (error) {
      emitTransportError(message['id'], 'MCP HTTP request failed: $error');
      return;
    }
    _sessionId ??= response.headers['mcp-session-id'];
    if (response.statusCode == 202 || response.statusCode == 204) {
      return; // notification/response accepted, no body
    }
    if (response.statusCode >= 400) {
      await _failWithBody(message['id'], response);
      return;
    }
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('text/event-stream')) {
      await _consumeSseBody(response.stream);
    } else {
      await _consumeJsonBody(response.stream);
    }
  }

  Future<void> _failWithBody(Object? id, http.StreamedResponse response) async {
    final body = await response.stream.bytesToString();
    emitTransportError(
      id,
      'MCP server answered HTTP ${response.statusCode}'
      '${body.isEmpty ? '' : ': ${body.length > 300 ? body.substring(0, 300) : body}'}',
    );
  }

  Future<void> _consumeSseBody(http.ByteStream stream) async {
    final parser = SseParser();
    await for (final chunk in stream) {
      for (final event in parser.push(chunk)) {
        emitSseData(event.data);
      }
    }
  }

  Future<void> _consumeJsonBody(http.ByteStream stream) async {
    final body = await stream.bytesToString();
    if (body.trim().isEmpty) return;
    try {
      emit(jsonDecode(body));
    } on Object {
      // A non-JSON success body carries nothing for the client.
    }
  }
}

/// The legacy HTTP+SSE MCP transport (GET stream + POST channel).
final class McpSseTransport extends _McpHttpTransportBase {
  McpSseTransport._(McpHttpServerConfig server, {http.Client? client})
    : _server = server,
      super(client);

  final McpHttpServerConfig _server;
  final _endpointReady = Completer<Uri>();
  Uri? _postUri;

  /// Opens the GET stream and waits for the server's `endpoint` event.
  /// Throws [McpServerUnavailableException] when the stream cannot be
  /// opened or the endpoint never arrives.
  static Future<McpSseTransport> connect(
    McpHttpServerConfig server, {
    http.Client? client,
    Duration endpointTimeout = const Duration(seconds: 30),
  }) async {
    final transport = McpSseTransport._(server, client: client);
    final request = http.Request('GET', Uri.parse(server.url));
    request.headers.addAll({...server.headers, 'accept': 'text/event-stream'});
    final http.StreamedResponse response;
    try {
      response = await transport._client.send(request);
    } on Object catch (error) {
      throw McpServerUnavailableException(
        'cannot open MCP SSE stream ${server.url}: $error',
        cause: error,
      );
    }
    if (response.statusCode != 200) {
      throw McpServerUnavailableException(
        'MCP SSE stream ${server.url} answered HTTP ${response.statusCode}',
      );
    }
    transport._readGetStream(response.stream);
    await transport._endpointReady.future.timeout(
      endpointTimeout,
      onTimeout: () => throw McpServerUnavailableException(
        'MCP SSE stream ${server.url} sent no endpoint event',
      ),
    );
    return transport;
  }

  void _readGetStream(Stream<List<int>> stream) {
    final parser = SseParser();
    stream.listen(
      (chunk) {
        for (final event in parser.push(chunk)) {
          _handleGetEvent(event);
        }
      },
      onError: (_) => _failEndpointWait(
        'MCP SSE stream ${_server.url} failed before the endpoint event',
      ),
      onDone: () => _failEndpointWait(
        'MCP SSE stream ${_server.url} closed before the endpoint event',
      ),
    );
  }

  void _handleGetEvent(SseEvent event) {
    if (event.event != 'endpoint') {
      emitSseData(event.data);
      return;
    }
    _postUri = Uri.parse(_server.url).resolve(event.data);
    if (!_endpointReady.isCompleted) {
      _endpointReady.complete(_postUri);
    }
  }

  void _failEndpointWait(String message) {
    if (!_endpointReady.isCompleted) {
      _endpointReady.completeError(McpServerUnavailableException(message));
    }
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> send(Map<String, dynamic> message) async {
    final uri = _postUri;
    if (uri == null) {
      emitTransportError(message['id'], 'MCP SSE transport has no POST URL');
      return;
    }
    final request = http.Request('POST', uri);
    request.headers.addAll({
      ..._server.headers,
      'content-type': 'application/json',
    });
    request.body = jsonEncode(message);
    try {
      final response = await _client.send(request);
      if (response.statusCode >= 400) {
        emitTransportError(
          message['id'],
          'MCP SSE POST answered HTTP ${response.statusCode}',
        );
      }
      await response.stream.drain<void>();
    } on Object catch (error) {
      emitTransportError(message['id'], 'MCP SSE POST failed: $error');
    }
  }
}

/// Opens the transport for a remote [server] (both HTTP kinds are pure
/// Dart, so hosts without process support still get remote servers).
Future<McpTransport> httpMcpTransport(
  McpHttpServerConfig server, {
  http.Client? client,
}) {
  return switch (server.transport) {
    McpHttpTransportKind.streamableHttp => Future.value(
      McpStreamableHttpTransport(server, client: client),
    ),
    McpHttpTransportKind.sse => McpSseTransport.connect(server, client: client),
  };
}
